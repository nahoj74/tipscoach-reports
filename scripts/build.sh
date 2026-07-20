#!/usr/bin/env bash
# Build step for tipscoach-reports Cloudflare Workers Static Assets.
#
# Copies only the explicit public allowlist from the repo root into dist/.
# This ensures no internal files (.git, wrangler config, node_modules, src/)
# are ever served as static assets.
#
# DESIGN: fail-closed, two-pass.
#   Pass 1 — scan the entire publishable input tree for symlinks and
#            unauthorized files.  Fail before touching anything.
#   Pass 2 — copy only authorized files into dist/.
#   Pass 3 — verify dist/ contains nothing forbidden.
#
# Allowlist (exact — nothing else is authorized):
#   Root files:
#     index.html  _headers  robots.txt  sitemap.xml(opt)
#   Legacy — explicit paths only:
#     2026/<subdir>/  — only .html files (no symlinks, no other file types)
#   _data/rounds.json  (only this one file under _data/)
#   rounds/<id>/  — only these plain files:
#     index.html  analysis.html  analysis.json
#     report.html  report.json
#     coupon.html  coupon.json  system.txt
#     round_summary.json  agent_summary.html  agent_summary.json
#     journal.html  journal.json
#   rounds/<id>/latest/metadata.json
#   rounds/<id>/releases/<rel>/  — same file set as round root + metadata.json
#   rounds/<id>/versions/<ver>/  — same file set as round root + metadata.json

set -euo pipefail

# ── Scope safety ────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

if [ $# -gt 0 ]; then
    echo "ERROR: build.sh takes no arguments. Output is always ${DIST_DIR}" >&2
    exit 1
fi

if [ -z "${DIST_DIR}" ] || [ "${DIST_DIR}" = "/" ] || [ "${DIST_DIR}" = "${REPO_ROOT}" ]; then
    echo "ERROR: DIST_DIR resolved to unsafe path: ${DIST_DIR}" >&2
    exit 1
fi

# ── Authorized file sets ─────────────────────────────────────────────

readonly -a ROOT_FILES=(index.html _headers robots.txt sitemap.xml)
readonly -a ROUND_FILES=(
    index.html  analysis.html  analysis.json
    report.html  report.json
    coupon.html  coupon.json  system.txt
    round_summary.json
    agent_summary.html  agent_summary.json
    journal.html  journal.json
)
# Release / version directories allow round files + metadata.json
readonly -a RELEASE_FILES=(
    "${ROUND_FILES[@]}"  metadata.json
)

# ── Helper: check if value is in a bash array ────────────────────────

_in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "${item}" = "${needle}" ] && return 0
    done
    return 1
}

# ── Pass 0 — pre-scan for symlinks EVERYWHERE reachable ──────────────

echo "==> Pass 0: scanning for symlinks"

SYMLINK_COUNT=0
scan_symlinks() {
    local scan_root="$1"
    if [ ! -e "${scan_root}" ]; then
        return 0
    fi
    # Use find -P (physical, never follow symlinks) + -type l
    while IFS= read -r -d '' symlink_path; do
        local rel="${symlink_path#${REPO_ROOT}/}"
        echo "  ✗ symlink: ${rel}"
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
    done < <(find -P "${scan_root}" -type l -print0 2>/dev/null || true)
}

scan_symlinks "${REPO_ROOT}/_data"
scan_symlinks "${REPO_ROOT}/rounds"
scan_symlinks "${REPO_ROOT}/2026"

# Also check if the top-level directories themselves are symlinks
for top_dir in _data rounds 2026; do
    if [ -L "${REPO_ROOT}/${top_dir}" ]; then
        echo "  ✗ ${top_dir}/ is a symlink — rejected"
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
    fi
done

# Check root-level publishable files for symlinks
for root_file in "${ROOT_FILES[@]}"; do
    local_f="${REPO_ROOT}/${root_file}"
    if [ -L "${local_f}" ]; then
        echo "  ✗ symlink: ${root_file} (root file)"
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
    fi
done

if [ "${SYMLINK_COUNT}" -gt 0 ]; then
    echo ""
    echo "ERROR: ${SYMLINK_COUNT} symlink(s) found in publishable input tree." >&2
    echo "Symlinks are not allowed.  Remove them before building." >&2
    exit 1
fi

echo "  ✓ no symlinks found"

# ── Pass 1 — validate all files in publishable input tree ────────────

echo ""
echo "==> Pass 1: validating input files"

FAILURES=0

# --- Dotfile guard: flag any dotfile/dotdir in publishable root areas ---
_dotfile_guard() {
    local scan_root="$1"
    local label="$2"
    if [ ! -d "${scan_root}" ]; then
        return 0
    fi
    # find dotfiles (but NOT . or ..)
    while IFS= read -r -d '' dotpath; do
        local rel="${dotpath#${REPO_ROOT}/}"
        echo "  ✗ ${rel} — dotfiles are not allowed in publishable tree"
        FAILURES=$((FAILURES + 1))
    done < <(find -P "${scan_root}" -maxdepth 1 -name '.*' -not -name '.' -not -name '..' -print0 2>/dev/null || true)
}

_dotfile_guard "${REPO_ROOT}/_data" "_data"
_dotfile_guard "${REPO_ROOT}/rounds" "rounds"

# Dotfiles at repo root that are NOT explicitly whitelisted infrastructure
for entry in "${REPO_ROOT}"/.*; do
    [ -e "${entry}" ] || continue
    fname="$(basename "${entry}")"
    # Infrastructure dotfiles that ARE allowed to exist (but not in dist/)
    case "${fname}" in
        .git|.gitignore|.wrangler|.node-version|.npmrc|.nvmrc)
            continue
            ;;
    esac
    rel="${entry#${REPO_ROOT}/}"
    echo "  ✗ ${rel} — unauthorized dotfile at repo root"
    FAILURES=$((FAILURES + 1))
done

validate_round_dir() {
    local dir="$1"
    local label="$2"
    local -n allowed_names_ref="$3"

    if [ ! -d "${dir}" ]; then
        return 0
    fi

    for entry in "${dir}"/*; do
        [ -e "${entry}" ] || continue

        local fname
        fname="$(basename "${entry}")"
        local rel
        rel="${entry#${REPO_ROOT}/}"

        # Skip known subdirectories
        case "${fname}" in
            latest|releases|versions)
                continue
                ;;
        esac

        if [ -f "${entry}" ]; then
            if _in_array "${fname}" "${allowed_names_ref[@]}"; then
                echo "  ✓ ${rel}"
            else
                echo "  ✗ ${rel} — NOT in allowlist"
                FAILURES=$((FAILURES + 1))
            fi
        elif [ -d "${entry}" ]; then
            echo "  ✗ ${rel} — unexpected subdirectory (only latest/releases/versions allowed)"
            FAILURES=$((FAILURES + 1))
        else
            echo "  ✗ ${rel} — not a regular file"
            FAILURES=$((FAILURES + 1))
        fi
    done
}

# Validate _data/ directory
if [ -d "${REPO_ROOT}/_data" ]; then
    echo "  → _data/"
    for entry in "${REPO_ROOT}/_data"/*; do
        [ -e "${entry}" ] || continue
        fname="$(basename "${entry}")"
        rel="${entry#${REPO_ROOT}/}"

        if [ "${fname}" = "rounds.json" ] && [ -f "${entry}" ]; then
            echo "    ✓ ${rel}"
        else
            echo "    ✗ ${rel} — only _data/rounds.json is authorized"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# Validate root-level files
echo "  → (root)"
for entry in "${REPO_ROOT}"/*; do
    [ -e "${entry}" ] || continue
    fname="$(basename "${entry}")"
    rel="${entry#${REPO_ROOT}/}"

    # Skip known non-publishable top-level items
    case "${fname}" in
        _data|rounds|2026|src|scripts|node_modules|.git|.gitignore|.wrangler|dist|package.json|package-lock.json|wrangler.jsonc|README.md|*.log)
            continue
            ;;
    esac

    if [ -f "${entry}" ]; then
        if _in_array "${fname}" "${ROOT_FILES[@]}"; then
            echo "  ✓ ${rel}"
        else
            echo "  ✗ ${rel} — NOT in root allowlist"
            FAILURES=$((FAILURES + 1))
        fi
    elif [ -d "${entry}" ]; then
        # Only known directories are allowed
        case "${fname}" in
            _data|rounds|src|scripts|node_modules|.git|.wrangler|dist)
                ;;
            *)
                echo "  ✗ ${rel} — unexpected directory at root"
                FAILURES=$((FAILURES + 1))
                ;;
        esac
    fi
done

# Validate rounds/
if [ -d "${REPO_ROOT}/rounds" ]; then
    echo "  → rounds/"
    for round_dir in "${REPO_ROOT}/rounds"/*/; do
        [ -d "${round_dir}" ] || continue
        round_id="$(basename "${round_dir}")"

        # Validate top-level round files
        validate_round_dir "${round_dir}" "rounds/${round_id}" ROUND_FILES

        # Validate latest/
        if [ -e "${round_dir}latest" ]; then
            if [ -f "${round_dir}latest/metadata.json" ]; then
                echo "    ✓ rounds/${round_id}/latest/metadata.json"
            fi
            # Any other file in latest/ is unauthorized
            for entry in "${round_dir}latest"/*; do
                [ -e "${entry}" ] || continue
                fname="$(basename "${entry}")"
                if [ "${fname}" != "metadata.json" ]; then
                    echo "    ✗ rounds/${round_id}/latest/${fname} — only metadata.json allowed in latest/"
                    FAILURES=$((FAILURES + 1))
                fi
            done
        fi

        # Validate releases/
        if [ -d "${round_dir}releases" ]; then
            for rel_dir in "${round_dir}releases"/*/; do
                [ -d "${rel_dir}" ] || continue
                rel_id="$(basename "${rel_dir}")"
                validate_round_dir "${rel_dir}" "rounds/${round_id}/releases/${rel_id}" RELEASE_FILES
            done
        fi

        # Validate versions/
        if [ -d "${round_dir}versions" ]; then
            for ver_dir in "${round_dir}versions"/*/; do
                [ -d "${ver_dir}" ] || continue
                ver_id="$(basename "${ver_dir}")"
                validate_round_dir "${ver_dir}" "rounds/${round_id}/versions/${ver_id}" RELEASE_FILES
            done
        fi
    done
fi

# ── Legacy 2026/ — explicit precise allowlist ──────────────────────

if [ -d "${REPO_ROOT}/2026" ]; then
    echo "  → 2026/ (legacy)"
    for year_dir in "${REPO_ROOT}/2026"/*/; do
        [ -d "${year_dir}" ] || continue
        year_id="$(basename "${year_dir}")"
        for legacy_file in "${year_dir}"*.html; do
            [ -e "${legacy_file}" ] || continue
            fname="$(basename "${legacy_file}")"
            rel="${legacy_file#${REPO_ROOT}/}"
            if [ -f "${legacy_file}" ]; then
                case "${fname}" in
                    *.html) echo "    ✓ ${rel}" ;;
                    *)      echo "    ✗ ${rel} — only .html files allowed in 2026/"
                            FAILURES=$((FAILURES + 1)) ;;
                esac
            elif [ -L "${legacy_file}" ]; then
                echo "    ✗ ${rel} — symlinks not allowed in 2026/"
                FAILURES=$((FAILURES + 1))
            elif [ -d "${legacy_file}" ]; then
                echo "    ✗ ${rel} — subdirectories not allowed in 2026/<id>/ (only .html files)"
                FAILURES=$((FAILURES + 1))
            else
                echo "    ✗ ${rel} — not a regular file"
                FAILURES=$((FAILURES + 1))
            fi
        done
    done
fi

# ── Directory-type guards: ensure key paths are directories, not files ──

_dir_must_be_dir() {
    local path="$1"
    local label="$2"
    if [ -e "${path}" ] && [ ! -d "${path}" ]; then
        echo "  ✗ ${label} — exists but is not a directory"
        FAILURES=$((FAILURES + 1))
    fi
}

_dir_must_be_dir "${REPO_ROOT}/rounds" "rounds/"
_dir_must_be_dir "${REPO_ROOT}/_data" "_data/"
_dir_must_be_dir "${REPO_ROOT}/2026" "2026/"

# Guard: every entry in 2026/ MUST be a directory
if [ -d "${REPO_ROOT}/2026" ]; then
    for entry in "${REPO_ROOT}/2026"/*; do
        [ -e "${entry}" ] || continue
        fname="$(basename "${entry}")"
        rel="${entry#${REPO_ROOT}/}"
        if [ ! -d "${entry}" ]; then
            echo "  ✗ ${rel} — 2026/<id> must be a directory"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# Guard: every entry in rounds/ MUST be a directory
if [ -d "${REPO_ROOT}/rounds" ]; then
    for entry in "${REPO_ROOT}/rounds"/*; do
        [ -e "${entry}" ] || continue
        fname="$(basename "${entry}")"
        rel="${entry#${REPO_ROOT}/}"
        if [ ! -d "${entry}" ]; then
            echo "  ✗ ${rel} — round-id must be a directory, not a $(file -b "${entry}")"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# For each round, check latest/releases/versions are dirs if they exist
if [ -d "${REPO_ROOT}/rounds" ]; then
    for round_dir in "${REPO_ROOT}/rounds"/*/; do
        [ -d "${round_dir}" ] || continue
        round_id="$(basename "${round_dir}")"
        _dir_must_be_dir "${round_dir}latest" "rounds/${round_id}/latest"
        _dir_must_be_dir "${round_dir}releases" "rounds/${round_id}/releases"
        _dir_must_be_dir "${round_dir}versions" "rounds/${round_id}/versions"
    done
fi

if [ "${FAILURES}" -gt 0 ]; then
    echo ""
    echo "ERROR: ${FAILURES} unauthorized file(s) found in publishable input tree." >&2
    echo "Only files in the explicit allowlist may be published." >&2
    exit 1
fi

echo "  ✓ all input files authorized"

# ── Pass 2 — clean and copy ──────────────────────────────────────────

echo ""
echo "==> Pass 2: cleaning and copying"

echo "  → removing ${DIST_DIR}/"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

copy_file() {
    local rel="$1"
    local src="${REPO_ROOT}/${rel}"
    local dst="${DIST_DIR}/${rel}"

    if [ ! -f "${src}" ]; then
        return 0  # optional file, skip silently
    fi
    mkdir -p "$(dirname "${dst}")"
    cp "${src}" "${dst}"
    echo "  ✓ ${rel}"
}

# Root files
for fname in "${ROOT_FILES[@]}"; do
    copy_file "${fname}"
done

# Legacy 2026/ — only .html files in explicit subdirectories
if [ -d "${REPO_ROOT}/2026" ]; then
    for year_dir in "${REPO_ROOT}/2026"/*/; do
        [ -d "${year_dir}" ] || continue
        for legacy_file in "${year_dir}"*.html; do
            [ -f "${legacy_file}" ] || continue
            rel="${legacy_file#${REPO_ROOT}/}"
            copy_file "${rel}"
        done
    done
fi

# _data/rounds.json
copy_file "_data/rounds.json"

# Rounds
if [ -d "${REPO_ROOT}/rounds" ]; then
    for round_dir in "${REPO_ROOT}/rounds"/*/; do
        [ -d "${round_dir}" ] || continue
        round_id="$(basename "${round_dir}")"

        for fname in "${ROUND_FILES[@]}"; do
            copy_file "rounds/${round_id}/${fname}"
        done

        # latest/
        copy_file "rounds/${round_id}/latest/metadata.json"

        # releases/
        if [ -d "${round_dir}releases" ]; then
            for rel_dir in "${round_dir}releases"/*/; do
                [ -d "${rel_dir}" ] || continue
                rel_id="$(basename "${rel_dir}")"
                for fname in "${RELEASE_FILES[@]}"; do
                    copy_file "rounds/${round_id}/releases/${rel_id}/${fname}"
                done
            done
        fi

        # versions/
        if [ -d "${round_dir}versions" ]; then
            for ver_dir in "${round_dir}versions"/*/; do
                [ -d "${ver_dir}" ] || continue
                ver_id="$(basename "${ver_dir}")"
                for fname in "${RELEASE_FILES[@]}"; do
                    copy_file "rounds/${round_id}/versions/${ver_id}/${fname}"
                done
            done
        fi
    done
fi

# ── Pass 3 — verify dist/ contents ───────────────────────────────────

echo ""
echo "==> Pass 3: verifying dist/"

DIST_FAILURES=0

check_exists() {
    if [ -f "${DIST_DIR}/${1}" ]; then
        echo "  ✓ ${1} present"
    else
        echo "  ✗ ${1} MISSING"
        DIST_FAILURES=$((DIST_FAILURES + 1))
    fi
}

check_absent() {
    if [ ! -e "${DIST_DIR}/${1}" ]; then
        echo "  ✓ ${1} absent (as expected)"
    else
        echo "  ✗ ${1} SHOULD NOT BE PRESENT"
        DIST_FAILURES=$((DIST_FAILURES + 1))
    fi
}

check_exists "_headers"
check_exists "robots.txt"

# Forbidden — must never appear in dist/
for forbidden in \
    "wrangler.jsonc" \
    "package.json" \
    "package-lock.json" \
    ".gitignore" \
    ".env" \
    "src/worker.js" \
    "scripts/build.sh" \
    "README.md"
do
    check_absent "${forbidden}"
done

# No unauthorized files in dist/
while IFS= read -r -d '' f; do
    rel="${f#${DIST_DIR}/}"
    case "${rel}" in
        *.log|*.md)
            echo "  ✗ ${rel} — forbidden file type in dist/"
            DIST_FAILURES=$((DIST_FAILURES + 1))
            ;;
    esac
done < <(find "${DIST_DIR}" -type f -print0 2>/dev/null || true)

# No directories other than the authorized ones
while IFS= read -r -d '' d; do
    rel="${d#${DIST_DIR}/}"
    # Strip trailing slash
    rel="${rel%/}"
    case "${rel}" in
        _data|rounds|rounds/*|rounds/*/latest|rounds/*/releases|rounds/*/releases/*|rounds/*/versions|rounds/*/versions/*|2026|2026/*)
            ;;  # authorized
        *)
            echo "  ✗ ${rel}/ — unexpected directory in dist/"
            DIST_FAILURES=$((DIST_FAILURES + 1))
            ;;
    esac
done < <(find "${DIST_DIR}" -type d -not -path "${DIST_DIR}" -print0 2>/dev/null || true)

echo ""
file_count="$(find "${DIST_DIR}" -type f 2>/dev/null | wc -l)"
echo "==> Build complete: ${file_count} files in ${DIST_DIR}/"

if [ "${DIST_FAILURES}" -gt 0 ]; then
    echo "ERROR: ${DIST_FAILURES} verification failure(s)" >&2
    exit 1
fi
