#!/usr/bin/env zsh

# Step table as percent of max brightness.
PCTS=(0.1 1 2 3 4 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100)

# brightnessctl -m prints one CSV line: device,class,current,percent,max
fields=(${(s:,:)"$(brightnessctl -m)"})
CUR=$fields[3]
MAX=$fields[5]

# Convert percentages to raw values, rounded to the nearest integer
integer s
STEPS=(0 1)
for p in $PCTS; do
    (( s = p * MAX / 100.0 + 0.5 ))
    STEPS+=($s)
done
typeset -U STEPS   # drop duplicates (matters on panels with a small max)

find_next() {
    local cur=$1 dir=$2
    if [[ $dir == up ]]; then
        for s in $STEPS; do
            if (( s > cur )); then
                print $s
                return
            fi
        done
        print $cur
    else
        local last=$cur
        for s in $STEPS; do
            if (( s >= cur )); then
                print $last
                return
            fi
            last=$s
        done
        print $last
    fi
}

case "$1" in
    up)
        brightnessctl set "$(find_next $CUR up)"
        ;;
    down)
        brightnessctl set "$(find_next $CUR down)"
        ;;
    set)
        brightnessctl set "$2"
        ;;
    steps)
        print -l $STEPS
        ;;
    *)
        print "Usage: $0 {up|down|set <value>|steps}"
        exit 1
        ;;
esac
