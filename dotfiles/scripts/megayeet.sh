#!/usr/bin/env zsh
# megayeet: full system upgrade.
#           Update flake inputs -> rebuild -> commit everything -> push to GitHub.

CYAN='\033[1;36m'
PURPLE='\033[1;35m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

REPO=/etc/nixos
UPDATE_LOG=/tmp/megayeet-update.log

# --- PRINT SYSTEM INFO --------------------------------------------------------
echo -e "${CYAN}Current NixOS version:${NC}"
nixos-version
sleep 0.3

echo -e "${CYAN}Currently running NixOS generation:${NC}"
readlink /nix/var/nix/profiles/system | cut -d '-' -f 2
sleep 0.3

echo -e "${CYAN}...which was activated at:${NC}"
stat -c '%y' /run/current-system
sleep 0.3

NIXURL=$(grep 'nixpkgs.url' $REPO/flake.nix | cut -d '"' -f 2)
HMURL=$(grep 'home-manager.url' $REPO/flake.nix | cut -d '"' -f 2)
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
cd $REPO || { echo -e "${RED}cannot cd to $REPO${NC}"; exit 1; }

if [[ ! -w flake.lock ]]; then
  echo -e "${RED}flake.lock is not writable by $USER.${NC}"
  echo -e "Fix once with:  doas chown -R $USER:users $REPO"
  exit 1
fi

echo -e "${PURPLE}Updating flake inputs...${NC}"
nix flake update 2>&1 | tee $UPDATE_LOG
if (( pipestatus[1] != 0 )); then
  echo -e "${RED}flake update failed.${NC}"
  exit 1
fi

# nix prints "• Updated input 'x':" followed by "→ 'new-url' (date)" for each change
CHANGES=$(grep -E "Updated input|→" $UPDATE_LOG)
if [[ -n $CHANGES ]]; then
  echo -e "${CYAN}Updated inputs:${NC}"
  print -r -- "$CHANGES"
else
  echo -e "${CYAN}All inputs already up to date.${NC}"
fi

# Stage everything (new files included) so the flake can see it
git add -A
echo -e "\e[3m~ Flake updated successfully ~\e[0m"
sleep 0.3

# --- SYSTEM REBUILD -----------------------------------------------------------
# Still needs root (activation writes /nix/var/nix/profiles and /run).
# Root's fetcher cache now lives in /root/.cache thanks to the doas setEnv fix.
echo -e "${PURPLE}Rebuilding system in-place with flake...${NC}"
if ! doas nixos-rebuild switch --flake $REPO; then
  echo -e "${RED}nixos-rebuild failed - nothing committed or pushed.${NC}"
  echo -e "To go back to the previous inputs:  git -C $REPO checkout HEAD -- flake.lock"
  exit 1
fi

echo -e "${CYAN}System generation count:${NC}"
doas nix-env --list-generations --profile /nix/var/nix/profiles/system | wc -l

# --- DISK USAGE ---------------------------------------------------------------
echo -e "${CYAN}Disk usage summary:${NC}"
df -h | grep -v 'tmpfs' | grep -v 'efi'

# --- GIT SYNC (only after a successful rebuild) -------------------------------
echo -e "${PURPLE}Syncing $REPO to GitHub...${NC}"
git add -A

if git diff --cached --quiet; then
  echo -e "${CYAN}No changes to commit.${NC}"
else
  git commit -q -F - <<EOF
System upgrade $(date '+%Y-%m-%d %H:%M')

$CHANGES
EOF
  if (( $? != 0 )); then
    echo -e "${RED}Commit failed.${NC}"
    exit 1
  fi
fi

if git push -q; then
  echo -e "${GREEN}Git sync complete.${NC}"
else
  echo -e "${PURPLE}Push failed - the commit is saved locally; it will go up on the next push.${NC}"
fi

# --- DONE ---------------------------------------------------------------------
echo -e "${PURPLE}Full in-place system upgrade complete.${NC}"
