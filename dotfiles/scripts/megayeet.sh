#!/usr/bin/env zsh
# Color codes
CYAN='\033[1;36m'
NC='\033[0m'
PURPLE='\033[1;35m'
RED='\033[1;31m'

# --- PRINT SYSTEM INFO --------------------------------------------------------
echo -e "${CYAN}Current NixOS version:${NC}"
nixos-version
sleep 0.3

echo -e "${CYAN}Currently running NixOS generation:${NC}"
readlink /nix/var/nix/profiles/system | cut -d '-' -f 2
sleep 0.3

echo -e "${CYAN}...which was built at:${NC}"
stat -c '%y' /run/current-system
sleep 0.3

# Show flake inputs
NIXURL=$(grep 'nixpkgs.url' /etc/nixos/flake.nix | cut -d '"' -f 2)
HMURL=$(grep 'home-manager.url' /etc/nixos/flake.nix | cut -d '"' -f 2)
echo -e "${CYAN}Current flake inputs:${NC}"
echo -e "\033[1m Nixpkgs:      \033[0m $NIXURL"
echo -e "\033[1m Home-manager: \033[0m $HMURL"
sleep 0.3

echo -e "${CYAN}Last boot time:${NC}"
systemd-analyze | head -1
sleep 0.3

# --- UPDATE FLAKE -------------------------------------------------------------
# Runs as YOU, not root. Fetching inputs and rewriting flake.lock needs no
# privileges as long as you own /etc/nixos. Running it under doas is what let
# root wander into ~/.cache/nix and trip libgit2's ownership check.
echo -e "${PURPLE}Updating flake inputs...${NC}"
cd /etc/nixos || { echo -e "${RED}cannot cd to /etc/nixos.${NC}"; exit 1; }

if [ ! -w flake.lock ]; then
    echo -e "${RED}flake.lock is not writable by $USER.${NC}"
    echo -e "Fix once with:  doas chown -R $USER:users /etc/nixos"
    exit 1
fi

if ! nix flake update; then
    echo -e "${RED}flake update failed.${NC}"
    exit 1
fi

echo -e "${CYAN}Updated packages:${NC}"
git diff flake.lock | grep -E '(Updated input|→)' | head -10

# Stage changes but don't commit yet
git add .

echo -e "\e[3m~ Flake updated successfully ~\e[0m"
sleep 0.3

# --- SYSTEM REBUILD -----------------------------------------------------------
# Still needs root (activation writes /nix/var/nix/profiles and /run).
# Root's fetcher cache now lives in /root/.cache thanks to the doas setEnv fix.
echo -e "${PURPLE}Rebuilding system in-place with flake...${NC}"
if ! doas nixos-rebuild switch --flake /etc/nixos; then
    echo -e "${RED}nixos-rebuild failed.${NC}"
    exit 1
fi

echo -e "${CYAN}System generation count:${NC}"
doas nix-env --list-generations --profile /nix/var/nix/profiles/system | wc -l

# --- DISK USAGE ---------------------------------------------------------------
echo -e "${CYAN}Disk usage summary:${NC}"
df -h | grep -v 'tmpfs' | grep -v 'efi'

# --- GIT SYNC (only after successful rebuild) ---------------------------------
if ping -c 1 -W 2 github.com >/dev/null 2>&1; then
    echo -e "${PURPLE}Syncing /etc/nixos to GitHub...${NC}"
    git commit -m "auto commit during system upgrade: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
    git pull --rebase origin main 2>/dev/null || true

    if git push -u origin main 2>/dev/null; then
        echo -e "${CYAN}Git sync complete.${NC}"
    else
        echo -e "${CYAN}Git sync failed (check connection).${NC}"
    fi
else
    echo -e "${CYAN}Git sync skipped (GitHub unreachable).${NC}"
fi

# --- DONE ---------------------------------------------------------------------
echo -e "${PURPLE}Full in-place system upgrade complete.${NC}"
