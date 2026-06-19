#!/bin/bash
# ============================================================================
#  install_ban_404.sh — Installation "cle en main" du ban automatique sur
#  flood de 404 (ipset + iptables, persistance au reboot, execution horaire).
#  Idempotent. Migre l'ancien chemin /etc/iptables/ipset et decommissionne
#  tout ancien script de ban 404 (quel que soit son nom).
# ============================================================================
set -u

SCRIPT_PATH="/usr/local/sbin/ban_404.sh"
CRON_PATH="/etc/cron.hourly/ban_404"        # SANS extension : run-parts ignore les noms contenant '.'
CRON_BASE="ban_404"
LOG_PATH="/var/log/ban_404.log"
LOGROTATE_PATH="/etc/logrotate.d/ban_404"
UPDATER_PATH="/usr/local/sbin/update_ban_404.sh"
CONF_PATH="/etc/ban_404.conf"
UPDATE_CRON="/etc/cron.daily/ban_404_update"

# >>> A EDITER UNE FOIS avant distribution : URL "raw" de ton depot (sans slash final) <<<
REPO_RAW="https://raw.githubusercontent.com/PixelsIng/ban-404/main"

die(){ echo "ERREUR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "a lancer en root (sudo)."

echo "==> Installation des paquets requis..."
export DEBIAN_FRONTEND=noninteractive
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get update || echo "   (apt-get update en erreur — on poursuit avec le cache local)"
install_pkgs(){ apt-get install -y ipset iptables-persistent ipset-persistent cron; }
if ! install_pkgs; then
    echo "   echec — tentative d'activation du depot 'universe' (requis pour ipset-persistent sur 22.04)..."
    command -v add-apt-repository >/dev/null 2>&1 && { add-apt-repository -y universe && apt-get update || true; }
    install_pkgs || die "echec installation paquets (le depot 'universe' est-il active ?)."
fi

systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
mkdir -p /etc/iptables

echo "==> Migration eventuelle de l'ancien chemin de persistance ipset..."
if [ -L /etc/iptables/ipsets ]; then
    link_target=$(readlink -f /etc/iptables/ipsets 2>/dev/null || true)
    echo "   /etc/iptables/ipsets est un lien -> ${link_target:-<casse>}"
    rm -f /etc/iptables/ipsets
    if [ -n "${link_target:-}" ] && [ -f "$link_target" ]; then
        cp -a "$link_target" /etc/iptables/ipsets
        echo "   contenu materialise dans un vrai fichier /etc/iptables/ipsets"
    fi
fi
if [ -f /etc/iptables/ipset ]; then
    rm -f /etc/iptables/ipset
    echo "   ancien /etc/iptables/ipset supprime"
fi

echo "==> Decommissionnement de tout ancien script de ban 404..."
# Un nom evoque-t-il un ancien ban-404 ? (ban+404 dans un sens ou l'autre, insensible casse)
is_legacy_name(){ printf '%s' "$1" | grep -qiE '(ban[_-]?404|404[_-]?ban|autoban404|auto_ban_404)'; }

shopt -s nullglob
for f in /etc/cron.hourly/* /etc/cron.daily/*; do
    base=$(basename "$f")
    [ "$base" = "$CRON_BASE" ] && continue                 # notre nouvelle tache : ne pas toucher
    if [ -L "$f" ]; then
        tgt=$(readlink -f "$f" 2>/dev/null || true)
        if is_legacy_name "$base" || { [ -n "${tgt:-}" ] && is_legacy_name "$(basename "$tgt")"; }; then
            [ -n "${tgt:-}" ] && [ -f "$tgt" ] && [ "$tgt" != "$SCRIPT_PATH" ] && { rm -f "$tgt"; echo "   ancien script supprime : $tgt"; }
            rm -f "$f"; echo "   ancien cron (lien) supprime : $f"
        fi
    elif [ -f "$f" ]; then
        ref=$(grep -oE '/[^[:space:]"'\'']*\.sh' "$f" 2>/dev/null | head -n1 || true)
        if is_legacy_name "$base" || { [ -n "${ref:-}" ] && is_legacy_name "$(basename "$ref")"; }; then
            [ -n "${ref:-}" ] && [ -f "$ref" ] && [ "$ref" != "$SCRIPT_PATH" ] && { rm -f "$ref"; echo "   ancien script supprime : $ref"; }
            rm -f "$f"; echo "   ancien cron supprime : $f"
        fi
    fi
done
shopt -u nullglob

# Copies orphelines dans les emplacements habituels
for d in /root /usr/local/bin /usr/local/sbin; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -regextype posix-extended \
        -iregex '.*(ban[_-]?404|404[_-]?ban|auto_ban_404).*\.sh' 2>/dev/null | while read -r s; do
        [ "$s" = "$SCRIPT_PATH" ] && continue
        rm -f "$s"; echo "   ancien script supprime : $s"
    done
done

# References dans crontab partage : signalees, pas auto-editees
hits=$(grep -rliE '(ban[_-]?404|404[_-]?ban|auto_ban_404)' /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | grep -v "$CRON_BASE" || true)
[ -n "${hits:-}" ] && echo "   /!\\ References a verifier/retirer manuellement : $hits"

# Ancienne chaine iptables eventuelle
if iptables -nL AUTOBAN404 >/dev/null 2>&1; then
    iptables -D INPUT -j AUTOBAN404 2>/dev/null || true
    iptables -F AUTOBAN404 2>/dev/null || true
    iptables -X AUTOBAN404 2>/dev/null || true
    echo "   chaine AUTOBAN404 demontee"
fi
[ -d /var/lib/auto-ban-404 ] && { rm -rf /var/lib/auto-ban-404; echo "   /var/lib/auto-ban-404 supprime"; }

echo "==> Deploiement du script : $SCRIPT_PATH"
cat > "$SCRIPT_PATH" <<'BAN404_EOF'
#!/bin/bash

BAN404_VERSION="1.0.0"

# Configuration (valeurs par defaut ; surchargees par /etc/ban_404.conf)
BASE_DIR="/var/www"
IPSET_NAME="ban_404_list"
IPSET_SAVE_FILE="/etc/iptables/ipsets"   # chemin canonique du plugin ipset-persistent
BAN_TIMEOUT=172800   # 48 heures
WINDOW=7200          # Fenetre glissante en secondes (2h). Cron horaire => recouvrement, pas de trou aux bornes.
TAIL_LINES=50000     # On n'analyse que les N dernieres lignes de chaque log (borne le cout sur gros sites).
                     # A augmenter si un site depasse TAIL_LINES requetes dans la fenetre WINDOW.
LOCK_FILE="/run/ban_404_list.lock"

# Whitelist des IPs a ne JAMAIS bannir (separees par | ) -- correspondance EXACTE
WHITELIST_IP="127.0.0.1"

# --- Surcharge par la config locale, NON versionnee (whitelist par serveur, REPO_RAW, etc.) ---
CONF_FILE="/etc/ban_404.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# Initialisation des options
DRY_RUN=false
SHOW_BLOCKED=false
VERBOSE=false

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options disponibles :"
    echo "  --dry-run        Simuler les actions (mode lecture seule)."
    echo "  --show-blocked   Afficher aussi les IPs deja dans l'ipset."
    echo "  --verbose        Afficher le detail de la recherche des logs."
    echo "  --help, -h       Afficher ce message d'aide."
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --show-blocked) SHOW_BLOCKED=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) show_help ;;
        *) echo "Option inconnue : $1. Utilisez --help."; exit 1 ;;
    esac
done

# --- Verrou anti-chevauchement (cron). Inutile en simulation (lecture seule). ---
if [ "$DRY_RUN" = false ]; then
    exec 9>"$LOCK_FILE" || { echo "Impossible d'ouvrir le verrou $LOCK_FILE"; exit 1; }
    if ! flock -n 9; then
        echo "Une autre instance tourne deja (verrou $LOCK_FILE). Abandon."
        exit 1
    fi
fi

if [ "$VERBOSE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "========================================="
        echo -e "   /!\\  MODE SIMULATION (DRY-RUN) ACTIF /!\\"
        echo -e "========================================="
    fi
    if [ "$SHOW_BLOCKED" = false ]; then
        echo -e "   FILTRE : IPs deja bloquees masquees\n"
    else
        echo -e "   AFFICHAGE : Toutes les IPs incluses\n"
    fi
    echo "=[ Recherche des fichiers de logs... ]="
fi

# FCrDNS sans dependance externe (getent, via la libc/nsswitch) :
#   1) PTR de l'IP  2) hostname = sous-domaine d'un crawler connu
#   3) ce hostname doit RE-RESOUDRE vers l'IP d'origine (anti-spoofing du PTR)
is_legit_crawler() {
    local ip="$1" rdns
    rdns=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -n1 | tr 'A-Z' 'a-z')
    [ -z "$rdns" ] && return 1

    case "$rdns" in
        *.googlebot.com|*.google.com|*.search.msn.com|*.bing.com|\
        *.yandex.com|*.yandex.net|*.yandex.ru|\
        *.apple.com|*.applebot.apple.com|*.baidu.com) ;;
        *) return 1 ;;
    esac

    # Forward-confirmed : l'IP d'origine doit figurer parmi les adresses du hostname
    getent ahosts "$rdns" 2>/dev/null | awk '{print $1}' | grep -qxF "$ip" || return 1

    echo "$rdns"
    return 0
}

if [ "$DRY_RUN" = false ]; then
    ipset list "$IPSET_NAME" &>/dev/null
    if [ $? -ne 0 ]; then
        ipset create "$IPSET_NAME" hash:ip timeout $BAN_TIMEOUT
    fi
    /sbin/iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP &>/dev/null
    if [ $? -ne 0 ]; then
        /sbin/iptables -I INPUT -m set --match-set "$IPSET_NAME" src -j DROP
        mkdir -p /etc/iptables
        /sbin/iptables-save > /etc/iptables/rules.v4
    fi
fi

# 1. Recherche des fichiers de logs
FILES_FOUND=()
for log_dir in ${BASE_DIR}/*/log/; do
    [ -d "$log_dir" ] || continue
    if [ -f "${log_dir}access.log" ]; then
        FILES_FOUND+=("${log_dir}access.log")
    else
        latest=$(ls -1t "${log_dir}"*access.log 2>/dev/null | head -n 1)
        [ -n "$latest" ] && FILES_FOUND+=("$latest")
    fi
done

# 2. Filtrage des fichiers lisibles
VALID_FILES=()
for file in "${FILES_FOUND[@]}"; do
    if [ -r "$file" ] && [ -s "$file" ]; then
        [ "$VERBOSE" = true ] && echo "-> OK (lisible) : $file"
        VALID_FILES+=("$file")
    else
        [ "$VERBOSE" = true ] && echo "-> Ignore : $file"
    fi
done

if [ ${#VALID_FILES[@]} -eq 0 ]; then
    echo "=> Aucun fichier de log valide trouve. Fin."
    exit 0
fi

# Borne basse de la fenetre, au format AAAAMMJJHHMMSS (comparable directement, sans mktime)
CUTOFF=$(date -d "@$(( $(date +%s) - WINDOW ))" '+%Y%m%d%H%M%S')
[ "$VERBOSE" = true ] && echo -e "\n=[ Analyse des ${TAIL_LINES} dernieres lignes/log depuis $CUTOFF ]="

# 3. Extraction et tri via awk
#    - tail -q : seulement les dernieres lignes de CHAQUE log (borne le cout)
#    - whitelist en correspondance EXACTE (split sur |)
#    - fenetre temporelle (on ignore les 404 trop vieux)
#    - insensibilite a la casse via tolower() (le flag /i n'existe pas en awk)
#    - filtre anti-bruit + honeypots (+100)
ips_data=$(tail -n "$TAIL_LINES" -q "${VALID_FILES[@]}" | awk -v wl="$WHITELIST_IP" -v cutoff="$CUTOFF" '
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", M, " ")
    for (i=1;i<=12;i++) mon[M[i]]=i
    n=split(wl, Wl, "|"); for (i=1;i<=n;i++) white[Wl[i]]=1
}
$9 == 404 && !($1 in white) {

    # --- Fenetre temporelle : $4 = [jj/Mon/aaaa:hh:mm:ss ---
    split(substr($4,2), d, /[\/:]/)
    ts = sprintf("%04d%02d%02d%02d%02d%02d", d[3], mon[d[2]], d[1], d[4], d[5], d[6])
    if (ts < cutoff) next

    p = tolower($7)

    # --- A. Bruit de fond (faux positifs) ---
    if (p ~ /\.(jpg|jpeg|png|gif|webp|ico|css|js|svg|woff2?|map)$/) next
    if (p ~ /(apple-touch-icon|favicon|browserconfig\.xml|mstile)/) next
    if (p ~ /(autodiscover\.xml|sitemap\.xml|robots\.txt|ads\.txt)/) next
    if (p ~ /\.well-known\/(security\.txt|pki-validation)/) next

    # --- B. Honeypots : +100 (ban quasi immediat) ---
    if (p ~ /(\.env|wp-config\.php|phpmyadmin|config\.json|setup\.php|actuator|xmlrpc\.php)/) {
        count[$1] += 100
    } else {
        count[$1]++
    }
}
END {
    for (ip in count) if (count[ip] > 10) print count[ip], ip
}' | sort -rn)

if [ -z "$ips_data" ]; then
    [ "$VERBOSE" = true ] && echo "Aucune IP suspecte trouvee."
    exit 0
fi

changes_made=false
rules_simulated=0
[ "$VERBOSE" = true ] && echo -e "\n=[ Traitement des IP ]="

# 4. Boucle de traitement
while read -r count ip; do
    [ -z "$ip" ] && continue

    crawler_domain=$(is_legit_crawler "$ip")
    if [ $? -eq 0 ]; then
        if [ "$DRY_RUN" = false ] && ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
            echo "[-] Deblocage de l'IP (crawler legitime) : $ip ($crawler_domain | $count 404)"
            ipset del "$IPSET_NAME" "$ip"
            changes_made=true
        elif [ "$DRY_RUN" = true ] && ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
            echo "[SIMULATION] [-] L'IP $ip aurait ete DEBANNIE (vrai robot : $crawler_domain)."
            rules_simulated=$((rules_simulated + 1))
        else
            [ "$SHOW_BLOCKED" = true ] && echo "[SKIP] Robot legitime non bloque : $ip"
        fi
        continue
    fi

    if ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
        [ "$SHOW_BLOCKED" = true ] && echo "[...] L'IP $ip est deja dans l'ipset ($count erreurs 404)."
    else
        if [ "$DRY_RUN" = true ]; then
            if [ "$count" -ge 100 ]; then
                echo "[SIMULATION] [+] L'IP $ip aurait ete bannie IMMEDIATEMENT (Honeypot detecte : $count)."
            else
                echo "[SIMULATION] [+] L'IP $ip aurait ete ajoutee a l'ipset ($count erreurs 404)."
            fi
            rules_simulated=$((rules_simulated + 1))
        else
            if [ "$count" -ge 100 ]; then
                echo "[+] Blocage IMMEDIAT (Honeypot) de l'IP : $ip"
            else
                echo "[+] Blocage (ipset) de l'IP : $ip ($count erreurs 404)"
            fi
            ipset -exist add "$IPSET_NAME" "$ip"
            changes_made=true
        fi
    fi
done <<< "$ips_data"

# 5. Sauvegarde
[ "$VERBOSE" = true ] && echo -e "\n=[ Resultat ]="
if [ "$DRY_RUN" = true ]; then
    echo "=> Mode simulation termine. $rules_simulated action(s) virtuelle(s) generee(s)."
else
    if [ "$changes_made" = true ]; then
        [ "$VERBOSE" = true ] && echo "=> Changements appliques. Sauvegarde de la configuration ipset..."
        mkdir -p "$(dirname "$IPSET_SAVE_FILE")"
        ipset save > "$IPSET_SAVE_FILE"
    else
        [ "$VERBOSE" = true ] && echo "=> Aucune modification requise dans l'ipset."
    fi
fi
BAN404_EOF
chmod 755 "$SCRIPT_PATH"

echo "==> Tache horaire : $CRON_PATH"
cat > "$CRON_PATH" <<EOF
#!/bin/sh
# Horodate chaque ligne de sortie du script avant de l'ecrire dans le log.
$SCRIPT_PATH 2>&1 | while IFS= read -r line; do
    printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$line"
done >> $LOG_PATH
EOF
chmod 755 "$CRON_PATH"

echo "==> Rotation du log : $LOGROTATE_PATH"
cat > "$LOGROTATE_PATH" <<EOF
$LOG_PATH {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

echo "==> Configuration locale : $CONF_PATH"
if [ ! -f "$CONF_PATH" ]; then
    cat > "$CONF_PATH" <<EOF
# /etc/ban_404.conf — configuration LOCALE par serveur (NON versionnee).
REPO_RAW="$REPO_RAW"
WHITELIST_IP="127.0.0.1"
#WINDOW=7200
#BAN_TIMEOUT=172800
#TAIL_LINES=50000
EOF
    chmod 600 "$CONF_PATH"
    echo "   cree (pense a adapter WHITELIST_IP sur ce serveur)"
else
    echo "   existant conserve (non ecrase)"
fi

echo "==> Self-updater : $UPDATER_PATH (+ $UPDATE_CRON)"
cat > "$UPDATER_PATH" <<'UPD_EOF'
#!/bin/bash
# update_ban_404.sh — met a jour /usr/local/sbin/ban_404.sh depuis le depot Git.
# Telecharge -> valide (shebang + syntaxe) -> bascule atomique. Jamais "curl | bash".
set -u

CONF_FILE="/etc/ban_404.conf"
TARGET="/usr/local/sbin/ban_404.sh"
LOG="/var/log/ban_404.log"

log(){ printf '%s [update] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${REPO_RAW:=}"
[ -z "$REPO_RAW" ] && { log "REPO_RAW non defini dans $CONF_FILE — MAJ ignoree."; exit 0; }

URL="$REPO_RAW/ban_404.sh"
TMP=$(mktemp /tmp/ban_404.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT

# Telechargement avec timeout
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$URL" -o "$TMP" || { log "telechargement KO ($URL)"; exit 0; }
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 30 -O "$TMP" "$URL" || { log "telechargement KO ($URL)"; exit 0; }
else
    log "ni curl ni wget — MAJ impossible"; exit 0
fi

# Validations avant toute bascule
[ -s "$TMP" ] || { log "fichier vide — abandon"; exit 0; }
head -n1 "$TMP" | grep -q '^#!/bin/bash' || { log "shebang inattendu — abandon"; exit 0; }
bash -n "$TMP" 2>/dev/null || { log "syntaxe invalide — abandon (rien remplace)"; exit 0; }

# Deja a jour ?
[ -f "$TARGET" ] && cmp -s "$TMP" "$TARGET" && exit 0

# Bascule atomique (copie dans le meme repertoire puis mv), avec sauvegarde
dir=$(dirname "$TARGET")
new=$(mktemp "$dir/.ban_404.XXXXXX") || { log "mktemp cible KO"; exit 0; }
if cp "$TMP" "$new" && chmod 755 "$new"; then
    [ -f "$TARGET" ] && cp -a "$TARGET" "${TARGET}.bak" 2>/dev/null || true
    mv -f "$new" "$TARGET" || { rm -f "$new"; log "bascule KO"; exit 0; }
    ver=$(grep -m1 '^BAN404_VERSION=' "$TARGET" | cut -d'"' -f2)
    log "ban_404.sh mis a jour${ver:+ (version $ver)}."
else
    rm -f "$new"; log "preparation KO"
fi
exit 0
UPD_EOF
chmod 755 "$UPDATER_PATH"
cat > "$UPDATE_CRON" <<EOF
#!/bin/sh
exec $UPDATER_PATH
EOF
chmod 755 "$UPDATE_CRON"

echo "==> Activation immediate (creation de l'ipset + regle DROP, puis persistance)..."
modprobe ip_set 2>/dev/null || true
# Recharger d'eventuels bans deja persistes (migration / reinstall) AVANT de re-sauvegarder
[ -s /etc/iptables/ipsets ] && ipset restore -exist < /etc/iptables/ipsets 2>/dev/null || true
"$SCRIPT_PATH" || true
netfilter-persistent save >/dev/null 2>&1 || true

cat <<EOF

------------------------------------------------------------
 Installation terminee.
   Script             : $SCRIPT_PATH
   Cron (horaire)     : $CRON_PATH   -> log dans $LOG_PATH
   Persistance reboot : /etc/iptables/ipsets + /etc/iptables/rules.v4
   Aucune dependance externe (FCrDNS via getent / libc)

 Tester sans rien modifier :
   $SCRIPT_PATH --dry-run --verbose
------------------------------------------------------------
EOF
