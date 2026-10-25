#!/usr/bin/env bash
# Step 3 of 3 — run this ON THE VPS, as root, AFTER DNS points at this server.
#
# Issues a Let's Encrypt certificate for the apex and www names over the ACME
# webroot the bootstrap config already serves, then swaps the temporary
# HTTP-only site for the full HTTPS config next to this script.
set -euo pipefail

DOMAIN="${DOMAIN:-patpatpatrick.com}"
EMAIL="${EMAIL:-}"
NGINX_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx"
CONF_SRC="${NGINX_SRC}/${DOMAIN}.conf"
SNIPPET_SRC="${NGINX_SRC}/tls-params.conf"

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo EMAIL=you@example.com $0" >&2
    exit 1
fi
if [[ -z ${EMAIL} ]]; then
    echo "set EMAIL so Let's Encrypt can warn you before expiry:" >&2
    echo "  sudo EMAIL=you@example.com $0" >&2
    exit 1
fi
for f in "${CONF_SRC}" "${SNIPPET_SRC}"; do
    if [[ ! -f ${f} ]]; then
        echo "missing nginx config file: ${f}" >&2
        exit 1
    fi
done

# DNS must already resolve here, or the ACME challenge cannot reach us.
# ahostsv4, not hosts: an AAAA record would otherwise be compared against the
# IPv4 address the echo service reports.
echo "==> checking that ${DOMAIN} resolves to this host"
resolved="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
mine="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
echo "    ${DOMAIN} -> ${resolved:-<unresolved>}   this host -> ${mine:-<unknown>}"
if [[ -n ${resolved} && -n ${mine} && ${resolved} != "${mine}" ]]; then
    echo "    warning: ${DOMAIN} does not resolve to this host." >&2
    echo "    If DNS has not propagated yet, Let's Encrypt will fail — wait and re-run." >&2
    if [[ -n ${FORCE:-} ]]; then
        echo "    FORCE set, continuing anyway." >&2
    elif [[ -t 0 ]]; then
        read -r -p "    continue anyway? [y/N] " reply
        [[ ${reply} == [yY] ]] || exit 1
    else
        # Running non-interactively (ssh without -t): there is no one to ask.
        echo "    re-run with FORCE=1 to proceed regardless." >&2
        exit 1
    fi
fi

echo "==> requesting the certificate"
certbot certonly \
    --webroot -w /var/www/certbot \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --email "${EMAIL}" --agree-tos --no-eff-email \
    --keep-until-expiring

echo "==> installing the HTTPS nginx config"
mkdir -p /etc/nginx/snippets
install -m 644 "${SNIPPET_SRC}" /etc/nginx/snippets/tls-params.conf
install -m 644 "${CONF_SRC}" "/etc/nginx/sites-available/${DOMAIN}"

# `http2 on;` is only understood from nginx 1.25.1 on; older builds (Ubuntu
# 24.04 ships 1.24, Debian 12 ships 1.22) take HTTP/2 on the listen line.
ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 0.0.0)"
if [[ "$(printf '%s\n1.25.1\n' "${ver}" | sort -V | head -1)" != "1.25.1" ]]; then
    echo "    nginx ${ver} predates 'http2 on' — moving HTTP/2 onto the listen line"
    sed -i \
        -e 's/^\( *\)http2 on;/\1# HTTP\/2 is enabled on the listen line (nginx < 1.25.1)/' \
        -e 's/^\( *\)listen \(\(\[::\]:\)\?443\) ssl;/\1listen \2 ssl http2;/' \
        "/etc/nginx/sites-available/${DOMAIN}"
fi

# nginx refuses to start with a `listen [::]` on a host that has no global
# IPv6 address, so drop those lines when IPv6 is unusable here.
if [[ -f /proc/net/if_inet6 ]] && command -v ip >/dev/null 2>&1 \
   && ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
    echo "    IPv6 detected, keeping the IPv6 listeners"
else
    echo "    no global IPv6 address — commenting out the IPv6 listeners"
    sed -i 's/^\( *\)listen \(\[::\]:[0-9]*.*\)$/\1# listen \2  # no IPv6 on this host/' \
        "/etc/nginx/sites-available/${DOMAIN}"
fi

ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
nginx -t
systemctl reload nginx

# certbot's packaged timer handles renewal; make sure nginx picks up new certs.
echo "==> wiring the renewal reload hook"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer 2>/dev/null || true

echo
echo "HTTPS is live. Verify:"
echo "  curl -sSI https://${DOMAIN}/ | head -1"
echo "  curl -sSI http://${DOMAIN}/  | head -2   # expect 301"
echo "  sudo certbot renew --dry-run"
