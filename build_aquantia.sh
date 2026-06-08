#!/bin/sh

# On récupère la version exacte du noyau en cours d'exécution
KERN_VER=$(freebsd-version -k)

echo "==============================================================="
echo " COMPILATION SUR MESURE - PILOTE AQUANTIA (LENOVO P620)"
echo " Cible détectée : $KERN_VER "
echo "==============================================================="

echo "=== [1/4] Vérification de l'environnement et Nettoyage ==="
if [ ! -f "/usr/src/sys/conf/newvers.sh" ]; then
    echo " [!] ERREUR CRITIQUE : Le code source du noyau est introuvable."
    echo " Veuillez exécuter : freebsd-update fetch install (avec le composant src)"
    exit 1
fi

kldunload -f if_atlantic 2>/dev/null
rm -rf /root/aqtion-freebsd
pkg install -y git-lite >/dev/null 2>&1

echo "=== [2/4] Téléchargement du pilote Aquantia (GitHub) ==="
cd /root || exit 1
git clone https://github.com/Aquantia/aqtion-freebsd.git
cd aqtion-freebsd || exit 1

echo "=== [3/4] Patchs API FreeBSD 15 & Bouclier Anti-Reset Lenovo ==="
# 1. Injection de l'ID Lenovo (0x07b1)
sed -i '' 's/AQ_DEVICE(0x07b0)/AQ_DEVICE(0x07b0), AQ_DEVICE(0x07b1)/g' aq_main.c

# 2. Conflit d'en-tête (unistd.h)
sed -i '' 's|^#include <unistd.h>|// #include <unistd.h>|g' *.[ch] 2>/dev/null

# 3. Adaptation de la macro DRIVER_MODULE pour FreeBSD 15
sed -i '' '/static devclass_t aq_devclass;/d' aq_main.c
sed -i '' 's/DRIVER_MODULE(atlantic.*/DRIVER_MODULE(atlantic, pci, aq_driver, 0, 0);/g' aq_main.c

# 4. Conversion vers l'API réseau Opaque (IfAPI)
for f in aq_main.c aq_media.c aq_ring.c; do
  awk '/#include <net\/if\.h>/ { print; print "#include <net/if_var.h>"; next } 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i '' 's/ifp->if_softc/if_getsoftc(ifp)/g' "$f"
  sed -i '' 's/ifp->if_flags/if_getflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_drv_flags/if_getdrvflags(ifp)/g' "$f"
  sed -i '' 's/ifp->if_capenable/if_getcapenable(ifp)/g' "$f"
  sed -i '' 's/ifp->if_baudrate/if_getbaudrate(ifp)/g' "$f"
  sed -i '' 's/ifp->if_mtu/if_getmtu(ifp)/g' "$f"
done

# 5. LE BOUCLIER LENOVO : On empêche le pilote d'éteindre le PHY
sed -i '' 's/err = aq_hw_reset(sc->hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_fw_ops->reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c
sed -i '' 's/err = hw->aq_hw_ops->hw_reset(hw);/err = 0; \/\/ LENOVO HACK/g' aq_main.c

echo "=== [4/4] Compilation Native ==="
# Ajout des variables pour ignorer les avertissements liés à la nouvelle architecture des bus
echo 'CFLAGS += -Wno-error -DBUS_IVARS_PRIVATE=10000' >> Makefile
make clean >/dev/null 2>&1

echo " -> Compilation en cours..."
if ! make NO_WERROR=yes WERROR=""; then
    echo " [!] Échec de la compilation."
    exit 1
fi

echo "=== [5/5] Installation et Chargement ==="
cp if_atlantic.ko /boot/modules/
sed -i '' '/if_atlantic_load/d' /boot/loader.conf 2>/dev/null
echo 'if_atlantic_load="YES"' >> /boot/loader.conf

echo "--- CHARGEMENT DU PILOTE ---"
if kldload /boot/modules/if_atlantic.ko; then
    echo " [OK] Pilote chargé en mémoire avec succès !"
    sleep 2
    ifconfig aq0 2>/dev/null || echo " [!] L'interface aq0 n'est pas apparue."
    
    echo "==============================================================="
    echo " N'oubliez pas de mettre à jour votre dépôt GitHub avec"
    echo " ce nouveau fichier if_atlantic.ko compilé pour la $KERN_VER !"
    echo "==============================================================="
else
    echo " [!] Le noyau a refusé de charger le pilote."
fi
