#!/usr/bin/env bash
# Regression tests for tipscoach-reports build.sh.
#
# Runs in an isolated temporary directory that mimics the repo structure.
# Never touches the real repo or its dist/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${BUILD_SCRIPT:-${REPO_ROOT}/scripts/build.sh}"

if [ ! -f "${BUILD_SCRIPT}" ]; then
    echo "ERROR: build.sh not found at ${BUILD_SCRIPT}" >&2
    exit 1
fi

PASSED=0
FAILED=0
TEST_COUNT=0

green()  { echo -e "\033[32m$*\033[0m"; }
red()    { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

run_test() {
    local name="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    echo ""
    yellow "--- Test ${TEST_COUNT}: ${name} ---"
    if "$@"; then
        green "  PASS: ${name}"
        PASSED=$((PASSED + 1))
    else
        red "  FAIL: ${name}"
        FAILED=$((FAILED + 1))
    fi
}

# ── Helper: create a minimal valid repo fixture ──────────────────────

create_fixture() {
    local dir="$1"
    mkdir -p "${dir}/_data"
    mkdir -p "${dir}/scripts"
    mkdir -p "${dir}/src"

    Rd="${dir}/rounds/topptipset-3999"
    mkdir -p "${Rd}/latest" "${Rd}/releases/r20260720T120000_000000" "${Rd}/versions/v001_20260720_1200"

    # Root files
    echo "<html>index</html>" > "${dir}/index.html"
    echo "User-agent: *"      > "${dir}/robots.txt"
    echo "/rounds/*
  X-Content-Type-Options: nosniff" > "${dir}/_headers"

    # _data
    echo '{"topptipset-3999":{"game":"topptipset"}}' > "${dir}/_data/rounds.json"

    Rd="${dir}/rounds/topptipset-3999"
    mkdir -p "${Rd}/latest" "${Rd}/releases/r20260720T120000_000000" "${Rd}/versions/v001_20260720_1200"

    # Round-root files (NO metadata.json at round root — only in releases/versions/latest)
    echo "<html>analysis</html>"  > "${Rd}/analysis.html"
    echo '{"ok":true}'            > "${Rd}/analysis.json"
    echo "<html>report</html>"    > "${Rd}/report.html"
    echo '{"ok":true}'            > "${Rd}/report.json"
    echo "<html>coupon</html>"    > "${Rd}/coupon.html"
    echo '{"ok":true}'            > "${Rd}/coupon.json"
    echo "1,2,X"                  > "${Rd}/system.txt"
    echo '{"ok":true}'            > "${Rd}/round_summary.json"
    echo "<html>index</html>"     > "${Rd}/index.html"

    # Release + version subdirectories — same as round root + metadata.json
    for subdir in "releases/r20260720T120000_000000" "versions/v001_20260720_1200"; do
        local sd="${Rd}/${subdir}"
        for fname in analysis.html analysis.json report.html report.json \
                     coupon.html coupon.json system.txt round_summary.json \
                     metadata.json index.html; do
            case "${fname}" in
                metadata.json) echo '{"release_id":"r2026"}' > "${sd}/${fname}" ;;
                system.txt)    echo "1,2,X" > "${sd}/${fname}" ;;
                *)             echo "<html>${fname}</html>" > "${sd}/${fname}" ;;
            esac
        done
    done

    # latest metadata
    echo '{"release_id":"r20260720T120000_000000"}' > "${dir}/rounds/topptipset-3999/latest/metadata.json"

    # Worker config (must NOT appear in dist)
    echo '{"name":"tipscoach-reports"}' > "${dir}/wrangler.jsonc"
    echo '{"private":true}'             > "${dir}/package.json"

    # Minimal worker
    echo "export default {}" > "${dir}/src/worker.js"

    # Copy build script into fixture (it reads REPO_ROOT from its own path)
    mkdir -p "${dir}/scripts"
    cp "${BUILD_SCRIPT}" "${dir}/scripts/build.sh"
    chmod +x "${dir}/scripts/build.sh"
}

# ══════════════════════════════════════════════════════════════════════
# Test 1 — normal build succeeds
# ══════════════════════════════════════════════════════════════════════

test_normal_build() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    cd "${tmp}"
    bash ./scripts/build.sh

    # Verify expected files exist
    test -f dist/index.html    || return 1
    test -f dist/_headers      || return 1
    test -f dist/robots.txt    || return 1
    test -f dist/_data/rounds.json || return 1

    # Verify forbidden files are absent
    test ! -e dist/package.json   || return 1
    test ! -e dist/wrangler.jsonc || return 1
    test ! -e dist/src            || return 1

    cd /
    rm -rf "${tmp}"
}
run_test "normal build succeeds" test_normal_build

# ══════════════════════════════════════════════════════════════════════
# Test 2 — symlinked round directory is rejected
# ══════════════════════════════════════════════════════════════════════

test_symlinked_round_dir() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    # Create external directory with a file
    local external
    external="$(mktemp -d)"
    echo "<html>external</html>" > "${external}/analysis.html"

    # Replace a round directory with a symlink to external
    rm -rf "${tmp}/rounds/topptipset-3999"
    ln -s "${external}" "${tmp}/rounds/symlinked-round"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        # Build must fail
        cd /; rm -rf "${tmp}" "${external}"; return 1
    fi

    # dist/ must not contain the external file
    if [ -d "${tmp}/dist" ] && [ -f "${tmp}/dist/rounds/symlinked-round/analysis.html" ]; then
        cd /; rm -rf "${tmp}" "${external}"; return 1
    fi

    cd /; rm -rf "${tmp}" "${external}"
}
run_test "symlinked round directory rejected" test_symlinked_round_dir

# ══════════════════════════════════════════════════════════════════════
# Test 3 — symlinked file in round directory is rejected
# ══════════════════════════════════════════════════════════════════════

test_symlinked_file() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    # Replace a file with a symlink
    local external_file="${tmp}/../external_analysis.html"
    echo "external" > "${external_file}"
    rm "${tmp}/rounds/topptipset-3999/analysis.html"
    ln -s "${external_file}" "${tmp}/rounds/topptipset-3999/analysis.html"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        rm -f "${external_file}"; cd /; rm -rf "${tmp}"; return 1
    fi

    rm -f "${external_file}"; cd /; rm -rf "${tmp}"
}
run_test "symlinked file in round dir rejected" test_symlinked_file

# ══════════════════════════════════════════════════════════════════════
# Test 4 — symlinked _data/rounds.json is rejected
# ══════════════════════════════════════════════════════════════════════

test_symlinked_data_file() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    local external_json="${tmp}/../external_rounds.json"
    echo '{}' > "${external_json}"
    rm "${tmp}/_data/rounds.json"
    ln -s "${external_json}" "${tmp}/_data/rounds.json"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        rm -f "${external_json}"; cd /; rm -rf "${tmp}"; return 1
    fi

    rm -f "${external_json}"; cd /; rm -rf "${tmp}"
}
run_test "symlinked _data/rounds.json rejected" test_symlinked_data_file

# ══════════════════════════════════════════════════════════════════════
# Test 5 — unauthorized file (debug.log) in round dir → fail
# ══════════════════════════════════════════════════════════════════════

test_unauthorized_file() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    echo "debug info" > "${tmp}/rounds/topptipset-3999/debug.log"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "unauthorized file (debug.log) rejected" test_unauthorized_file

# ══════════════════════════════════════════════════════════════════════
# Test 6 — extra file in _data/ fails
# ══════════════════════════════════════════════════════════════════════

test_extra_data_file() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    echo "secret" > "${tmp}/_data/secrets.json"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "extra file in _data/ rejected" test_extra_data_file

# ══════════════════════════════════════════════════════════════════════
# Test 7 — .env at root is rejected
# ══════════════════════════════════════════════════════════════════════

test_env_file_rejected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    echo "TOKEN=abc" > "${tmp}/.env"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test ".env at root rejected" test_env_file_rejected

# ══════════════════════════════════════════════════════════════════════
# Test 8 — build rejects arguments
# ══════════════════════════════════════════════════════════════════════

test_rejects_arguments() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    cd "${tmp}"
    if bash ./scripts/build.sh /tmp/somewhere 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "build rejects arguments" test_rejects_arguments

# ══════════════════════════════════════════════════════════════════════
# Test 9 — dist/ contains no forbidden files after successful build
# ══════════════════════════════════════════════════════════════════════

test_dist_forbidden_absent() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    cd "${tmp}"
    bash ./scripts/build.sh

    for forbidden in \
        "package.json" \
        "wrangler.jsonc" \
        "package-lock.json" \
        ".gitignore" \
        ".env" \
        "src/worker.js" \
        "scripts/build.sh" \
        "README.md"
    do
        if [ -e "dist/${forbidden}" ]; then
            cd /; rm -rf "${tmp}"; return 1
        fi
    done

    cd /; rm -rf "${tmp}"
}
run_test "dist/ contains no forbidden files" test_dist_forbidden_absent

# ══════════════════════════════════════════════════════════════════════
# Test 10 — integration: real repo build succeeds
# ══════════════════════════════════════════════════════════════════════

test_real_repo_build() {
    # Run in an isolated copy of the repo's publishable input — never touch
    # the real checkout.  The build script resolves REPO_ROOT from its own
    # path, so a full copy of the scripts/ directory makes it work.
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    # Mirror the real repo's publishable input + build infrastructure
    for item in scripts src index.html _headers robots.txt _data rounds 2026 \
                wrangler.jsonc package.json; do
        if [ -e "${REPO_ROOT}/${item}" ]; then
            cp -r "${REPO_ROOT}/${item}" "${tmp}/"
        fi
    done

    cd "${tmp}"
    bash ./scripts/build.sh

    # Verify critical artifacts present
    test -f dist/_headers           || return 1
    test -f dist/robots.txt         || return 1
    test -f dist/_data/rounds.json  || return 1

    # Legacy content if present
    if [ -d "${REPO_ROOT}/2026" ]; then
        test -d dist/2026 || return 1
    fi

    # Forbidden files absent
    test ! -e dist/package.json   || return 1
    test ! -e dist/wrangler.jsonc || return 1
    test ! -e dist/src            || return 1

    cd /
    rm -rf "${tmp}"
}
run_test "real repo build succeeds" test_real_repo_build

# ══════════════════════════════════════════════════════════════════════
# Test 11 — symlinked root file (index.html) rejected
# ══════════════════════════════════════════════════════════════════════

test_symlinked_root_file() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    local external="/tmp/ext_index_$$.html"
    echo "ext" > "${external}"
    rm "${tmp}/index.html"
    ln -s "${external}" "${tmp}/index.html"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        rm -f "${external}"; cd /; rm -rf "${tmp}"; return 1
    fi

    rm -f "${external}"; cd /; rm -rf "${tmp}"
}
run_test "symlinked root file rejected" test_symlinked_root_file

# ══════════════════════════════════════════════════════════════════════
# Test 12 — regular file where directory expected (rounds/id as file)
# ══════════════════════════════════════════════════════════════════════

test_file_instead_of_dir() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    # Replace a round directory with a regular file
    rm -rf "${tmp}/rounds/topptipset-3999"
    echo "not a dir" > "${tmp}/rounds/topptipset-3999"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "regular file where round dir expected rejected" test_file_instead_of_dir

# ══════════════════════════════════════════════════════════════════════
# Test 13 — file instead of latest/ directory
# ══════════════════════════════════════════════════════════════════════

test_file_instead_of_latest_dir() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    rm -rf "${tmp}/rounds/topptipset-3999/latest"
    echo "not a dir" > "${tmp}/rounds/topptipset-3999/latest"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "file instead of latest/ dir rejected" test_file_instead_of_latest_dir

# ══════════════════════════════════════════════════════════════════════
# Test 14 — extra _data file (.env) rejected
# ══════════════════════════════════════════════════════════════════════

test_dotfile_in_data_rejected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    echo "SECRET=xyz" > "${tmp}/_data/.env"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "dotfile in _data/ rejected" test_dotfile_in_data_rejected

# ══════════════════════════════════════════════════════════════════════
# Test 15 — unauthorized root file (.env at root) rejected (dup guard)
# ══════════════════════════════════════════════════════════════════════

# Already covered by Test 7 — skip duplicate.

# ══════════════════════════════════════════════════════════════════════
# Test 15 — dist.bak in fixture root is rejected
# ══════════════════════════════════════════════════════════════════════

test_dist_bak_rejected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    # dist.bak in repo root must fail
    mkdir -p "${tmp}/dist.bak"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "dist.bak in fixture root rejected" test_dist_bak_rejected

# ══════════════════════════════════════════════════════════════════════
# Test 16 — 2026/<id>/oavsiktlig.txt is rejected
# ══════════════════════════════════════════════════════════════════════

test_legacy_txt_rejected() {
    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" RETURN

    create_fixture "${tmp}"

    # Add legacy 2026/ directory
    mkdir -p "${tmp}/2026/01"
    echo "<html>legacy</html>" > "${tmp}/2026/01/report.html"

    # Add unauthorized .txt in legacy path
    echo "should not be here" > "${tmp}/2026/01/oavsiktlig.txt"

    cd "${tmp}"
    if bash ./scripts/build.sh 2>/dev/null; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    # dist/ must not contain the .txt file
    if [ -d "${tmp}/dist" ] && [ -f "${tmp}/dist/2026/01/oavsiktlig.txt" ]; then
        cd /; rm -rf "${tmp}"; return 1
    fi

    cd /; rm -rf "${tmp}"
}
run_test "2026/<id>/oavsiktlig.txt rejected" test_legacy_txt_rejected

# ══════════════════════════════════════════════════════════════════════

echo ""
echo "========================================"
echo "  Results: ${PASSED} passed, ${FAILED} failed (${TEST_COUNT} total)"
echo "========================================"

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
