#!/usr/bin/env bash
# Hint-based quick select, in the spirit of tmux-fingers / WezTerm's quick
# select. Overlays the whole window (all panes at once) with dimmed text,
# labels every path, URL, hash, IP, ... with a hint letter, and copies the one
# whose hint you press.
#
#   lowercase hint  copy to the tmux buffer and the system clipboard
#   uppercase hint  copy, then paste it into the active pane
#   Esc / q / C-c   cancel
#
# Modes:
#   quick-select.sh [pane-id]        launcher: opens the overlay popup
#   quick-select.sh --hints <pane>   the overlay itself (runs inside the popup)
#
# display-popup does not expand #{...} in its command, so the launcher resolves
# the pane and bakes it into the popup command.

set -uo pipefail

self=$(readlink -f "$0" 2>/dev/null || echo "$0")

# Column arithmetic below assumes characters, not bytes.
if [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ] && [ "${LANG:-}" != *UTF-8* ]; then
  export LC_ALL=C.UTF-8
fi

# What counts as selectable. Kept in one place; used as a dynamic regex by awk,
# so it must stay POSIX ERE (no \b, no \d).
QS_RE='(https?|ftp|file|ssh|git)://[^][:space:]"'"'"'`<>|(){}]+'
QS_RE=$QS_RE'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+:[^[:space:]"'"'"'`<>|(){}]+'
QS_RE=$QS_RE'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
QS_RE=$QS_RE'|(~|\.{1,2})?[A-Za-z0-9._@%+-]*(/[A-Za-z0-9._@%+:#-]+)+/?'
QS_RE=$QS_RE'|[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?'
QS_RE=$QS_RE'|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
QS_RE=$QS_RE'|[0-9a-f]{7,40}'
QS_RE=$QS_RE'|[A-Za-z0-9._-]+\.[A-Za-z][A-Za-z0-9]{0,7}'
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

read -r window win_width win_height <<<"$(tmux display-message -p -t "$pane" \
  '#{window_id} #{window_width} #{window_height}')"

case $(tmux show-options -gv pane-border-lines 2>/dev/null) in
  heavy)  vline='┃'; hline='━' ;;
  double) vline='║'; hline='═' ;;
  simple) vline='|'; hline='-' ;;
  *)      vline='│'; hline='─' ;;
esac

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

overlay=$(compose | awk -v MAP="$map" -v WW="$win_width" -v WH="$win_height" \
                       -v VLINE="$vline" -v HLINE="$hline" '
BEGIN {
  FS = "\t"
  RE   = ENVIRON["QS_RE"]
  # Home row first, then the rest of the alphabet.
  ALPH = "asdfjklghqwertyuiopzxcvbnm"
  DIM   = "\033[38;5;244m"
  HIT   = "\033[38;5;110m"
  HINT  = "\033[1;38;5;232;48;5;215m"
  RESET = "\033[0m"
  blank = sprintf("%" WW "s", "")
  for (r = 1; r <= WH; r++) G[r] = blank
}

function put(r, c, text,   w) {
  if (r < 1 || r > WH || c > WW) return
  w = length(text)
  if (c < 1) { text = substr(text, 2 - c); w = length(text); c = 1 }
  if (c + w - 1 > WW) { text = substr(text, 1, WW - c + 1); w = length(text) }
  if (w <= 0) return
  G[r] = substr(G[r], 1, c - 1) text substr(G[r], c + w)
}

$1 == "P" {
  np++
  pid[np] = $2; pleft[np] = $3; ptop[np] = $4; pw[np] = $5; ph[np] = $6
  prow = 0
  next
}
$1 == "L" {
  put(ptop[np] + prow + 1, pleft[np] + 1, substr($0, 3))
  prow++
  next
}

END {
  # Pane borders, so the overlay looks like the window it covers.
  for (p = 1; p <= np; p++) {
    if (pleft[p] > 0)
      for (r = ptop[p] + 1; r <= ptop[p] + ph[p]; r++) put(r, pleft[p], VLINE)
    if (ptop[p] > 0) {
      bar = ""
      for (i = 0; i < pw[p]; i++) bar = bar HLINE
      put(ptop[p], pleft[p] + 1, bar)
    }
  }

  n = 0
  for (r = 1; r <= WH; r++) {
    s = G[r]; pos = 1
    while (pos <= length(s)) {
      rest = substr(s, pos)
      if (!match(rest, RE)) break
      st  = pos + RSTART - 1
      len = RLENGTH
      pos = st + (len > 0 ? len : 1)
      txt = substr(s, st, len)
      while (len > 1 && substr(txt, len, 1) ~ /[.,:;")'"'"']/) { len--; txt = substr(txt, 1, len) }
      prev = (st > 1) ? substr(s, st - 1, 1) : " "
      # A match starting right after a word character is a fragment, not a token.
      if (len >= 2 && prev !~ /[A-Za-z0-9_]/) {
        n++; mrow[n] = r; mcol[n] = st; mlen[n] = len; mtxt[n] = txt
      }
    }
  }
  if (n == 0) { print "NONE" > MAP; exit }

  # Identical text shares one hint, so repeated tokens do not burn letters.
  # Hints are handed out bottom-up, so the newest matches get the easiest keys.
  uniq = 0
  for (i = n; i >= 1; i--) if (!(mtxt[i] in seen)) { seen[mtxt[i]] = ++uniq }
  two = (uniq > 26)
  for (i = n; i >= 1; i--) {
    k = seen[mtxt[i]]
    if (two) {
      a = int((k - 1) / 26) + 1; b = ((k - 1) % 26) + 1
      hint[i] = substr(ALPH, a, 1) substr(ALPH, b, 1)
    } else {
      hint[i] = substr(ALPH, k, 1)
    }
  }
  for (t in seen) {
    k = seen[t]
    if (two) {
      a = int((k - 1) / 26) + 1; b = ((k - 1) % 26) + 1
      h = substr(ALPH, a, 1) substr(ALPH, b, 1)
    } else {
      h = substr(ALPH, k, 1)
    }
    printf "%s\t%s\n", h, t > MAP
  }

  for (r = 1; r <= WH; r++) {
    s = G[r]; out = ""; cur = 1
    for (i = 1; i <= n; i++) {
      if (mrow[i] != r) continue
      out = out DIM substr(s, cur, mcol[i] - cur)
      h = hint[i]
      out = out HINT h RESET HIT substr(mtxt[i], length(h) + 1) RESET
      cur = mcol[i] + mlen[i]
    }
    out = out DIM substr(s, cur) RESET
    print out
  }
}
')

if [ "$(head -1 "$map" 2>/dev/null)" = NONE ] || [ ! -s "$map" ]; then
  tmux display-message 'quick-select: nothing found'
  exit 0
fi

# Draw the overlay without scrolling the last line off.
printf '\033[2J\033[H%s' "${overlay%$'\n'}"

hint_len=$(awk -F'\t' 'NR==1{print length($1); exit}' "$map")
keys=""
for _ in $(seq "$hint_len"); do
  IFS= read -rsn1 key || exit 0
  case $key in
    '' | $'\033' | q | $'\003') exit 0 ;;
  esac
  keys=$keys$key
done

paste=0
case $keys in
  *[A-Z]*) paste=1; keys=$(printf '%s' "$keys" | tr '[:upper:]' '[:lower:]') ;;
esac

selection=$(awk -F'\t' -v h="$keys" '$1 == h { print substr($0, index($0, "\t") + 1); exit }' "$map")
[ -n "$selection" ] || exit 0

tmux set-buffer -w -- "$selection"
if [ "$paste" = 1 ]; then
  tmux paste-buffer -t "$pane"
else
  tmux display-message "copied: $selection"
fi
