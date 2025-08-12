# waybar-audio-visualizer

A real-time audio visualizer for Waybar using Cava + Playerctl, styled in Tokyo Night colors.

## Features
 - Smooth gradient bars
 - Debounced updates (no flicker on song change)
 - Fixed bar width
 - Works with Spotify and other MPRIS players

## Dependencies
 - cava 
 - playerctl 
 - jq
## Installation
Place waybar-audio-visualizer.sh in ~/.config/waybar/scripts/

Make it executable:
chmod +x ~/.config/waybar/scripts/waybar-audio-visualizer.sh

add this to your waybar config:
"custom/music": {
  "exec": "~/.config/waybar/scripts/waybar-visualizer.sh -b 12 -f 60 -d 600",
  "return-type": "json",
  "tail": true,
  "format": "{text}",
  "tooltip": true,
  "markup": true
}

