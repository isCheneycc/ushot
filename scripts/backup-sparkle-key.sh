#!/bin/bash
set -euo pipefail
set +x
ulimit -c 0
unset SPARKLE_ED25519_PRIVATE_KEY SPARKLE_PRIVATE_KEY PRIVATE_KEY RECOVERED_PRIVATE_KEY DERIVED_PUBLIC_KEY

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
[[ "$OUTPUT_PATH" == "$CANONICAL_OUTPUT" ]] \
  || release_die "Backup output path must be absolute, canonical, and free of symbolic-link traversal."
case "$CANONICAL_OUTPUT" in
  "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
    release_die "Refusing to place an encrypted signing-key backup inside the source repository."
    ;;
esac
[[ ! -e "$CANONICAL_OUTPUT" && ! -L "$CANONICAL_OUTPUT" ]] \
  || release_die "Backup output already exists; refusing to overwrite it: $CANONICAL_OUTPUT"

release_require_command openssl
release_require_command security
release_require_command shasum
[[ -x "$SCRIPT_DIR/derive-sparkle-public-key.swift" ]] \
  || release_die "Sparkle public-key derivation helper is unavailable."
if ! { : < /dev/tty; } 2>/dev/null; then
  release_die "A controlling terminal is required for OpenSSL's hidden password prompts."
fi

umask 077
WORKSPACE="$(mktemp -d "$CANONICAL_PARENT/.ushot-sparkle-key-backup.XXXXXX")"
chmod 700 "$WORKSPACE"
ENCRYPTED_BACKUP="$WORKSPACE/private-key.backup.enc"
PRIVATE_KEY=""
RECOVERED_PRIVATE_KEY=""
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  unset PRIVATE_KEY RECOVERED_PRIVATE_KEY DERIVED_PUBLIC_KEY
  if [[ -n "${WORKSPACE:-}" && -d "$WORKSPACE" && ! -L "$WORKSPACE" ]]; then
    rm -rf -- "$WORKSPACE"
  fi
  return "$status"
}
trap cleanup EXIT
signal_exit() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

release_log "Requesting access to the existing Sparkle key in the macOS login Keychain."
if ! PRIVATE_KEY="$(
  /usr/bin/security find-generic-password \
    -a "$USHOT_SPARKLE_KEY_ACCOUNT" \
    -s "https://sparkle-project.org" \
    -w
)"; then
  release_die "Could not export the existing Sparkle key from the macOS login Keychain."
fi
[[ -n "$PRIVATE_KEY" ]] \
  || release_die "The macOS login Keychain returned an empty Sparkle private key."
export -n PRIVATE_KEY

DERIVED_PUBLIC_KEY="$(
  printf '%s' "$PRIVATE_KEY" | "$SCRIPT_DIR/derive-sparkle-public-key.swift"
)"
[[ "$DERIVED_PUBLIC_KEY" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
  || release_die "The exported private key does not match Ushot's embedded Sparkle public key."
unset DERIVED_PUBLIC_KEY

release_log "Choose a strong backup password and store it separately from the encrypted file."
if ! printf '%s' "$PRIVATE_KEY" | \
  /usr/bin/openssl enc \
      -aes-256-cbc \
      -salt \
      -pbkdf2 \
      -iter 600000 \
      -md sha256 \
      -out "$ENCRYPTED_BACKUP"; then
  release_die "OpenSSL did not create an encrypted backup."
fi
[[ -s "$ENCRYPTED_BACKUP" ]] \
  || release_die "OpenSSL did not create an encrypted backup."
release_validate_openssl_salted_ciphertext "$ENCRYPTED_BACKUP"
chmod 600 "$ENCRYPTED_BACKUP"

release_log "Re-enter the password once to prove the encrypted backup can be decrypted."
if ! RECOVERED_PRIVATE_KEY="$(
  /usr/bin/openssl enc \
    -d \
    -aes-256-cbc \
    -pbkdf2 \
    -iter 600000 \
    -md sha256 \
    -in "$ENCRYPTED_BACKUP" \
    < /dev/tty
)"; then
  release_die "Encrypted backup recovery check failed."
fi
[[ "$PRIVATE_KEY" == "$RECOVERED_PRIVATE_KEY" ]] \
  || release_die "Encrypted backup recovery check did not reproduce the original key."
unset PRIVATE_KEY RECOVERED_PRIVATE_KEY

BACKUP_SHA256="$(shasum -a 256 "$ENCRYPTED_BACKUP" | awk '{print $1}')"
[[ "$BACKUP_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || release_die "Could not calculate the encrypted backup SHA-256."
ln "$ENCRYPTED_BACKUP" "$CANONICAL_OUTPUT" \
  || release_die "Backup output appeared during creation; refusing to overwrite it: $CANONICAL_OUTPUT"
rm "$ENCRYPTED_BACKUP"
release_log "Encrypted Sparkle key backup created and locally recovery-checked."
printf 'backup=%s\nsha256=%s\n' "$CANONICAL_OUTPUT" "$BACKUP_SHA256"
