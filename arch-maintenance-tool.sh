#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run with sudo.${NC}"
   exit 1
fi

if [ -f /var/lib/pacman/db.lck ]; then
    echo -e "${RED}Pacman is currently running (db.lck exists). Please wait.${NC}"
    exit 1
fi

if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER=$SUDO_USER
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    echo -e "${RED}Run this script via sudo from a user account.${NC}"
    exit 1
fi

if ! command -v paccache &> /dev/null; then
    echo -e "${YELLOW}Installing pacman-contrib...${NC}"
    pacman -S --noconfirm pacman-contrib &>/dev/null
fi

get_size() {
    du -s "$1" 2>/dev/null | cut -f1 || echo "0"
}

format_size() {
    numfmt --to=iec --from-unit=1K "$1"
}

clear
echo -e "${BLUE}Analyzing system...${NC}"

SIZE_PAC_BEFORE=$(get_size /var/cache/pacman/pkg/)
SIZE_LOGS_BEFORE=$(get_size /var/log/journal)
SIZE_CACHE_BEFORE=$(get_size "$USER_HOME/.cache/thumbnails")

AUR_DIR=""
AUR_HELPER="none"
SIZE_AUR_BEFORE=0

if [ -d "$USER_HOME/.cache/yay" ]; then
    AUR_DIR="$USER_HOME/.cache/yay"
    AUR_HELPER="yay"
elif [ -d "$USER_HOME/.cache/paru" ]; then
    AUR_DIR="$USER_HOME/.cache/paru"
    AUR_HELPER="paru"
fi

if [ "$AUR_HELPER" != "none" ]; then
    SIZE_AUR_BEFORE=$(get_size "$AUR_DIR")
fi

mapfile -t ORPHANS_LIST < <(pacman -Qtdq || true)
ORPHANS_COUNT=${#ORPHANS_LIST[@]}

TARGET_LOGS=51200
LOGS_TO_REMOVE=0
if [ "$SIZE_LOGS_BEFORE" -gt "$TARGET_LOGS" ]; then
    LOGS_TO_REMOVE=$((SIZE_LOGS_BEFORE - TARGET_LOGS))
fi

echo ""
echo -e "${YELLOW}CURRENT SYSTEM STATE:${NC}"
echo -e "1. Pacman cache:     ${RED}$(format_size $SIZE_PAC_BEFORE)${NC} (target: keep 3 latest versions)"
echo -e "2. AUR cache ($AUR_HELPER):  ${RED}$(format_size $SIZE_AUR_BEFORE)${NC} (target: clear all)"
echo -e "3. System logs:      ${RED}$(format_size $SIZE_LOGS_BEFORE)${NC} (target: 50MB)"
echo -e "4. Thumbnails:       ${RED}$(format_size $SIZE_CACHE_BEFORE)${NC} (target: clear all)"
echo -e "5. Orphan Packages:  ${RED}$ORPHANS_COUNT${NC}"

if [[ $ORPHANS_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}Orphans detected:${NC}"
    echo "${ORPHANS_LIST[*]}"
fi
echo ""

read -p "Proceed with cleanup? [y/N]: " decision
case "$decision" in
    [yY]) echo "" ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo -e "${BLUE}Starting cleanup...${NC}"

paccache -rk3 &>/dev/null
paccache -ruk0 &>/dev/null

if [ "$AUR_HELPER" == "yay" ]; then
    sudo -u "$REAL_USER" yay -Sc --noconfirm &>/dev/null
elif [ "$AUR_HELPER" == "paru" ]; then
    sudo -u "$REAL_USER" paru -Sc --noconfirm &>/dev/null
fi

if [[ $ORPHANS_COUNT -gt 0 ]]; then
    pacman -Rns "${ORPHANS_LIST[@]}" --noconfirm &>/dev/null
fi

journalctl --vacuum-size=50M &>/dev/null

if [ -d "$USER_HOME/.cache/thumbnails" ]; then
    rm -rf "$USER_HOME/.cache/thumbnails"/*
fi

SIZE_PAC_AFTER=$(get_size /var/cache/pacman/pkg/)
SIZE_LOGS_AFTER=$(get_size /var/log/journal)
SIZE_CACHE_AFTER=$(get_size "$USER_HOME/.cache/thumbnails")

if [ "$AUR_HELPER" != "none" ]; then
    SIZE_AUR_AFTER=$(get_size "$AUR_DIR")
else
    SIZE_AUR_AFTER=0
fi

FREED_PAC=$((SIZE_PAC_BEFORE - SIZE_PAC_AFTER))
FREED_AUR=$((SIZE_AUR_BEFORE - SIZE_AUR_AFTER))
FREED_LOGS=$((SIZE_LOGS_BEFORE - SIZE_LOGS_AFTER))
FREED_CACHE=$((SIZE_CACHE_BEFORE - SIZE_CACHE_AFTER))

TOTAL_FREED=$((FREED_PAC + FREED_AUR + FREED_LOGS + FREED_CACHE))

echo ""
echo -e "${GREEN}SUCCESS${NC}"
echo -e "Total space freed:  ${GREEN}$(format_size $TOTAL_FREED)${NC}"
echo -e "1. Pacman cache:    $(format_size $FREED_PAC)"
echo -e "2. AUR cache:       $(format_size $FREED_AUR)"
echo -e "3. System logs:     $(format_size $FREED_LOGS)"
echo -e "4. Thumbnails:      $(format_size $FREED_CACHE)"
if [[ $ORPHANS_COUNT -gt 0 ]]; then
    echo "5. Removed $ORPHANS_COUNT orphan packages."
fi
echo ""
