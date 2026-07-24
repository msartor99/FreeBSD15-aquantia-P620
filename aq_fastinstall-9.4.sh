#!/bin/sh
# ==============================================================================
# IDEMPOTENT FAST INSTALLATION SCRIPT FOR AQUANTIA/MARVELL 10GbE
# Target: Universal Desktop Deployment (FreeBSD 14.x & 15.x)
# Mode: Pre-compiled binary injection (No compilation required)
# Version: 9.4 (Decoupled Offloads for Flawless bsdconfig Integration)
# File: aq_fastinstall.sh
# ==============================================================================

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 ERROR: This script must be run as root." 1>&2
    exit 1
fi

MODULE_DIR="/boot/modules"
SYS_VERSION=$(uname -r)
EXACT_VERSION=$(uname -r | cut -d'-' -f1)
DRIVER_NAME="if_atlantic"

echo "=========================================================================="
echo "⚡ Starting FAST Aquantia/Marvell 10GbE Driver Installation"
echo "   Detected OS Version: FreeBSD ${SYS_VERSION}"
echo "   Detected Target: ${EXACT_VERSION}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 0. ABSOLUTE PURGE OF PREVIOUS CONFIGURATIONS AND FILES
# ------------------------------------------------------------------------------
echo "=== [0/3] Purging all previous Aquantia drivers and configurations ==="

rm -f "${MODULE_DIR}/if_atlantic.ko"
rm -f "${MODULE_DIR}/if_aq.ko"
rm -f "/tmp/if_atlantic.ko"
rm -f "/usr/local/etc/rc.d/aq_offloads"

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
    sed -i '' '/aq_offloads_enable/d' /etc/rc.conf
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
# 1. DOWNLOAD PRE-COMPILED KERNEL MODULE BASED ON EXACT SUB-VERSION
# ------------------------------------------------------------------------------
echo "=== [1/3] Downloading Pre-compiled Kernel Module ==="

case "$EXACT_VERSION" in
    15.1)
        echo " ⚙️ FreeBSD 15.1 architecture detected."
        URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/main/FB15_1_if_atlantic.ko"
        ;;
    15.0)
        echo " ⚙️ FreeBSD 15.0 architecture detected."
        URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/main/FB15_0_if_atlantic.ko"
        ;;
    14.1|14.2)
        echo " ⚙️ FreeBSD 14.x architecture detected."
        URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/main/FB14_if_atlantic.ko"
        ;;
    *)
        echo " ❌ ERROR: Unsupported precise FreeBSD version: $EXACT_VERSION"
        exit 1
        ;;
esac

echo " [+] Fetching binary module from GitHub..."
fetch -o "/tmp/if_atlantic.ko" "$URL"

if [ ! -f "/tmp/if_atlantic.ko" ]; then
    echo " ❌ ERROR: Failed to download the kernel module from ${URL}."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. INSTALL MODULE
# ------------------------------------------------------------------------------
echo "=== [2/3] Installing Kernel Module ==="

mkdir -p "$MODULE_DIR"
mv "/tmp/if_atlantic.ko" "${MODULE_DIR}/if_atlantic.ko"
chmod 555 "${MODULE_DIR}/if_atlantic.ko"

echo " [✓] Module successfully installed to ${MODULE_DIR}/if_atlantic.ko"

# ------------------------------------------------------------------------------
# 3. PERSISTENCE AND BUG WORKAROUNDS (DECOUPLED FOR BSDCONFIG)
# ------------------------------------------------------------------------------
echo "=== [3/3] Configuring Persistence & Bug Workarounds ==="

add_line_if_missing "${DRIVER_NAME}_load=\"YES\"" /boot/loader.conf
echo " [+] Added ${DRIVER_NAME} to /boot/loader.conf"

add_line_if_missing 'hw.pci.enable_aspm="0"' /boot/loader.conf
add_line_if_missing 'hw.dmar.enable="0"' /boot/loader.conf

# Limit to exactly 8 queues to avoid PCIe lane starvation on Threadripper.
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

# CREATION OF THE RC.D SCRIPT TO APPLY HARDWARE OFFLOADS BEFORE NETWORK INITIALIZATION
echo " [+] Creating dedicated hardware offload script for bsdconfig compatibility..."
RC_SCRIPT="/usr/local/etc/rc.d/aq_offloads"

cat << 'EOF' > "$RC_SCRIPT"
#!/bin/sh
# PROVIDE: aq_offloads
# REQUIRE: root
# BEFORE: network_interfaces

. /etc/rc.subr

name="aq_offloads"
rcvar="aq_offloads_enable"
start_cmd="aq_offloads_start"

aq_offloads_start()
{
    echo "⚙️ Applying Aquantia AQ107 hardware offload workarounds..."
    if ifconfig aq0 >/dev/null 2>&1; then
        ifconfig aq0 -tso -lro -txcsum -rxcsum -vlanhwtso
    fi
}

load_rc_config $name
run_rc_command "$1"
EOF

chmod 555 "$RC_SCRIPT"
add_line_if_missing 'aq_offloads_enable="YES"' /etc/rc.conf

echo "-------------------------------------------------------"
echo " ✅ FAST INSTALLATION COMPLETE!"
echo " PLEASE REBOOT NOW."
echo " After reboot, run 'bsdconfig networking' to configure aq0."
echo "-------------------------------------------------------"
