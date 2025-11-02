#!/bin/bash
# merged WordPress Docker + Cloudflare Tunnel deployer
# because apparently we can't have nice, simple scripts
# This glues your WordPress Docker stack to Cloudflare in one go.
# It:
#   1. Prompts you for a Cloudflare API token (must have: Tunnel Edit, DNS Edit).
#   2. Prompts you for the public hostname (like lde123.yourdomain.com).
#   3. Deploys Docker + MariaDB + WordPress (ARM64-safe, idempotent).
#   4. Creates a Cloudflare Tunnel via API for that hostname.
#   5. Pushes tunnel config (hostname -> http://localhost:<real-port>).
#   6. Creates/updates the DNS CNAME in Cloudflare.
#   7. Installs cloudflared as a systemd service.
# Run it, answer the two questions, done.
# If it breaks, it’s because the universe is hostile, not because of the script.

set -euo pipefail

#----------------------------
# helpers (adapted)
#----------------------------
run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    run_sudo apt-get update
    APT_UPDATED=1
  fi
}

apt_update_force() {
  APT_UPDATED=0
  apt_update_once
}

install_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt_update_once
    run_sudo apt-get install -y "$pkg"
  fi
}

#----------------------------
# interactive Cloudflare input (the part humans always forget)
#----------------------------
printf "Cloudflare API token (must have: Cloudflare Tunnel Edit + DNS Edit): "
IFS= read -rs CF_API_TOKEN
printf "\n"
if [ -z "$CF_API_TOKEN" ]; then
  echo "Cloudflare API token is required. Try again when you remember it."
  exit 1
fi

read -rp "Public hostname to expose (FQDN, e.g. lde123.example.com): " CF_HOSTNAME
if [ -z "$CF_HOSTNAME" ]; then
  echo "Hostname is required. You said you wanted it wired. This is the wire."
  exit 1
fi

export CF_API_TOKEN CF_HOSTNAME

#=====================================================================
# WordPress-on-Docker (original wp-lde.sh body starts here, mostly intact)
#=====================================================================
#----------------------------
# 0. basic dirs
#----------------------------
PROJECT_DIR="${PWD}/wordpress-docker"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

#----------------------------
# 1. base packages
#----------------------------
install_pkg ca-certificates
install_pkg curl
install_pkg gnupg
install_pkg lsb-release
# pwgen is nice to have for random creds
install_pkg pwgen || true

#----------------------------
# 2. install docker (official repo) if missing
#----------------------------
if ! command -v docker >/dev/null 2>&1; then
  # prepare keyring dir
  run_sudo install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | run_sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  DOCKER_LIST=/etc/apt/sources.list.d/docker.list
  DOCKER_REPO_ADDED=0
  if [ ! -f "$DOCKER_LIST" ]; then
    CODENAME=$(lsb_release -cs)
    ARCH=$(dpkg --print-architecture)
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" | \
      run_sudo tee "$DOCKER_LIST" >/dev/null
    DOCKER_REPO_ADDED=1
  fi

  if [ "$DOCKER_REPO_ADDED" -eq 1 ]; then
    apt_update_force
  else
    apt_update_once
  fi
  # primary attempt: official docker packages
  if ! run_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null; then
    # fallback to distro docker
    run_sudo apt-get install -y docker.io
  fi
fi

#----------------------------
# 3. ensure docker service is up
#----------------------------
run_sudo systemctl enable --now docker 2>/dev/null || run_sudo service docker start 2>/dev/null || true

#----------------------------
# 4. make docker usable for current user
#----------------------------
if ! getent group docker >/dev/null 2>&1; then
  run_sudo groupadd docker
fi
if ! id -nG "$USER" | grep -qw docker; then
  run_sudo usermod -aG docker "$USER" || true
fi

DOCKER="docker"

#----------------------------
# 5. docker network & volumes
#----------------------------
if ! $DOCKER network inspect wp-net >/dev/null 2>&1; then
  $DOCKER network create wp-net
fi

if ! $DOCKER volume inspect wp-mariadb-data >/dev/null 2>&1; then
  $DOCKER volume create wp-mariadb-data
fi

if ! $DOCKER volume inspect wp-wordpress-data >/dev/null 2>&1; then
  $DOCKER volume create wp-wordpress-data
fi

#----------------------------
# 6. .env handling (re-runnable)
#----------------------------
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  WP_DB_NAME="${WP_DB_NAME:-wordpress}"
  WP_DB_USER="${WP_DB_USER:-wpuser}"
  WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(pwgen -s 16 1 2>/dev/null || echo wp_pass_$(openssl rand -hex 4))}"
  WP_DB_ROOT_PASSWORD="${WP_DB_ROOT_PASSWORD:-$(pwgen -s 18 1 2>/dev/null || echo wp_root_$(openssl rand -hex 5))}"
else
  # Generate values
  if command -v pwgen >/dev/null 2>&1; then
    WP_DB_NAME="wordpress_$(pwgen -A0 6 1)"
    WP_DB_USER="wpuser_$(pwgen -A0 4 1)"
    WP_DB_PASSWORD="$(pwgen -s 16 1)"
    WP_DB_ROOT_PASSWORD="$(pwgen -s 18 1)"
  else
    # fallback to openssl
    install_pkg openssl
    WP_DB_NAME="wordpress_$(openssl rand -hex 3)"
    WP_DB_USER="wpuser_$(openssl rand -hex 2)"
    WP_DB_PASSWORD="$(openssl rand -hex 12)"
    WP_DB_ROOT_PASSWORD="$(openssl rand -hex 14)"
  fi
  cat >"$ENV_FILE" <<EOF
WP_DB_NAME="$WP_DB_NAME"
WP_DB_USER="$WP_DB_USER"
WP_DB_PASSWORD="$WP_DB_PASSWORD"
WP_DB_ROOT_PASSWORD="$WP_DB_ROOT_PASSWORD"
EOF
fi

#----------------------------
# 7. start MariaDB container
#----------------------------
if $DOCKER ps --format '{{.Names}}' | grep -q '^wp-mariadb$'; then
  :
else
  $DOCKER run -d \
    --name wp-mariadb \
    --network wp-net \
    -v wp-mariadb-data:/var/lib/mysql \
    -e MARIADB_DATABASE="$WP_DB_NAME" \
    -e MARIADB_USER="$WP_DB_USER" \
    -e MARIADB_PASSWORD="$WP_DB_PASSWORD" \
    -e MARIADB_ROOT_PASSWORD="$WP_DB_ROOT_PASSWORD" \
    --restart unless-stopped \
    mariadb:11
fi

#----------------------------
# 8. pick HTTP port for WordPress
#----------------------------
PORT=8080
if $DOCKER ps --format '{{.Ports}}' | grep -q ':8080->80/tcp'; then
  PORT=8081
fi

#----------------------------
# 9. start WordPress container
#----------------------------
if $DOCKER ps --format '{{.Names}}' | grep -q '^wordpress$'; then
  :
else
  $DOCKER run -d \
    --name wordpress \
    --network wp-net \
    -e WORDPRESS_DB_HOST=wp-mariadb:3306 \
    -e WORDPRESS_DB_NAME="$WP_DB_NAME" \
    -e WORDPRESS_DB_USER="$WP_DB_USER" \
    -e WORDPRESS_DB_PASSWORD="$WP_DB_PASSWORD" \
    -v wp-wordpress-data:/var/www/html \
    -p ${PORT}:80 \
    --restart unless-stopped \
    wordpress:latest
fi

#----------------------------
# 10. wait for DB to be ready (using client container)
#----------------------------
$DOCKER pull mysql:8.4

echo "Waiting for MariaDB to become ready..."
TRY=0
MAX_TRIES=30
DB_READY=0
while [ "$TRY" -lt "$MAX_TRIES" ]; do
  if $DOCKER run --rm --network wp-net mysql:8.4 \
      mysql -h wp-mariadb -u"$WP_DB_USER" -p"$WP_DB_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
    DB_READY=1
    break
  fi
  TRY=$((TRY+1))
  sleep 2
done

if [ "$DB_READY" -ne 1 ]; then
  echo "Warning: MariaDB is still not responding after ${MAX_TRIES} attempts. WordPress may initialize slower."
fi

#----------------------------
# 11. final local status
#----------------------------
echo
echo "------------------------------------------------------------"
echo "WordPress Docker stack is up."
echo "Project dir: $PROJECT_DIR"
echo "DB name:      $WP_DB_NAME"
echo "DB user:      $WP_DB_USER"
echo "DB password:  $WP_DB_PASSWORD"
echo "DB root pass: $WP_DB_ROOT_PASSWORD"
echo "MariaDB:      docker container 'wp-mariadb'"
echo "WordPress:    docker container 'wordpress'"
echo "URL:          http://localhost:${PORT}"
echo "Env file:     $PROJECT_DIR/.env"
echo "------------------------------------------------------------"
echo "If you just got added to the 'docker' group, open a new shell."

#=====================================================================
# Cloudflare Tunnel + DNS automation
#=====================================================================

# we need jq for JSON parsing
install_pkg jq

# install cloudflared from official repo (idempotent)
if ! command -v cloudflared >/dev/null 2>&1; then
  run_sudo mkdir -p --mode=0755 /usr/share/keyrings
  if [ ! -f /usr/share/keyrings/cloudflare-public-v2.gpg ]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | run_sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
  fi
  CLOUDFLARED_REPO_ADDED=0
  if [ ! -f /etc/apt/sources.list.d/cloudflared.list ]; then
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | run_sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    CLOUDFLARED_REPO_ADDED=1
  fi
  if [ "$CLOUDFLARED_REPO_ADDED" -eq 1 ]; then
    apt_update_force
  else
    apt_update_once
  fi
  run_sudo apt-get install -y cloudflared
fi

echo "[cf] discovering Cloudflare account..."
ACCOUNTS_JSON=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" https://api.cloudflare.com/client/v4/accounts)
if [ "$(echo "$ACCOUNTS_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to fetch Cloudflare accounts. Raw:"
  echo "$ACCOUNTS_JSON"
  exit 1
fi

CF_ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.result[0].id')
CF_ACCOUNT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r '.result[0].name')
if [ -z "$CF_ACCOUNT_ID" ] || [ "$CF_ACCOUNT_ID" = "null" ]; then
  echo "Could not determine Cloudflare account id."
  exit 1
fi
echo "[cf] using account: $CF_ACCOUNT_NAME ($CF_ACCOUNT_ID)"

echo "[cf] determining zone for hostname $CF_HOSTNAME ..."
ZONES_JSON=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones?per_page=200")
if [ "$(echo "$ZONES_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to list zones."
  echo "$ZONES_JSON"
  exit 1
fi

CF_ZONE_ID=""
CF_ZONE_NAME=""

while IFS= read -r zline; do
  zname=$(echo "$zline" | cut -d'|' -f1)
  zid=$(echo "$zline" | cut -d'|' -f2)
  case "$CF_HOSTNAME" in
    *"$zname")
      CF_ZONE_ID="$zid"
      CF_ZONE_NAME="$zname"
      break
      ;;
  esac
done < <(echo "$ZONES_JSON" | jq -r '.result[] | "\(.name)|\(.id)"')

if [ -z "$CF_ZONE_ID" ]; then
  echo "Could not match hostname '$CF_HOSTNAME' to any zone in your account."
  exit 1
fi
echo "[cf] using zone: $CF_ZONE_NAME ($CF_ZONE_ID)"

# tunnel name (lazy unique)
TUNNEL_NAME="wp-$(date +%s)"

echo "[cf] creating tunnel $TUNNEL_NAME ..."
CREATE_TUNNEL_JSON=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"name":"'"$TUNNEL_NAME"'","config_src":"cloudflare"}')

if [ "$(echo "$CREATE_TUNNEL_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to create tunnel."
  echo "$CREATE_TUNNEL_JSON"
  exit 1
fi

TUNNEL_ID=$(echo "$CREATE_TUNNEL_JSON" | jq -r '.result.id')
TUNNEL_TOKEN=$(echo "$CREATE_TUNNEL_JSON" | jq -r '.result.token')
if [ -z "$TUNNEL_ID" ] || [ -z "$TUNNEL_TOKEN" ] || [ "$TUNNEL_ID" = "null" ]; then
  echo "Tunnel creation response incomplete."
  echo "$CREATE_TUNNEL_JSON"
  exit 1
fi
echo "[cf] tunnel id: $TUNNEL_ID"

# WordPress port from earlier
WP_PORT="${PORT:-8080}"

echo "[cf] pushing remote tunnel configuration (hostname -> http://localhost:$WP_PORT) ..."
PUT_CFG_JSON=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "config": {
      "ingress": [
        {
          "hostname": "'"$CF_HOSTNAME"'",
          "service": "http://localhost:'"$WP_PORT"'"
        },
        {
          "service": "http_status:404"
        }
      ]
    }
  }')

if [ "$(echo "$PUT_CFG_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to set tunnel configuration."
  echo "$PUT_CFG_JSON"
  exit 1
fi

echo "[cf] ensuring DNS CNAME $CF_HOSTNAME -> $TUNNEL_ID.cfargotunnel.com ..."
CF_DNS_TARGET="${TUNNEL_ID}.cfargotunnel.com"

EXIST_JSON=$(curl -sS -G "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -d "type=CNAME" \
  -d "name=$CF_HOSTNAME")

REC_ID=$(echo "$EXIST_JSON" | jq -r '.result[0].id // empty')

if [ -n "$REC_ID" ]; then
  echo "[cf] updating existing DNS record $REC_ID ..."
  UPDATE_JSON=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$REC_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"CNAME","name":"'"$CF_HOSTNAME"'","content":"'"$CF_DNS_TARGET"'","proxied":true}')
  if [ "$(echo "$UPDATE_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to update DNS record."
    echo "$UPDATE_JSON"
    exit 1
  fi
else
  echo "[cf] creating DNS record ..."
  CREATE_DNS_JSON=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"CNAME","name":"'"$CF_HOSTNAME"'","content":"'"$CF_DNS_TARGET"'","proxied":true}')
  if [ "$(echo "$CREATE_DNS_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to create DNS record."
    echo "$CREATE_DNS_JSON"
    exit 1
  fi
fi

echo "[cf] installing cloudflared systemd service ..."
run_sudo cloudflared service install "$TUNNEL_TOKEN"
run_sudo systemctl restart cloudflared || true
run_sudo systemctl enable cloudflared || true

echo
echo "============================================================"
echo "Local WordPress:        http://localhost:${WP_PORT}"
echo "Public (Cloudflare):    https://$CF_HOSTNAME"
echo "Cloudflare Tunnel ID:   $TUNNEL_ID"
echo "Cloudflare Account:     $CF_ACCOUNT_NAME"
echo "Project dir:            $PROJECT_DIR"
echo "============================================================"
echo "If you're reading this, the script actually did its job. Miracles happen."
