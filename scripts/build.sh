#!/usr/bin/env bash
# Build step for tipscoach-reports Cloudflare Workers Static Assets.
#
# Copies only the explicit public allowlist from the repo root into dist/.
# This ensures no internal files (.git, wrangler config, node_modules, src/)
# are ever served as static assets.
#
# Allowlist:
#   index.html          — root listing
#   rounds/             — all per-round artifacts
#   _data/rounds.json   — round registry consumed by root index
#   robots.txt          — crawler policy
#   _headers            — Cloudflare Static Assets HTTP headers
#   sitemap.xml         — optional, included if present

set -euo pipefail

DIST_DIR="${1:-dist}"
SRC_ROOT="${2:-.}"

echo "==> Cleaning ${DIST_DIR}/"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# ── Copy allowlisted files ──────────────────────────────────────────

copy_if_exists() {
    local src="${SRC_ROOT}/${1}"
    local dst="${DIST_DIR}/${1}"
    if [ -e "${src}" ]; then
        mkdir -p "$(dirname "${dst}")"
        cp -r "${src}" "${dst}"
        echo "  ✓ ${1}"
    else
        echo "  - ${1} (missing, skipped)"
    fi
}

copy_if_exists "index.html"
copy_if_exists "rounds"
copy_if_exists "_data"
copy_if_exists "robots.txt"
copy_if_exists "_headers"
copy_if_exists "sitemap.xml"

echo "==> Build complete: $(find "${DIST_DIR}" -type f | wc -l) files in ${DIST_DIR}/"
