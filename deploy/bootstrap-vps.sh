#!/usr/bin/env bash
# Step 1 of 3 — run this ON THE VPS, as root (or with sudo).
#
# Installs nginx, creates the deploy directories, opens 80/443 and serves the
# site over plain HTTP so you can verify it before DNS and TLS are involved.
# TLS comes afterwards, from enable-https.sh.
set -euo pipefail

DOMAIN="${DOMAIN:-patpatpatrick.com}"
WEBROOT="/var/www/${DOMAIN}"

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo DOMAIN=${DOMAIN} $0" >&2
    exit 1
fi

echo "==> installing nginx + certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx rsync

echo "==> creating ${WEBROOT}/{releases,current} and the ACME webroot"
mkdir -p "${WEBROOT}/releases" /var/www/certbot
# A placeholder release so nginx has a valid root before the first deploy.
if [[ ! -e "${WEBROOT}/current" ]]; then
    mkdir -p "${WEBROOT}/releases/bootstrap"
    echo "<!doctype html><title>${DOMAIN}</title><h1>${DOMAIN}</h1><p>Waiting for first deploy.</p>" \
        > "${WEBROOT}/releases/bootstrap/index.html"
    ln -sfn "${WEBROOT}/releases/bootstrap" "${WEBROOT}/current"
fi
chown -R www-data:www-data "${WEBROOT}" /var/www/certbot

# A `listen [::]:80` on a host without a global IPv6 address makes nginx fail
# to start outright, so only emit it when IPv6 is actually usable.
LISTEN6=""
if [[ -f /proc/net/if_inet6 ]] && command -v ip >/dev/null 2>&1 \
   && ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
    LISTEN6="    listen [::]:80;"
    echo "==> IPv6 detected, will listen on it too"
else
    echo "==> no global IPv6 address, listening on IPv4 only"
fi

echo "==> installing a temporary HTTP-only nginx site"
cat > "/etc/nginx/sites-available/${DOMAIN}" <<CONF
server {
    listen 80;
${LISTEN6}
    server_name ${DOMAIN} www.${DOMAIN};

    root  ${WEBROOT}/current;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ \$uri.html =404;
    }

    error_page 404 /404.html;
}
CONF
ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f /etc/nginx/sites-enabled/default

echo "==> opening ports 80 and 443"
# OCI/ARM images ship an iptables ruleset that only allows 22. Harmless to
# re-run: the rules are only added when absent.
if command -v iptables >/dev/null 2>&1; then
    for port in 80 443; do
        if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 4 -p tcp --dport "${port}" -j ACCEPT
        fi
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow 80/tcp  >/dev/null
    ufw allow 443/tcp >/dev/null
fi

echo "==> testing and reloading nginx"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo
echo "Done. Now, from your laptop:"
echo "  1. deploy/deploy.sh                 # push the built site up"
echo "  2. curl -H 'Host: ${DOMAIN}' http://<VPS_IP>/   # verify before DNS"
echo "  3. point DNS at <VPS_IP>, then run deploy/enable-https.sh on the VPS"
