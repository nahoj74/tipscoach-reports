#!/usr/bin/env bash
# Build step for tipscoach-reports Cloudflare Workers Static Assets.
#
# Copies only the explicit public allowlist from the repo root into dist/.
# This ensures no internal files (.git, wrangler config, node_modules, src/)
# are ever served as static assets.
#
# Allowlist (exact paths — nothing else is copied):
#   index.html              — root listing
#   robots.txt              — crawler policy
#   _headers                — Cloudflare Static Assets HTTP headers
#   sitemap.xml             — optional, included if present
#   _data/rounds.json       — round registry consumed by root index
#   rounds/<id>/index.html  — per-round summary
#   rounds/<id>/analysis.html
#   rounds/<id>/analysis.json
#   rounds/<id>/report.html
#   rounds/<id>/report.json
#   rounds/<id>/coupon.html
#   rounds/<id>/coupon.json
#   rounds/<id>/system.txt
#   rounds/<id>/round_summary.json
#   rounds/<id>/metadata.json   (latest/metadata.json — already under rounds/)
#   rounds/<id>/releases/*      (release snapshots)
#   rounds/<id>/versions/*      (versioned artifacts)
#   rounds/<id>/agent_summary.html
#   rounds/<id>/agent_summary.json
#   rounds/<id>/journal.html
#   rounds/<id>/journal.json

set -euo pipefail

# ── Scope safety ────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

# Refuse to operate if called with an argument (no arbitrary output dir)
if [ $# -gt 0 ]; then
    echo "ERROR: build.sh takes no arguments. Output is always ${DIST_DIR}" >&2
    exit 1
fi

# Paranoid guards before rm -rf
if [ -z "${DIST_DIR}" ] || [ "${DIST_DIR}" = "/" ] || [ "${DIST_DIR}" = "${REPO_ROOT}" ]; then
    echo "ERROR: DIST_DIR resolved to unsafe path: ${DIST_DIR}" >&2
    exit 1
fi

echo "==> Cleaning ${DIST_DIR}/"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# ── Helper — copy single file, fail if it is a symlink ──────────────

copy_file() {
    local src="${REPO_ROOT}/${1}"
    local dst="${DIST_DIR}/${1}"

    if [ ! -e "${src}" ]; then
        echo "  - ${1} (missing, skipped)"
        return 0
    fi

    if [ -L "${src}" ]; then
        echo "ERROR: ${1} is a symlink — rejected" >&2
        exit 1
    fi

    if [ ! -f "${src}" ]; then
        echo "ERROR: ${1} is not a regular file — rejected" >&2
        exit 1
    fi

    mkdir -p "$(dirname "${dst}")"
    cp "${src}" "${dst}"
    echo "  ✓ ${1}"
}

# ── Copy allowlisted root-level files ───────────────────────────────

copy_file "index.html"
copy_file "robots.txt"
copy_file "_headers"
copy_file "sitemap.xml" || true  # optional
copy_file "_data/rounds.json"

# ── Copy allowlisted round artifacts ─────────────────────────────────

ROUNDS_DIR="${REPO_ROOT}/rounds"
if [ -d "${ROUNDS_DIR}" ]; then
    # Allowed file names within a round directory
    ALLOWED_NAMES=(
        index.html  analysis.html  analysis.json
        report.html  report.json
        coupon.html  coupon.json  system.txt
        round_summary.json
        agent_summary.html  agent_summary.json
        journal.html  journal.json
    )

    for round_dir in "${ROUNDS_DIR}"/*/; do
        round_id="$(basename "${round_dir}")"
        [ "${round_id}" = "*" ] && continue  # glob didn't match

        echo "  → rounds/${round_id}/"

        # Copy allowed top-level files
        for fname in "${ALLOWED_NAMES[@]}"; do
            local_src="${round_dir}${fname}"
            if [ -f "${local_src}" ]; then
                if [ -L "${local_src}" ]; then
                    echo "ERROR: rounds/${round_id}/${fname} is a symlink — rejected" >&2
                    exit 1
                fi
                copy_file "rounds/${round_id}/${fname}"
            fi
        done

        # Copy latest/ metadata
        if [ -f "${round_dir}latest/metadata.json" ]; then
            copy_file "rounds/${round_id}/latest/metadata.json"
        fi

        # Copy releases/ tree (recursive, but only known artifact names)
        if [ -d "${round_dir}releases" ]; then
            for release_dir in "${round_dir}releases"/*/; do
                [ ! -d "${release_dir}" ] && continue
                rel_id="$(basename "${release_dir}")"
                for fname in "${ALLOWED_NAMES[@]}" metadata.json; do
                    local_src="${release_dir}${fname}"
                    if [ -f "${local_src}" ]; then
                        if [ -L "${local_src}" ]; then
                            echo "ERROR: rounds/${round_id}/releases/${rel_id}/${fname} is a symlink — rejected" >&2
                            exit 1
                        fi
                        copy_file "rounds/${round_id}/releases/${rel_id}/${fname}"
                    fi
                done
            done
        fi

        # Copy versions/ tree
        if [ -d "${round_dir}versions" ]; then
            for ver_dir in "${round_dir}versions"/*/; do
                [ ! -d "${ver_dir}" ] && continue
                ver_id="$(basename "${ver_dir}")"
                for fname in "${ALLOWED_NAMES[@]}" metadata.json; do
                    local_src="${ver_dir}${fname}"
                    if [ -f "${local_src}" ]; then
                        if [ -L "${local_src}" ]; then
                            echo "ERROR: rounds/${round_id}/versions/${ver_id}/${fname} is a symlink — rejected" >&2
                            exit 1
                        fi
                        copy_file "rounds/${round_id}/versions/${ver_id}/${fname}"
                    fi
                done
            done
        fi
    done
fi

# ── Verify build output ─────────────────────────────────────────────

echo ""
echo "==> Verifying build output"

failures=0

check_exists() {
    if [ -f "${DIST_DIR}/${1}" ]; then
        echo "  ✓ ${1} present"
    else
        echo "  ✗ ${1} MISSING"
        failures=$((failures + 1))
    fi
}

check_absent() {
    if [ ! -e "${DIST_DIR}/${1}" ]; then
        echo "  ✓ ${1} absent (as expected)"
    else
        echo "  ✗ ${1} SHOULD NOT BE PRESENT"
        failures=$((failures + 1))
    fi
}

# Expected files (at least one round directory assumed if rounds/ exists)
check_exists "_headers"
check_exists "robots.txt"
check_exists "_data/rounds.json"

if [ -d "${ROUNDS_DIR}" ] && [ "$(ls -A "${ROUNDS_DIR}" 2>/dev/null)" ]; then
    check_exists "index.html"
fi

# Forbidden files — must never appear in dist/
for forbidden in \
    "wrangler.jsonc" \
    "package.json" \
    ".gitignore" \
    ".env" \
    "src/worker.js" \
    "scripts/build.sh"
do
    check_absent "${forbidden}"
done

# No .log, .md (except sitemap), or other suspicious files in dist/
while IFS= read -r -d '' f; do
    rel="${f#${DIST_DIR}/}"
    case "${rel}" in
        *.log)
            echo "  ✗ ${rel} — log files must not be published"
            failures=$((failures + 1))
            ;;
    esac
done < <(find "${DIST_DIR}" -type f -print0 2>/dev/null || true)

echo ""
file_count="$(find "${DIST_DIR}" -type f 2>/dev/null | wc -l)"
echo "==> Build complete: ${file_count} files in ${DIST_DIR}/"

if [ "${failures}" -gt 0 ]; then
    echo "ERROR: ${failures} verification failure(s)" >&2
    exit 1
fi
