#!/bin/sh

KERN_VER=$(freebsd-version -k)

echo "==============================================================="
echo " INSTALLATION ULTIME - AQUANTIA LENOVO P620 "
echo " Cible : $KERN_VER "
echo "==============================================================="

echo "=== [1/6] Neutralisation du pilote natif (Anti-Cold Boot Crash) ==="
# On empêche FreeBSD de charger son pilote natif par erreur
sysrc devmatch_blocklist+="if_aq" >/dev/null 2>&1
# On ampute le fichier physique pour être sûr à 100%
if [ -f "/boot/kernel/if_aq.ko" ]; then
    mv /boot/kernel/if_aq.ko /boot/kernel/if_aq.ko.bak
    echo " -> Pilote natif if_aq.ko neutralisé."
fi
kldunload -f if_aq 2>/dev/null
kldunload -f if_atlantic 2>/dev/null

echo "=== [2/6] Préparation et Téléchargement ==="
if [ ! -f "/usr/src/sys/conf/newvers.sh" ]; then
    echo " [!] ERREUR : Code source /usr/src introuvable."
    exit 1
fi
pkg install -y git-lite >/dev/null 2>&1
rm -rf /root/aqtion-freebsd
git clone --depth 1 https://github.com/Aquantia/aqtion-freebsd.git /root/aqtion-freebsd >/dev/null 2>&1
cd /root/aqtion-freebsd || exit 1

echo "=== [3/6] Application des Patchs (API 15 & Lenovo Hack) ==="
sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0), AQ_DEVICE(0x07b1)/g' aq_main.c
sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' *.[ch] 2>/dev/null
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic.*/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

for f in aq_main.c aq_media.c aq_ring.c; do
  awk '/#include <net\/if\.h>/ { print; print "#include <net/if_var.h>"; next } 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
  sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
  sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
  sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

# Bouclier d'alimentation Lenovo
sed -i '' 's/err = aq_hw_reset(sc->hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_fw_ops->reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_hw_ops->hw_reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c

echo "=== [4/6] Compilation ==="
echo 'CFLAGS += -Wno-error -DBUS_IVARS_PRIVATE=10000' >> Makefile
make clean >/dev/null 2>&1
if ! make NO_WERROR=yes WERROR="" >/dev/null 2>&1; then
    echo " [!] Échec de la compilation."
    exit 1
fi
cp if_atlantic.ko /boot/modules/

echo "=== [5/6] Configuration Idempotente (Loader, rc, sysctl) ==="
# --- LOADER.CONF ---
# Nettoyage des anciennes entrées
sed -i '' '/if_atlantic_load/d' /boot/loader.conf
sed -i '' '/if_aq_load/d' /boot/loader.conf
sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf
sed -i '' '/hw.atlantic./d' /boot/loader.conf
sed -i '' '/hw.aq./d' /boot/loader.conf

cat << 'INNER_EOF' >> /boot/loader.conf
# --- HACK LENOVO P620 AQUANTIA ---
if_atlantic_load="YES"
hw.pci.enable_aspm="0"
hw.atlantic.msix_disable="0"
hw.aq.msix_disable="0"
hw.atlantic.max_queues="8"
hw.aq.max_queues="8"
hw.atlantic.enable_rss="0"
hw.atlantic.enable_tso="0"
hw.atlantic.enable_lro="0"
hw.aq.enable_rss="0"
hw.aq.enable_tso="0"
hw.aq.enable_lro="0"
INNER_EOF

# --- RC.CONF ---
sed -i '' '/ifconfig_aq0/d' /etc/rc.conf
# Adapter "DHCP" par votre IP fixe si nécessaire (ex: inet 192.168.1.50 netmask 255.255.255.0)
echo 'ifconfig_aq0="DHCP -tso -lro -txcsum -rxcsum"' >> /etc/rc.conf

# --- SYSCTL.CONF (Flow Control) ---
touch /etc/sysctl.conf
sed -i '' '/dev\.atlantic\..*\.fc/d' /etc/sysctl.conf
sed -i '' '/dev\.aq\..*\.fc/d' /etc/sysctl.conf
echo 'dev.atlantic.0.fc=0' >> /etc/sysctl.conf
echo 'dev.aq.0.fc=0' >> /etc/sysctl.conf

echo "=== [6/6] Finalisation ==="
echo " [OK] Pilote compilé, isolé et configuré avec succès !"
echo "==============================================================="
echo " ACTION REQUISE : "
echo " 1. Éteignez la machine complètement (halt -p)."
echo " 2. Débranchez le câble d'alimentation 10 secondes (Cold Boot)."
echo " 3. Rallumez. Le réseau montera tout seul, sans crash."
echo "==============================================================="
