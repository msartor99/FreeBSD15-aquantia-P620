#!/bin/sh
# ==============================================================================
# IDEMPOTENT INSTALLATION AND COMPILATION SCRIPT FOR AQUANTIA/MARVELL 10GbE
# Target: Universal Desktop Deployment (FreeBSD 14.x & 15.x)
# Version: 5.4 (Strict Sysctl Override for iflib Queue Limiting)
# File: install_aq_universal.sh
# ==============================================================================

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 ERROR: This script must be run as root." 1>&2
    exit 1
fi

WORKDIR="/root/aqtion-freebsd"
MODULE_DIR="/boot/modules"
SRC_TARBALL="/root/src.txz"

# Extract OS properties securely
SYS_VERSION=$(uname -r)
BASE_RELEASE=$(uname -r | cut -d'-' -f1-2)
MAJOR_VERSION=$(uname -K | cut -c 1-2)

echo "=========================================================================="
echo "🌐 Starting Aquantia/Marvell 10GbE Driver Installation & Debug"
echo "   Detected OS Version: FreeBSD ${SYS_VERSION}"
echo "   Base Release Target: ${BASE_RELEASE}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 0. ABSOLUTE PURGE OF PREVIOUS CONFIGURATIONS AND FILES
# ------------------------------------------------------------------------------
echo "=== [0/6] Purging all previous Aquantia drivers, builds and configurations ==="

rm -rf "$WORKDIR"
rm -rf "/tmp/AQtion"
rm -f "$SRC_TARBALL"
rm -f "${MODULE_DIR}/if_atlantic.ko"

if [ -f /usr/src/sys/dev/aq/if_aq.c.bak ]; then
    echo " [+] Restoring pristine, unpatched native if_aq.c source file..."
    cp /usr/src/sys/dev/aq/if_aq.c.bak /usr/src/sys/dev/aq/if_aq.c
fi

if [ -f /boot/loader.conf ]; then
    echo " [+] Cleaning Aquantia entries from /boot/loader.conf..."
    sed -i '' '/if_atlantic_load/d' /boot/loader.conf
    sed -i '' '/if_aq_load/d' /boot/loader.conf
    sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf
    sed -i '' '/hw.dmar.enable/d' /boot/loader.conf
    sed -i '' '/hw.aq/d' /boot/loader.conf
    sed -i '' '/dev.aq/d' /boot/loader.conf
fi

if [ -f /etc/rc.conf ]; then
    echo " [+] Cleaning Aquantia network interface from /etc/rc.conf..."
    sed -i '' '/ifconfig_aq0/d' /etc/rc.conf
fi

if [ -f /etc/sysctl.conf ]; then
    echo " [+] Cleaning Aquantia entries from /etc/sysctl.conf..."
    sed -i '' '/dev.aq/d' /etc/sysctl.conf
fi

echo " [✓] System configurations reset."

# ------------------------------------------------------------------------------
# 1. DEPENDENCIES
# ------------------------------------------------------------------------------
echo "=== [1/6] Installing dependencies (git) ==="
pkg install -y git

add_line_if_missing() {
    LINE="$1"
    FILE="$2"
    if [ ! -f "$FILE" ]; then
        touch "$FILE"
    fi
    grep -qF -- "$LINE" "$FILE" || echo "$LINE" >> "$FILE"
}

# ------------------------------------------------------------------------------
# 2. SOURCE TREE PREPARATION
# ------------------------------------------------------------------------------
echo "=== [2/6] Preparing Clean Kernel Source Tree for ${BASE_RELEASE} ==="

if [ -d "/usr/src/sys" ]; then
    echo " [!] Source tree found in /usr/src."
else
    echo " [!] Source tree missing. Attempting to fetch..."
    if echo "$SYS_VERSION" | grep -q "RELEASE"; then
        rm -f "$SRC_TARBALL"
        echo " [+] Downloading kernel sources for ${BASE_RELEASE}..."
        fetch -o "$SRC_TARBALL" "https://download.freebsd.org/releases/amd64/${BASE_RELEASE}/src.txz"
        if [ -f "$SRC_TARBALL" ]; then
            echo " [+] Extracting sources to /usr/src..."
            tar -C / -xf "$SRC_TARBALL"
            rm -f "$SRC_TARBALL"
        else
            echo " ❌ FAILED to download sources."
            exit 1
        fi
    else
        echo " ❌ WARNING: Non-RELEASE kernel detected."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. DRIVER FETCHING & PATCHING
# ------------------------------------------------------------------------------
echo "=== [3/6] Fetching Driver Source Code ==="

if [ "$MAJOR_VERSION" -eq 15 ]; then
    echo " ⚙️ FreeBSD 15.x architecture detected."
    cd /usr/src/sys/dev/aq || exit 1
    [ ! -f if_aq.c.bak ] && cp if_aq.c if_aq.c.bak
    
    echo "=== [4/6] Applying Hardware ID Patches ==="
    if ! grep -qi "0xd107" if_aq.c; then
        sed -i '' 's/{ 0, 0, 0, 0, NULL }/{ 0x1d6a, 0xd107, 0, 0, "Aquantia AQC107 NBase-T Lenovo P620" },\n\t{ 0, 0, 0, 0, NULL }/g' if_aq.c
    fi
    
    echo "=== [5/6] Building Kernel Module ==="
    cd /usr/src/sys/modules/aq || exit 1
    make clean
    make -j$(sysctl -n hw.ncpu)
    make install || exit 1
    DRIVER_NAME="if_aq"
else
    echo " ⚙️ FreeBSD 14.x architecture detected."
    cd /root || exit 1
    [ ! -d "$WORKDIR" ] && git clone https://github.com/Aquantia/aqtion-freebsd.git "$WORKDIR"
    cd "$WORKDIR" || exit 1
    git checkout . 
    make clean

    echo "=== [4/6] Applying FreeBSD 14 Patches ==="
    for f in *.[ch]; do
        grep -q "#include <unistd.h>" "$f" && sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' "$f"
    done
    sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
    sed -i '' 's/DRIVER_MODULE(atlantic, pci, aq_driver, aq_devclass, 0, 0);/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c
    for f in aq_main.c aq_media.c aq_ring.c; do
        grep -q "#include <net/if_var.h>" "$f" || sed -i '' '/#include <net\/if.h>/a\
#include <net/if_var.h>' "$f"
        sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
        sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
        sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
        sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
        sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
        sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
    done
    if ! grep -qi "0xd107" aq_main.c; then
        sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0),\
\tAQ_DEVICE(0x1d6a, 0xd107)/g' aq_main.c
    fi

    echo "=== [5/6] Building Kernel Module ==="
    make -j$(sysctl -n hw.ncpu)
    if [ -f "if_atlantic.ko" ]; then
        mkdir -p "$MODULE_DIR"
        cp if_atlantic.ko "$MODULE_DIR/"
    else
        exit 1
    fi
    DRIVER_NAME="if_atlantic"
fi

# ------------------------------------------------------------------------------
# 6. PERSISTENCE AND BUG WORKAROUNDS
# ------------------------------------------------------------------------------
echo "=== [6/6] Configuring Persistence & Bug Workarounds ==="

add_line_if_missing "${DRIVER_NAME}_load=\"YES\"" /boot/loader.conf
add_line_if_missing 'hw.pci.enable_aspm="0"' /boot/loader.conf
add_line_if_missing 'hw.dmar.enable="0"' /boot/loader.conf

# CRITICAL FIX: The iflib framework overrides loader.conf on boot. We must force limits via sysctl.conf and early loader parameters.
# Limit to exactly 8 queues (and thus 8+1=9 MSI-X vectors) to avoid PCIe lane starvation on Threadripper.
add_line_if_missing 'hw.aq.num_queues="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxds="1024"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxds="1024"' /boot/loader.conf

# Force hardware features off directly in sysctl to prevent mid-flight firmware panics
add_line_if_missing 'dev.aq.0.eee_enable="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_rx="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_tx="0"' /etc/sysctl.conf

if ! grep -q "ifconfig_aq0" /etc/rc.conf; then
    echo 'ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum -vlanhwtso"' >> /etc/rc.conf
else
    sed -i '' 's/ifconfig_aq0="DHCP"/ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum -vlanhwtso"/g' /etc/rc.conf
fi

echo "-------------------------------------------------------"
echo " ✅ INSTALLATION COMPLETE!"
echo " PLEASE REBOOT NOW. Do not kldload manually to ensure iflib parameters apply correctly."
echo "-------------------------------------------------------"
