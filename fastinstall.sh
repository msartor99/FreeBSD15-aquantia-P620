#!/bin/sh

# Script d'installation rapide pour Driver Aquantia (P620)
# Ce script ne demande NI compilation NI sources.

DRIVER_NAME="if_atlantic.ko"
MODULE_DIR="/boot/modules"

 git clone https://github.com/msartor99/FreeBSD15-aquantia-P620 /tmp/fb15_assets
 cd /tmp/fb15_assets

if [ "$(id -u)" -ne 0 ]; then 
    echo "Erreur : root requis."
    exit 1
fi

# 1. Copie du binaire
echo "Installation du driver..."
cp "$DRIVER_NAME" "$MODULE_DIR/"
chmod 555 "$MODULE_DIR/$DRIVER_NAME"

# 2. Chargement immediat
echo "Chargement du module..."
kldload -v "$MODULE_DIR/$DRIVER_NAME"

# 3. Configuration de la persistance au boot
echo "Configuration du demarrage..."

# Chargement auto du driver
if ! grep -q "if_atlantic_load" /boot/loader.conf; then
    echo 'if_atlantic_load="YES"' >> /boot/loader.conf
    echo 'hw.aq.msix_disable="1"' >> /boot/loader.conf
    echo 'hw.aq.num_queues="1"' >> /boot/loader.conf
    echo 'hw.pci.enable_aspm="0"' >> /boot/loader.conf
    echo 'hw.dmar.enable="0"' >> /boot/loader.conf
    echo 'dev.aq.0.iflib.override_nrxds="512"' >> /boot/loader.conf
    echo 'dev.aq.0.iflib.override_ntxds="512"' >> /boot/loader.conf
fi

# Activation reseau DHCP
if ! grep -q "ifconfig_aq0" /etc/rc.conf; then
    echo 'ifconfig_aq0="DHCP promisc -rxcsum -txcsum -tso -lro -vlanhwtso -vlanhwcsum"' >> /etc/rc.conf
fi

ifconfig down && ifconfig up
echo "Termine ! L'interface aq0 devrait etre active."
ifconfig aq0
