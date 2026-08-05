#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

OUTPUT_PATH=""

usage() {
  printf '%s\n' "usage: $0 --output /absolute/path/Ushot-Sparkle-key.backup.enc"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_PATH="${2:?--output requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$OUTPUT_PATH" ]] || { usage >&2; exit 1; }
[[ "$OUTPUT_PATH" == /* ]] \
  || release_die "Backup output must be an absolute path outside the repository."

OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
  || release_die "Backup parent must be an existing real directory: $OUTPUT_PARENT"
CANONICAL_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
CANONICAL_OUTPUT="$CANONICAL_PARENT/$(basename "$OUTPUT_PATH")"
case "$CANONICAL_OUTPUT" in
  "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
    release_die "Refusing to place an encrypted signing-key backup inside the source repository."
    ;;
esac
[[ ! -e "$CANONICAL_OUTPUT" && ! -L "$CANONICAL_OUTPUT" ]] \
  || release_die "Backup output already exists; refusing to overwrite it: $CANONICAL_OUTPUT"

release_require_command openssl
release_require_command shasum
SPARKLE_BIN="$($SCRIPT_DIR/download-sparkle-tools.sh | tail -n 1)"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
[[ -x "$GENERATE_KEYS" ]] \
  || release_die "Sparkle generate_keys is unavailable: $GENERATE_KEYS"
[[ -x "$SCRIPT_DIR/derive-sparkle-public-key.swift" ]] \
  || release_die "Sparkle public-key derivation helper is unavailable."

umask 077
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-sparkle-key-backup.XXXXXX")"
PLAINTEXT_KEY="$WORKSPACE/private-key.txt"
ENCRYPTED_BACKUP="$WORKSPACE/private-key.backup.enc"
RECOVERY_CHECK="$WORKSPACE/recovered-private-key.txt"
cleanup() {
  rm -rf "$WORKSPACE"
}
trap cleanup EXIT

release_log "Requesting access to the existing Sparkle key in the macOS login Keychain."
"$GENERATE_KEYS" \
  --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
  -x "$PLAINTEXT_KEY"

DERIVED_PUBLIC_KEY="$("$SCRIPT_DIR/derive-sparkle-public-key.swift" < "$PLAINTEXT_KEY")"
[[ "$DERIVED_PUBLIC_KEY" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
  || release_die "The exported private key does not match Ushot's embedded Sparkle public key."
unset DERIVED_PUBLIC_KEY

release_log "Choose a strong backup password and store it separately from the encrypted file."
/usr/bin/openssl enc \
  -aes-256-cbc \
  -salt \
  -pbkdf2 \
  -iter 600000 \
  -md sha256 \
  -in "$PLAINTEXT_KEY" \
  -out "$ENCRYPTED_BACKUP"
[[ -s "$ENCRYPTED_BACKUP" ]] \
  || release_die "OpenSSL did not create an encrypted backup."

release_log "Re-enter the password once to prove the encrypted backup can be decrypted."
/usr/bin/openssl enc \
  -d \
  -aes-256-cbc \
  -pbkdf2 \
  -iter 600000 \
  -md sha256 \
  -in "$ENCRYPTED_BACKUP" \
  -out "$RECOVERY_CHECK"
cmp "$PLAINTEXT_KEY" "$RECOVERY_CHECK" \
  || release_die "Encrypted backup recovery check did not reproduce the original key."

mv "$ENCRYPTED_BACKUP" "$CANONICAL_OUTPUT"
chmod 600 "$CANONICAL_OUTPUT"
BACKUP_SHA256="$(shasum -a 256 "$CANONICAL_OUTPUT" | awk '{print $1}')"
release_log "Encrypted Sparkle key backup created and locally recovery-checked."
printf 'backup=%s\nsha256=%s\n' "$CANONICAL_OUTPUT" "$BACKUP_SHA256"
