#!/bin/sh

# Colors (ANSI escape sequences for FreeBSD /bin/sh via printf)
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

printf "${BLUE}===> Automatic Build & Setup for 'aq' Driver (Idempotent)${NC}\n"

# 1. Exact system kernel version detection (e.g., 15.1-RELEASE-p2)
SYS_VER=$(freebsd-version -k)
printf "${GREEN}[1/5] Detected running kernel: %s${NC}\n" "$SYS_VER"

# Extract version branch (e.g., 15.1 -> releng/15.1)
RELENG_BRANCH=$(echo "$SYS_VER" | sed -E 's/([0-9]+\.[0-9]+)-RELEASE.*/releng\/\1/')
printf "${BLUE}Targeting kernel source branch: %s${NC}\n" "$RELENG_BRANCH"

# 2. Dependency check and kernel sources retrieval
printf "${GREEN}[2/5] Checking build tools and kernel sources...${NC}\n"
pkg install -y git gmake 2>/dev/null

if [ ! -f "/usr/src/sys/kern/init_main.c" ]; then
    printf "${BLUE}Kernel sources missing in /usr/src. Fetching %s...${NC}\n" "$RELENG_BRANCH"
    git clone --depth 1 -b "$RELENG_BRANCH" https://git.freebsd.org/src.git /usr/src
else
    printf "${BLUE}Kernel sources already present in /usr/src.${NC}\n"
fi

# 3. Workspace preparation
WORK_DIR="/tmp/aq_force_16"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# 4. Fetch modern driver source code from freebsd-src tree
printf "${GREEN}[3/5] Fetching modern 'aq' driver source code...${NC}\n"
git clone --depth 1 --filter=blob:none --sparse https://github.com/freebsd/freebsd-src.git fbsd_16
cd fbsd_16
git sparse-checkout set sys/dev/aq sys/modules/aq

DEV_AQ_SRC="$(pwd)/sys/dev/aq"
MOD_AQ_SRC="$(pwd)/sys/modules/aq"

# 5. Kernel module compilation
printf "${GREEN}[4/5] Compiling if_aq.ko module...${NC}\n"
cd "$MOD_AQ_SRC"
export SYSDIR=/usr/src/sys
sed -i '' "s|\${SRCTOP}/sys/dev/aq|$DEV_AQ_SRC|g" Makefile

make clean && make

if [ ! -f "if_aq.ko" ]; then
    printf "${RED}Error: Compilation of if_aq.ko failed.${NC}\n"
    exit 1
fi

# 6. Idempotent Installation and Configuration
printf "${GREEN}[5/5] Installing module and updating configurations...${NC}\n"

# Binary installation
mkdir -p /boot/modules
cp if_aq.ko /boot/modules/
chmod 555 /boot/modules/if_aq.ko

# Safe helper function for loader.conf (bypasses sysrc limitations with dots in variable names)
update_loader() {
    local var="$1"
    local val="$2"
    [ -f /boot/loader.conf ] && sed -i '' "/${var}=/d" /boot/loader.conf
    echo "${var}=\"${val}\"" >> /boot/loader.conf
}

# Cleanup outdated driver entries in loader.conf
sed -i '' '/if_atlantic/d' /boot/loader.conf 2>/dev/null || true

# Cleanup obsolete OIDs from sysctl.conf that cause boot errors
if [ -f /etc/sysctl.conf ]; then
    sed -i '' '/dev.aq.0/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '' '/compat.linux.print_warnings/d' /etc/sysctl.conf 2>/dev/null || true
fi

# Apply Single Queue stability settings (Aquantia PHY fix)
update_loader "if_aq_load" "YES"
update_loader "hw.aq.num_queues" "1"
update_loader "dev.aq.0.iflib.override_nrxqs" "1"
update_loader "dev.aq.0.iflib.override_ntxqs" "1"

# Network configuration in /etc/rc.conf
sysrc ifconfig_aq0="DHCP"

# 7. Dynamic module reloading attempt
printf "${BLUE}Attempting runtime module update...${NC}\n"

ifconfig aq0 down 2>/dev/null || true
kldunload if_aq 2>/dev/null || true
kldunload if_atlantic 2>/dev/null || true

kldload /boot/modules/if_aq.ko 2>/dev/null || true

printf "${GREEN}!!! SETUP COMPLETE !!!${NC}\n"
printf "${BLUE}/boot/loader.conf configured with Single Queue parameters.${NC}\n"
printf "${BLUE}Obsolete sysctl entries cleaned up from /etc/sysctl.conf.${NC}\n"
printf "${BLUE}A REBOOT is recommended for the kernel to enforce queue limits cleanly.${NC}\n"