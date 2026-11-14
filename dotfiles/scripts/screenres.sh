#!/usr/bin/env zsh
laptop_display="eDP-1"

res_4k_120="3072x1920@120"
res_4k_60="3072x1920@60"
res_1920="1920x1200"
res_touhou="1680x1050"
res_mid="1280x800"
res_vga="640x480"

# Prints e.g. "3072 1920 120" for the named monitor
query_mode() {
    hyprctl monitors -j | jq -r --arg m "$laptop_display" \
        '.[] | select(.name == $m) | "\(.width) \(.height) \(.refreshRate | round)"'
}

read -r width height hz <<< "$(query_mode)"
current="${width}x${height}"

set_resolution() {
    local reply
    reply=$(hyprctl eval "hl.monitor({ output = '$laptop_display', mode = '$1', position = '0x0', scale = 1 })")
    if [[ $reply != ok ]]; then
        notify-send -u critical "Screen Resolution" "hyprctl rejected $1: $reply"
        return 1
    fi
    sleep 0.5   # give the modeset a moment before checking the result
    local w h r
    read -r w h r <<< "$(query_mode)"
    notify-send "Screen Resolution" "Requested $1 → now ${w}x${h}@${r}"
}

case "$current" in
    3072x1920)
        if (( hz >= 100 )); then
            set_resolution "$res_4k_60"
        else
            set_resolution "$res_1920"
        fi
        ;;
    1920x1200) set_resolution "$res_touhou" ;;
    1680x1050) set_resolution "$res_mid" ;;
    1280x800)  set_resolution "$res_vga" ;;
    *)         set_resolution "$res_4k_120" ;;
esac
