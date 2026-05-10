# OLS WordPress Deployment

One-shot shell script that installs and configures **OpenLiteSpeed + MariaDB + PHP (lsphp) + WordPress** on a fresh Debian server.

## Requirements

| Requirement | Details |
|---|---|
| OS | Debian 11 (Bullseye), 12 (Bookworm), or 13 (Trixie) |
| Access | Root / sudo |
| RAM | 1 GB minimum (2 GB recommended) |
| DNS | Domain A record pointing to the server (required for SSL only) |

## Quick start

```bash
# 1. Clone or copy the repo onto the server
git clone https://github.com/c-wann/ols-wp-deployment.git
cd ols-wp-deployment

# 2. Copy and edit the config
cp config.env.example config.env
nano config.env

# 3. Run
sudo bash deploy.sh --config config.env
```

Without a config file the script runs with sensible defaults (`example.com`, no SSL, auto-generated passwords).

## Multi-site deployment

The script is designed to run multiple times on the same server to host multiple WordPress sites.

**First site (full installation):**
```bash
sudo bash deploy.sh --config config.env
```

**Additional sites (only new vhost + database):**
```bash
# Create a new config for the additional site
export DOMAIN="site2.com"
export WP_DB_NAME="wordpress2"
export WP_DB_USER="wpuser2"
sudo bash deploy.sh
```

On subsequent runs:
- ✅ System packages (OpenLiteSpeed, PHP, MariaDB) are skipped if already installed
- ✅ Firewall rules are preserved and updated (not reset)
- ✅ New virtual host, database, and WordPress installation are created
- ✅ All services are reloaded with the new configuration

## What the script does

| Step | Action |
|---|---|
| 1 | Updates system packages |
| 2 | Adds the official LiteSpeed APT repo and installs **OpenLiteSpeed** (skipped on re-runs) |
| 3 | Installs **lsphp** (default: PHP 8.4) with WordPress-required extensions (skipped on re-runs) |
| 4 | Installs and secures **MariaDB** (skipped on re-runs) |
| 5 | Creates the WordPress database and a dedicated DB user |
| 6 | Installs **WP-CLI** (skipped on re-runs) |
| 7 | Downloads **WordPress** and writes `wp-config.php` |
| 8 | Creates and registers an **OpenLiteSpeed virtual host** with WordPress rewrite rules |
| 9 | (Optional) Requests a **Let's Encrypt** certificate via Certbot |
| 10 | Configures **UFW** firewall (first run: full reset; re-runs: preserves existing rules) |
| 11 | Enables and starts services |
| 12 | Runs `wp core install` to pre-configure the WP admin account |

## Configuration reference

All options can be set in `config.env` or exported as environment variables before running the script.

| Variable | Default | Description |
|---|---|---|
| `DOMAIN` | `example.com` | Primary domain for the site |
| `PHP_VERSION` | `84` | lsphp package suffix (83 = 8.3, 84 = 8.4) |
| `INSTALL_SSL` | `false` | Request a Let's Encrypt certificate |
| `WP_ADMIN_USER` | `admin` | WordPress admin username |
| `WP_ADMIN_EMAIL` | `admin@example.com` | WordPress admin email |
| `WP_DB_NAME` | `wordpress` | WordPress database name |
| `WP_DB_USER` | `wpuser` | WordPress database user |
| `WP_DB_PASS` | *(auto)* | WordPress database password |
| `MYSQL_ROOT_PASS` | *(auto)* | MariaDB root password |
| `OLS_ADMIN_USER` | `admin` | OpenLiteSpeed admin username |
| `OLS_ADMIN_PASS` | *(auto)* | OpenLiteSpeed admin password |

## After deployment

- **WordPress**: `http(s)://DOMAIN`
- **OLS Admin panel**: `https://SERVER_IP:7080`
- **Credentials file**: `/root/.ols-wp-credentials` (chmod 600)
  - Contains credentials for all deployed sites (appended on each run)

If WP-CLI core install was skipped (e.g. domain not yet resolving), visit `http://DOMAIN/wp-admin` to complete the WordPress setup wizard manually.

## SSL

Set `INSTALL_SSL=true` **after** your domain's DNS A record resolves to the server. Certbot runs in standalone mode and a cron job handles automatic renewal.

## Ports opened by UFW

| Port | Purpose |
|---|---|
| 22 | SSH |
| 80 | HTTP |
| 443 | HTTPS |
| 7080 | OpenLiteSpeed admin panel |
