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

for tool in ssh rsync; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "${tool} is not installed — see deploy/README.md for what this machine needs" >&2
        exit 1
    fi
done
if ! command -v jekyll >/dev/null 2>&1 && ! command -v bundle >/dev/null 2>&1; then
    echo "neither jekyll nor bundle found — install Ruby and Jekyll first" >&2
    echo "  macOS: brew install ruby && gem install jekyll bundler" >&2
    exit 1
fi

echo "==> building the site"
# A template, not a bare -d: BSD/macOS mktemp rejects -d on its own.
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/patpatpatrick-build.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
# Prefer bundler when the project is set up for it, since it pins gem
# versions. Gemfile.lock is required for that branch: without it `bundle exec`
# goes off to resolve dependencies over the network and can hang for minutes.
build_site() {
    if [[ -f Gemfile.lock ]] && command -v bundle >/dev/null 2>&1; then
        bundle exec jekyll build --destination "${BUILD_DIR}"
    else
        jekyll build --destination "${BUILD_DIR}"
    fi
}
if ! build_site; then
    echo >&2
    echo "the build failed. If the error above mentions missing gems, run:" >&2
    echo "  bundle install" >&2
    exit 1
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

# macOS 15 replaced rsync with openrsync, which has no --link-dest. Without it
# a release is a full copy instead of hardlinks against the live one — more
# disk, same result — so degrade rather than fail.
LINK_DEST=()
if rsync --help 2>&1 | grep -q -- "--link-dest"; then
    LINK_DEST=(--link-dest="${WEBROOT}/current/")
else
    echo "    note: this rsync has no --link-dest; the release will be a full copy"
fi
if [[ -n ${DRY_RUN:-} ]]; then
    echo "==> DRY RUN against the live release (nothing is written)"
    rsync "${RSYNC_OPTS[@]}" --dry-run --itemize-changes \
        "${BUILD_DIR}/" "${SSH_HOST}:${WEBROOT}/current/"
    exit 0
fi

echo "==> uploading release ${RELEASE} to ${SSH_HOST}"
ssh "${SSH_HOST}" "mkdir -p '${WEBROOT}/releases/${RELEASE}'"
rsync "${RSYNC_OPTS[@]}" "${LINK_DEST[@]+"${LINK_DEST[@]}"}" \
    "${BUILD_DIR}/" "${SSH_HOST}:${WEBROOT}/releases/${RELEASE}/"

echo "==> activating ${RELEASE}"
# A quoted heredoc: the remote script is sent verbatim and values arrive as
# positional parameters. With an unquoted one the local shell would expand
# everything first, down to backticks inside comments.
ssh "${SSH_HOST}" "bash -s -- '${WEBROOT}' '${RELEASE}' '${KEEP_RELEASES}'" <<'REMOTE'
set -euo pipefail
webroot="$1"; release="$2"; keep="$3"

cd "$webroot"
test -s "releases/$release/index.html"

# The swap below replaces a symlink; refuse if someone made it a real directory.
if [[ -e current && ! -L current ]]; then
    echo "$webroot/current is not a symlink - refusing to replace it" >&2
    exit 1
fi

# ln -sfn unlinks before it symlinks, leaving a window with no current at all;
# rename(2) via mv -T swaps in one step.
ln -sfn "$webroot/releases/$release" current.new
mv -Tf current.new current

# Prune old releases, keeping the newest $keep plus whatever current points at.
live="$(basename "$(readlink -f current)")"
ls -1 releases | sort -r | tail -n +$(( keep + 1 )) | while read -r old; do
    # An explicit if, not a short-circuit: under set -e the && form makes the
    # loop body exit non-zero on every release that is kept.
    if [[ "$old" != "$live" ]]; then
        rm -rf "releases/$old"
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
