#!/bin/sh
# ==============================================================================
# IDEMPOTENT FAST INSTALLATION SCRIPT FOR AQUANTIA/MARVELL 10GbE
# Target: Universal Desktop Deployment (FreeBSD 14.x & 15.x)
# Mode: Pre-compiled binary injection (No compilation required)
# File: aq_fastinstall.sh
# ==============================================================================

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 ERROR: This script must be run as root." 1>&2
    exit 1
fi

MODULE_DIR="/boot/modules"
SYS_VERSION=$(uname -r)
MAJOR_VERSION=$(uname -K | cut -c 1-2)
DRIVER_NAME="if_atlantic"
INTERFACE_NAME="aq0"

echo "=========================================================================="
echo "⚡ Starting FAST Aquantia/Marvell 10GbE Driver Installation"
echo "   Detected OS Version: FreeBSD ${SYS_VERSION}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 0. ABSOLUTE PURGE OF PREVIOUS CONFIGURATIONS AND FILES
# ------------------------------------------------------------------------------
echo "=== [0/3] Purging all previous Aquantia drivers and configurations ==="

rm -f "${MODULE_DIR}/if_atlantic.ko"
rm -f "${MODULE_DIR}/if_aq.ko"
rm -f "/tmp/if_atlantic.ko"

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
# 1. DOWNLOAD PRE-COMPILED KERNEL MODULE
# ------------------------------------------------------------------------------
echo "=== [1/3] Downloading Pre-compiled Kernel Module ==="

if [ "$MAJOR_VERSION" -eq 15 ]; then
    echo " ⚙️ FreeBSD 15.x architecture detected."
    # Use RAW Github URL to fetch the binary file, not the HTML wrapper
    URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/cac5ac6ac55c4c08dce89b8a59a6204267c7d5f9/FB15_if_atlantic.ko"
elif [ "$MAJOR_VERSION" -eq 14 ]; then
    echo " ⚙️ FreeBSD 14.x architecture detected."
    # Use RAW Github URL to fetch the binary file, not the HTML wrapper
    URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/cac5ac6ac55c4c08dce89b8a59a6204267c7d5f9/FB14_if_atlantic.ko"
else
    echo " ❌ ERROR: Unsupported FreeBSD major version: $MAJOR_VERSION"
    exit 1
fi

echo " [+] Fetching binary module from GitHub..."
fetch -o "/tmp/if_atlantic.ko" "$URL"

if [ ! -f "/tmp/if_atlantic.ko" ]; then
    echo " ❌ ERROR: Failed to download the kernel module."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. INSTALL MODULE
# ------------------------------------------------------------------------------
echo "=== [2/3] Installing Kernel Module ==="

mkdir -p "$MODULE_DIR"
mv "/tmp/if_atlantic.ko" "${MODULE_DIR}/if_atlantic.ko"
# Ensure the module has the correct executable permissions for the kernel linker
chmod 555 "${MODULE_DIR}/if_atlantic.ko"

echo " [✓] Module successfully installed to ${MODULE_DIR}/if_atlantic.ko"

# ------------------------------------------------------------------------------
# 3. PERSISTENCE AND BUG WORKAROUNDS
# ------------------------------------------------------------------------------
echo "=== [3/3] Configuring Persistence & Bug Workarounds ==="

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
echo " ✅ FAST INSTALLATION COMPLETE!"
echo " PLEASE REBOOT NOW."
echo "-------------------------------------------------------"
