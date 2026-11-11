#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export LAMBDA_WREQ_OUT_DIR="$TEMP/out"
export LAMBDA_WREQ_ARCH=arm64
export LAMBDA_WREQ_NATIVE=""
source "$ROOT/lib/common.sh"
PKG="$TEMP/package"
ASSET=wreq-js.linux-arm64-gnu.node
mkdir -p "$PKG/rust" "$OUT_DIR/native/3.2.0" "$OUT_DIR/native/latest"
printf bundled > "$PKG/rust/$ASSET"
printf stale > "$OUT_DIR/native/latest/$ASSET"
printf cached > "$OUT_DIR/native/3.2.0/$ASSET"
[[ "$(ensure_native_binary "$PKG" 3.2.0)" == "$PKG/rust/$ASSET" ]]
rm "$PKG/rust/$ASSET"
[[ "$(ensure_native_binary "$PKG" 3.2.0)" == "$OUT_DIR/native/3.2.0/$ASSET" ]]
rm "$OUT_DIR/native/3.2.0/$ASSET"
# Missing exact-version assets must fail, never use the unversioned cache or latest.
curl() {
  [[ "$*" == *'/download/v3.2.0/'* ]] || exit 90
  return 22
}
if (ensure_native_binary "$PKG" 3.2.0); then
  echo 'Unexpected native fallback' >&2
  exit 1
fi
[[ ! -e "$OUT_DIR/native/3.2.0/$ASSET" ]]
echo 'native: bundled priority, exact-version cache and failed-download checks passed'
