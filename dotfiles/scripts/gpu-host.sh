# gpu-host: give the dGPU back to the nvidia driver, unless a VM still has it.
# No shebang or `set -euo pipefail` here: writeShellApplication adds both.

GPU="0000:01:00.0"
DEV="/sys/bus/pci/devices/$GPU"

die() { echo "gpu-host: $*" >&2; exit 1; }

current_driver() {
  if [[ -e $DEV/driver ]]; then
    basename "$(readlink "$DEV/driver")"
  else
    echo none
  fi
}

# --- Sanity checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -d $DEV ]] || die "no PCI device at $GPU"

drv=$(current_driver)
if [[ $drv == nvidia ]]; then
  echo "gpu-host: already on nvidia"
  exit 0
fi

# --- VM guard -------------------------------------------------------------------
# QEMU holds /dev/vfio/<group> open while the VM runs. Unbinding under it
# doesn't fail; it blocks until QEMU lets go, which looks like a hung shell.
if [[ -e $DEV/iommu_group ]]; then
  group=$(basename "$(readlink "$DEV/iommu_group")")
  if [[ -e /dev/vfio/$group ]] && fuser -s "/dev/vfio/$group"; then
    echo "gpu-host: IOMMU group $group is still open (VM running?):" >&2
    fuser -v "/dev/vfio/$group" || true
    exit 1
  fi
fi

# --- Release from vfio-pci ------------------------------------------------------
echo > "$DEV/driver_override"            # empty write clears the override
if [[ -e $DEV/driver ]]; then
  echo "$GPU" > "$DEV/driver/unbind"
fi

# --- Bind to nvidia ---------------------------------------------------------------
modprobe nvidia_drm                        # pulls in nvidia + nvidia_modeset
modprobe nvidia_uvm                        # CUDA needs this; NixOS loads it at boot
echo "$GPU" > /sys/bus/pci/drivers_probe || true

drv=$(current_driver)
[[ $drv == nvidia ]] || die "bind failed, device is on '$drv' (check dmesg)"

if systemctl is-enabled --quiet nvidia-persistenced.service 2>/dev/null; then
  systemctl start nvidia-persistenced.service
fi

echo "gpu-host: $GPU is back on nvidia"
