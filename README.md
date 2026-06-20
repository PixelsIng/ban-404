# ban-404

Ban automatique des IP qui génèrent un flood de 404 (scanners, brute-force de
chemins) sur des serveurs Apache multi-sites, via **ipset + iptables**.
Détection sur fenêtre glissante, honeypots (`.env`, `wp-config.php`…),
exclusion du bruit (assets, favicon, robots.txt…), crawlers légitimes épargnés
par **FCrDNS** (reverse DNS confirmé). Persistance au reboot via
`ipset-persistent`. Mise à jour centralisée par auto-pull (`cron.daily`).
Messages **multilingues** (en, fr, de, es, it).

## Contenu du dépôt

| Fichier                 | Rôle |
|-------------------------|------|
| `ban_404.sh`            | Le script de ban (déployé en `/usr/local/sbin/ban_404.sh`, lancé par `cron.hourly`). |
| `install_ban_404.sh`    | Installeur clé en main (paquets, cron, persistance, migration, décommissionnement). |
| `update_ban_404.sh`     | Self-updater : télécharge → valide → bascule le moteur **et lui-même** (lancé par `cron.daily`). |
| `ban_404.conf.example`  | Modèle de config locale par serveur. |

La **config par serveur** (whitelist, `REPO_RAW`, réglages) vit dans
`/etc/ban_404.conf`, **hors dépôt** : les mises à jour ne l'écrasent jamais.

## Mise en place (une seule fois)

1. Pousser ces fichiers dans un dépôt GitHub `ban-404`.
2. Dans `install_ban_404.sh`, éditer la variable `REPO_RAW` avec l'URL *raw* du
   dépôt, par ex. `https://raw.githubusercontent.com/PixelsIng/ban-404/main`.
   Commit + push.

## Installation d'un serveur

```bash
# Récupérer puis lancer (on ne fait pas « curl | bash » : on télécharge, on lit, on exécute)
curl -fsSL https://raw.githubusercontent.com/PixelsIng/ban-404/main/install_ban_404.sh -o /tmp/install_ban_404.sh
sudo bash /tmp/install_ban_404.sh

# Adapter la whitelist de CE serveur
sudo nano /etc/ban_404.conf      # WHITELIST_IP="127.0.0.1|TES.IP.FIXES"

# (Optionnel) changer la langue des messages : en | fr | de | es | it
sudo /usr/local/sbin/ban_404.sh --lang fr

# Vérifier sans rien bannir
sudo /usr/local/sbin/ban_404.sh --dry-run --verbose
```

L'installeur est **idempotent** (relançable) et gère la migration de l'ancien
chemin `/etc/iptables/ipset` ainsi que le retrait d'anciens scripts de ban 404.

## Mises à jour

Améliorer `ban_404.sh` → `git push`. Chaque serveur récupère la nouvelle
version via `cron.daily` (sous 24 h). Validation `bash -n` avant bascule : un
commit cassé n'est jamais déployé. Forcer tout de suite :

```bash
sudo /usr/local/sbin/update_ban_404.sh
```

> Le self-updater met à jour **`ban_404.sh` ET lui-même** (`update_ban_404.sh`).
> Si tu modifies l'installeur ou la structure cron, relance l'installeur sur les
> serveurs (rare).

## Réglages (`/etc/ban_404.conf`)

| Variable          | Défaut      | Rôle |
|-------------------|-------------|------|
| `BAN404_LANG`     | (auto)      | Langue des messages : `en` (défaut), `fr`, `de`, `es`, `it`. Auto-détectée depuis la locale du shell/système ; ajoutée par l'updater si absente. Modifiable via `ban_404.sh --lang <code>`. |
| `WHITELIST_IP`    | `127.0.0.1` | IP jamais bannies (séparées par `\|`, correspondance exacte). |
| `WINDOW`          | `7200`      | Fenêtre glissante (s) sur laquelle on compte les 404. |
| `BAN_TIMEOUT`     | `172800`    | Durée du ban (s). |
| `TAIL_LINES`      | `50000`     | Lignes analysées par log (borne le coût sur gros sites). |
| `BAN_THRESHOLD`   | `10`        | Ban si le score dépasse ce seuil dans la fenêtre. |
| `HONEYPOT_SCORE`  | `100`       | Score ajouté par hit honeypot (≥ ce score ⇒ ban immédiat). |
| `REPO_RAW`        | —           | URL *raw* du dépôt (utilisée par le self-updater). |

Réglages avancés (regex `awk`, à ne surcharger qu'en connaissance de cause) :
`HONEYPOT_PATTERN` (motifs honeypot) et `NOISE_PATTERN` (bruit ignoré). Voir
`ban_404.conf.example`.

## Prérequis

Ubuntu/Debian. Sur Ubuntu 22.04, `ipset-persistent` est dans le dépôt
**universe** (activé par défaut sur Ubuntu Server). Aucune dépendance externe
au-delà des paquets posés par l'installeur (`ipset`, `iptables-persistent`,
`ipset-persistent`, `cron`).
