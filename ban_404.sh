#!/bin/bash

BAN404_VERSION="1.2.0"

# Configuration (valeurs par defaut ; surchargees par /etc/ban_404.conf)
BASE_DIR="/var/www"
IPSET_NAME="ban_404_list"
IPSET_SAVE_FILE="/etc/iptables/ipsets"   # chemin canonique du plugin ipset-persistent
BAN_TIMEOUT=172800   # 48 heures
WINDOW=7200          # Fenetre glissante en secondes (2h). Cron horaire => recouvrement, pas de trou aux bornes.
TAIL_LINES=50000     # On n'analyse que les N dernieres lignes de chaque log (borne le cout sur gros sites).
                     # A augmenter si un site depasse TAIL_LINES requetes dans la fenetre WINDOW.
LOCK_FILE="/run/ban_404_list.lock"

# Seuils & motifs de detection (surchargables par la conf)
BAN_THRESHOLD=10     # Ban si le score depasse ce seuil dans la fenetre.
HONEYPOT_SCORE=100   # Score ajoute par hit honeypot (>= ce score => ban immediat).
HONEYPOT_PATTERN='\.env|wp-config\.php|phpmyadmin|config\.json|setup\.php|actuator|xmlrpc\.php'
NOISE_PATTERN='\.(jpg|jpeg|png|gif|webp|ico|css|js|svg|woff2?|map)$|apple-touch-icon|favicon|browserconfig\.xml|mstile|autodiscover\.xml|sitemap\.xml|robots\.txt|ads\.txt|\.well-known/(security\.txt|pki-validation)'

# Whitelist des IPs a ne JAMAIS bannir (separees par | ) -- correspondance EXACTE
WHITELIST_IP="127.0.0.1"

# ============================================================================
#  i18n — messages multilingues (en, fr, de, es, it). Le code/les commentaires
#  restent en francais ; SEULS les messages affiches sont traduisibles.
#  Les tableaux sont independants de la langue : on peut les definir avant le
#  sourcing de la conf. La langue effective est resolue apres (detect_lang).
# ============================================================================
declare -A T_EN T_FR T_DE T_ES T_IT

T_EN[version.line]="ban_404.sh version %s"
T_FR[version.line]="ban_404.sh version %s"
T_DE[version.line]="ban_404.sh version %s"
T_ES[version.line]="ban_404.sh version %s"
T_IT[version.line]="ban_404.sh version %s"

T_EN[help.usage]="Usage: %s [OPTIONS]"
T_FR[help.usage]="Usage : %s [OPTIONS]"
T_DE[help.usage]="Aufruf: %s [OPTIONEN]"
T_ES[help.usage]="Uso: %s [OPCIONES]"
T_IT[help.usage]="Uso: %s [OPZIONI]"

T_EN[help.options_header]="Available options:"
T_FR[help.options_header]="Options disponibles :"
T_DE[help.options_header]="Verfügbare Optionen:"
T_ES[help.options_header]="Opciones disponibles:"
T_IT[help.options_header]="Opzioni disponibili:"

T_EN[help.dryrun]="  --dry-run        Simulate actions (read-only mode)."
T_FR[help.dryrun]="  --dry-run        Simuler les actions (mode lecture seule)."
T_DE[help.dryrun]="  --dry-run        Aktionen simulieren (Nur-Lese-Modus)."
T_ES[help.dryrun]="  --dry-run        Simular las acciones (modo de solo lectura)."
T_IT[help.dryrun]="  --dry-run        Simulare le azioni (modalità di sola lettura)."

T_EN[help.showblocked]="  --show-blocked   Also show IPs already in the ipset."
T_FR[help.showblocked]="  --show-blocked   Afficher aussi les IP déjà dans l'ipset."
T_DE[help.showblocked]="  --show-blocked   Auch IPs anzeigen, die bereits im ipset sind."
T_ES[help.showblocked]="  --show-blocked   Mostrar también las IP que ya están en el ipset."
T_IT[help.showblocked]="  --show-blocked   Mostrare anche gli IP già presenti nell'ipset."

T_EN[help.verbose]="  --verbose        Show details of the log search."
T_FR[help.verbose]="  --verbose        Afficher le détail de la recherche des logs."
T_DE[help.verbose]="  --verbose        Details der Log-Suche anzeigen."
T_ES[help.verbose]="  --verbose        Mostrar el detalle de la búsqueda de registros."
T_IT[help.verbose]="  --verbose        Mostrare il dettaglio della ricerca dei log."

T_EN[help.lang]="  --lang <code>    Set the language (en, fr, de, es, it) in the config and exit."
T_FR[help.lang]="  --lang <code>    Définir la langue (en, fr, de, es, it) dans la config et quitter."
T_DE[help.lang]="  --lang <code>    Sprache (en, fr, de, es, it) in der Konfiguration setzen und beenden."
T_ES[help.lang]="  --lang <code>    Definir el idioma (en, fr, de, es, it) en la configuración y salir."
T_IT[help.lang]="  --lang <code>    Impostare la lingua (en, fr, de, es, it) nella configurazione e uscire."

T_EN[help.version]="  --version        Show the version and exit."
T_FR[help.version]="  --version        Afficher la version et quitter."
T_DE[help.version]="  --version        Version anzeigen und beenden."
T_ES[help.version]="  --version        Mostrar la versión y salir."
T_IT[help.version]="  --version        Mostrare la versione e uscire."

T_EN[help.help]="  --help, -h       Show this help message."
T_FR[help.help]="  --help, -h       Afficher ce message d'aide."
T_DE[help.help]="  --help, -h       Diese Hilfemeldung anzeigen."
T_ES[help.help]="  --help, -h       Mostrar este mensaje de ayuda."
T_IT[help.help]="  --help, -h       Mostrare questo messaggio di aiuto."

T_EN[err.unknown_opt]="Unknown option: %s. Use --help."
T_FR[err.unknown_opt]="Option inconnue : %s. Utilisez --help."
T_DE[err.unknown_opt]="Unbekannte Option: %s. Verwenden Sie --help."
T_ES[err.unknown_opt]="Opción desconocida: %s. Use --help."
T_IT[err.unknown_opt]="Opzione sconosciuta: %s. Usare --help."

T_EN[lang.missing]="--lang requires a code: en, fr, de, es, it."
T_FR[lang.missing]="--lang requiert un code : en, fr, de, es, it."
T_DE[lang.missing]="--lang erfordert einen Code: en, fr, de, es, it."
T_ES[lang.missing]="--lang requiere un código: en, fr, de, es, it."
T_IT[lang.missing]="--lang richiede un codice: en, fr, de, es, it."

T_EN[lang.unsupported]="Unsupported language: %s. Supported: en, fr, de, es, it."
T_FR[lang.unsupported]="Langue non supportée : %s. Supportées : en, fr, de, es, it."
T_DE[lang.unsupported]="Nicht unterstützte Sprache: %s. Unterstützt: en, fr, de, es, it."
T_ES[lang.unsupported]="Idioma no soportado: %s. Soportados: en, fr, de, es, it."
T_IT[lang.unsupported]="Lingua non supportata: %s. Supportate: en, fr, de, es, it."

T_EN[lang.noconf]="Config file %s not found. Run the installer first."
T_FR[lang.noconf]="Fichier de config %s introuvable. Lancez d'abord l'installeur."
T_DE[lang.noconf]="Konfigurationsdatei %s nicht gefunden. Führen Sie zuerst den Installer aus."
T_ES[lang.noconf]="Archivo de configuración %s no encontrado. Ejecute primero el instalador."
T_IT[lang.noconf]="File di configurazione %s non trovato. Eseguire prima l'installer."

T_EN[lang.write_fail]="Cannot write to %s (try with sudo)."
T_FR[lang.write_fail]="Impossible d'écrire dans %s (essayez avec sudo)."
T_DE[lang.write_fail]="Schreiben in %s nicht möglich (mit sudo versuchen)."
T_ES[lang.write_fail]="No se puede escribir en %s (pruebe con sudo)."
T_IT[lang.write_fail]="Impossibile scrivere su %s (provare con sudo)."

T_EN[lang.changed]="Language set to %s in %s."
T_FR[lang.changed]="Langue définie sur %s dans %s."
T_DE[lang.changed]="Sprache auf %s in %s gesetzt."
T_ES[lang.changed]="Idioma establecido en %s en %s."
T_IT[lang.changed]="Lingua impostata su %s in %s."

T_EN[banner.sim_active]="SIMULATION MODE (DRY-RUN) ACTIVE"
T_FR[banner.sim_active]="MODE SIMULATION (DRY-RUN) ACTIF"
T_DE[banner.sim_active]="SIMULATIONSMODUS (DRY-RUN) AKTIV"
T_ES[banner.sim_active]="MODO SIMULACIÓN (DRY-RUN) ACTIVO"
T_IT[banner.sim_active]="MODALITÀ SIMULAZIONE (DRY-RUN) ATTIVA"

T_EN[verbose.filter_hidden]="   FILTER: IPs already blocked are hidden\n"
T_FR[verbose.filter_hidden]="   FILTRE : les IP déjà bloquées sont masquées\n"
T_DE[verbose.filter_hidden]="   FILTER: bereits gesperrte IPs werden ausgeblendet\n"
T_ES[verbose.filter_hidden]="   FILTRO: las IP ya bloqueadas se ocultan\n"
T_IT[verbose.filter_hidden]="   FILTRO: gli IP già bloccati sono nascosti\n"

T_EN[verbose.filter_all]="   DISPLAY: all IPs included\n"
T_FR[verbose.filter_all]="   AFFICHAGE : toutes les IP incluses\n"
T_DE[verbose.filter_all]="   ANZEIGE: alle IPs eingeschlossen\n"
T_ES[verbose.filter_all]="   VISUALIZACIÓN: todas las IP incluidas\n"
T_IT[verbose.filter_all]="   VISUALIZZAZIONE: tutti gli IP inclusi\n"

T_EN[verbose.searching_logs]="=[ Searching for log files... ]="
T_FR[verbose.searching_logs]="=[ Recherche des fichiers de logs... ]="
T_DE[verbose.searching_logs]="=[ Suche nach Log-Dateien... ]="
T_ES[verbose.searching_logs]="=[ Buscando archivos de registro... ]="
T_IT[verbose.searching_logs]="=[ Ricerca dei file di log... ]="

T_EN[verbose.log_ok]="-> OK (readable): %s"
T_FR[verbose.log_ok]="-> OK (lisible) : %s"
T_DE[verbose.log_ok]="-> OK (lesbar): %s"
T_ES[verbose.log_ok]="-> OK (legible): %s"
T_IT[verbose.log_ok]="-> OK (leggibile): %s"

T_EN[verbose.log_skip]="-> Skipped: %s"
T_FR[verbose.log_skip]="-> Ignoré : %s"
T_DE[verbose.log_skip]="-> Übersprungen: %s"
T_ES[verbose.log_skip]="-> Ignorado: %s"
T_IT[verbose.log_skip]="-> Ignorato: %s"

T_EN[no_valid_files]="=> No valid log file found. Done."
T_FR[no_valid_files]="=> Aucun fichier de log valide trouvé. Fin."
T_DE[no_valid_files]="=> Keine gültige Log-Datei gefunden. Ende."
T_ES[no_valid_files]="=> No se encontró ningún archivo de registro válido. Fin."
T_IT[no_valid_files]="=> Nessun file di log valido trovato. Fine."

T_EN[verbose.analyzing]="\n=[ Analyzing last %s lines/log since %s ]="
T_FR[verbose.analyzing]="\n=[ Analyse des %s dernières lignes/log depuis %s ]="
T_DE[verbose.analyzing]="\n=[ Analyse der letzten %s Zeilen/Log seit %s ]="
T_ES[verbose.analyzing]="\n=[ Analizando las últimas %s líneas/log desde %s ]="
T_IT[verbose.analyzing]="\n=[ Analisi delle ultime %s righe/log da %s ]="

T_EN[no_suspect]="No suspicious IP found."
T_FR[no_suspect]="Aucune IP suspecte trouvée."
T_DE[no_suspect]="Keine verdächtige IP gefunden."
T_ES[no_suspect]="No se encontró ninguna IP sospechosa."
T_IT[no_suspect]="Nessun IP sospetto trovato."

T_EN[verbose.processing]="\n=[ Processing IPs ]="
T_FR[verbose.processing]="\n=[ Traitement des IP ]="
T_DE[verbose.processing]="\n=[ Verarbeitung der IPs ]="
T_ES[verbose.processing]="\n=[ Procesando las IP ]="
T_IT[verbose.processing]="\n=[ Elaborazione degli IP ]="

T_EN[unban.crawler]="[-] Unbanning IP (legitimate crawler): %s (%s | %s 404)"
T_FR[unban.crawler]="[-] Déblocage de l'IP (crawler légitime) : %s (%s | %s 404)"
T_DE[unban.crawler]="[-] Entsperrung der IP (legitimer Crawler): %s (%s | %s 404)"
T_ES[unban.crawler]="[-] Desbloqueo de la IP (crawler legítimo): %s (%s | %s 404)"
T_IT[unban.crawler]="[-] Sblocco dell'IP (crawler legittimo): %s (%s | %s 404)"

T_EN[sim.unban]="[SIMULATION] [-] IP %s would be UNBANNED (real bot: %s)."
T_FR[sim.unban]="[SIMULATION] [-] L'IP %s aurait été DÉBANNIE (vrai robot : %s)."
T_DE[sim.unban]="[SIMULATION] [-] IP %s würde ENTSPERRT (echter Bot: %s)."
T_ES[sim.unban]="[SIMULATION] [-] La IP %s sería DESBLOQUEADA (robot real: %s)."
T_IT[sim.unban]="[SIMULATION] [-] L'IP %s verrebbe SBLOCCATO (bot reale: %s)."

T_EN[skip.crawler]="[SKIP] Legitimate bot not blocked: %s"
T_FR[skip.crawler]="[SKIP] Robot légitime non bloqué : %s"
T_DE[skip.crawler]="[SKIP] Legitimer Bot nicht gesperrt: %s"
T_ES[skip.crawler]="[SKIP] Robot legítimo no bloqueado: %s"
T_IT[skip.crawler]="[SKIP] Bot legittimo non bloccato: %s"

T_EN[already.banned]="[...] IP %s is already in the ipset (%s 404 errors)."
T_FR[already.banned]="[...] L'IP %s est déjà dans l'ipset (%s erreurs 404)."
T_DE[already.banned]="[...] IP %s ist bereits im ipset (%s 404-Fehler)."
T_ES[already.banned]="[...] La IP %s ya está en el ipset (%s errores 404)."
T_IT[already.banned]="[...] L'IP %s è già nell'ipset (%s errori 404)."

T_EN[sim.ban_honeypot]="[SIMULATION] [+] IP %s would be banned IMMEDIATELY (honeypot detected: %s)."
T_FR[sim.ban_honeypot]="[SIMULATION] [+] L'IP %s aurait été bannie IMMÉDIATEMENT (honeypot détecté : %s)."
T_DE[sim.ban_honeypot]="[SIMULATION] [+] IP %s würde SOFORT gesperrt (Honeypot erkannt: %s)."
T_ES[sim.ban_honeypot]="[SIMULATION] [+] La IP %s sería bloqueada INMEDIATAMENTE (honeypot detectado: %s)."
T_IT[sim.ban_honeypot]="[SIMULATION] [+] L'IP %s verrebbe bloccato IMMEDIATAMENTE (honeypot rilevato: %s)."

T_EN[sim.ban_add]="[SIMULATION] [+] IP %s would be added to the ipset (%s 404 errors)."
T_FR[sim.ban_add]="[SIMULATION] [+] L'IP %s aurait été ajoutée à l'ipset (%s erreurs 404)."
T_DE[sim.ban_add]="[SIMULATION] [+] IP %s würde zum ipset hinzugefügt (%s 404-Fehler)."
T_ES[sim.ban_add]="[SIMULATION] [+] La IP %s se añadiría al ipset (%s errores 404)."
T_IT[sim.ban_add]="[SIMULATION] [+] L'IP %s verrebbe aggiunto all'ipset (%s errori 404)."

T_EN[ban.honeypot]="[+] IMMEDIATE block (honeypot) of IP: %s"
T_FR[ban.honeypot]="[+] Blocage IMMÉDIAT (honeypot) de l'IP : %s"
T_DE[ban.honeypot]="[+] SOFORTIGE Sperre (Honeypot) der IP: %s"
T_ES[ban.honeypot]="[+] Bloqueo INMEDIATO (honeypot) de la IP: %s"
T_IT[ban.honeypot]="[+] Blocco IMMEDIATO (honeypot) dell'IP: %s"

T_EN[ban.add]="[+] Block (ipset) of IP: %s (%s 404 errors)"
T_FR[ban.add]="[+] Blocage (ipset) de l'IP : %s (%s erreurs 404)"
T_DE[ban.add]="[+] Sperre (ipset) der IP: %s (%s 404-Fehler)"
T_ES[ban.add]="[+] Bloqueo (ipset) de la IP: %s (%s errores 404)"
T_IT[ban.add]="[+] Blocco (ipset) dell'IP: %s (%s errori 404)"

T_EN[verbose.result_header]="\n=[ Result ]="
T_FR[verbose.result_header]="\n=[ Résultat ]="
T_DE[verbose.result_header]="\n=[ Ergebnis ]="
T_ES[verbose.result_header]="\n=[ Resultado ]="
T_IT[verbose.result_header]="\n=[ Risultato ]="

T_EN[result.sim]="=> Simulation finished. %s virtual action(s) generated."
T_FR[result.sim]="=> Mode simulation terminé. %s action(s) virtuelle(s) générée(s)."
T_DE[result.sim]="=> Simulation beendet. %s virtuelle Aktion(en) erzeugt."
T_ES[result.sim]="=> Simulación finalizada. %s acción(es) virtual(es) generada(s)."
T_IT[result.sim]="=> Simulazione terminata. %s azione/i virtuale/i generata/e."

T_EN[verbose.changes_saved]="=> Changes applied. Saving the ipset configuration..."
T_FR[verbose.changes_saved]="=> Changements appliqués. Sauvegarde de la configuration ipset..."
T_DE[verbose.changes_saved]="=> Änderungen angewendet. ipset-Konfiguration wird gespeichert..."
T_ES[verbose.changes_saved]="=> Cambios aplicados. Guardando la configuración de ipset..."
T_IT[verbose.changes_saved]="=> Modifiche applicate. Salvataggio della configurazione ipset..."

T_EN[verbose.no_change]="=> No change required in the ipset."
T_FR[verbose.no_change]="=> Aucune modification requise dans l'ipset."
T_DE[verbose.no_change]="=> Keine Änderung im ipset erforderlich."
T_ES[verbose.no_change]="=> No se requiere ningún cambio en el ipset."
T_IT[verbose.no_change]="=> Nessuna modifica richiesta nell'ipset."

# Detection de la langue : locale du shell (ou /etc/default/locale en repli pour
# le contexte cron), code 2 lettres retenu s'il fait partie des langues gerees.
detect_lang() {
    local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    if [ -z "$l" ] && [ -r /etc/default/locale ]; then
        l=$(. /etc/default/locale 2>/dev/null; printf '%s' "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}")
    fi
    l="${l%%.*}"; l="${l%%_*}"; l="${l,,}"
    case "$l" in en|fr|de|es|it) printf '%s' "$l" ;; *) printf '%s' en ;; esac
}

# --- Surcharge par la config locale, NON versionnee (whitelist par serveur, REPO_RAW, langue, etc.) ---
CONF_FILE="/etc/ban_404.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# Resolution de la langue : conf > locale du shell > en. Puis validation.
: "${BAN404_LANG:=$(detect_lang)}"
BAN404_LANG="${BAN404_LANG,,}"
case "$BAN404_LANG" in en|fr|de|es|it) ;; *) BAN404_LANG=en ;; esac

# t <cle> [args...] : imprime la traduction (\n du format interpretes) + saut de ligne final.
# Le format est TOUJOURS notre chaine ; les donnees ($ip, $count...) passent en arguments
# positionnels consommes par les %s -> aucune injection de format possible.
t() {
    local key="$1"; shift
    local ref="T_${BAN404_LANG^^}[$key]"
    local fmt="${!ref-}"
    [ -z "$fmt" ] && fmt="${T_EN[$key]-}"   # fallback EN si la cle manque pour la langue
    [ -z "$fmt" ] && fmt="$key"             # ultime garde-fou : jamais muet
    # '--' : empeche printf d'interpreter un format commencant par '-' comme une option.
    # shellcheck disable=SC2059
    printf -- "$fmt\n" "$@"
}

# Initialisation des options
DRY_RUN=false
SHOW_BLOCKED=false
VERBOSE=false

show_help() {
    t version.line "$BAN404_VERSION"
    t help.usage "$0"
    echo ""
    t help.options_header
    t help.dryrun
    t help.showblocked
    t help.verbose
    t help.lang
    t help.version
    t help.help
    exit 0
}

# --lang <code> : ecrit BAN404_LANG dans la conf (remplace ou ajoute), puis quitte.
change_lang() {
    local new_lang="${1:-}"
    new_lang="${new_lang,,}"
    case "$new_lang" in
        en|fr|de|es|it) ;;
        "") t lang.missing; exit 1 ;;
        *) t lang.unsupported "$new_lang"; exit 1 ;;
    esac
    if [ ! -f "$CONF_FILE" ]; then
        t lang.noconf "$CONF_FILE"; exit 1
    fi
    if grep -q '^BAN404_LANG=' "$CONF_FILE"; then
        local tmp
        tmp=$(mktemp) || { t lang.write_fail "$CONF_FILE"; exit 1; }
        # cat > conserve les permissions/proprietaire de la conf (chmod 600 root)
        if sed "s/^BAN404_LANG=.*/BAN404_LANG=\"$new_lang\"/" "$CONF_FILE" > "$tmp" && cat "$tmp" > "$CONF_FILE"; then
            rm -f "$tmp"
        else
            rm -f "$tmp"; t lang.write_fail "$CONF_FILE"; exit 1
        fi
    else
        {
            printf '\n# Langue des messages : en (defaut) | fr | de | es | it\n'
            printf 'BAN404_LANG="%s"\n' "$new_lang"
        } >> "$CONF_FILE" || { t lang.write_fail "$CONF_FILE"; exit 1; }
    fi
    BAN404_LANG="$new_lang"   # confirmation dans la NOUVELLE langue
    t lang.changed "$new_lang" "$CONF_FILE"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --show-blocked) SHOW_BLOCKED=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --lang) change_lang "${2:-}" ;;
        --lang=*) change_lang "${1#*=}" ;;
        --version) t version.line "$BAN404_VERSION"; exit 0 ;;
        --help|-h) show_help ;;
        *) t err.unknown_opt "$1"; exit 1 ;;
    esac
done

# --- Verrou anti-chevauchement (cron). Inutile en simulation (lecture seule). ---
if [ "$DRY_RUN" = false ]; then
    exec 9>"$LOCK_FILE" || { t lock.open_fail "$LOCK_FILE"; exit 1; }
    if ! flock -n 9; then
        t lock.busy "$LOCK_FILE"
        exit 1
    fi
fi

if [ "$VERBOSE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "========================================="
        echo "   /!\\  $(t banner.sim_active)  /!\\"
        echo "========================================="
    fi
    if [ "$SHOW_BLOCKED" = false ]; then
        t verbose.filter_hidden
    else
        t verbose.filter_all
    fi
    t verbose.searching_logs
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
        [ "$VERBOSE" = true ] && t verbose.log_ok "$file"
        VALID_FILES+=("$file")
    else
        [ "$VERBOSE" = true ] && t verbose.log_skip "$file"
    fi
done

if [ ${#VALID_FILES[@]} -eq 0 ]; then
    t no_valid_files
    exit 0
fi

# Borne basse de la fenetre, au format AAAAMMJJHHMMSS (comparable directement, sans mktime)
CUTOFF=$(date -d "@$(( $(date +%s) - WINDOW ))" '+%Y%m%d%H%M%S')
[ "$VERBOSE" = true ] && t verbose.analyzing "${TAIL_LINES}" "$CUTOFF"

# 3. Extraction et tri via awk
#    - tail -q : seulement les dernieres lignes de CHAQUE log (borne le cout)
#    - whitelist en correspondance EXACTE (split sur |)
#    - fenetre temporelle (on ignore les 404 trop vieux)
#    - insensibilite a la casse via tolower() (le flag /i n'existe pas en awk)
#    - filtre anti-bruit + honeypots, seuils/motifs surchargables via la conf.
#    Les motifs passent par ENVIRON (pas -v) : pas de re-traitement des echappements
#    (\.  reste \.) ; les seuils numeriques passent par -v.
ips_data=$(tail -n "$TAIL_LINES" -q "${VALID_FILES[@]}" | \
    HONEYPOT_RE="$HONEYPOT_PATTERN" NOISE_RE="$NOISE_PATTERN" \
    awk -v wl="$WHITELIST_IP" -v cutoff="$CUTOFF" -v thr="$BAN_THRESHOLD" -v hp="$HONEYPOT_SCORE" '
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", M, " ")
    for (i=1;i<=12;i++) mon[M[i]]=i
    n=split(wl, Wl, "|"); for (i=1;i<=n;i++) white[Wl[i]]=1
    noise_re = ENVIRON["NOISE_RE"]
    honeypot_re = ENVIRON["HONEYPOT_RE"]
}
$9 == 404 && !($1 in white) {

    # --- Fenetre temporelle : $4 = [jj/Mon/aaaa:hh:mm:ss ---
    split(substr($4,2), d, /[\/:]/)
    ts = sprintf("%04d%02d%02d%02d%02d%02d", d[3], mon[d[2]], d[1], d[4], d[5], d[6])
    if (ts < cutoff) next

    p = tolower($7)

    # --- A. Bruit de fond (faux positifs) ---
    if (p ~ noise_re) next

    # --- B. Honeypots : +HONEYPOT_SCORE (ban quasi immediat) ---
    if (p ~ honeypot_re) {
        count[$1] += hp
    } else {
        count[$1]++
    }
}
END {
    for (ip in count) if (count[ip] > thr) print count[ip], ip
}' | sort -rn)

if [ -z "$ips_data" ]; then
    [ "$VERBOSE" = true ] && t no_suspect
    exit 0
fi

changes_made=false
rules_simulated=0
[ "$VERBOSE" = true ] && t verbose.processing

# 4. Boucle de traitement
while read -r count ip; do
    [ -z "$ip" ] && continue

    crawler_domain=$(is_legit_crawler "$ip")
    if [ $? -eq 0 ]; then
        if [ "$DRY_RUN" = false ] && ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
            t unban.crawler "$ip" "$crawler_domain" "$count"
            ipset del "$IPSET_NAME" "$ip"
            changes_made=true
        elif [ "$DRY_RUN" = true ] && ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
            t sim.unban "$ip" "$crawler_domain"
            rules_simulated=$((rules_simulated + 1))
        else
            [ "$SHOW_BLOCKED" = true ] && t skip.crawler "$ip"
        fi
        continue
    fi

    if ipset test "$IPSET_NAME" "$ip" &>/dev/null; then
        [ "$SHOW_BLOCKED" = true ] && t already.banned "$ip" "$count"
    else
        if [ "$DRY_RUN" = true ]; then
            if [ "$count" -ge "$HONEYPOT_SCORE" ]; then
                t sim.ban_honeypot "$ip" "$count"
            else
                t sim.ban_add "$ip" "$count"
            fi
            rules_simulated=$((rules_simulated + 1))
        else
            if [ "$count" -ge "$HONEYPOT_SCORE" ]; then
                t ban.honeypot "$ip"
            else
                t ban.add "$ip" "$count"
            fi
            ipset -exist add "$IPSET_NAME" "$ip"
            changes_made=true
        fi
    fi
done <<< "$ips_data"

# 5. Sauvegarde
[ "$VERBOSE" = true ] && t verbose.result_header
if [ "$DRY_RUN" = true ]; then
    t result.sim "$rules_simulated"
else
    if [ "$changes_made" = true ]; then
        [ "$VERBOSE" = true ] && t verbose.changes_saved
        mkdir -p "$(dirname "$IPSET_SAVE_FILE")"
        ipset save > "$IPSET_SAVE_FILE"
    else
        [ "$VERBOSE" = true ] && t verbose.no_change
    fi
fi
