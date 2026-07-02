#!/bin/sh
# ==============================================================================
# IDEMPOTENT INSTALLATION AND CONFIGURATION SCRIPT FOR AQUANTIA/MARVELL 10GbE
# Target: Universal Desktop Deployment (FreeBSD 14.x & 15.x)
# Version: 9.6 (Native bsddialog Interface & Universal English Finalizer)
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
TMP_DATA="/tmp/aq_dialog_data.txt"

# Extract OS properties securely
SYS_VERSION=$(uname -r)
BASE_RELEASE=$(uname -r | cut -d'-' -f1-2)
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
rm -f "/usr/local/etc/rc.d/aq_offloads"
rm -f "$TMP_DATA"

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
    sed -i '' '/defaultrouter/d' /etc/rc.conf
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

# 2. Fix DRIVER_MODULE macro arguments
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

# ------------------------------------------------------------------------------
# 4. PERSISTENCE AND SYSTEM TUNING
# ------------------------------------------------------------------------------
echo "=== [6/6] Configuring Persistence & System Tuning ==="

add_line_if_missing "${DRIVER_NAME}_load=\"YES\"" /boot/loader.conf
echo " [+] Added ${DRIVER_NAME} to /boot/loader.conf"

add_line_if_missing 'hw.pci.enable_aspm="0"' /boot/loader.conf
add_line_if_missing 'hw.dmar.enable="0"' /boot/loader.conf

# Limit queues to avoid PCIe lane starvation on Threadripper.
add_line_if_missing 'hw.aq.num_queues="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxqs="8"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_nrxds="1024"' /boot/loader.conf
add_line_if_missing 'dev.aq.0.iflib.override_ntxds="1024"' /boot/loader.conf

# Force hardware features off directly in sysctl to prevent mid-flight firmware panics
add_line_if_missing 'dev.aq.0.eee_enable="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_rx="0"' /etc/sysctl.conf
add_line_if_missing 'dev.aq.0.fc_tx="0"' /etc/sysctl.conf

# Create the detached hardware offload manager for bsdconfig flexibility
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

# ------------------------------------------------------------------------------
# 5. NATIVE TUI NETWORK CONFIGURATION (bsddialog implementation)
# ------------------------------------------------------------------------------

# Loop for IP Address Input
while :; do
    bsddialog --title "Aquantia IP Setup" --inputbox "Enter the static IP address for aq0:" 0 0 "192.168.254.3" 2> "$TMP_DATA"
    [ $? -ne 0 ] && continue
    USER_IP=$(cat "$TMP_DATA")
    [ -n "$USER_IP" ] && break
done

# Smart Netmask Auto-Calculation
FIRST_OCTET=$(echo "$USER_IP" | cut -d'.' -f1)
if [ "$FIRST_OCTET" -ge 192 ] && [ "$FIRST_OCTET" -le 223 ]; then
    DEFAULT_MASK="255.255.255.0"
elif [ "$FIRST_OCTET" -ge 128 ] && [ "$FIRST_OCTET" -le 191 ]; then
    DEFAULT_MASK="255.255.0.0"
elif [ "$FIRST_OCTET" -ge 1 ] && [ "$FIRST_OCTET" -le 127 ]; then
    DEFAULT_MASK="255.0.0.0"
else
    DEFAULT_MASK="255.255.255.0"
fi

# Loop for Netmask Input
while :; do
    bsddialog --title "Aquantia Netmask Setup" --inputbox "Enter the subnet mask:" 0 0 "$DEFAULT_MASK" 2> "$TMP_DATA"
    [ $? -ne 0 ] && continue
    USER_MASK=$(cat "$TMP_DATA")
    [ -n "$USER_MASK" ] && break
done

# Loop for Gateway Input
while :; do
    bsddialog --title "Aquantia Gateway Setup" --inputbox "Enter the default gateway address:" 0 0 "192.168.254.1" 2> "$TMP_DATA"
    [ $? -ne 0 ] && continue
    USER_GW=$(cat "$TMP_DATA")
    [ -n "$USER_GW" ] && break
done

# Loop for Primary DNS Input
while :; do
    bsddialog --title "Aquantia DNS Setup" --inputbox "Enter the primary DNS server:" 0 0 "1.1.1.1" 2> "$TMP_DATA"
    [ $? -ne 0 ] && continue
    USER_DNS1=$(cat "$TMP_DATA")
    [ -n "$USER_DNS1" ] && break
done

# Optional Secondary DNS Input
bsddialog --title "Aquantia DNS Setup" --inputbox "Enter the secondary DNS server (Optional):" 0 0 "" 2> "$TMP_DATA"
USER_DNS2=$(cat "$TMP_DATA")

# ------------------------------------------------------------------------------
# 6. FILE INJECTION & FINALIZATION WITH TUI PAUSE
# ------------------------------------------------------------------------------
echo " [+] Injecting network properties into /etc/rc.conf..."
add_line_if_missing "ifconfig_aq0=\"inet ${USER_IP} netmask ${USER_MASK}\"" /etc/rc.conf
add_line_if_missing "defaultrouter=\"${USER_GW}\"" /etc/rc.conf

echo " [+] Updating DNS resolving table in /etc/resolv.conf..."
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak

echo "# Generated by Aquantia Setup Script" > /etc/resolv.conf
echo "nameserver ${USER_DNS1}" >> /etc/resolv.conf
if [ -n "$USER_DNS2" ]; then
    echo "nameserver ${USER_DNS2}" >> /etc/resolv.conf
fi

# Clean up temp dialog data
rm -f "$TMP_DATA"

# Universal English completion message inside a native TUI window with operator blocking/pause
FINAL_MSG="The configuration of the AQ107 card is complete.\nThe IP address ${USER_IP} has been successfully configured.\n\nIn case of issues, please use 'bsdconfig' (Network section) to modify the parameters of the card.\n\nThank you."

bsddialog --title "Configuration Complete" --msgbox "$FINAL_MSG" 0 0

clear
echo "-------------------------------------------------------"
echo " ✅ SCRIPT FINISHED. PLEASE REBOOT YOUR SYSTEM NOW."
echo "-------------------------------------------------------"