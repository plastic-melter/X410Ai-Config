# gpu-vm: move the dGPU from nvidia to vfio-pci, but only if the host isn't using it.
# No shebang or `set -euo pipefail` here: writeShellApplication adds both.

GPU="0000:01:00.0"
DEV="/sys/bus/pci/devices/$GPU"

die() { echo "gpu-vm: $*" >&2; exit 1; }

current_driver() {
  if [[ -e $DEV/driver ]]; then
    basename "$(readlink "$DEV/driver")"
  else
    echo none
  fi
}

restore_host() {
  modprobe nvidia_drm || true
  modprobe nvidia_uvm || true
  if [[ $persistenced_was_active == true ]]; then
    systemctl start nvidia-persistenced.service || true
  fi
}

# --- Sanity checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -d $DEV ]] || die "no PCI device at $GPU"
[[ -e $DEV/iommu_group ]] || die "$GPU has no IOMMU group (is intel_iommu=on set?)"

group=$(basename "$(readlink "$DEV/iommu_group")")

drv=$(current_driver)
if [[ $drv == vfio-pci ]]; then
  echo "gpu-vm: already on vfio-pci (IOMMU group $group)"
  exit 0
fi
[[ $drv == nvidia ]] || die "GPU is on '$drv', expected nvidia"

# Every device in the IOMMU group must be on vfio-pci, or QEMU rejects the group.
for d in /sys/kernel/iommu_groups/"$group"/devices/*; do
  [[ ${d##*/} == "$GPU" ]] && continue
  echo "gpu-vm: warning: IOMMU group $group also contains ${d##*/}; it must be on vfio-pci too" >&2
done

# --- Idle guard ----------------------------------------------------------------
status=$(<"$DEV/power/runtime_status")
[[ $status == suspended ]] || die "GPU is $status ($(<"$DEV/power_state")); refusing"

shopt -s nullglob
handles=( /dev/nvidia* /dev/dri/by-path/pci-"$GPU"-* )
shopt -u nullglob

if (( ${#handles[@]} )) && fuser -s "${handles[@]}"; then
  echo "gpu-vm: GPU is suspended but these processes still hold it open:" >&2
  fuser -v "${handles[@]}" || true
  exit 1
fi

# --- Release from nvidia -------------------------------------------------------
persistenced_was_active=false
if systemctl is-active --quiet nvidia-persistenced.service; then
  persistenced_was_active=true
  systemctl stop nvidia-persistenced.service
fi

# Unload in dependency order, skipping modules that aren't loaded.
# modprobe -r also drops now-unused dependencies, so later entries may already be gone.
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
  if [[ -d /sys/module/$m ]] && ! modprobe -r "$m"; then
    echo "gpu-vm: could not unload $m (still in use); restoring host driver" >&2
    lsmod | grep -E '^nvidia' >&2 || true
    restore_host
    exit 1
  fi
done

# --- Bind to vfio-pci ---------------------------------------------------------
modprobe vfio-pci
echo vfio-pci > "$DEV/driver_override"
if [[ -e $DEV/driver ]]; then
  echo "$GPU" > "$DEV/driver/unbind"
fi
echo "$GPU" > /sys/bus/pci/drivers_probe || true

drv=$(current_driver)
[[ $drv == vfio-pci ]] || die "bind failed, device is on '$drv' (check dmesg)"
echo "gpu-vm: $GPU is on vfio-pci (IOMMU group $group, /dev/vfio/$group)"
