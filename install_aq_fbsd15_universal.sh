#!/bin/sh

# =================================================================
# Aquantia (Atlantic) 10GbE Driver Installation Script
# Optimized for FreeBSD 15.0-RELEASE & Lenovo P620 (P-Series)
# =================================================================

WORKDIR="/root/aqtion-freebsd"
MODULE_DIR="/boot/modules"
SRC_TARBALL="/root/src.txz"

# 1. Root privilege check
if [ "$(id -u)" -ne 0 ]; then 
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "=== [1/6] Installing dependencies (git) ==="
pkg install -y git

echo "=== [2/6] Verifying Kernel Source Tree ==="
if [ ! -d "/usr/src/sys" ]; then
    echo "Kernel sources not found in /usr/src/sys. Downloading..."
    if [ ! -f "$SRC_TARBALL" ]; then
        fetch -o "$SRC_TARBALL" https://download.freebsd.org/releases/amd64/15.0-RELEASE/src.txz
    fi
    tar -C / -xvf "$SRC_TARBALL"
else
    echo " [OK] Kernel sources already present."
fi

echo "=== [3/6] Fetching Driver Source Code ==="
cd /root || exit 1
if [ ! -d "$WORKDIR" ]; then
    git clone https://github.com/Aquantia/aqtion-freebsd.git
fi
cd "$WORKDIR" || exit 1
git checkout . # Reset to clean state to avoid patch collisions
make clean

echo "=== [4/6] Applying FreeBSD 15 Compatibility Patches ==="

# A. Resolve 'pause' conflict by commenting out unistd.h
# This prevents the user-space/kernel-space name collision
grep -l "#include <unistd.h>" *.[ch] | xargs sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g'

# B. Update DRIVER_MODULE macro and remove unused aq_devclass
# FreeBSD 15 expects 5 arguments for DRIVER_MODULE in this context
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic, pci, aq_driver, aq_devclass, 0, 0);/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

# C. Add net/if_var.h header
# Required for accessing opaque ifnet structures in FreeBSD 15
for f in aq_main.c aq_media.c aq_ring.c; do
    sed -i '' '/#include <net\/if.h>/a\
#include <net/if_var.h>' "$f"
done

# D. Convert to Opaque API (ifp-> to if_get*)
# Direct access to ifp members is no longer allowed
for f in aq_main.c aq_media.c aq_ring.c; do
    sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
    sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
    sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
    sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
    sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
    sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

# E. Add Lenovo P620 specific Device ID (0x07b1)
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

echo "=== [6/6] Configuring Persistence ==="

# Enable module loading at boot
if ! grep -q "if_atlantic_load" /boot/loader.conf; then
    echo 'if_atlantic_load="YES"' >> /boot/loader.conf
    echo " [+] Added if_atlantic_load to /boot/loader.conf"
fi

# Enable DHCP on the interface at boot
if ! grep -q "ifconfig_aq0" /etc/rc.conf; then
    echo 'ifconfig_aq0="DHCP"' >> /etc/rc.conf
    echo " [+] Added ifconfig_aq0 to /etc/rc.conf"
fi

echo "-------------------------------------------------------"
echo " INSTALLATION COMPLETE!"
echo " The aq0 interface will be ready after next reboot."
echo " To enable it now without rebooting:"
echo "   kldload if_atlantic"
echo "   ifconfig aq0 up"
echo "   dhclient aq0"
echo "-------------------------------------------------------"

