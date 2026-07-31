#!/usr/bin/env bash
# Hint-based quick select, in the spirit of tmux-fingers / WezTerm's quick
# select. Overlays the current pane with dimmed text, labels every path, URL,
# hash, IP, ... with a hint letter, and copies the one whose hint you press.
#
#   lowercase hint  copy to the tmux buffer and the system clipboard
#   uppercase hint  copy, then paste it into the pane
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
  read -r width height <<<"$(tmux display-message -p -t "$pane" '#{pane_width} #{pane_height}')"
  tmux display-popup -B -E -t "$pane" -x P -y P -w "$width" -h "$height" \
    "$(printf '%q %q %q' "$self" --hints "$pane")"
  exit $?
fi

# ----------------------------------------------------------------- overlay ---
pane=$2
map=$(mktemp "${TMPDIR:-/tmp}/tmux-quick-select.XXXXXX")
trap 'rm -f "$map"' EXIT

# When the pane is scrolled up in copy mode, capture what is on screen there
# rather than the bottom of the history. (scroll_position is empty outside copy
# mode, so query it on its own.)
height=$(tmux display-message -p -t "$pane" '#{pane_height}')
scroll=$(tmux display-message -p -t "$pane" '#{scroll_position}')
if [ -n "$scroll" ] && [ "$scroll" -gt 0 ] 2>/dev/null; then
  capture=(capture-pane -p -t "$pane" -S "-$scroll" -E "$((height - 1 - scroll))")
else
  capture=(capture-pane -p -t "$pane")
fi

overlay=$(tmux "${capture[@]}" | awk -v MAP="$map" '
BEGIN {
  RE   = ENVIRON["QS_RE"]
  # Home row first, then the rest of the alphabet.
  ALPH = "asdfjklghqwertyuiopzxcvbnm"
  DIM   = "\033[38;5;244m"
  HIT   = "\033[38;5;110m"
  HINT  = "\033[1;38;5;232;48;5;215m"
  RESET = "\033[0m"
}
{ line[NR] = $0 }
END {
  rows = NR
  n = 0
  for (r = 1; r <= rows; r++) {
    s = line[r]; pos = 1
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
      printf "%s\t%s\n", substr(ALPH, a, 1) substr(ALPH, b, 1), t > MAP
    } else {
      printf "%s\t%s\n", substr(ALPH, k, 1), t > MAP
    }
  }

  for (r = 1; r <= rows; r++) {
    s = line[r]; out = ""; cur = 1
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
