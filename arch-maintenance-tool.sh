#!/bin/bash

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
    echo -e "${RED}Pacman is currently running (db.lck exists). Please wait for it to finish.${NC}"
    exit 1
fi

if [ -n "$SUDO_USER" ]; then
    REAL_USER=$SUDO_USER
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    echo -e "${RED}Please run this script via sudo from a user account.${NC}"
    exit 1
fi

if ! command -v paccache &> /dev/null; then
    echo -e "${YELLOW}Installing pacman-contrib for cache analysis...${NC}"
    pacman -S --noconfirm pacman-contrib &>/dev/null
fi

get_size() {
    du -s "$1" 2>/dev/null | cut -f1 || echo "0"
}

format_size() {
    numfmt --to=iec --from-unit=1K "$1"
}

clear

echo "Analyzing system..."

PAC_SAVINGS_RAW=$(paccache -rk3 -d 2>/dev/null | grep "saved" | awk '{print $(NF-1) $(NF)}')
if [[ -z "$PAC_SAVINGS_RAW" ]]; then
    PAC_SAVINGS_DISPLAY="0"
else
    PAC_SAVINGS_DISPLAY="$PAC_SAVINGS_RAW"
fi

SIZE_PAC_RAW=$(get_size /var/cache/pacman/pkg/)

AUR_DIR=""
AUR_HELPER="none"
SIZE_AUR_RAW=0

if [ -d "$USER_HOME/.cache/yay" ]; then
    AUR_DIR="$USER_HOME/.cache/yay"
    AUR_HELPER="yay"
elif [ -d "$USER_HOME/.cache/paru" ]; then
    AUR_DIR="$USER_HOME/.cache/paru"
    AUR_HELPER="paru"
fi

if [ "$AUR_HELPER" != "none" ]; then
    SIZE_AUR_RAW=$(get_size "$AUR_DIR")
fi
AUR_SAVINGS=$(format_size $SIZE_AUR_RAW)

TARGET_LOGS=51200
SIZE_LOGS_RAW=$(get_size /var/log/journal)
DIFF_LOGS=$((SIZE_LOGS_RAW - TARGET_LOGS))

if [ $DIFF_LOGS -lt 0 ]; then DIFF_LOGS=0; fi
LOGS_SAVINGS=$(format_size $DIFF_LOGS)

SIZE_CACHE_RAW=$(get_size "$USER_HOME/.cache/thumbnails")
CACHE_SAVINGS=$(format_size $SIZE_CACHE_RAW)

mapfile -t ORPHANS_LIST < <(pacman -Qtdq)
ORPHANS_COUNT=${#ORPHANS_LIST[@]}

echo ""
echo -e "${YELLOW}PROPOSED CLEANUP:${NC}"
echo -e "1. Pacman cache:    ${RED}$PAC_SAVINGS_DISPLAY${NC} (keep 3 versions)"
echo -e "2. AUR cache:       ${RED}$AUR_SAVINGS${NC} ($AUR_HELPER)"
echo -e "3. System logs:     ${RED}$LOGS_SAVINGS${NC} (reduce to 50MB)"
echo -e "4. Thumbnails:      ${RED}$CACHE_SAVINGS${NC} (clear all)"
echo -e "5. Orphan Packages: ${RED}$ORPHANS_COUNT${NC}"

if [[ $ORPHANS_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}Orphans to remove:${NC}"
    echo "${ORPHANS_LIST[*]}"
fi
echo ""

read -p "Do you want to proceed with cleanup? [y/N]: " decision
case "$decision" in
    [yY])
        echo ""
        echo -e "Starting cleanup..."
        ;;
    *)
        echo ""
        echo "Aborted."
        exit 0
        ;;
esac

paccache -r &>/dev/null
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

rm -rf "$USER_HOME/.cache/thumbnails"/* &>/dev/null

SIZE_PAC_AFTER=$(get_size /var/cache/pacman/pkg/)
SIZE_LOGS_AFTER=$(get_size /var/log/journal)
SIZE_CACHE_AFTER=$(get_size "$USER_HOME/.cache/thumbnails")

if [ "$AUR_HELPER" != "none" ]; then
    SIZE_AUR_AFTER=$(get_size "$AUR_DIR")
else
    SIZE_AUR_AFTER=0
fi

FREED_PAC=$((SIZE_PAC_RAW - SIZE_PAC_AFTER))
FREED_AUR=$((SIZE_AUR_RAW - SIZE_AUR_AFTER))
FREED_LOGS=$((SIZE_LOGS_RAW - SIZE_LOGS_AFTER))
FREED_CACHE=$((SIZE_CACHE_RAW - SIZE_CACHE_AFTER))

if [ $FREED_PAC -lt 0 ]; then FREED_PAC=0; fi
if [ $FREED_AUR -lt 0 ]; then FREED_AUR=0; fi
if [ $FREED_LOGS -lt 0 ]; then FREED_LOGS=0; fi
if [ $FREED_CACHE -lt 0 ]; then FREED_CACHE=0; fi

TOTAL_FREED=$((FREED_PAC + FREED_AUR + FREED_LOGS + FREED_CACHE))

echo ""
echo -e "${GREEN}SUCCESS${NC}"
echo -e "Total space freed: ${GREEN}$(format_size $TOTAL_FREED)${NC}"
echo -e "1. Pacman cache:    ${RED}$(format_size $FREED_PAC)${NC}"
echo -e "2. AUR cache:       ${RED}$(format_size $FREED_AUR)${NC}"
echo -e "3. System logs:     ${RED}$(format_size $FREED_LOGS)${NC}"
echo -e "4. Thumbnails:      ${RED}$(format_size $FREED_CACHE)${NC}"
if [[ $ORPHANS_COUNT -gt 0 ]]; then
    echo "5. Removed $ORPHANS_COUNT orphan packages."
fi
echo ""
