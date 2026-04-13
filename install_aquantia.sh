#!/bin/sh

echo "==============================================================="
echo " QUICK DEPLOYMENT - AQUANTIA DRIVER (LENOVO P620) "
echo "==============================================================="

# === 1. System Version Check ===
KERN_VER=$(freebsd-version -k)
echo "[*] Detected kernel version: $KERN_VER"

if [ "$KERN_VER" != "15.0-RELEASE-p5" ]; then
    echo " [!] WARNING: This driver was compiled specifically for 15.0-RELEASE-p5."
    echo "     Using a different version may cause a Kernel Panic."
    echo "     Cancel with Ctrl+C or wait 5 seconds to force installation..."
    sleep 5
fi

# === 2. Fetch Module from GitHub ===
echo "[*] Downloading if_atlantic.ko from GitHub..."
pkg install -y git-lite >/dev/null 2>&1

# Use /tmp to avoid cluttering the system
rm -rf /tmp/aquantia_repo
git clone --depth 1 https://github.com/msartor99/FreeBSD15-aquantia-P620.git /tmp/aquantia_repo >/dev/null 2>&1

if [ ! -f "/tmp/aquantia_repo/if_atlantic.ko" ]; then
    echo " [!] Error: if_atlantic.ko not found in the repository."
    exit 1
fi

echo "[*] Installing module to /boot/modules/..."
cp /tmp/aquantia_repo/if_atlantic.ko /boot/modules/
chmod 555 /boot/modules/if_atlantic.ko

# === 3. Idempotent Configuration: /boot/loader.conf ===
echo "[*] Configuring kernel parameters (loader.conf)..."
# Purge any existing traces to guarantee idempotence
sed -i '' '/if_aq_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/if_atlantic_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.atlantic./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.aq./d' /boot/loader.conf 2>/dev/null

# Inject the optimal configuration
cat << 'EOF' >> /boot/loader.conf
# --- LENOVO P620 AQUANTIA WORKAROUND ---
if_atlantic_load="YES"
hw.pci.enable_aspm="0"
hw.atlantic.msix_disable="1"
hw.atlantic.enable_rss="0"
hw.atlantic.enable_tso="0"
hw.atlantic.enable_lro="0"
hw.atlantic.max_queues="1"
EOF

# === 4. Idempotent Configuration: /etc/rc.conf ===
echo "[*] Configuring network interface (rc.conf)..."
# Remove any old configuration for aq0
sed -i '' '/ifconfig_aq0/d' /etc/rc.conf 2>/dev/null

# Inject configuration to disable hardware offloading
echo 'ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum"' >> /etc/rc.conf

# === 5. Final Cleanup ===
rm -rf /tmp/aquantia_repo

echo "==============================================================="
echo " [OK] Installation completed successfully! "
echo "==============================================================="
echo " IMPORTANT: You must reboot the machine (preferably a Cold Boot)"
echo " to ensure the motherboard validates the ASPM power protection."
echo "==============================================================="
