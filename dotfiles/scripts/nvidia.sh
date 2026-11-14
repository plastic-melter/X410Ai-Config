#!/usr/bin/env zsh
STATE=$(cat /sys/bus/pci/devices/0000:01:00.0/power_state)
STATUS=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)
case $STATE in
  D0)
    echo " ($STATE $STATUS)"
    ;;
  D3cold)
    echo "󰤄 ($STATE $STATUS)"
    ;;
  *)
    echo "???"
    ;;
esac
