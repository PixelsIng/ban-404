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
