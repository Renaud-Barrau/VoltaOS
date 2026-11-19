#!/bin/bash
# CI build and checks (used by .github/workflows/ci.yml, also runnable by hand).
#
#   QT_PREFIX=~/Qt/6.11.1/gcc_64 bash scripts/ci_build.sh [build|aa-test|smoke|qmllint|all]
#
# Expects the system packages listed in .github/workflows/ci.yml (Debian 13) and Qt in $QT_PREFIX.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

QT_PREFIX="${QT_PREFIX:-$HOME/Qt/6.11.1/gcc_64}"
BUILD_DIR="${BUILD_DIR:-build/ci}"
STEP="${1:-all}"
[ -d "$QT_PREFIX/lib/cmake/Qt6" ] || { echo "Qt not found in $QT_PREFIX (set QT_PREFIX)" >&2; exit 1; }

group()    { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

do_build() {
    group "Configure"
    cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_PREFIX"
    endgroup
    group "Build"
    cmake --build "$BUILD_DIR" -j"$(nproc)"
    endgroup
}

# Android Auto client self-test against a fake phone. Both sides use a throwaway self-signed pair:
# the test checks the protocol, not Google's certificate.
do_aa_test() {
    local d="$BUILD_DIR/aa-test"
    group "Android Auto self-test"
    cmake -S tests/androidauto -B "$d" -G Ninja -DCMAKE_PREFIX_PATH="$QT_PREFIX"
    cmake --build "$d" -j"$(nproc)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=volta-ci" \
        -keyout "$d/test.key" -out "$d/test.crt" 2>/dev/null
    QT_QPA_PLATFORM=offscreen "$d/aa_fake_phone_test" "$d/test.crt" "$d/test.key"
    endgroup
}

# Starts the UI headless for a few seconds and fails on QML load errors or if the map libraries do not load.
# Python services and the network are not needed: they may log errors, which are ignored here.
do_smoke() {
    local log="$BUILD_DIR/smoke.log" bin="$BUILD_DIR/VoltaOS"
    group "Headless smoke test"
    set +e
    QT_QPA_PLATFORM=offscreen QTWEBENGINE_DISABLE_SANDBOX=1 VOLTA_DIR="$PWD" \
        timeout -s INT 25 "$bin" >"$log" 2>&1
    set -e
    endgroup
    local errors
    errors=$(grep -E '\[maplibre\] library not loaded|qrc:/.*(TypeError|ReferenceError|is not a type|is not installed|Non-existent|failed to load|Cannot assign|Unable to assign)' "$log" || true)
    if ! grep -q 'FIRST FRAME' "$log"; then
        echo "::error::the UI did not render its first frame"; tail -n 80 "$log"; exit 1
    fi
    if [ -n "$errors" ]; then
        echo "::error::QML errors during startup"; echo "$errors"; exit 1
    fi
    echo "first frame rendered, no QML load errors"
}

# Qt's static QML checker. Report only for now: the existing code base has not been cleaned up for it.
do_qmllint() {
    local log="$BUILD_DIR/qmllint.log"
    group "qmllint (report only)"
    cmake --build "$BUILD_DIR" --target all_qmllint >"$log" 2>&1 || true
    cat "$log"
    endgroup
    echo "::warning::qmllint: $(grep -c 'Warning:' "$log" || true) warnings (report only, see the qmllint group)"
}

case "$STEP" in
    build)   do_build ;;
    aa-test) do_aa_test ;;
    smoke)   do_smoke ;;
    qmllint) do_qmllint ;;
    all)     do_build; do_aa_test; do_smoke; do_qmllint ;;
    *) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
