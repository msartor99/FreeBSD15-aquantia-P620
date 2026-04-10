#!/bin/sh

# Configuration
REPO_URL="https://raw.githubusercontent.com/msartor99/FreeBSD15-aquantia-P620/main/if_aq.ko"
DEST_PATH="/boot/modules/if_aq.ko"

echo "--- Installation du driver Aquantia AQC107 pour P620 ---"

# 1. Téléchargement du binaire (utilise fetch, natif sur FreeBSD)
echo "Downloading if_aq.ko from GitHub..."
mkdir -p /boot/modules
fetch -o $DEST_PATH $REPO_URL

if [ $? -ne 0 ]; then
    echo "Erreur : Impossible de télécharger le fichier. Vérifie l'URL ou ta connexion."
    exit 1
fi

# 2. Sécurisation des permissions
chmod 555 $DEST_PATH
chown root:wheel $DEST_PATH

# 3. Configuration du boot (loader.conf)
echo "Configuration du loader.conf..."

# On évite les doublons si le script est lancé plusieurs fois
sed -i '' '/if_aq_load/d' /boot/loader.conf
sed -i '' '/if_aq_name/d' /boot/loader.conf
sed -i '' '/hw.aq.msix_disable/d' /boot/loader.conf

echo 'if_aq_load="YES"' >> /boot/loader.conf
echo 'if_aq_name="/boot/modules/if_aq.ko"' >> /boot/loader.conf
# Paramètres de stabilité spécifiques au chipset AMD du P620
echo 'hw.aq.msix_disable="1"' >> /boot/loader.conf

# 4. Chargement immédiat
echo "Chargement du module..."
kldunload if_aq 2>/dev/null
kldload $DEST_PATH

# 5. Vérification
echo "--- Statut de l'interface ---"
ifconfig aq0