#!/usr/bin/env zsh
# yeet: rebuild the system from /etc/nixos.
#       With --push "message", also commit and push to GitHub after a successful rebuild.

CYAN='\033[1;36m'
PURPLE='\033[1;35m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

REPO=/etc/nixos
LOG=/tmp/yeet.log
USAGE='Usage: yeet [--push "commit message"]'

# --- ARGUMENTS ----------------------------------------------------------------
PUSH=false
MSG=""

while (( $# > 0 )); do
  case $1 in
    --push)
      if [[ -z $2 ]]; then
        echo -e "${RED}--push needs a commit message${NC}"
        echo "$USAGE"
        exit 1
      fi
      PUSH=true
      MSG=$2
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "$USAGE"
      exit 1
      ;;
  esac
done

cd $REPO || { echo -e "${RED}cannot cd to $REPO${NC}"; exit 1; }

# --- STAGE --------------------------------------------------------------------
# The flake only sees files git knows about, so new files have to be staged
# before every rebuild, whether or not we push afterwards.
echo -e "${CYAN}Staging changes...${NC}"
git add -A

# --- REBUILD ------------------------------------------------------------------
# Output goes to the screen AND to $LOG, so a failure can be searched afterwards.
echo -e "${CYAN}Rebuilding NixOS system...${NC}"
doas nixos-rebuild switch --flake $REPO 2>&1 | tee $LOG

if (( pipestatus[1] != 0 )); then
  grep -oiE "path '[^']+' does not exist" $LOG && \
    echo -e "${RED}↑ referenced file missing on disk${NC}"
  echo -e "${RED}Rebuild failed - nothing committed or pushed${NC}"
  exit 1
fi
echo -e "${GREEN}Rebuild succeeded${NC}"

# --- SYNC ---------------------------------------------------------------------
[[ $PUSH == true ]] || exit 0

if git diff --cached --quiet; then
  echo -e "${PURPLE}No changes to commit${NC}"
else
  echo -e "${CYAN}Committing...${NC}"
  git commit -q -m "$MSG" || { echo -e "${RED}Commit failed${NC}"; exit 1; }
fi

# Push even if nothing new was committed: this also sends any commits
# left over from an earlier run that couldn't reach GitHub.
echo -e "${CYAN}Pushing to GitHub...${NC}"
if git push -q; then
  echo -e "${GREEN}Push complete${NC}"
else
  echo -e "${PURPLE}Push failed - the commit is saved locally; it will go up on the next push${NC}"
  exit 1
fi
