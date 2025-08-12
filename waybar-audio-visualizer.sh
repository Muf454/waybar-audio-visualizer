#!/usr/bin/env bash
# waybar-visualizer.sh — neon edition (debounced, fixed-length bars, base-10 safe)
# Deps: cava, playerctl, jq
set -euo pipefail

BARS=12
FPS=60
DELAY_MS=600    # delay showing bars after real track change (set 0 to disable)

ICON_NOTE="🎵"
ICON_PAUSE="❚❚"
ICON_STOP="■"

while getopts "b:f:d:h" opt; do
  case "$opt" in
    b) BARS="$OPTARG" ;;
    f) FPS="$OPTARG" ;;
    d) DELAY_MS="$OPTARG" ;;
    h) echo "Usage: $0 [-b BARS] [-f FPS] [-d DELAY_MS]"; exit 0 ;;
  esac
done

CFG="$(mktemp -t cava_cfg_XXXX)"
FIFO_CAVA="$(mktemp -u -t cava_fifo_XXXX)"
FIFO_PCTL="$(mktemp -u -t pctl_fifo_XXXX)"
PIDFILE="$(mktemp -t vis_pids_XXXX)"

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    while read -r p; do [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true; done < "$PIDFILE"
  fi
  rm -f "$CFG" "$PIDFILE"
  [[ -p "$FIFO_CAVA" ]] && rm -f "$FIFO_CAVA"
  [[ -p "$FIFO_PCTL" ]] && rm -f "$FIFO_PCTL"
}
trap cleanup EXIT INT TERM

mkfifo "$FIFO_CAVA" "$FIFO_PCTL"

# CAVA config (literal heredoc so no quoting issues)
cat > "$CFG" <<'EOF'
[general]
mode = normal
framerate = __FPS__
bars = __BARS__

[output]
method = raw
raw_target = __FIFO__
data_format = ascii
ascii_max_range = 8
EOF
# patch placeholders
sed -i \
  -e "s|__FPS__|${FPS}|g" \
  -e "s|__BARS__|${BARS}|g" \
  -e "s|__FIFO__|${FIFO_CAVA}|g" "$CFG"

# Blocks 1..8
BLOCKS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

# Tokyo Night–style smooth gradient (purple → blue → cyan)
PALETTE=( "#bb9af7" "#a7aefc" "#93b6fb" "#7aa2f7" "#66b8ff" "#54c8e8" "#3ccad6" "#2ac3de" )

TITLE_COLOR="#c0caf5"
NOTE_COLOR="#7aa2f7"
PAUSE_COLOR="#bb9af7"
STOP_COLOR="#c0caf5"

# Palette drift for gentle shimmer (no CSS animation)
OFFSET=0

# Helpers
pango_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
emit_json() { jq -c -n --arg t "$1" --arg tip "$2" --arg cls "$3" --arg alt "$4" '{text:$t, tooltip:$tip, class:$cls, alt:$alt}'; }
msleep() { perl -e "select(undef,undef,undef,$1/1000)"; }

# Kill cava + reader, keep playerctl
kill_cava_chain() {
  if [[ -f "$PIDFILE" ]]; then
    tail -n +2 "$PIDFILE" 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null || true; done
    head -n1 "$PIDFILE" > "${PIDFILE}.keep" 2>/dev/null || true
    mv "${PIDFILE}.keep" "$PIDFILE" 2>/dev/null || true
  fi
  [[ -p "$FIFO_CAVA" ]] && rm -f "$FIFO_CAVA"
  mkfifo "$FIFO_CAVA"
}

# Fixed-length bars = exactly $BARS columns
colorize_bars_fixed() {
  local nums=() tok
  for tok in "$@"; do
    tok="${tok//[^0-9]/}"
    [[ -z "$tok" ]] && continue
    tok=$((10#$tok))               # force decimal (fixes 08/017)
    (( tok < 1 )) && tok=1
    (( tok > 8 )) && tok=8
    nums+=("$tok")
  done
  local n=${#nums[@]}
  if (( n == 0 )); then
    nums=()
    for ((i=0;i<BARS;i++)); do nums+=(1); done
  elif (( n < BARS )); then
    local last=${nums[$((n-1))]}
    while (( ${#nums[@]} < BARS )); do nums+=("$last"); done
  elif (( n > BARS )); then
    nums=("${nums[@]:0:BARS}")
  fi

  local out="" i=0 lvl ch color
  for lvl in "${nums[@]}"; do
    ch="${BLOCKS[$((lvl-1))]}"
    color="${PALETTE[$(( (i + OFFSET) % ${#PALETTE[@]} ))]}"
    out+="<span foreground=\"$color\">$ch</span>"
    ((i++))
  done
  printf '%s' "$out"
}

# Playerctl JSON format kept in a *single-quoted* variable (no quoting headaches)
FORMAT='{"text":"{{artist}} - {{title}}","tooltip":"{{playerName}} - {{markup_escape(artist)}} - {{markup_escape(title)}}","alt":"{{status}}","class":"{{status}}","trackid":"{{mpris:trackid}}"}'

# Start playerctl stream
playerctl -a metadata --format "$FORMAT" -F > "$FIFO_PCTL" &
echo $! >> "$PIDFILE"

LAST_KEY=""
LAST_STATUS=""

# Main loop
while IFS= read -r LINE || [[ -n "${LINE:-}" ]]; do
  STATUS="$(jq -r '.class' <<<"$LINE" 2>/dev/null || echo "Stopped")"
  TITLE_RAW="$(jq -r '.text'  <<<"$LINE" 2>/dev/null || echo "")"
  TIP="$(jq -r '.tooltip' <<<"$LINE" 2>/dev/null || echo "")"
  TRACKID="$(jq -r '.trackid' <<<"$LINE" 2>/dev/null || echo "")"
  TITLE_ESC="$(pango_escape "$TITLE_RAW")"
  KEY="${STATUS}|${TRACKID}"

  case "$STATUS" in
    Playing)
      if [[ "$KEY" != "$LAST_KEY" ]]; then
        kill_cava_chain
        emit_json "<span foreground=\"$NOTE_COLOR\">$ICON_NOTE</span> <span foreground=\"$TITLE_COLOR\">$TITLE_ESC</span>" "$TIP" "playing neon" "Playing"
        (( DELAY_MS > 0 )) && msleep "$DELAY_MS"

        cava -p "$CFG" >/dev/null 2>&1 &
        echo $! >> "$PIDFILE"

        (
          while IFS= read -r row; do
            row="${row//;/ }"
            BARS_HTML="$(colorize_bars_fixed $row)"
            OFFSET=$(( (OFFSET + 1) % ${#PALETTE[@]} ))
            emit_json "$BARS_HTML&#8239;<span foreground=\"$TITLE_COLOR\">$TITLE_ESC</span>" "$TIP" "playing neon" "Playing"
          done < "$FIFO_CAVA"
        ) &
        echo $! >> "$PIDFILE"
      else
        emit_json "<span foreground=\"$NOTE_COLOR\">$ICON_NOTE</span> <span foreground=\"$TITLE_COLOR\">$TITLE_ESC</span>" "$TIP" "playing neon" "Playing"
      fi
      ;;
    Paused)
      if [[ "$LAST_STATUS" != "Paused" ]]; then
        kill_cava_chain
        emit_json "<span foreground=\"$PAUSE_COLOR\">$ICON_PAUSE</span> <span foreground=\"$TITLE_COLOR\">$TITLE_ESC</span>" "$TIP" "paused neon" "Paused"
      fi
      ;;
    Stopped|*)
      if [[ "$LAST_STATUS" != "Stopped" ]]; then
        kill_cava_chain
        if [[ -n "$TITLE_RAW" && "$TITLE_RAW" != " - " ]]; then
          emit_json "<span foreground=\"$STOP_COLOR\">$ICON_STOP</span> <span foreground=\"$TITLE_COLOR\">$TITLE_ESC</span>" "$TIP" "stopped neon" "Stopped"
        else
          emit_json "<span foreground=\"$STOP_COLOR\">$ICON_STOP</span>" "No active player" "stopped neon" "Stopped"
        fi
      fi
      ;;
  esac

  LAST_KEY="$KEY"
  LAST_STATUS="$STATUS"
done < "$FIFO_PCTL"
