#!/usr/bin/env bash
# Step 2 of 3 — run this from a machine that can SSH to the VPS (your laptop).
#
# Builds the Jekyll site locally and ships it to the VPS as a new release,
# then flips the `current` symlink in one rename(2). nginx needs no reload and
# no visitor ever sees a half-copied site.
#
#   ./deploy/deploy.sh                 # build and deploy
#   SSH_HOST=arm-vps ./deploy/deploy.sh
#   DRY_RUN=1 ./deploy/deploy.sh       # show what would change, send nothing
set -euo pipefail

SSH_HOST="${SSH_HOST:-arm-vps}"
DOMAIN="${DOMAIN:-patpatpatrick.com}"
WEBROOT="${WEBROOT:-/var/www/${DOMAIN}}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> building the site"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
if command -v bundle >/dev/null 2>&1 && [[ -f Gemfile.lock ]]; then
    bundle exec jekyll build --destination "${BUILD_DIR}"
else
    jekyll build --destination "${BUILD_DIR}"
fi

# CNAME only means something to GitHub Pages, and README.md is the upstream
# theme's documentation — neither belongs on the live server.
rm -f "${BUILD_DIR}/CNAME" "${BUILD_DIR}/README.md"

pages="$(find "${BUILD_DIR}" -name '*.html' | wc -l | tr -d ' ')"
if [[ ! -s "${BUILD_DIR}/index.html" || ${pages} -lt 2 ]]; then
    echo "build looks wrong (${pages} html files, index.html empty or missing) — not deploying" >&2
    exit 1
fi
echo "    ${pages} pages, $(du -sh "${BUILD_DIR}" | cut -f1)"

RELEASE="$(date -u +%Y%m%d-%H%M%S)"
RSYNC_OPTS=(-az --delete --human-readable)
if [[ -n ${DRY_RUN:-} ]]; then
    echo "==> DRY RUN against the live release (nothing is written)"
    rsync "${RSYNC_OPTS[@]}" --dry-run --itemize-changes \
        "${BUILD_DIR}/" "${SSH_HOST}:${WEBROOT}/current/"
    exit 0
fi

echo "==> uploading release ${RELEASE} to ${SSH_HOST}"
ssh "${SSH_HOST}" "mkdir -p '${WEBROOT}/releases/${RELEASE}'"
# --link-dest hardlinks the unchanged files against the live release, so each
# deploy costs only what actually changed.
rsync "${RSYNC_OPTS[@]}" \
    --link-dest="${WEBROOT}/current/" \
    "${BUILD_DIR}/" "${SSH_HOST}:${WEBROOT}/releases/${RELEASE}/"

echo "==> activating ${RELEASE}"
ssh "${SSH_HOST}" bash -s <<REMOTE
set -euo pipefail
cd '${WEBROOT}'
test -s "releases/${RELEASE}/index.html"
# The swap below relies on `current` being a symlink, not a real directory.
if [[ -e current && ! -L current ]]; then
    echo "${WEBROOT}/current is not a symlink — refusing to replace it" >&2
    exit 1
fi
# ln -sfn unlinks before it symlinks; rename(2) via mv -T swaps in one step.
ln -sfn "${WEBROOT}/releases/${RELEASE}" current.new
mv -Tf current.new current
# Prune old releases, keeping the newest ${KEEP_RELEASES} plus whatever
# `current` points at.
live="\$(basename "\$(readlink -f current)")"
ls -1 releases | sort -r | tail -n +\$(( ${KEEP_RELEASES} + 1 )) | while read -r old; do
    # An explicit if, not `[[ ]] && continue`: under set -e the short-circuit
    # form makes the loop body exit non-zero on every kept release.
    if [[ "\$old" != "\$live" ]]; then
        rm -rf "releases/\$old"
    fi
done
REMOTE

echo
echo "==> deployed. verifying"
if ssh "${SSH_HOST}" "curl -fsS -o /dev/null -w '%{http_code}' -H 'Host: ${DOMAIN}' http://127.0.0.1/" 2>/dev/null | grep -qE '^(200|301)$'; then
    echo "    nginx serves the new release"
else
    echo "    could not verify locally on the VPS — check: ssh ${SSH_HOST} 'tail /var/log/nginx/${DOMAIN%%.*}.error.log'" >&2
fi
echo "    https://${DOMAIN}/"
