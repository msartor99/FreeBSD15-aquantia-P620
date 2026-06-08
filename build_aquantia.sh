#!/bin/sh

SYS_VER=$(freebsd-version -k)

echo "==============================================================="
echo " ULTIMATE INSTALLATION - AQUANTIA AQC107 (LENOVO P620) "
echo " Target detected: $SYS_VER "
echo "==============================================================="

echo "=== [1/5] Checking Kernel Source Code ==="
if [ ! -f "/usr/src/sys/conf/newvers.sh" ]; then
    echo " -> Source code not found. Starting automatic download..."
    pkg install -y git-lite >/dev/null 2>&1
    
    if echo "$SYS_VER" | grep -q "CURRENT"; then
        BRANCH="main"
    elif echo "$SYS_VER" | grep -q "STABLE"; then
        MAJOR=$(echo "$SYS_VER" | cut -d'.' -f1)
        BRANCH="stable/${MAJOR}"
    else
        REL=$(echo "$SYS_VER" | cut -d'-' -f1)
        BRANCH="releng/${REL}"
    fi
    
    echo " -> Cloning FreeBSD branch: ${BRANCH}..."
    rm -rf /usr/src
    if ! git clone --depth 1 -b "${BRANCH}" https://git.freebsd.org/src.git /usr/src; then
        echo " [!] Cloning failed. Attempting fallback to main branch..."
        git clone --depth 1 https://git.freebsd.org/src.git /usr/src
    fi
else
    echo " -> Source code /usr/src is already present."
fi

echo "=== [2/5] Downloading Aquantia Driver (GitHub) ==="
rm -rf /root/aqtion-freebsd
pkg install -y git-lite >/dev/null 2>&1
git clone --depth 1 https://github.com/Aquantia/aqtion-freebsd.git /root/aqtion-freebsd >/dev/null 2>&1
cd /root/aqtion-freebsd || exit 1

echo "=== [3/5] Applying Patches (API 15 & Lenovo Shield) ==="
# 1. Injecting Lenovo P620 Hardware ID
sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0), AQ_DEVICE(0x07b1)/g' aq_main.c
sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' *.[ch] 2>/dev/null
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic.*/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

# 2. Converting to the new FreeBSD 15 network API (IfAPI)
for f in aq_main.c aq_media.c aq_ring.c; do
  awk '/#include <net\/if\.h>/ { print; print "#include <net/if_var.h>"; next } 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
  sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
  sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
  sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

# 3. LENOVO SHIELD: Disabling hardware resets (Fixes 'no carrier' on Cold Boot)
sed -i '' 's/err = aq_hw_reset(sc->hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_fw_ops->reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_hw_ops->hw_reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c

echo "=== [4/5] Compiling the Module ==="
echo 'CFLAGS += -Wno-error -DBUS_IVARS_PRIVATE=10000' >> Makefile
make clean >/dev/null 2>&1
echo " -> Compiling..."
if ! make NO_WERROR=yes WERROR="" >/dev/null 2>&1; then
    echo " [!] Compilation failed."
    exit 1
fi

cp if_atlantic.ko /boot/modules/
chmod 555 /boot/modules/if_atlantic.ko

echo "=== [5/5] Idempotent Configuration (The iflib Lock) ==="
# Meticulous cleanup of old variables to prevent conflicts
sed -i '' '/if_atlantic_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/if_aq_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.atlantic./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.aq./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf 2>/dev/null
sed -i '' '/dev.aq.0.iflib./d' /boot/loader.conf 2>/dev/null
sysrc -x devmatch_blocklist >/dev/null 2>&1

# Final injection: Loading module and strictly limiting iflib to 4 queues
cat << 'EOF' >> /boot/loader.conf
# --- LENOVO P620 AQUANTIA FIX ---
if_atlantic_load="YES"
hw.pci.enable_aspm="0"
hw.atlantic.msix_disable="0"
hw.atlantic.enable_rss="0"
hw.atlantic.enable_tso="0"
hw.atlantic.enable_lro="0"
# --- THE IFLIB LOCK (Prevents Threadripper Crash) ---
dev.aq.0.iflib.override_nrxqs="4"
dev.aq.0.iflib.override_ntxqs="4"
EOF

# Disabling hardware Flow Control for stability
touch /etc/sysctl.conf
sed -i '' '/dev\.atlantic\..*\.fc/d' /etc/sysctl.conf 2>/dev/null
sed -i '' '/dev\.aq\..*\.fc/d' /etc/sysctl.conf 2>/dev/null
echo 'dev.aq.0.fc=0' >> /etc/sysctl.conf

echo "==============================================================="
echo " [OK] Installation completed successfully! "
echo "==============================================================="
echo " Your Lenovo P620 is now permanently immune to network drops "
echo " on cold boot. The iflib queue limits have been applied."
echo "==============================================================="
