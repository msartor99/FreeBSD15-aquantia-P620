#!/bin/sh
# ==============================================================================
# IDEMPOTENT INSTALLATION AND CONFIGURATION SCRIPT FOR AQUANTIA/MARVELL 10GbE
# Target: Universal Desktop Deployment (FreeBSD 14.x & 15.x)
# Version: 9.1 (Automated Source Version Validation for 15.1 Support)
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
BASE_RELEASE=$(uname -r | cut -d'-' -f1-2) # Strip patch level (e.g., 15.1-RELEASE-p1 -> 15.1-RELEASE)
MAJOR_VERSION=$(uname -K | cut -c 1-2)

echo "=========================================================================="
echo "🌐 Starting Aquantia/Marvell 10GbE Driver Installation & Debug"
echo "    Detected OS Version: FreeBSD ${SYS_VERSION}"
echo "    Base Release Target: ${BASE_RELEASE}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 0. ABSOLUTE PURGE OF PREVIOUS CONFIGURATIONS AND FILES
# ------------------------------------------------------------------------------
echo "=== [0/6] Purging all previous Aquantia drivers, builds and configurations ==="

rm -rf "$WORKDIR"
rm -rf "/tmp/AQtion"
rm -f "$SRC_TARBALL"
rm -f "${MODULE_DIR}/if_atlantic.ko"
rm -f "${MODULE_DIR}/if_aq.ko"

if [ -f /boot/loader.conf ]; then
    echo " [+] Cleaning Aquantia entries from /boot/loader.conf..."
    sed -i '' '/if_atlantic_load/d' /boot/loader.conf
    sed -i '' '/if_aq_load/d' /boot/loader.conf
    sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf
    sed -i '' '/hw.dmar.enable/d' /boot/loader.conf
    sed -i '' '/hw.aq/d' /boot/loader.conf
    sed -i '' '/dev.aq/d' /boot/loader.conf
    sed -i '' '/hw.atlantic/d' /boot/loader.conf
    sed -i '' '/dev.atlantic/d' /boot/loader.conf
fi

if [ -f /etc/rc.conf ]; then
    echo " [+] Cleaning Aquantia network interface from /etc/rc.conf..."
    sed -i '' '/ifconfig_aq0/d' /etc/rc.conf
    sed -i '' '/ifconfig_atlantic0/d' /etc/rc.conf
fi

if [ -f /etc/sysctl.conf ]; then
    echo " [+] Cleaning Aquantia entries from /etc/sysctl.conf..."
    sed -i '' '/dev.aq/d' /etc/sysctl.conf
    sed -i '' '/dev.atlantic/d' /etc/sysctl.conf
fi

echo " [✓] System configurations reset."

# Helper function to append a line cleanly only if it doesn't exist yet
add_line_if_missing() {
    LINE="$1"
    FILE="$2"
    if [ ! -f "$FILE" ]; then
        touch "$FILE"
    fi
    grep -qF -- "$LINE" "$FILE" || echo "$LINE" >> "$FILE"
}

# ------------------------------------------------------------------------------
# 1. DEPENDENCIES
# ------------------------------------------------------------------------------
echo "=== [1/6] Installing dependencies (git) ==="
pkg install -y git

# ------------------------------------------------------------------------------
# 2. SOURCE TREE PREPARATION & VERSION VALIDATION
# ------------------------------------------------------------------------------
echo "=== [2/6] Preparing Kernel Source Tree for ${BASE_RELEASE} ==="

if [ -d "/usr/src/sys" ]; then
    if [ -f "/usr/src/sys/conf/newvers.sh" ]; then
        SRC_REV=$(grep "^REVISION=" /usr/src/sys/conf/newvers.sh | cut -d'"' -f2)
        SRC_BR=$(grep "^BRANCH=" /usr/src/sys/conf/newvers.sh | cut -d'"' -f2)
        DETECTED_SRC="${SRC_REV}-${SRC_BR}"
        
        if [ "$DETECTED_SRC" = "$BASE_RELEASE" ]; then
            echo " [✓] Valid source tree found for ${BASE_RELEASE}."
        else
            echo " [!] Source tree mismatch (Found: ${DETECTED_SRC}, Expected: ${BASE_RELEASE})."
            echo " [+] Purging old sources to prevent kernel mismatch..."
            rm -rf /usr/src/*
        fi
    else
        echo " [!] Corrupted source tree found. Purging..."
        rm -rf /usr/src/*
    fi
fi

if [ ! -d "/usr/src/sys" ]; then
    echo " [+] Source tree missing or purged. Attempting to fetch..."
    if echo "$SYS_VERSION" | grep -q "RELEASE"; then
        echo " [+] Downloading kernel sources for RELEASE ${BASE_RELEASE}..."
        fetch -o "$SRC_TARBALL" "https://download.freebsd.org/releases/amd64/${BASE_RELEASE}/src.txz"
        if [ -f "$SRC_TARBALL" ]; then
            echo " [+] Extracting sources to /usr/src..."
            tar -C / -xf "$SRC_TARBALL"
            rm -f "$SRC_TARBALL"
        else
            echo " ❌ FAILED to download sources from official mirrors."
            exit 1
        fi
    else
        echo " [+] Non-RELEASE kernel detected. Using git to fetch sources..."
        rm -rf /usr/src/*
        git clone --depth 1 -b main https://git.freebsd.org/src.git /usr/src
        if [ $? -ne 0 ]; then
             echo " ❌ FAILED to clone kernel sources via git."
             exit 1
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 3. DRIVER DEPLOYMENT
# ------------------------------------------------------------------------------
echo "=== [3/6] Fetching Out-of-Tree Driver Source Code ==="

cd /root || exit 1
git clone https://github.com/Aquantia/aqtion-freebsd.git "$WORKDIR"
cd "$WORKDIR" || exit 1
make clean

echo "=== [4/6] Applying Code Compatibility Patches ==="

# 1. Fix the unistd.h / systm.h pause() conflict
echo " [+] Commenting out conflicting <unistd.h> includes..."
for f in *.[ch]; do
    grep -q "#include <unistd.h>" "$f" && sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' "$f"
done

# 2. Fix DRIVER_MODULE macro arguments (removed devclass argument in modern FreeBSD)
echo " [+] Stripping legacy devclass bindings..."
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic, pci, aq_driver, aq_devclass, 0, 0);/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

# 3. FreeBSD 15 IfAPI Transition (Opaque ifnet structure)
echo " [+] Migrating structures to IfAPI accessors..."
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

# 4. Inject specific Lenovo P620 Hardware ID (0xd107)
echo " [+] Injecting Aquantia AQC107 Device ID (0xd107)..."
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
    echo " ❌ Compilation FAILED."
    exit 1
fi
DRIVER_NAME="if_atlantic"
INTERFACE_NAME="aq0"

# ------------------------------------------------------------------------------
# 4. PERSISTENCE AND BUG WORKAROUNDS
# ------------------------------------------------------------------------------
echo "=== [6/6] Configuring Persistence & Bug Workarounds ==="

add_line_if_missing "${DRIVER_NAME}_load=\"YES\"" /boot/loader.conf
echo " [+] Added ${DRIVER_NAME} to /boot/loader.conf"

add_line_if_missing 'hw.pci.enable_aspm="0"' /boot/loader.conf
add_line_if_missing 'hw.dmar.enable="0"' /boot/loader.conf

# CRITICAL FIX: Limit to exactly 8 queues to avoid PCIe lane starvation on Threadripper.
add_line_if_missing 'hw.aq.num_queues="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxds="1024"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxds="1024"' /boot/loader.conf
echo " [+] Restricted driver MSI-X vectors and ring queues to a maximum of 8."

# Force hardware features off directly in sysctl to prevent mid-flight firmware panics
add_line_if_missing 'dev.aq.0.eee_enable="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_rx="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_tx="0"' /etc/sysctl.conf

if ! grep -q "ifconfig_${INTERFACE_NAME}" /etc/rc.conf; then
    echo "ifconfig_${INTERFACE_NAME}=\"DHCP -tso -lro -txcsum -rxcsum -vlanhwtso\"" >> /etc/rc.conf
    echo " [+] Added ifconfig_${INTERFACE_NAME} with hardware offload workarounds."
else
    sed -i '' "s/ifconfig_${INTERFACE_NAME}=\"DHCP\"/ifconfig_${INTERFACE_NAME}=\"DHCP -tso -lro -txcsum -rxcsum -vlanhwtso\"/g" /etc/rc.conf
fi

echo "-------------------------------------------------------"
echo " ✅ INSTALLATION COMPLETE!"
echo " PLEASE REBOOT NOW TO ACTIVATED THE AQ107 CARD."
echo "-------------------------------------------------------"