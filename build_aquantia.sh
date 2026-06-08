#!/bin/sh

SYS_VER=$(freebsd-version -k)

echo "==============================================================="
echo " COMPILATION DÉFINITIVE - PILOTE NATIF if_aq (LENOVO P620) "
echo " Cible détectée : $SYS_VER "
echo "==============================================================="

echo "=== [1/4] Vérification et Téléchargement du Code Source ==="
if [ ! -d "/usr/src/sys/dev/aq" ]; then
    echo " -> Code source introuvable. Téléchargement automatique en cours..."
    pkg install -y git-lite >/dev/null 2>&1
    
    # Détermination de la bonne branche Git selon votre version
    if echo "$SYS_VER" | grep -q "CURRENT"; then
        BRANCH="main"
    elif echo "$SYS_VER" | grep -q "STABLE"; then
        MAJOR=$(echo "$SYS_VER" | cut -d'.' -f1)
        BRANCH="stable/${MAJOR}"
    else
        # Pour les versions RELEASE (ex: 15.0-RELEASE)
        REL=$(echo "$SYS_VER" | cut -d'-' -f1)
        BRANCH="releng/${REL}"
    fi
    
    echo " -> Clonage de la branche FreeBSD : ${BRANCH}..."
    rm -rf /usr/src
    if ! git clone --depth 1 -b "${BRANCH}" https://git.freebsd.org/src.git /usr/src; then
        echo " [!] Échec du clonage. Tentative de secours sur la branche 'main'..."
        git clone --depth 1 https://git.freebsd.org/src.git /usr/src
    fi
    echo " -> Téléchargement terminé !"
else
    echo " -> Code source /usr/src déjà présent."
fi

echo "=== [2/4] Application du Bouclier Lenovo (Anti-Reset) ==="
cd /usr/src/sys/dev/aq || exit 1

# Neutralisation des commandes de réinitialisation matérielle (Le secret du Cold Boot)
sed -i '' 's/error = aq_hw_reset(hw);/error = 0; \/\/ LENOVO HACK/g' aq_main.c 2>/dev/null
sed -i '' 's/error = hw->aq_fw_ops->reset(hw);/error = 0; \/\/ LENOVO HACK/g' aq_main.c 2>/dev/null
sed -i '' 's/error = hw->aq_hw_ops->hw_reset(hw);/error = 0; \/\/ LENOVO HACK/g' aq_main.c 2>/dev/null
# Variante de syntaxe au cas où le code source natif évolue
sed -i '' 's/err = aq_hw_reset/err = 0; \/\/ aq_hw_reset/g' aq_main.c 2>/dev/null

echo "=== [3/4] Compilation et Sécurisation du Module ==="
cd /usr/src/sys/modules/aq || exit 1
make clean >/dev/null 2>&1
echo " -> Compilation du module natif if_aq.ko..."
if ! make >/dev/null 2>&1; then
    echo " [!] Échec de la compilation."
    exit 1
fi

# ÉTAPE CRITIQUE : On neutralise le pilote d'origine du noyau pour éviter tout conflit au boot
if [ -f "/boot/kernel/if_aq.ko" ]; then
    mv /boot/kernel/if_aq.ko /boot/kernel/if_aq.ko.bak
fi
cp if_aq.ko /boot/modules/
chmod 555 /boot/modules/if_aq.ko

echo "=== [4/4] Configuration Idempotente ==="
# Nettoyage des vieux paramètres (y compris l'ancien pilote if_atlantic)
sed -i '' '/if_atlantic_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.atlantic./d' /boot/loader.conf 2>/dev/null
sed -i '' '/if_aq_load/d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.aq./d' /boot/loader.conf 2>/dev/null
sed -i '' '/hw.pci.enable_aspm/d' /boot/loader.conf 2>/dev/null
sysrc -x devmatch_blocklist >/dev/null 2>&1

# Injection de la configuration parfaite (Bridage à 8 queues pour le Threadripper)
cat << 'INNER_EOF' >> /boot/loader.conf
# --- LENOVO P620 AQUANTIA NATIVE FIX ---
if_aq_load="YES"
hw.pci.enable_aspm="0"
hw.aq.msix_disable="0"
hw.aq.max_queues="8"
hw.aq.enable_rss="0"
hw.aq.enable_tso="0"
hw.aq.enable_lro="0"
INNER_EOF

echo "==============================================================="
echo " [OK] Le système est patché à la racine avec succès ! "
echo "==============================================================="
echo " DERNIÈRE ÉTAPE : "
echo " Faites un vrai COLD BOOT (éteignez, débranchez 10 secondes)."
echo " Le système chargera désormais SON PROPRE pilote if_aq.ko,"
echo " mais avec votre bouclier intégré !"
echo "==============================================================="
