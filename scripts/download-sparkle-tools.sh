#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

TOOLS_ROOT="${TOOLS_ROOT:-$PROJECT_ROOT/build/tools}"
INSTALL_ROOT="$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION"
BIN_DIR="$INSTALL_ROOT/bin"
ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$USHOT_SPARKLE_VERSION/Sparkle-$USHOT_SPARKLE_VERSION.tar.xz"

if [[ -x "$BIN_DIR/generate_appcast" \
      && -x "$BIN_DIR/generate_keys" \
      && -x "$BIN_DIR/sign_update" \
      && -f "$INSTALL_ROOT/.archive.sha256" \
      && "$(<"$INSTALL_ROOT/.archive.sha256")" == "$USHOT_SPARKLE_ARCHIVE_SHA256" ]]; then
  release_log "Using cached, checksum-pinned Sparkle $USHOT_SPARKLE_VERSION tools."
  printf '%s\n' "$BIN_DIR"
  exit 0
fi

release_require_command curl
release_require_command tar
release_require_command shasum
mkdir -p "$TOOLS_ROOT"
STAGING_DIR="$(mktemp -d "$TOOLS_ROOT/.Sparkle-$USHOT_SPARKLE_VERSION.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ARCHIVE_PATH="$STAGING_DIR/Sparkle-$USHOT_SPARKLE_VERSION.tar.xz"
release_log "Downloading Sparkle $USHOT_SPARKLE_VERSION tools from the official release."
curl --fail --silent --show-error --location \
  --proto '=https' \
  --tlsv1.2 \
  "$ARCHIVE_URL" \
  --output "$ARCHIVE_PATH"
ACTUAL_SHA256="$(release_sha256 "$ARCHIVE_PATH")"
[[ "$ACTUAL_SHA256" == "$USHOT_SPARKLE_ARCHIVE_SHA256" ]] \
  || release_die "Sparkle archive checksum mismatch: expected $USHOT_SPARKLE_ARCHIVE_SHA256, got $ACTUAL_SHA256"

tar -xf "$ARCHIVE_PATH" -C "$STAGING_DIR"
for tool in generate_appcast generate_keys sign_update; do
  [[ -x "$STAGING_DIR/bin/$tool" ]] || release_die "Sparkle archive is missing executable bin/$tool"
done
printf '%s' "$ACTUAL_SHA256" > "$STAGING_DIR/.archive.sha256"

if [[ -e "$INSTALL_ROOT" ]]; then
  rm -rf "$INSTALL_ROOT"
fi
mv "$STAGING_DIR" "$INSTALL_ROOT"
trap - EXIT

"$BIN_DIR/generate_appcast" --help >/dev/null
release_log "Installed checksum-pinned Sparkle tools: $BIN_DIR"
printf '%s\n' "$BIN_DIR"
