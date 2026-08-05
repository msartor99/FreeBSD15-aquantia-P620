#!/bin/sh

# Couleurs
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo "${BLUE}===> Installation et Compilation Automatique du driver 'aq'${NC}"

# 1. Détection de la version exacte du système (ex: 15.1-RELEASE-p2)
SYS_VER=$(freebsd-version -k)
echo "${GREEN}[1/5] Détection du noyau : ${SYS_VER}${NC}"

# Extraction du numéro de version majeur/mineur (ex: 15.1) pour la branche Git releng/X.Y
RELENG_BRANCH=$(echo "$SYS_VER" | sed -E 's/([0-9]+\.[0-9]+)-RELEASE.*/releng\/\1/')

echo "${BLUE}Branche de sources ciblée : ${RELENG_BRANCH}${NC}"

# 2. Gestion des dépendances et sources du noyau
echo "${GREEN}[2/5] Vérification des outils et sources...${NC}"
pkg install -y git gmake 2>/dev/null

# Si les sources ne sont pas présentes ou ne correspondent pas, on clone la bonne branche releng
if [ ! -f "/usr/src/sys/kern/init_main.c" ]; then
    echo "${BLUE}Sources manquantes dans /usr/src. Récupération de ${RELENG_BRANCH}...${NC}"
    git clone --depth 1 -b "$RELENG_BRANCH" https://git.freebsd.org/src.git /usr/src
else
    echo "${BLUE}Sources système déjà présentes dans /usr/src.${NC}"
fi

# 3. Préparation du répertoire de travail
WORK_DIR="/tmp/aq_force_16"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# 4. Récupération du code source du driver
echo "${GREEN}[3/5] Récupération du code source du driver 'aq'...${NC}"
git clone --depth 1 --filter=blob:none --sparse https://github.com/freebsd/freebsd-src.git fbsd_16
cd fbsd_16
git sparse-checkout set sys/dev/aq sys/modules/aq

DEV_AQ_SRC="$(pwd)/sys/dev/aq"
MOD_AQ_SRC="$(pwd)/sys/modules/aq"

# 5. Compilation du module kernel
echo "${GREEN}[4/5] Compilation du module if_aq.ko...${NC}"
cd "$MOD_AQ_SRC"
export SYSDIR=/usr/src/sys
sed -i '' "s|\${SRCTOP}/sys/dev/aq|$DEV_AQ_SRC|g" Makefile

make clean && make

if [ ! -f "if_aq.ko" ]; then
    echo "${RED}Erreur : La compilation du module if_aq.ko a échoué.${NC}"
    exit 1
fi

# 6. Installation et Configuration IDEMPOTENTE
echo "${GREEN}[5/5] Installation du module et mise à jour des configurations...${NC}"

# Installation du binaire
mkdir -p /boot/modules
cp if_aq.ko /boot/modules/
chmod 555 /boot/modules/if_aq.ko

# Fonction personnalisée pour écrire proprement dans /boot/loader.conf (outrepasse les limites de sysrc avec les '.')
update_loader() {
    local var="$1"
    local val="$2"
    [ -f /boot/loader.conf ] && sed -i '' "/${var}=/d" /boot/loader.conf
    echo "${var}=\"${val}\"" >> /boot/loader.conf
}

# Application des paramètres de stabilité (Fix Single Queue pour Aquantia)
update_loader "if_aq_load" "YES"
update_loader "hw.aq.num_queues" "1"
update_loader "dev.aq.0.iflib.override_nrxqs" "1"
update_loader "dev.aq.0.iflib.override_ntxqs" "1"

# Configuration réseau automatique dans /etc/rc.conf
sysrc ifconfig_aq0="DHCP"

# 7. Activation dynamique
echo "${BLUE}Tentative de chargement du module...${NC}"

# Coupure préalable pour libérer le verrou du noyau
ifconfig aq0 down 2>/dev/null || true

# Déchargement des anciens drivers s'ils sont présentés
kldunload if_aq 2>/dev/null || true
kldunload if_atlantic 2>/dev/null || true

# Chargement du nouveau driver
kldload /boot/modules/if_aq.ko 2>/dev/null || true

if [ $? -eq 0 ]; then
    echo "${GREEN}!!! SCRIPT EXÉCUTÉ AVEC SUCCÈS POUR ${SYS_VER} !!!${NC}"
    ifconfig aq0 up 2>/dev/null || true
    sleep 2
    ifconfig aq0 2>/dev/null || true
else
    echo "${RED}Note : Le module n'a pas pu être remplacé à chaud (ressource occupée).${NC}"
fi

echo "${BLUE}Le fichier /boot/loader.conf est prêt. Un REDÉMARRAGE est recommandé.${NC}"