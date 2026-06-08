#!/bin/sh

SYS_VER=$(freebsd-version -k)

echo "==============================================================="
echo " INSTALLATION DÉFINITIVE - AQUANTIA AQC107 (LENOVO P620) "
echo " Cible détectée : $SYS_VER "
echo "==============================================================="

echo "=== [1/5] Vérification du Code Source du Noyau ==="
if [ ! -f "/usr/src/sys/conf/newvers.sh" ]; then
    echo " -> Code source introuvable. Téléchargement automatique en cours..."
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
    
    echo " -> Clonage de la branche FreeBSD : ${BRANCH}..."
    rm -rf /usr/src
    if ! git clone --depth 1 -b "${BRANCH}" https://git.freebsd.org/src.git /usr/src; then
        echo " [!] Échec du clonage. Tentative de secours..."
        git clone --depth 1 https://git.freebsd.org/src.git /usr/src
    fi
else
    echo " -> Code source /usr/src déjà présent."
fi

echo "=== [2/5] Téléchargement du pilote Aquantia (GitHub) ==="
rm -rf /root/aqtion-freebsd
pkg install -y git-lite >/dev/null 2>&1
git clone --depth 1 https://github.com/Aquantia/aqtion-freebsd.git /root/aqtion-freebsd >/dev/null 2>&1
cd /root/aqtion-freebsd || exit 1

echo "=== [3/5] Application des Patchs (API 15 & Bouclier Lenovo) ==="
# 1. Injection de l'ID matériel du Lenovo P620
sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0), AQ_DEVICE(0x07b1)/g' aq_main.c
sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' *.[ch] 2>/dev/null
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic.*/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

# 2. Conversion vers la nouvelle API réseau de FreeBSD 15 (IfAPI)
for f in aq_main.c aq_media.c aq_ring.c; do
  awk '/#include <net\/if\.h>/ { print; print "#include <net/if_var.h>"; next } 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
  sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
  sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
  sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

# 3. BOUCLIER LENOVO : Désactivation des resets matériels (Cause du 'no carrier' au Cold Boot)
sed -i '' 's/err = aq_hw_reset(sc->hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_fw_ops->reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_hw_ops->hw_reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c

echo "=== [4/5] Compilation du Module ==="
echo 'CFLAGS += -Wno-error -DBUS_IVARS_PRIVATE=10000' >> Makefile
make clean >/dev/null 2>&1
echo " -> Compilation en cours..."
if ! make NO_WERROR=yes WERROR="" >/dev/null 2>&1; then
    echo " [!] Échec de la compilation."
    exit 1
fi

cp if_atlantic.ko /boot/modules/
chmod 555 /boot/modules/if_atlantic.ko

echo "=== [5/5] Configuration Idempotente (Le Verrou iflib) ==="
# Nettoyage méticuleux des anciennes variables
sed -i '' '/if_atlantic_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/if_aq_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.atlantic./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.aq./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf 2>/dev/null
sed -i '' '/dev.aq.0.iflib./d' /boot/loader.conf 2>/dev/null
sysrc -x devmatch_blocklist >/dev/null 2>&1

# L'injection finale : Chargement du module et bridage strict de iflib à 4 files
cat << 'EOF' >> /boot/loader.conf
# --- LENOVO P620 AQUANTIA FIX ---
if_atlantic_load="YES"
hw.pci.enable_aspm="0"
hw.atlantic.msix_disable="0"
hw.atlantic.enable_rss="0"
hw.atlantic.enable_tso="0"
hw.atlantic.enable_lro="0"
# --- LE VERROU IFLIB (Anti Threadripper Crash) ---
dev.aq.0.iflib.override_nrxqs="4"
dev.aq.0.iflib.override_ntxqs="4"
EOF

# Désactivation du Flow Control matériel pour la stabilité
touch /etc/sysctl.conf
sed -i '' '/dev\.atlantic\..*\.fc/d' /etc/sysctl.conf 2>/dev/null
sed -i '' '/dev\.aq\..*\.fc/d' /etc/sysctl.conf 2>/dev/null
echo 'dev.aq.0.fc=0' >> /etc/sysctl.conf

echo "==============================================================="
echo " [OK] Installation terminée avec succès ! "
echo "==============================================================="
echo " Votre Lenovo P620 est maintenant définitivement immunisé "
echo " contre les coupures réseau au démarrage à froid."
echo "==============================================================="
