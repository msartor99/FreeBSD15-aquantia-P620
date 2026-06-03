#!/bin/sh

# =================================================================
# Aquantia (Atlantic) 10GbE Driver Installation Script
# Optimized for FreeBSD 15.x & Lenovo P620 (P-Series)
# =================================================================

WORKDIR="/root/aqtion-freebsd"
MODULE_DIR="/boot/modules"
SRC_TARBALL="/root/src.txz"
SYS_VERSION=$(uname -r)

# 1. Root privilege check
if [ "$(id -u)" -ne 0 ]; then 
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "=== [1/6] Installing dependencies (git) ==="
pkg install -y git

echo "=== [2/6] Preparing Clean Kernel Source Tree for ${SYS_VERSION} ==="

# IDEMPOTENCE: Purge de l'ancien dossier et de l'archive pour éviter tout conflit d'ABI
if [ -d "/usr/src" ]; then
    echo " [!] Ancien dossier /usr/src détecté. Suppression en cours..."
    rm -rf /usr/src
fi

if [ -f "$SRC_TARBALL" ]; then
    echo " [!] Ancienne archive source détectée. Suppression..."
    rm -f "$SRC_TARBALL"
fi

echo " [+] Téléchargement des sources du noyau pour ${SYS_VERSION}..."
fetch -o "$SRC_TARBALL" "https://download.freebsd.org/releases/amd64/${SYS_VERSION}/src.txz"

echo " [+] Extraction des sources..."
tar -C / -xf "$SRC_TARBALL"

echo "=== [3/6] Fetching Driver Source Code ==="
cd /root || exit 1
if [ ! -d "$WORKDIR" ]; then
    git clone https://github.com/Aquantia/aqtion-freebsd.git
fi
cd "$WORKDIR" || exit 1
git checkout . 
make clean

echo "=== [4/6] Applying FreeBSD 15 Compatibility Patches ==="

grep -l "#include <unistd.h>" *.[ch] | xargs sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g'

sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic, pci, aq_driver, aq_devclass, 0, 0);/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

for f in aq_main.c aq_media.c aq_ring.c; do
    sed -i '' '/#include <net\/if.h>/a\
#include <net/if_var.h>' "$f"
done

for f in aq_main.c aq_media.c aq_ring.c; do
    sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
    sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
    sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
    sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
    sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
    sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0),\
\tAQ_DEVICE(0x07b1)/g' aq_main.c

echo "=== [5/6] Building and Installing Kernel Module ==="
make
if [ -f "if_atlantic.ko" ]; then
    mkdir -p "$MODULE_DIR"
    cp if_atlantic.ko "$MODULE_DIR/"
    echo " [+] Module successfully installed to $MODULE_DIR"
else
    echo " [!] Compilation FAILED."
    exit 1
fi

echo "=== [6/6] Configuring Persistence & Bug Workarounds ==="

if ! grep -q "if_atlantic_load" /boot/loader.conf; then
    echo 'if_atlantic_load="YES"' >> /boot/loader.conf
    echo " [+] Added if_atlantic_load to /boot/loader.conf"
fi

# BUG FIX: Disable Hardware Offloading (TSO, LRO, Checksums) which causes Aquantia chips to crash/power off
if ! grep -q "ifconfig_aq0" /etc/rc.conf; then
    echo 'ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum"' >> /etc/rc.conf
    echo " [+] Added ifconfig_aq0 with hardware offload workarounds to /etc/rc.conf"
else
    # Update existing entry if present
    sed -i '' 's/ifconfig_aq0="DHCP"/ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum"/g' /etc/rc.conf
fi

echo "-------------------------------------------------------"
echo " INSTALLATION COMPLETE!"
echo " The aq0 interface will be ready after next reboot."
echo " To enable it now without rebooting:"
echo "   kldload if_atlantic"
echo "   ifconfig aq0 -tso -lro -txcsum -rxcsum up"
echo "   dhclient aq0"
echo "-------------------------------------------------------"
