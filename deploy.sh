#!/usr/bin/env bash
# =============================================================================
# OpenLiteSpeed + WordPress Deployment Script for Debian
# =============================================================================
# Usage: sudo bash deploy.sh [--config config.env]
# =============================================================================

set -euo pipefail

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# ─── Runtime flags ───────────────────────────────────────────────────────────
VERBOSE_OUTPUT=true
RESET_SITE=false
CONFIG_FILE="config.env"
CREDS_FILE="/root/.ols-wp-credentials"
STATE_DIR="/root/.ols-wp-state"

APT_FLAGS=()
WGET_FLAGS=()
CURL_FLAGS=()
WP_CLI_DOWNLOAD_FLAGS=()

apt_get() { apt-get "${APT_FLAGS[@]}" "$@"; }
wget_cmd() { wget "${WGET_FLAGS[@]}" "$@"; }
curl_cmd() { curl "${CURL_FLAGS[@]}" "$@"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ -n "${2:-}" ]] || error "--config requires a file path."
            CONFIG_FILE="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE_OUTPUT=true
            shift
            ;;
        --quiet)
            VERBOSE_OUTPUT=false
            shift
            ;;
        --reset-site|--cleanup)
            RESET_SITE=true
            shift
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

if [[ "$VERBOSE_OUTPUT" == "false" ]]; then
    APT_FLAGS=(-qq)
    WGET_FLAGS=(-q)
    CURL_FLAGS=(-fsSL)
    WP_CLI_DOWNLOAD_FLAGS=(--quiet)
else
    CURL_FLAGS=(-fL)
fi

# ─── Defaults (override via config.env or environment) ───────────────────────
: "${DOMAIN:=example.com}"
: "${WP_ADMIN_USER:=admin}"
: "${WP_ADMIN_EMAIL:=admin@example.com}"
: "${WP_DB_NAME:=wordpress}"
: "${WP_DB_USER:=wpuser}"
: "${WP_DB_PASS:=}"           # auto-generated if empty
: "${MYSQL_ROOT_PASS:=}"      # auto-generated if empty
: "${OLS_ADMIN_USER:=admin}"
: "${OLS_ADMIN_PASS:=}"       # auto-generated if empty
: "${PHP_VERSION:=84}"        # lsphp version, e.g. 84 = PHP 8.4
: "${INSTALL_SSL:=false}"     # set to true to request a Let's Encrypt cert
: "${WEBROOT:=/var/www/${DOMAIN}}"
: "${OLS_VHOST_DIR:=/usr/local/lsws/conf/vhosts/${DOMAIN}}"
: "${WP_CLI_PATH:=/usr/local/bin/wp}"

# ─── Load optional config file ───────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    info "Loaded config from $CONFIG_FILE"
fi

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)."

# ─── Debian check ────────────────────────────────────────────────────────────
[[ -f /etc/debian_version ]] || error "This script requires a Debian-based OS."

# Determine Debian version (e.g. 11, 12, 13)
DEBIAN_VERSION_ID="$(lsb_release -rs 2>/dev/null | cut -d. -f1)"
DEBIAN_CODENAME="$(lsb_release -cs 2>/dev/null)"

case "$DEBIAN_VERSION_ID" in
    11) ;; # Bullseye
    12) ;; # Bookworm
    13) ;; # Trixie
    *)
        warn "Debian ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) is not officially tested."
        warn "Supported versions: 11 (Bullseye), 12 (Bookworm), 13 (Trixie)."
        read -r -p "Continue anyway? [y/N] " _REPLY
        [[ "${_REPLY,,}" == "y" ]] || error "Aborted."
        ;;
esac
info "Detected Debian ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME})"

# ─── Detect if this is a re-run (multi-site scenario) ──────────────────────────
IS_FIRST_RUN=true
if command -v lshttpd &>/dev/null; then
    IS_FIRST_RUN=false
fi

REQUESTED_DOMAIN="$DOMAIN"

if [[ -f "$CREDS_FILE" ]]; then
    SAVED_DOMAIN="$(awk -F= '/^DOMAIN=/{print $2; exit}' "$CREDS_FILE" 2>/dev/null || true)"
    if [[ "$SAVED_DOMAIN" == "$REQUESTED_DOMAIN" ]]; then
        # shellcheck disable=SC1090
        source "$CREDS_FILE"
        info "Loaded previous credentials from $CREDS_FILE"
    fi
fi

mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/${DOMAIN}.state"
FAILED_MARKER="${STATE_DIR}/${DOMAIN}.failed"
touch "$STATE_FILE"

cleanup_state() {
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        rm -f "$FAILED_MARKER" "$STATE_FILE"
    else
        printf '%s\n' "$(date)" > "$FAILED_MARKER"
        warn "Previous run marked as failed: $FAILED_MARKER"
    fi
}
trap cleanup_state EXIT

if [[ -f "$FAILED_MARKER" ]]; then
    warn "Detected a previous failed run for ${DOMAIN}. Reusing saved credentials to continue."
fi

if [[ "$RESET_SITE" == "true" ]]; then
    warn "Reset requested: removing existing site files for ${DOMAIN} before redeploying."
    rm -rf "$WEBROOT"
    rm -rf "$OLS_VHOST_DIR"
    rm -f "$FAILED_MARKER"
    sed -i "/virtualhost ${DOMAIN}/,/^}/d" /usr/local/lsws/conf/httpd_config.conf 2>/dev/null || true
    sed -i "/map[[:space:]]\+${DOMAIN}[[:space:]]\+${DOMAIN}/d" /usr/local/lsws/conf/httpd_config.conf 2>/dev/null || true
fi

# ─── Generate passwords if not set ───────────────────────────────────────────
generate_pass() { tr -dc 'A-Za-z0-9!@#%^&*()-_=+' </dev/urandom | head -c 24; }
[[ -n "$MYSQL_ROOT_PASS" ]] || MYSQL_ROOT_PASS="$(generate_pass)"
[[ -n "$WP_DB_PASS" ]]      || WP_DB_PASS="$(generate_pass)"
[[ -n "$OLS_ADMIN_PASS" ]]  || OLS_ADMIN_PASS="$(generate_pass)"

# ─── Save generated credentials ──────────────────────────────────────────────
save_credentials() {
    cat > "$CREDS_FILE" <<EOF
# OpenLiteSpeed + WordPress credentials
# Generated: $(date)
DOMAIN=$DOMAIN
OLS_ADMIN_USER=$OLS_ADMIN_USER
OLS_ADMIN_PASS=$OLS_ADMIN_PASS
MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS
WP_DB_NAME=$WP_DB_NAME
WP_DB_USER=$WP_DB_USER
WP_DB_PASS=$WP_DB_PASS
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_EMAIL=$WP_ADMIN_EMAIL
EOF
    chmod 600 "$CREDS_FILE"
    success "Credentials saved to $CREDS_FILE"
}

# =============================================================================
# 1. System update & prerequisites
# =============================================================================
install_prerequisites() {
    section "Updating system and installing prerequisites"
    apt_get update
    apt_get upgrade -y
    apt_get install -y \
        curl wget gnupg2 lsb-release ca-certificates \
        software-properties-common apt-transport-https \
        unzip expect openssl ufw
    success "Prerequisites installed"
}

# =============================================================================
# 2. OpenLiteSpeed
# =============================================================================
install_openlitespeed() {
    section "Installing OpenLiteSpeed"

    if command -v lshttpd &>/dev/null; then
        warn "OpenLiteSpeed is already installed — skipping"
        return
    fi

    # Add official LiteSpeed repo
    wget_cmd -O /tmp/repo.litespeed.sh https://repo.litespeed.sh
    bash /tmp/repo.litespeed.sh
    rm -f /tmp/repo.litespeed.sh

    apt_get update
    apt_get install -y openlitespeed

    success "OpenLiteSpeed installed"

    # Set admin password
    /usr/local/lsws/admin/misc/admpass.sh <<EOF
$OLS_ADMIN_USER
$OLS_ADMIN_PASS
$OLS_ADMIN_PASS
EOF
    success "OLS admin password set"
}

# =============================================================================
# 3. PHP (via lsphp)
# =============================================================================
install_php() {
    section "Installing PHP ${PHP_VERSION:0:1}.${PHP_VERSION:1} (lsphp${PHP_VERSION})"

    local PKGS=(
        "lsphp${PHP_VERSION}"
        "lsphp${PHP_VERSION}-common"
        "lsphp${PHP_VERSION}-mysql"
        "lsphp${PHP_VERSION}-curl"
        "lsphp${PHP_VERSION}-gd"
        "lsphp${PHP_VERSION}-imagick"
        "lsphp${PHP_VERSION}-intl"
        "lsphp${PHP_VERSION}-mbstring"
        "lsphp${PHP_VERSION}-opcache"
        "lsphp${PHP_VERSION}-soap"
        "lsphp${PHP_VERSION}-xml"
        "lsphp${PHP_VERSION}-zip"
        "lsphp${PHP_VERSION}-redis"
    )

    apt_get install -y "${PKGS[@]}" || {
        warn "Some optional PHP extensions may not be available — installing core only"
        apt_get install -y \
            "lsphp${PHP_VERSION}" \
            "lsphp${PHP_VERSION}-common" \
            "lsphp${PHP_VERSION}-mysql" \
            "lsphp${PHP_VERSION}-curl" \
            "lsphp${PHP_VERSION}-gd" \
            "lsphp${PHP_VERSION}-mbstring" \
            "lsphp${PHP_VERSION}-opcache" \
            "lsphp${PHP_VERSION}-xml" \
            "lsphp${PHP_VERSION}-zip"
    }

    success "PHP lsphp${PHP_VERSION} installed"
}

# =============================================================================
# 4. MariaDB
# =============================================================================
install_mariadb() {
    section "Installing MariaDB"

    if command -v mysql &>/dev/null; then
        warn "MariaDB/MySQL already installed — skipping"
        return
    fi

    apt_get install -y mariadb-server mariadb-client

    systemctl enable --now mariadb

    # Secure installation (non-interactive)
    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    success "MariaDB installed and secured"
}

# =============================================================================
# 5. Create WordPress database & user
# =============================================================================
create_database() {
    section "Creating WordPress database"

    mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    success "Database '${WP_DB_NAME}' and user '${WP_DB_USER}' created"
}

# =============================================================================
# 6. WordPress
# =============================================================================
install_wordpress() {
    section "Installing WordPress"

    mkdir -p "$WEBROOT"

    # Download via WP-CLI (installed below) or fall back to direct download
    if command -v wp &>/dev/null; then
        wp core download --path="$WEBROOT" --allow-root "${WP_CLI_DOWNLOAD_FLAGS[@]}"
    else
        curl_cmd -L https://wordpress.org/latest.tar.gz | tar -xz -C /tmp
        cp -r /tmp/wordpress/. "$WEBROOT/"
        rm -rf /tmp/wordpress
    fi

    # wp-config.php
    local SALT
    SALT="$(curl_cmd https://api.wordpress.org/secret-key/1.1/salt/)"
    cat > "${WEBROOT}/wp-config.php" <<PHP
<?php
define( 'DB_NAME',     '${WP_DB_NAME}' );
define( 'DB_USER',     '${WP_DB_USER}' );
define( 'DB_PASSWORD', '${WP_DB_PASS}' );
define( 'DB_HOST',     'localhost' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  '' );

${SALT}

\$table_prefix = 'wp_';

define( 'WP_DEBUG',     false );
define( 'WP_DEBUG_LOG', false );

/* HTTPS detection behind proxy */
if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] ) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    \$_SERVER['HTTPS'] = 'on';
}

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP

    # Permissions
    chown -R nobody:nogroup "$WEBROOT"
    find "$WEBROOT" -type d -exec chmod 755 {} \;
    find "$WEBROOT" -type f -exec chmod 644 {} \;

    success "WordPress downloaded and configured at $WEBROOT"
}

# =============================================================================
# 7. WP-CLI
# =============================================================================
install_wpcli() {
    section "Installing WP-CLI"

    if [[ -f "$WP_CLI_PATH" ]]; then
        warn "WP-CLI already present — skipping"
        return
    fi

    curl_cmd -o "$WP_CLI_PATH" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x "$WP_CLI_PATH"

    success "WP-CLI installed at $WP_CLI_PATH"
}

# =============================================================================
# 8. OpenLiteSpeed virtual host configuration
# =============================================================================
configure_vhost() {
    section "Configuring OpenLiteSpeed virtual host for ${DOMAIN}"

    local PHP_BIN="/usr/local/lsws/lsphp${PHP_VERSION}/bin/lsphp"

    # ── Virtual host config directory ──────────────────────────────────────
    mkdir -p "${OLS_VHOST_DIR}/conf"
    mkdir -p "${OLS_VHOST_DIR}/logs"

    # ── vhost.conf ─────────────────────────────────────────────────────────
    cat > "${OLS_VHOST_DIR}/vhost.conf" <<VHCONF
docRoot                   \$VH_ROOT/html
vhDomain                  ${DOMAIN}
vhAliases                 www.${DOMAIN}
adminEmails               ${WP_ADMIN_EMAIL}
enableGzip                1
enableBr                  1

index  {
  useServer               0
  indexFiles              index.php, index.html
}

errorlog \$VH_ROOT/logs/error.log {
  useServer               0
  logLevel                ERROR
  rollingSize             10M
}

accesslog \$VH_ROOT/logs/access.log {
  useServer               0
  rollingSize             10M
  keepDays                30
  compressArchive         1
}

phpIniOverride {
  php_value upload_max_filesize 64M
  php_value post_max_size 64M
  php_value memory_limit 256M
  php_value max_execution_time 300
}

context / {
  type                    NULL
  location                \$DOC_ROOT
  allowBrowse             1
  rewrite {
    enable                1
    rules                 <<<END_RULES
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
END_RULES
  }
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}

vhssl  {
  keyFile                 /etc/letsencrypt/live/${DOMAIN}/privkey.pem
  certFile                /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  certChain               1
}
VHCONF

    # ── Symlink webroot ─────────────────────────────────────────────────────
    ln -sfn "$WEBROOT" "${OLS_VHOST_DIR}/html"

    # ── Register vhost + listener in httpd_config.conf ─────────────────────
    local HTTPD_CONF="/usr/local/lsws/conf/httpd_config.conf"

    # Add PHP external app if not already present
    if ! grep -q "lsphp${PHP_VERSION}" "$HTTPD_CONF"; then
        cat >> "$HTTPD_CONF" <<EXTAPP

extprocessor lsphp${PHP_VERSION} {
  type                    lsapi
  address                 UDS://tmp/lshttpd/lsphp${PHP_VERSION}.sock
  maxConns                35
  env                     PHP_LSAPI_CHILDREN=35
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    ${PHP_BIN}
  backlog                 100
  instances               1
}
EXTAPP
    fi

    # Add vhost definition if not already present
    if ! grep -q "virtualhost ${DOMAIN}" "$HTTPD_CONF"; then
        cat >> "$HTTPD_CONF" <<VHDEF

virtualhost ${DOMAIN} {
  vhRoot                  ${OLS_VHOST_DIR}
  configFile              ${OLS_VHOST_DIR}/vhost.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              2
}
VHDEF
    fi

    # Add domain mapping to existing listeners instead of modifying Default
    if ! grep -q "map.*${DOMAIN}" "$HTTPD_CONF"; then
        # Try to add to HTTP listener
        if grep -q "listener HTTP {" "$HTTPD_CONF"; then
            sed -i "/listener HTTP {/,/}/ s/^}/  map                     ${DOMAIN} ${DOMAIN}\n}/" "$HTTPD_CONF"
        fi
        # Try to add to HTTPS listener
        if grep -q "listener HTTPS {" "$HTTPD_CONF"; then
            sed -i "/listener HTTPS {/,/}/ s/^}/  map                     ${DOMAIN} ${DOMAIN}\n}/" "$HTTPD_CONF"
        fi
        # If neither exists, create them
        if ! grep -q "map.*${DOMAIN}" "$HTTPD_CONF"; then
            cat >> "$HTTPD_CONF" <<LSTN

listener HTTP {
  address                 *:80
  secure                  0
  map                     ${DOMAIN} ${DOMAIN}
}

listener HTTPS {
  address                 *:443
  secure                  1
  map                     ${DOMAIN} ${DOMAIN}
}
LSTN
        fi
    fi

    success "Virtual host configured"
}

# =============================================================================
# 9. Let's Encrypt SSL (optional)
# =============================================================================
install_ssl() {
    [[ "$INSTALL_SSL" == "true" ]] || return 0

    section "Installing Let's Encrypt SSL for ${DOMAIN}"

    apt_get install -y certbot

    # Stop OLS temporarily so certbot can bind port 80
    systemctl stop lsws

    certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "$WP_ADMIN_EMAIL" \
        -d "$DOMAIN" \
        -d "www.${DOMAIN}" || {
            warn "Certbot failed — SSL not configured. Ensure DNS for ${DOMAIN} points to this server."
            systemctl start lsws
            return
        }

    systemctl start lsws

    # Auto-renewal via cron
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload lsws'") | crontab -

    success "SSL certificate installed and auto-renewal scheduled"
}

# =============================================================================
# 10. Firewall
# =============================================================================
configure_firewall() {
    section "Configuring UFW firewall"

    # Only reset firewall on first run; on re-runs, just add missing rules
    if [[ "$IS_FIRST_RUN" == "true" ]]; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
    fi

    # Add rules (idempotent — already-added rules won't cause errors)
    ufw allow ssh || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 7080/tcp || true

    # Enable if not already enabled
    if ! ufw status | grep -q "^Status: active"; then
        ufw --force enable
    fi

    success "Firewall configured"
}

# =============================================================================
# 11. Enable & start services
# =============================================================================
start_services() {
    section "Enabling and starting services"

    systemctl enable --now mariadb
    systemctl enable lsws
    systemctl restart lsws

    success "Services started"
}

# =============================================================================
# 12. WordPress core install via WP-CLI
# =============================================================================
run_wp_install() {
    section "Running WordPress core install"

    local PROTO="http"
    [[ "$INSTALL_SSL" == "true" ]] && PROTO="https"

    wp core install \
        --path="$WEBROOT" \
        --url="${PROTO}://${DOMAIN}" \
        --title="WordPress on OpenLiteSpeed" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --admin_password="$(generate_pass)" \
        --skip-email \
        --allow-root || \
        warn "WP-CLI core install skipped (may already be installed or DB not yet reachable via HTTP)"

    success "WordPress core install complete"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    local PROTO="http"
    [[ "$INSTALL_SSL" == "true" ]] && PROTO="https"

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗"
    echo -e "║         Deployment Complete — Summary                ║"
    echo -e "╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Site URL       : ${BOLD}${PROTO}://${DOMAIN}${RESET}"
    echo -e "  OLS Admin      : ${BOLD}https://$(hostname -I | awk '{print $1}'):7080${RESET}"
    echo -e "  OLS Admin User : ${BOLD}${OLS_ADMIN_USER}${RESET}"
    echo -e "  OLS Admin Pass : ${BOLD}${OLS_ADMIN_PASS}${RESET}"
    echo ""
    echo -e "  DB Name        : ${BOLD}${WP_DB_NAME}${RESET}"
    echo -e "  DB User        : ${BOLD}${WP_DB_USER}${RESET}"
    echo -e "  DB Password    : ${BOLD}${WP_DB_PASS}${RESET}"
    echo -e "  MySQL Root Pass: ${BOLD}${MYSQL_ROOT_PASS}${RESET}"
    echo ""
    echo -e "  WP Admin User  : ${BOLD}${WP_ADMIN_USER}${RESET}"
    echo -e "  WP Admin Email : ${BOLD}${WP_ADMIN_EMAIL}${RESET}"
    echo ""
    echo -e "  All credentials saved to: ${BOLD}${CREDS_FILE}${RESET}"
    echo ""
    echo -e "  ${YELLOW}Next step:${RESET} Open ${PROTO}://${DOMAIN}/wp-admin to complete"
    echo -e "  WordPress setup if WP-CLI install was skipped."
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    if [[ "$IS_FIRST_RUN" == "true" ]]; then
        echo "  ║   OpenLiteSpeed + WordPress Deployment        ║"
    else
        echo "  ║   OpenLiteSpeed + WordPress Add-Site          ║"
    fi
    echo "  ║   Target: ${DOMAIN}"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${RESET}"

    save_credentials
    install_prerequisites
    install_openlitespeed
    install_php
    install_mariadb
    create_database
    install_wpcli
    install_wordpress
    configure_vhost
    configure_firewall
    install_ssl
    start_services
    run_wp_install
    print_summary
}

main "$@"
