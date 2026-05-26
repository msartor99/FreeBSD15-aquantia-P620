#!/bin/sh
# ==============================================================================
# Script d'installation autonome - Carte Réseau Aquantia 10G (Lenovo P620)
# Cible : FreeBSD 15
# ==============================================================================

set -e

# Vérification des droits root
if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : Ce script doit être exécuté en tant que root."
    exit 1
fi

echo "=== [1/3] Préparation et téléchargement ==="
if ! command -v git >/dev/null 2>&1; then
    echo "-> Installation de git-lite..."
    env ASSUME_ALWAYS_YES=YES pkg install git-lite
fi

echo "-> Récupération des sources depuis GitHub..."
rm -rf /root/aquantia_p620_src
git clone https://github.com/msartor99/FreeBSD15-aquantia-P620 /root/aquantia_p620_src
cd /root/aquantia_p620_src

echo "=== [2/3] Compilation et installation du pilote ==="
# Exécution de ton script universel
sh install_aq_fbsd15_universal.sh

echo "=== [3/3] Application du correctif PHY (Anti-Crash) ==="
echo "-> Injection des paramètres dans /boot/loader.conf..."

# Utilisation de grep/sed pour gérer les points dans les variables (bypass de sysrc)
for AQ_VAR in "nrxqs" "ntxqs"; do
    if grep -q "^dev.aq.0.iflib.override_${AQ_VAR}=" /boot/loader.conf 2>/dev/null; then
        sed -i '' "s/^dev.aq.0.iflib.override_${AQ_VAR}=.*/dev.aq.0.iflib.override_${AQ_VAR}=\"8\"/" /boot/loader.conf
    else
        echo "dev.aq.0.iflib.override_${AQ_VAR}=\"8\"" >> /boot/loader.conf
    fi
done

echo "=============================================================================="
echo " INSTALLATION AQUANTIA TERMINÉE !"
echo " [!] Débranchez temporairement votre connexion internet de secours."
echo " [!] N'oubliez pas d'éteindre complètement la machine (Cold Boot) "
echo "     pendant 15 secondes pour initialiser la carte Aquantia proprement."
echo "=============================================================================="
