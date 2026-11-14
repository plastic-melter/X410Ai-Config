{ inputs, outputs, lib, config, pkgs, ... }: 

let

  # Make the login screen (SDDM) look nice
  sddm-astronaut-themed = pkgs.sddm-astronaut.override {
    embeddedTheme = "astronaut";
    themeConfig = {
      Background = "/etc/nixos/dotfiles/wallpapers/misc/jellyfish-dark-flipped.jpg";
      FormPosition = "left";
      PartialBlur = "true";
      MainColor = "#cad3f5";
      AccentColor = "#c6a0f6";
      BackgroundColor = "#24273a";
    };
  };

  # Workaround for upstream bug: kvmfr module compiles but fails to merge on 7.3
  # 2026-10-21, issue #575192 opened 2026-10-17
  kp = config.boot.kernelPackages;
  kvmfr2 = kp.kvmfr.overrideAttrs (old: {
    installPhase = ''
      runHook preInstall
      make -C ${kp.kernel.dev}/lib/modules/${kp.kernel.modDirVersion}/build \
        M="$PWD" \
        ${lib.escapeShellArgs (old.makeFlags or [ ])} \
        INSTALL_MOD_PATH="$out" \
        INSTALL_MOD_DIR=kernel/drivers/misc \
        DEPMOD=true \
        modules_install
      runHook postInstall
    '';
  });

  # Allocate the dGPU to vfio-pci (for VM use) or leave it to PRIME offload (gaming, etc)
  gpu-vm = pkgs.writeShellApplication {
    name = "gpu-vm";
    runtimeInputs = with pkgs; [ psmisc kmod coreutils systemd ];
    text = builtins.readFile ./dotfiles/scripts/gpu-vm.sh;
  };
  gpu-host = pkgs.writeShellApplication {
    name = "gpu-host";
    runtimeInputs = with pkgs; [ psmisc kmod coreutils ];
    text = builtins.readFile ./dotfiles/scripts/gpu-host.sh;
  };

  # Nvidia offload: render on dGPU, pass finished frames to iGPU for display; make vulkan apps only see the dGPU; etc
  nvidia-offload = pkgs.writeShellApplication {
    name = "nvidia-offload";
    text = ''
      export __NV_PRIME_RENDER_OFFLOAD=1
      export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
      export __GLX_VENDOR_LIBRARY_NAME=nvidia
      export __VK_LAYER_NV_optimus=NVIDIA_only
      export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json
      exec "$@"
    '';
  };

  # Dispatch scripts for toggling power settings (triggered by waybar module)
  powerToggleApply = pkgs.writeShellScript "power-toggle-apply"
    (builtins.readFile ./dotfiles/scripts/power-toggle-apply.sh);
  powerToggle = pkgs.writeShellScriptBin "power-toggle"
    (builtins.replaceStrings [ "@apply@" ] [ "${powerToggleApply}" ]
      (builtins.readFile ./dotfiles/scripts/power-toggle-readout.sh));

  # RAPL PL1/PL2 (µW), written to both MSR and MMIO paths
  # The EC keeps re-raising PL1, so a timer reapplies this every 5s (+ udev on AC plug/unplug)
  raplApply = pkgs.writeShellScript "rapl-apply" ''
    if [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = 1 ]; then
      pl1=65000000; pl2=65000000 # AC
    else
      pl1=28000000; pl2=65000000 # battery
    fi
    for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
      [ -d "$d" ] || continue
      echo $pl1 > $d/constraint_0_power_limit_uw
      echo $pl2 > $d/constraint_1_power_limit_uw
    done
  '';

  # Hibernate: fill in after first boot with the new 128 GiB swapfile
  #   ext4:  doas filefrag -v /var/lib/swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}'
  #   btrfs: doas btrfs inspect-internal map-swapfile -r /var/lib/swapfile
  # null = no hibernate; lid close just suspends
  resumeOffset = null;
  canHibernate = resumeOffset != null;

in {

#############################################
############# X410Ai CONFIG #################
#############################################

imports = [
  ./hardware-configuration.nix
];

# ============================================
# NIX, NIXPKGS, BOOT, SWAP
# ============================================

nix = {
  package = pkgs.nixVersions.latest;
  extraOptions = "experimental-features = nix-command flakes";
  settings = {
    trusted-users = [ "root" "joe" ];
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    require-sigs = true;
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
};

nixpkgs.config = {
  allowBroken = false;
  allowInsecure = false;
  allowUnfree = true;
  allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "brscan4"                 # Brother MFC-L2820DW scanner driver
    "brscan4-etc-files"       # ^ dep
    "brother-udev-rule-type1" # ^ dep
    "grayjay"                 # multi-plaform video client from FULU
    "grayjay-frontend"        # ^ dep
    "grayjay-libcurlshim"     # ^ dep
    "nvidia-x11"              # NVIDIA userspace driver (dGPU)
    "nvidia-settings"         # ^ dep
    "obsidian"                # note-taking thing: proprietary b/c optional paid online sync thing
    "picoscope"               # Pico Technologies binary
    "spotify"                 # obviously the electron client is unfree
    "steam"                   # steam is very convenient, can find DRM-free versions of games later if needed
    "steam-unwrapped"         # ^ dep
    "unrar"                   # RAR is is a proprietary compression algo, thus unrar is proprietary
  ];
};

boot = {
  plymouth.enable = false; # prefer systemd output
  consoleLogLevel = 4; # 0 = emergency only, 4 = warnings and above, 7 = wall of spam
  loader = {
    efi.canTouchEfiVariables = true;
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
      enableCryptodisk = true;
      configurationLimit = 20;
      default = "saved"; # default to last-used boot entry
      gfxmodeEfi = "2880x1800,1920x1200,auto"; # first mode the panel supports wins
      splashImage = null;
      theme = ./dotfiles/grub;
      extraConfig = ''
        menuentry "Reboot" --class reboot { reboot }
        menuentry "Poweroff" --class shutdown { halt }
      '';
    };
    timeout = 2;
  };
  #extraModulePackages = [ config.boot.kernelPackages.kvmfr ]; # Looking Glass / VM KVMFR
  extraModulePackages = [ kvmfr2 ]; # Temporary patch
  initrd.kernelModules = [ "kvmfr" ]; # Looking Glass / VM KVMFR
  kernelModules = [ 
    "ntsync" # CoD WaW performance
    "uinput" # B0XX native USB
    "kvm-intel" # enables hardware-accelerated virtualization (VMX)
    "vfio" # VFIO subsystem: allows QEMU to access hardware directly
    "vfio_iommu_type1" # IOMMU backend for VFIO: handles addr trans/isolation between VM and hardware
    "vfio_pci" # allows binding specific PCI devices (ex: GPU) to VFIO driver isntead of host driver
    "hid_nintendo" # Switch controller pairing
    "thinkpad_acpi" # fan control, platform profile, charge thresholds
  ];
  kernelPackages = pkgs.linuxPackages_latest;
  kernelParams = [
    "boot.shell_on_fail" # rescue shell if stage-1 fails
    "acpi.dump_ecdt=1" # more EC logging
    "no_console_suspend" # keep console active during suspend for better logging
    "mem_sleep_default=s2idle" # Arrow Lake has no S3, forces the only working sleep state
    "intel_iommu=on" # enable IOMMU for VFIO passthrough
    "iommu=pt" # passthrough mode, tells IOMMU to only translate for devices that need it (VMs)
    #"pcie_aspm=force" # force ASPM on all links (old config had it misspelled "pci_aspm", so it never applied)
  ] ++ lib.optional canHibernate "resume_offset=${toString resumeOffset}";
  resumeDevice = lib.mkIf canHibernate config.fileSystems."/".device; # swapfile lives on root fs
  kernel.sysctl."net.ipv4.ip_forward" = 1; # IP forwarding
  extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=US
    options kvmfr static_size_mb=256
    options thinkpad_acpi fan_control=1
  ''; 
  # cfg...         = resolve JP/US IR flag mismatch
  # kvmfr...       = set memory size for video stuff: 128M=4k SDR, 256M=4k HDR, etc
  # ...fan_control = enable writing /proc/acpi/ibm/fan (thinkfan)
  initrd.availableKernelModules = [ "usb_storage" ];
};

swapDevices = [{
  device = "/var/lib/swapfile";
  size = 128*1024; # 128 GiB: need to be able to write 96GB during hibernate
}];

# ============================================
# NETWORKING, SYSTEMD SERVICES
# ============================================

networking = {
  hostName = "X410Ai";
  useDHCP = false;
  networkmanager = {
    enable = true;
  };
  firewall.interfaces.virbr0 = {
    allowedUDPPorts = [ 53 67 ]; # DNS, DHCP
    allowedTCPPorts = [ 53 ]; # DNS over TCP (large responses)
  };
};

# Suspend-to-disk after 1h of sleep; rewrite trackpoint sensitivity after sleep
systemd.sleep.settings.Sleep.HibernateDelaySec = "1h";
powerManagement.resumeCommands = ''
  for f in /sys/bus/hid/devices/*17EF:6009*/sensitivity; do
    [ -e "$f" ] && echo 235 > "$f"
  done
'';

# Make these files user-writeable so a waybar module can toggle them
systemd.tmpfiles.rules = [
  "z /sys/devices/system/cpu/intel_pstate/no_turbo 0664 root bodo -"
  "z /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 0664 root bodo -"
  "z /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 0664 root bodo -"
  "f /dev/shm/looking-glass 0660 joe kvm -"
  # ^ Looking Glass setup
];

systemd.services = {
  NetworkManager-wait-online.enable = false;
  "systemd-networkd-wait-online".enable = false;
  libvirtd = {
    stopIfChanged = false;
    serviceConfig.LimitMEMLOCK = "infinity";
  };

  # Reset SK-8855 to revive trackpoint after EMI issues
  trackpoint-reset = {
    description = "USB bus reset of the SK-8855 (unsticks TrackPoint)";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 0.5";
      ExecStart = "${pkgs.usbutils}/bin/usbreset 17ef:6009";
    };
  };

  # Set SK-8855 sensitivity
  trackpoint-sensitivity = {
    description = "Set SK-8855 TrackPoint sensitivity";
    wantedBy = [ "multi-user.target" "post-resume.target" ];
    after = [ "post-resume.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "tp-sens" ''
        for f in /sys/bus/hid/devices/*17EF:6009*/sensitivity; do
          [ -e "$f" ] && echo 235 > "$f"
        done
      '';
    };
  };

# Save the trouble of running 'virsh netstart default' each time:
  libvirtd.postStart = ''
    sleep 2
    virsh net-start default || true
    virsh net-autostart default || true
  '';

  # Read energy_uj as root and present a user-readable average over 2sec
  # This allows for estimating CPU PkgWatt in userspace w/o enabling Platypus vulnerability
  rapl-watts = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Restart = "always"; RestartSec = 2; };
    script = ''
      D=/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0
      max=$(cat $D/max_energy_range_uj)
      e0=$(cat $D/energy_uj)
      while sleep 2; do
        e1=$(cat $D/energy_uj)
        de=$(( e1 - e0 )); [ $de -lt 0 ] && de=$(( de + max ))
        e0=$e1
        w10=$(( de / 200000 ))          # µJ / 2 s → deciwatts
        printf '%d.%d\n' $(( w10 / 10 )) $(( w10 % 10 )) > /run/pkg_watts.tmp
        mv /run/pkg_watts.tmp /run/pkg_watts
      done
    '';
  };

  # Enforce RAPL limits (see raplApply above)
  rapl-limits = {
    description = "Apply RAPL PL1/PL2 for current power source";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = raplApply;
      LogLevelMax = "notice"; # keep the 5s runs out of the journal
    };
  };

  battery-health = {
    description = "Log battery health once per boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "time-sync.target" ];
    wants = [ "time-sync.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "battery-health" ''
        b=/sys/class/power_supply/BAT0
        printf '%s\t%s\t%s\t%s\n' \
          "$(date -Iseconds)" \
          "$(cat $b/cycle_count)" \
          "$(cat $b/energy_full)" \
          "$(cat $b/energy_full_design)" \
          >> /var/lib/battery-health/log.tsv
      '';
      StateDirectory = "battery-health";
    };
  };

};

systemd.timers.rapl-limits = {
  description = "Reapply RAPL limits every 5s (EC override workaround)";
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "10s";
    OnUnitActiveSec = "5s";
    AccuracySec = "1s";
  };
};

# ============================================
# LOCALIZATION
# ============================================

time = { 
  timeZone = "America/Los_Angeles";
  hardwareClockInLocalTime = false; # RTC is set to UTC for Windows
};
i18n = {
  defaultLocale = "en_US.UTF-8";
  inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      #fcitx5-mozc
      fcitx5-gtk
    ];
    fcitx5.waylandFrontend = true;
  };
};

console = {
  font = "Lat2-Terminus16";
  keyMap = "jp106";
};

# ============================================
# HARDWARE
# ============================================

hardware = {
  nvidia = { # NOTE: we are not using PRIME, nor finegrained PM, as vfio-pci owns the GPU
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    powerManagement = {
      enable = true;
      finegrained = true;
    };
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      intelBusId  = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  graphics = {
    enable = true;
    enable32Bit = true; # for steam/wine/32-bit GL
    extraPackages = with pkgs; [ # drivers not auto-installed
      intel-media-driver  # iHD, for Gen 8+
      vpl-gpu-rt # QSV encode (ffmpeg, OBS, etc)
    ];
  };
  cpu.intel.updateMicrocode = true;
  uinput.enable = true; # B0XX native USB
  bluetooth = {
    enable = true;
    powerOnBoot = false;
  };
  enableRedistributableFirmware = true;
  trackpoint = { # built-in TrackPoint
    emulateWheel = true;
    speed = 97;
    sensitivity = 128;
  };
  sane = {
    enable = true;
    disabledDefaultBackends = [ "escl" ];
    extraBackends = [
      pkgs.sane-airscan
      (pkgs.writeTextFile {
        name = "airscan-brother";
        destination = "/etc/sane.d/airscan.conf";
        text = ''
          [devices]
          "Brother MFC" = http://192.168.1.16/eSCL, escl
  
          [options]
          discovery = disable
        '';
      })
    ];
  };
  printers = {
    ensurePrinters = [{
      name = "BrotherMFC";
      deviceUri = "socket://192.168.1.39:9100";
      model = "everywhere";
      ppdOptions = { PageSize = "Letter"; };
    }];
    ensureDefaultPrinter = "BrotherMFC";
  };
};

# ============================================
# SECURITY
# ============================================

security = {
  rtkit.enable = true;
  polkit = {
    enable = true;
    extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "trackpoint-reset.service" &&
        action.lookup("verb") == "start" &&
        subject.user == "joe") {
          return polkit.Result.YES;
        }
      });
    '';
  };
  sudo.enable = false;
  doas = {
    enable = true;
    extraRules = [
      {
        users = [ "joe" ];
        persist = true; # password once per tty, then cached ~5 min
        keepEnv = true;
      }
      {
        users = [ "joe" ];
        noPass = true;
        cmd = "${powerToggleApply}";
        args = [ ]; # and only with no arguments
      }
      {
        groups   = [ "wheel" ];
        keepEnv  = true;
        persist  = true;
        setEnv   = [ "-XDG_CACHE_HOME" "-XDG_CONFIG_HOME" "-XDG_DATA_HOME" "-XDG_STATE_HOME" ];
      }
    ];
  };
};

# ============================================
# SERVICES
# ============================================

services = {

  # Xorg
  xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ]; # also gates hardware.nvidia; dGPU is on vfio-pci, iGPU drives everything
    xkb = {
      layout = "jp";
      model = "jp106";
    };
    desktopManager.runXdgAutostartIfNone = true;
  };

  # Login Manager + Autologin
  displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
      package = pkgs.kdePackages.sddm;
      theme = "sddm-astronaut-theme";
      extraPackages = [ pkgs.kdePackages.qtmultimedia sddm-astronaut-themed ];
    };
    defaultSession = "hyprland-uwsm";
    autoLogin = {
      enable = true;
      user = "joe";
    };
  };

  # Lid Switch Action (hyprlock will run first, still)
  logind.settings.Login = let
    lid = if canHibernate then "suspend-then-hibernate" else "suspend";
  in {
    HandleLidSwitch = lid;
    HandleLidSwitchExternalPower = lid;
  };

  # Input
  libinput = {
    enable = true;
    touchpad = { 
      disableWhileTyping = true;
      naturalScrolling = true;
    };
    mouse = {
     accelProfile = "flat";
     accelSpeed = "0.0";
    };
  };
  joycond.enable = true; # Switch controller
  keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = {
        main = { # Hold = layer, tap = original key
          muhenkan = "overload(nav, muhenkan)";
          henkan   = "overload(sym, henkan)";
        };
        # 無変換 as layer 1
        nav = {
          i = "up";
          j = "left";
          k = "down";
          l = "right";
          u = "back";
          o = "forward";
        };
        # 変換 as layer 2
        sym = {
          # m = "mute";
        };
      };
    };
  };

  # Local AI
  ollama = {
    enable = true;
    package = pkgs.ollama-cpu; # dGPU is reserved for VMs
  };

  # Audio
  pulseaudio.enable = false;
  pipewire = {
    enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };
    pulse.enable = true;
    jack.enable = true;
    wireplumber = {
      enable = true;
      configPackages = [
        (pkgs.writeTextDir "share/wireplumber/bluetooth.lua.d/51-bluez-config.lua" ''
          bluez_monitor.properties = {
            ["bluez5.enable-sbc-xq"] = true,
            ["bluez5.enable-msbc"] = true,
            ["bluez5.enable-hw-volume"] = true,
            ["bluez5.headset-roles"] = "[]"
          }
        '')
      ];
    };
  };

  # System Services
  udisks2.enable = true; # auto-mount removeable drives
  fstrim.enable = true; # periodic SSD/NVMe trim for health
  fwupd.enable = true; # firmware updates via LVFS
  journald.settings.Journal.Storage = "persistent"; # persistent journald for troubleshooting things that cause system crashes
  timesyncd.enable = true; # syncs clock to NTP servers over internet
  printing = {
    enable = true; # enable CUPS for using printers
    drivers = [ pkgs.brlaser ]; # Brother MFC printer-scanner
  };
  openssh = {
    enable = true; # enable SSH
    #settings.PasswordAuthentication = false; # key-only for security reasons, bleh
    settings.KbdInteractiveAuthentication = false; # closes the PAM side-door that can still accept passwords
  };
  blueman.enable = true; # convenient bluetooth GUI
  gvfs.enable = true; # required for Thunar to use .local/share/Trash

  # Power Management / Hardware
  power-profiles-daemon.enable = false; # don't fight tlp
  tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 90;
      STOP_CHARGE_THRESH_BAT0 = 95;
      # PCIe runtime PM: "on" = always on, "auto" = let devices suspend to low-power states
      # "auto" on AC too: don't power on the dGPU if it's not needed
      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";
      # Governor:
      #   "performance" = p-states pinned max, EPP pinned performance
      #   "powersave" = full HWP range (can still boost to max under load)
      CPU_SCALING_GOVERNOR_ON_AC  = "powersave";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      # EPP: the main efficiency knob, controls frequency scaling behavior via 'cpufreq' sysfs interface
      #   "power" = 255
      #   "balance_power" = 192
      #   "default" = mystery firmware pick... probably 128
      #   "balance_performance" = 128
      #   "performance" = 0
      CPU_ENERGY_PERF_POLICY_ON_AC  = "balance_performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      # Turbo: 1 = allowed, 0 = capped at base clocks
      CPU_BOOST_ON_AC  = 1;
      CPU_BOOST_ON_BAT = 0;
      # ThinkPad platform_profile (ACPI): fan curves, firmware PL1/PL2, etc.
      PLATFORM_PROFILE_ON_AC  = "performance";
      PLATFORM_PROFILE_ON_BAT = "low-power";
    };
  };
  thermald.enable = true; # Intel thermal daemon
  upower.enable = true; # dbus service that abstracts PM hardware an gives a nice API rather than poking /sys directly
  thinkfan = {
    enable = true;
    levels = [
      [ 0                    0  60 ]
      [ 1                   55  68 ]
      [ 2                   64  82 ]
      [ 3                   78  85 ]
      [ 5                   82  92 ]
      [ 7                   90  97 ]
      [ "level full-speed"  95  32767 ]
    ];
  };

  # USB Device Rules
  # udev package for KVMFR (for Looking Glass)
  udev.packages = lib.singleton (pkgs.writeTextFile
    { 
      name = "kvmfr";
      text = ''
        SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"
      '';
      destination = "/etc/udev/rules.d/70-kvmfr.rules";
    }
  );

  udev.extraRules = ''

    # Make Hyprland use the iGPU, ensuring the dGPU can be scooped up for VM use
    SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="0000:00:02.0", SYMLINK+="dri/igpu"

    # B0XX native USB
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="02a1", MODE="0666", GROUP="input"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="02a1", MODE="0666", GROUP="input"

    # Omega TC-08 DAQ
    ATTRS{idVendor}=="0ce9", MODE="0660", TAG+="uaccess"

    # GCC adapter
    SUBSYSTEM=="usb", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0337", MODE="0666"

    # Teensy 4.1
    ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
    ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789a]*", ENV{MTP_NO_PROBE}="1"
    KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666"
    KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666"
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666"

    # NXP boards (Teensy 4.x bootloader)
    KERNEL=="hidraw*", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="013*", MODE:="0666"
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="013*", MODE:="0666"

    # PicoScope
    SUBSYSTEM=="usb", ATTR{idVendor}=="0ce9", MODE="0666"

    # STM32 flashing in DFU mode
    SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0666"

    # SK-8855 sensitivity
    SUBSYSTEM=="input", ATTRS{name}=="keyd virtual pointer", ENV{ID_INPUT_MOUSE}=="1", ENV{ID_INPUT_POINTINGSTICK}="1"

    # RAPL: reapply limits immediately on AC plug/unplug
    SUBSYSTEM=="power_supply", KERNEL=="AC", RUN+="${pkgs.systemd}/bin/systemctl --no-block start rapl-limits.service"

    # Looking Glass
    SUBSYSTEM=="kvmfr", OWNER="joe", GROUP="kvm", MODE="0660"
  '';

  # Printers/scanners: access to scanner
  avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true; # enable briefly only for printer discovery on LAN
  };
};

# ============================================
# VIRTUALIZATION
# ============================================

virtualisation.spiceUSBRedirection.enable = true;

virtualisation.libvirtd = {
  enable = true;
  onBoot = "ignore"; # don't autostart VMs at boot
  onShutdown = "shutdown"; # ACPI-shutdown guests cleanly instead of suspending
  qemu = {
    package = pkgs.qemu_kvm;
    runAsRoot = true;
    swtpm.enable = true; # TPM for Win11
    vhostUserPackages = [ pkgs.virtiofsd ]; # the virtiofs daemon, for shared folder
    verbatimConfig = ''
      cgroup_device_acl = [
        "/dev/null", "/dev/full", "/dev/zero", "/dev/random", "/dev/urandom",
        "/dev/ptmx", "/dev/kvm", "/dev/userfaultfd", "/dev/kvmfr0"
      ]
    '';
  };
};

# Prevent execution and priv escelation in the shared file pool
fileSystems."/home/joe/vmshare" = {
  device = "/home/joe/.vmshare-store";
  fsType = "none";
  options = [ "bind" "nosuid" "nodev" "noexec" ];
};

# ============================================
# SYSTEM-WIDE PROGRAM CONFIG
# ============================================

programs = {
  bash = {
    enable = true;
    shellAliases = {
      rm = "trash-put"; # system-wide safety
    };
  };
  zsh = {
    enable = true;
    shellAliases = {
      rm = "trash-put"; # system-wide safety
    };
  };
  git = {
    enable = true;
    config.safe.directory = "/etc/nixos";
  };
  dconf.enable = true;
  seahorse.enable = true;
  gamescope.enable = true;
  xwayland.enable = true;
  ydotool.enable = true;
  firefox = {
    enable = true;
    preferences = {
      # Don't discard tabs under memory pressure
      #"browser.tabs.unloadOnLowMemory" = false;
      # Load all tabs at startup, no click-to-load placeholders
      #"browser.sessionstore.restore_on_demand" = false;
      # Clamp background-tab timer interval (default 1000msec) to cut idle wakeups
      #"dom.min_background_timeout_value" = 100000;
      # Pre-render tabs on hover so switching paints instantly
      #"browser.tabs.remote.warmup.enabled" = true;
    };
    preferencesStatus = "user";
  };
  nix-ld = {
    enable = true; # run things that expect FHS paths
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zstd
    ];
  };
  steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    extraPackages = with pkgs; [
      mangohud
      obs-studio-plugins.obs-vkcapture
    ];
    package = pkgs.steam.override {
      extraEnv = {
        SDL_KEYBOARD_LAYOUT = "jp";
      };
    };
  };
  hyprland = {
    enable = true;
    withUWSM = true; # prevent zombie xdg-desktop-portal-hyprland hammering CPU after logout/-in
  };
  virt-manager.enable = true;
};

# ============================================
# FONTS
# ============================================

fonts = {
  packages = with pkgs; [
    carlito
    dejavu_fonts
    ipafont
    nerd-fonts.jetbrains-mono
    kochi-substitute
    liberation_ttf
    nerd-fonts.fira-code
    nerd-fonts.symbols-only
    noto-fonts-cjk-sans
    powerline-symbols
    powerline-fonts
    source-code-pro
    ttf-bitstream-vera
  ];
  fontconfig.defaultFonts = {
    monospace = [ "FiraCode Nerd Font Mono" "Symbols Nerd Font Mono" "DejaVu Sans Mono" "IPAGothic" ];
    sansSerif = [ "DejaVu Sans" "Symbols Nerd Font" "IPAPGothic" ];
    serif     = [ "DejaVu Serif" "IPAPMincho" ];
  };
};

# ============================================
# ENV VARS
# ============================================

environment.variables = {
  QT_IM_MODULE = "fcitx";     # https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland
  XMODIFIERS = "@im=fcitx";
  SDL_IM_MODULE = "fcitx";
  GLFW_IM_MODULE = "ibus";
  QT_QPA_PLATFORMTHEME = "qt5ct";
  XDG_ICON_FALLBACK = "/etc/nixos/dotfiles/images/blankicon.png";
};

environment.sessionVariables = {
  MOZ_ENABLE_WAYLAND = "1"; # firefox wants this
  NIXOS_OZONE_WL = "1"; # make eletron apps run native wayland
  LIBVA_DRIVER_NAME = "iHD"; # VA-API on iGPU
  LIBVIRT_DEFAULT_URI = "qemu:///system";
  AQ_DRM_DEVICES = "/dev/dri/igpu"; # keep dGPU free for specific tasks
  __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
};

environment.etc."libinput/local-overrides.quirks".text = ''
  [keyd virtual pointer]
  MatchBus=usb
  MatchVendor=0x0FAC
  MatchProduct=0x1ADE
  AttrTrackpointMultiplier=2.5
'';

# ============================================
# XDG PORTAL
# ============================================

xdg.portal = {
  enable = true;
  extraPortals = with pkgs; [ xdg-desktop-portal-gtk ];
  config = {
    common = {
      default = [ "hyprland" "gtk" ]; 
      # ^ Each interface gets the first portal that implements it; hyprland for screenshare, gtk for all else
      "org.freedesktop.impl.portal.FileChooser" = "gtk";
      "org.freedesktop.impl.portal.Settings" = "gtk";
    };
  };
};

# ============================================
# USER ACCOUNT
# ============================================

users = {
  defaultUserShell = pkgs.zsh;
  groups.bodo = {}; # ensure it exists for the tmpfiles rules above
  users.joe = {
    isNormalUser = true;
    extraGroups = [
      "bodo"      # ...special group for special people
      "adbusers"  # access to android debug stuff
      "dialout"   # access to serial ports
      "libvirtd"  # access to libvirt VM management
      "kvm"       # looking glass
      "audio"     # access to audio devices
      "video"     # access to video devices
      "power"     # access to power management
      "scanner"   # access to scanner
      "lp"        # access to scanner
      "plugdev"   # access to removable/USB devices (rpi flashing etc)
      "network"   # access to network interface
      "wheel"     # access to sudo
      "input"     # access to input devices
      "uinput"    # access to virtual input devices
    ];
    openssh.authorizedKeys.keys = [
    # "ssh-ed69420 ABC67..."
    # ssh keys will go here...
    ];
  };
}; 

# ============================================
# SYSTEM PACKAGES
# ============================================

environment.systemPackages = (with pkgs; [

  # VM stuff
  freerdp # RDP client on host connects to VM NAT
  looking-glass-client # KVM frame relay implementation
  virt-manager # manage VMs
 
  # Nvidia stuff
  gpu-vm
  gpu-host
  nvidia-offload

  # Pre-userspace
  sddm-astronaut-themed # sddm login screen theme

  # HARDWARE + DRIVERS + EXTERNAL DEVICES
  acpid # watch ACPI events
  alsa-utils # sound utils
  android-tools # contains ADB, fastboot, etc
  brightnessctl # control laptop display backlight
  dfu-util # flash STM32s in DFU mode
  efibootmgr # manage boot entries on EUFI NVRAM
  exfatprogs # format stuff as exfat
  hdparm # format disks/drives
  intel-gpu-tools # check iGPU resource utilization
  lm_sensors # tons of hardware sensors
  lshw # list hardware inventory
  msr-tools # read/write to/from the MSR
  parted # format disks/drives
  pciutils # contains PCI tools like lspci
  pulseaudio # gives pactl for steam
  udisks2 # for mounting disks from userland

  # UTILS
  bc # calculations
  btop # like htop but nicer
  cachix # binary caches
  config.boot.kernelPackages.turbostat # Intel monitoring tool
  cpufrequtils # cpu frequency control/query
  curl # download web stuff
  dislocker # unlock Bitlocker encryption
  dmidecode # dump DMI/SMBIOS tables in human-readable format
  drm_info # dump info about drm devices, such as laptop panels
  file # determines file type/info
  foot # backup terminal in case wezterm is borked
  git # distributed version control system
  htop # view resource usage
  id3v2 # view/edit mp3 metadata
  iftop # like htop but for network stuff
  inetutils # network tools such as telnet
  iotop # view disk usage/processes
  kdePackages.audex # CD ripper for videos
  keyd # key remapping daemon at evdev level
  killall # allows for killing processes by name
  libinput # hyprland pulls libinput, but this gives CLI tools
  lsof # shows which processes have files/devices open
  moreutils # useful UNIX tools: ts, sponge, vidir, etc.
  neovim # vim with more goodness
  nethogs # view per-process network throughput
  nixos-option # query NixOS module options
  ntfs3g # allows to read/write NTFS
  p7zip # 7z/rar/zip compression tool
  powertop # diagnose and optimize power consumption
  ranger # TUI file browser
  rpiboot # tool to boot Pis over USB
  s-tui # terminal TUI for CPU temp/power/freq
  scanmem # ...for reverse engineering LoT2
  smartmontools # monitor storage systems (ex: SSD health)
  stress-ng # hardware stress tool
  tmux # terminal multiplexer
  traceroute # traces network hops
  trash-cli # alias rm -> similar to Recycle Bin
  unzip # extracting .zip files
  upower # dbus service for power management
  usbutils # handy USB utils like lsusb
  vim # text editor (note: home.nix has nvim)
  wget # command line network downloader
  woeusb # writes ISO to drives nicer than dd

  # LIBRARIES
  libarchive # tools for tar, zip, etc.
  libnotify # desktop notification library
  libusb1 # various; flash STM32s
  libva-utils # power management stuff
]) ++ [ powerToggle ];

################################################
########## DO NOT EVER CHANGE THIS #############
################################################
system.stateVersion = "25.11";
################################################
}
