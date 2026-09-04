#!/usr/bin/env bash
# Hint-based quick select, in the spirit of tmux-fingers / WezTerm's quick
# select. Overlays the whole window (all panes at once) with dimmed text,
# labels every path, URL, hash, IP, ... with a hint letter, and copies the one
# whose hint you press.
#
#   lowercase hint  copy to the tmux buffer and the system clipboard
#   uppercase hint  copy, then paste it into the active pane
#   Esc / C-c        cancel
#
# Modes:
#   quick-select.sh [pane-id]        launcher: opens the overlay popup
#   quick-select.sh --hints <pane>   the overlay itself (runs inside the popup)
#
# display-popup does not expand #{...} in its command, so the launcher resolves
# the pane and bakes it into the popup command.

set -uo pipefail

self=$(readlink -f "$0" 2>/dev/null || echo "$0")

# What counts as selectable. Kept in one place; used as a dynamic regex by awk,
# so it must stay POSIX ERE (no \b, no \d).
QS_RE='(https?|ftp|file|ssh|git)://[^][:space:]"'"'"'`<>|(){}]+'
QS_RE=$QS_RE'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+:[^[:space:]"'"'"'`<>|(){}]+'
QS_RE=$QS_RE'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
QS_RE=$QS_RE'|(~|\.{1,2})?[A-Za-z0-9._@%+-]*(/[A-Za-z0-9._@%+:#-]+)+/?'
# Rust item paths
QS_RE=$QS_RE'|[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)+'
QS_RE=$QS_RE'|[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?'
QS_RE=$QS_RE'|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
# jujutsu change IDs are reverse-hex digits (k-z only), so they never collide
# with the git-hash rule below.
QS_RE=$QS_RE'|[k-z]{8,32}'
QS_RE=$QS_RE'|[0-9a-f]{7,40}'
export QS_RE

# ---------------------------------------------------------------- launcher ---
if [ "${1:-}" != --hints ]; then
  pane=${1:-${TMUX_PANE:-$(tmux display-message -p '#{pane_id}')}}
  read -r width height status position <<<"$(tmux display-message -p -t "$pane" \
    '#{window_width} #{window_height} #{status} #{status-position}')"

  # -y is the row *below* the popup (it occupies [y - h, y - 1]), so the window
  # area has to be offset past a status line sitting above it.
  case $status in
    off) lines=0 ;;
    on)  lines=1 ;;
    [0-9]*) lines=$status ;;
    *)   lines=1 ;;
  esac
  [ "$position" = top ] || lines=0
  bottom=$((lines + height))

  tmux display-popup -B -E -t "$pane" -x 0 -y "$bottom" -w "$width" -h "$height" \
    "$(printf '%q %q %q' "$self" --hints "$pane")"
  exit $?
fi

# ----------------------------------------------------------------- overlay ---
pane=$2
map=$(mktemp "${TMPDIR:-/tmp}/tmux-quick-select.XXXXXX")
trap 'rm -f "$map"' EXIT

window=$(tmux display-message -p -t "$pane" '#{window_id}')

# Border glyphs: vertical, horizontal, then the corners and tees, matching the
# window's pane-border-lines setting.
case $(tmux show-options -gv pane-border-lines 2>/dev/null) in
  heavy)  glyphs='┃ ━ ┏ ┓ ┗ ┛ ┣ ┫ ┻ ┳ ╋' ;;
  double) glyphs='║ ═ ╔ ╗ ╚ ╝ ╠ ╣ ╩ ╦ ╬' ;;
  simple) glyphs='| - + + + + + + + + +' ;;
  *)      glyphs='│ ─ ┌ ┐ └ ┘ ├ ┤ ┴ ┬ ┼' ;;
esac
read -r b_v b_h b_dr b_dl b_ur b_ul b_udr b_udl b_ulr b_dlr b_all <<<"$glyphs"

# Rebuild the window: every pane's visible text placed at its own offset. Panes
# scrolled up in copy mode contribute what is on screen there (scroll_position
# is empty outside copy mode, so it is queried on its own).
compose() {
  tmux list-panes -t "$window" \
    -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}' |
  while read -r id left top pw ph; do
    printf 'P\t%s\t%s\t%s\t%s\t%s\n' "$id" "$left" "$top" "$pw" "$ph"
    scroll=$(tmux display-message -p -t "$id" '#{scroll_position}')
    if [ -n "$scroll" ] && [ "$scroll" -gt 0 ] 2>/dev/null; then
      tmux capture-pane -p -t "$id" -S "-$scroll" -E "$((ph - 1 - scroll))"
    else
      tmux capture-pane -p -t "$id"
    fi | sed 's/^/L\t/'
  done
}

overlay=$(compose | awk -v MAP="$map" \
  -v B_V="$b_v" -v B_H="$b_h" -v B_DR="$b_dr" -v B_DL="$b_dl" -v B_UR="$b_ur" \
  -v B_UL="$b_ul" -v B_UDR="$b_udr" -v B_UDL="$b_udl" -v B_ULR="$b_ulr" \
  -v B_DLR="$b_dlr" -v B_ALL="$b_all" '
BEGIN {
  FS   = "\t"
  ORS  = ""
  RE   = ENVIRON["QS_RE"]
  # Home row first, then the rest of the alphabet.
  ALPH = "asdfjklghqwertyuiopzxcvbnm"
  DIM   = "\033[38;5;244m"
  HIT   = "\033[38;5;110m"
  HINT  = "\033[1;38;5;232;48;5;215m"
  RESET = "\033[0m"
}

# Each pane line is drawn where tmux drew it, using absolute cursor moves, and
# is never padded. That keeps wide characters (emoji, CJK) harmless: the
# terminal measures them exactly as tmux did, and nothing can reflow.
function at(row, col) { return sprintf("\033[%d;%dH", row + 1, col + 1) }

# Border glyph for a cell, from its up/down/left/right connections.
function glyph(m) {
  if (m == 10) return B_DR
  if (m == 6)  return B_DL
  if (m == 9)  return B_UR
  if (m == 5)  return B_UL
  if (m == 11) return B_UDR
  if (m == 7)  return B_UDL
  if (m == 13) return B_ULR
  if (m == 14) return B_DLR
  if (m == 15) return B_ALL
  if (m == 4 || m == 8 || m == 12) return B_H
  return B_V
}

$1 == "P" {
  np++
  pid[np] = $2; pleft[np] = $3; ptop[np] = $4; pwid[np] = $5; phgt[np] = $6
  prow = 0
  next
}
$1 == "L" {
  nl++
  ltext[nl] = substr($0, 3)
  lrow[nl]  = ptop[np] + prow
  lcol[nl]  = pleft[np]
  prow++
  next
}

END {
  # Collect matches, remembering the window row/column of each line they sit on.
  n = 0
  for (j = 1; j <= nl; j++) {
    s = ltext[j]; pos = 1
    while (pos <= length(s)) {
      rest = substr(s, pos)
      if (!match(rest, RE)) break
      st  = pos + RSTART - 1
      len = RLENGTH
      pos = st + (len > 0 ? len : 1)
      txt = substr(s, st, len)
      # Char just past the raw match, checked before trailing punctuation is
      # trimmed off (after trimming it would only ever be that punctuation).
      next_ch = substr(s, st + len, 1)
      while (len > 1 && substr(txt, len, 1) ~ /[.,:;")'"'"']/) { len--; txt = substr(txt, 1, len) }
      prev = (st > 1) ? substr(s, st - 1, 1) : " "
      # A match butting up against a word character on either side is a
      # fragment, not a token: e.g. a capped rule like the git-hash one would
      # otherwise offer the first 40 chars of a longer hex-looking word.
      if (len >= 2 && prev !~ /[A-Za-z0-9_]/ && next_ch !~ /[A-Za-z0-9_]/) {
        n++; mline[n] = j; mpos[n] = st; mlen[n] = len; mtxt[n] = txt
      }
    }
  }
  if (n == 0) { print "NONE" > MAP; exit }

  # Order matches bottom-right first, so the newest output gets the easiest
  # hints regardless of the order tmux lists panes in.
  for (i = 1; i <= n; i++) { ord[i] = i; key[i] = lrow[mline[i]] * 100000 + lcol[mline[i]] + mpos[i] }
  for (i = 2; i <= n; i++) {
    v = ord[i]; k = key[v]; jj = i - 1
    while (jj >= 1 && key[ord[jj]] < k) { ord[jj + 1] = ord[jj]; jj-- }
    ord[jj + 1] = v
  }

  # Identical text shares one hint, so repeated tokens do not burn letters.
  uniq = 0
  for (i = 1; i <= n; i++) if (!(mtxt[ord[i]] in seen)) seen[mtxt[ord[i]]] = ++uniq

  # Keep as many hints single-letter as possible: only enough trailing letters
  # are given up as two-letter prefixes to cover what is left over, and those
  # are used round-robin so consecutive two-letter hints start differently.
  A = length(ALPH)
  if (uniq <= A) {
    singles = uniq; prefixes = 0
  } else {
    prefixes = int((uniq - A + A - 2) / (A - 1))
    if (prefixes > A) prefixes = A
    singles = A - prefixes
  }
  for (k = 1; k <= singles; k++) label[k] = substr(ALPH, k, 1)
  m = 0
  for (k = singles + 1; k <= uniq; k++) {
    if (m >= prefixes * A) break
    label[k] = substr(ALPH, singles + (m % prefixes) + 1, 1) substr(ALPH, int(m / prefixes) + 1, 1)
    m++
  }
  for (t in seen) if (label[seen[t]] != "") printf "%s\t%s\n", label[seen[t]], t > MAP
  for (i = 1; i <= n; i++) hint[i] = label[seen[mtxt[i]]]

  # Pane borders, so the overlay looks like the window it covers. Cells are
  # collected first, then drawn with the glyph their connections call for, which
  # is how the tees and crosses between panes come out right.
  for (p = 1; p <= np; p++) {
    if (pleft[p] > 0)
      for (r = ptop[p]; r < ptop[p] + phgt[p]; r++) { VS[r, pleft[p] - 1] = 1; cell[r, pleft[p] - 1] = 1 }
    if (ptop[p] > 0)
      for (c = pleft[p]; c < pleft[p] + pwid[p]; c++) { HS[ptop[p] - 1, c] = 1; cell[ptop[p] - 1, c] = 1 }
    if (ptop[p] > 0 && pleft[p] > 0) {
      VS[ptop[p] - 1, pleft[p] - 1] = 1; HS[ptop[p] - 1, pleft[p] - 1] = 1
      cell[ptop[p] - 1, pleft[p] - 1] = 1
    }
  }
  for (bc in cell) {
    split(bc, rc, SUBSEP); r = rc[1] + 0; c = rc[2] + 0
    m = ((r - 1, c) in VS) + 2 * ((r + 1, c) in VS) + 4 * ((r, c - 1) in HS) + 8 * ((r, c + 1) in HS)
    print at(r, c) DIM glyph(m) RESET
  }

  # Pane contents, with hints stamped over the first cell(s) of each match.
  for (j = 1; j <= nl; j++) {
    s = ltext[j]
    if (s == "") continue
    out = ""; cur = 1
    for (i = 1; i <= n; i++) {
      if (mline[i] != j || hint[i] == "") continue
      out = out DIM substr(s, cur, mpos[i] - cur)
      h = hint[i]
      out = out HINT h RESET HIT substr(mtxt[i], length(h) + 1) RESET
      cur = mpos[i] + mlen[i]
    }
    print at(lrow[j], lcol[j]) out DIM substr(s, cur) RESET
  }
}
')

if [ "$(head -1 "$map" 2>/dev/null)" = NONE ] || [ ! -s "$map" ]; then
  tmux display-message 'quick-select: nothing found'
  exit 0
fi

# Auto-wrap off means an over-wide line clips instead of reflowing the screen.
printf '\033[?7l\033[?25l\033[2J%s' "$overlay"

read_key() {
  IFS= read -rsn1 key || exit 0
  case $key in
    '' | $'\033' | $'\003') exit 0 ;;
    *[A-Z]*) paste=1; key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]') ;;
  esac
}

paste=0
read_key
keys=$key
# Only wait for a second key if the first one is a two-letter hint's prefix.
if ! awk -F'\t' -v h="$keys" '$1 == h { found = 1 } END { exit !found }' "$map" &&
   awk -F'\t' -v h="$keys" 'length($1) == 2 && substr($1, 1, 1) == h { found = 1 } END { exit !found }' "$map"; then
  read_key
  keys=$keys$key
fi

selection=$(awk -F'\t' -v h="$keys" '$1 == h { print substr($0, index($0, "\t") + 1); exit }' "$map")
[ -n "$selection" ] || exit 0

tmux set-buffer -w -- "$selection"
if [ "$paste" = 1 ]; then
  tmux paste-buffer -t "$pane"
else
  tmux display-message "copied: $selection"
fi
