#!/bin/bash
set -euo pipefail
set +x
ulimit -c 0
umask 077
IFS=$' \t\n'
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG
unset BASH_ENV CDPATH ENV RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE \
  SPARKLE_ED25519_PRIVATE_KEY SPARKLE_PRIVATE_KEY PRIVATE_KEY

readonly FEED_HOST="ischeneycc.github.io"
readonly ARCHIVE_HOST="github.com"
readonly FEED_ROUTE="/ushot/updates/v1/appcast.xml"
readonly ARCHIVE_ROUTE="/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.zip"
readonly DEFAULT_FEED_FIXTURE="appcast.xml"
readonly DEFAULT_ARCHIVE_FIXTURE="Ushot-0.1.4-arm64.zip"

OPERATION="serve"
FIXTURES_DIRECTORY=""
CASES_DIRECTORY=""
FEED_FIXTURE="$DEFAULT_FEED_FIXTURE"
ARCHIVE_FIXTURE="$DEFAULT_ARCHIVE_FIXTURE"
INITIAL_CASE="normal"
FEED_TRANSFER_MODE="normal"
REQUEST_EVIDENCE=""
PORT="443"
SELF_TEST_ONLY=false
EXPECTED_SCRIPT_SHA256=""
ROOT_COPY_DIRECTORY=""
RECOVERY_SESSION_ID=""
RECOVERY_CA_SHA256=""
CA_CERTIFICATE_PATH=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "usage:" \
    "  $0 --fixtures-directory ABSOLUTE_DIR [serve options]" \
    "  $0 --cases-directory ABSOLUTE_CASES_ROOT [serve options]" \
    "" \
    "Serve options:" \
    "  --feed-fixture NAME          Feed basename (default: $DEFAULT_FEED_FIXTURE)." \
    "  --archive-fixture NAME       Archive basename (default: $DEFAULT_ARCHIVE_FIXTURE)." \
    "  --initial-case LABEL         Initial case label (default: normal)." \
    "  --feed-transfer-mode MODE    normal (Content-Length) or chunked (default: normal)." \
    "  --request-evidence ABS_PATH  New persistent TSV evidence file (required on port 443)." \
    "  --port PORT                  Listener port (default: 443)." \
    "  --self-test                  Transport self-test then exit; only valid above port 1023." \
    "" \
    "A cases root is the exact prepare-update-transition-fixtures.sh output: seven fixed" \
    "case directories plus fixture-manifest.json and SHA256SUMS.txt, with no other" \
    "top-level entries. Each case contains exactly appcast.xml and the archive. The operator can switch" \
    "preloaded cases and normal/chunked feed mode without reinstalling trust or hosts." \
    "Port 443 accepts only this complete manifest-bound cases-root form; the single" \
    "--fixtures-directory form is available only for unprivileged high-port diagnostics." \
    "" \
    "The normal invocation never calls sudo or changes hosts, trust, or network state." \
    "Port 443 prints a hash-bound root-copy launcher for explicit operator review."
}

if [[ "${1:-}" == "--install-ca" ]]; then
  OPERATION="install-ca"
  shift
elif [[ "${1:-}" == "--install-hosts" ]]; then
  OPERATION="install-hosts"
  shift
elif [[ "${1:-}" == "--recover-cleanup" ]]; then
  OPERATION="recover-cleanup"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixtures-directory) FIXTURES_DIRECTORY="${2:?--fixtures-directory requires a value}"; shift 2 ;;
    --cases-directory) CASES_DIRECTORY="${2:?--cases-directory requires a value}"; shift 2 ;;
    --feed-fixture) FEED_FIXTURE="${2:?--feed-fixture requires a value}"; shift 2 ;;
    --archive-fixture) ARCHIVE_FIXTURE="${2:?--archive-fixture requires a value}"; shift 2 ;;
    --initial-case) INITIAL_CASE="${2:?--initial-case requires a value}"; shift 2 ;;
    --feed-transfer-mode) FEED_TRANSFER_MODE="${2:?--feed-transfer-mode requires a value}"; shift 2 ;;
    --request-evidence) REQUEST_EVIDENCE="${2:?--request-evidence requires a value}"; shift 2 ;;
    --port) PORT="${2:?--port requires a value}"; shift 2 ;;
    --self-test) SELF_TEST_ONLY=true; shift ;;
    --expected-script-sha256) EXPECTED_SCRIPT_SHA256="${2:?--expected-script-sha256 requires a value}"; shift 2 ;;
    --root-copy-directory) ROOT_COPY_DIRECTORY="${2:?--root-copy-directory requires a value}"; shift 2 ;;
    --session-id) RECOVERY_SESSION_ID="${2:?--session-id requires a value}"; shift 2 ;;
    --ca-sha256) RECOVERY_CA_SHA256="${2:?--ca-sha256 requires a value}"; shift 2 ;;
    --ca-path) CA_CERTIFICATE_PATH="${2:?--ca-path requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIRECTORY/$(basename "${BASH_SOURCE[0]}")"
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] \
  || die "Script must be a regular, non-symbolic-link file."

trusted_system_sha256() {
  local digest_output
  local target_path="$1"

  [[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/openssl)" == "0:0:755" ]] \
    || die "System SHA-256 executable identity is not exact."
  /usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C \
    /usr/bin/codesign --verify --strict \
      --test-requirement '=anchor apple and identifier "com.apple.openssl"' \
      /usr/bin/openssl \
    || die "System SHA-256 executable failed the Apple code-signing requirement."
  digest_output="$(/usr/bin/env -i \
    PATH="$PATH" LC_ALL=C LANG=C OPENSSL_CONF=/dev/null \
    /usr/bin/openssl dgst -sha256 -r "$target_path")" \
    || die "Trusted system SHA-256 execution failed."
  digest_output="${digest_output%% *}"
  [[ "$digest_output" =~ ^[0-9a-f]{64}$ ]] \
    || die "Trusted system SHA-256 output is malformed."
  printf '%s\n' "$digest_output"
}

verify_system_ruby() {
  [[ -f /usr/bin/ruby && ! -L /usr/bin/ruby \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/ruby)" == "0:0:555" ]] \
    || die "System Ruby executable identity is not exact."
  /usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C \
    /usr/bin/codesign --verify --strict \
      --test-requirement '=anchor apple and identifier "com.apple.ruby"' \
      /usr/bin/ruby \
    || die "System Ruby failed the Apple code-signing requirement."
}

ACTUAL_SCRIPT_SHA256="$(trusted_system_sha256 "$SCRIPT_PATH")"
verify_system_ruby

CURRENT_UID="$(/usr/bin/id -u)"
CURRENT_GID="$(/usr/bin/id -g)"
CURRENT_USER="$(/usr/bin/id -un)"
SUDO_LOGIN_USER="${SUDO_USER:-}"
SUDO_LOGIN_UID="${SUDO_UID:-}"
SUDO_LOGIN_GID="${SUDO_GID:-}"

[[ "$CURRENT_USER" =~ ^[A-Za-z0-9._-]+$ \
    && "$(/usr/bin/id -u "$CURRENT_USER" 2>/dev/null)" == "$CURRENT_UID" \
    && "$(/usr/bin/id -g "$CURRENT_USER" 2>/dev/null)" == "$CURRENT_GID" ]] \
  || die "Current login identity is not canonical."

if [[ "$CURRENT_UID" == "0" ]]; then
  [[ "$EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$ACTUAL_SCRIPT_SHA256" == "$EXPECTED_SCRIPT_SHA256" ]] \
    || die "Every root operation requires the reviewed root-copy SHA-256."
  [[ "$SUDO_LOGIN_USER" != "" && "$SUDO_LOGIN_USER" != "root" \
      && "$SUDO_LOGIN_UID" =~ ^[1-9][0-9]*$ \
      && "$SUDO_LOGIN_GID" =~ ^[0-9]+$ \
      && "$(/usr/bin/id -u "$SUDO_LOGIN_USER" 2>/dev/null)" == "$SUDO_LOGIN_UID" \
      && "$(/usr/bin/id -g "$SUDO_LOGIN_USER" 2>/dev/null)" == "$SUDO_LOGIN_GID" ]] \
    || die "Root mode requires a valid non-root sudo login identity."
  [[ "$ROOT_COPY_DIRECTORY" == /private/var/root/ushot-loopback-launch.* \
      && -d "$ROOT_COPY_DIRECTORY" \
      && ! -L "$ROOT_COPY_DIRECTORY" \
      && "$(cd "$ROOT_COPY_DIRECTORY" && pwd -P)" == "$ROOT_COPY_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u' "$ROOT_COPY_DIRECTORY")" == "0" \
      && "$(/usr/bin/stat -f '%Lp' "$ROOT_COPY_DIRECTORY")" == "700" \
      && "$SCRIPT_DIRECTORY" == "$ROOT_COPY_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u' "$SCRIPT_PATH")" == "0" \
      && "$(/usr/bin/stat -f '%Lp' "$SCRIPT_PATH")" == "500" ]] \
    || die "Root execution is permitted only from the verified root-owned launcher copy."
elif [[ -n "$EXPECTED_SCRIPT_SHA256" || -n "$ROOT_COPY_DIRECTORY" ]]; then
  die "Root-copy arguments are invalid in an unprivileged process."
fi

print_quoted_command() {
  local argument
  printf '  '
  for argument in "$@"; do
    printf '%q ' "$argument"
  done
  printf '\n'
}

print_hash_bound_launcher() {
  local -a serve_arguments
  local launcher

  serve_arguments=(--expected-script-sha256 "$ACTUAL_SCRIPT_SHA256")
  if [[ -n "$FIXTURES_DIRECTORY" ]]; then
    serve_arguments+=(--fixtures-directory "$FIXTURES_DIRECTORY")
  else
    serve_arguments+=(--cases-directory "$CASES_DIRECTORY")
  fi
  serve_arguments+=(
    --feed-fixture "$FEED_FIXTURE"
    --archive-fixture "$ARCHIVE_FIXTURE"
    --initial-case "$INITIAL_CASE"
    --feed-transfer-mode "$FEED_TRANSFER_MODE"
    --request-evidence "$REQUEST_EVIDENCE"
    --port "$PORT"
  )

launcher='set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LANG=C
LC_ALL=C
export PATH LANG LC_ALL
unset BASH_ENV ENV CDPATH GLOBIGNORE BASH_XTRACEFD PS4 PROMPT_COMMAND
unset OPENSSL_CONF OPENSSL_MODULES OPENSSL_ENGINES
while IFS= read -r inherited_name; do
  case "$inherited_name" in
    DYLD_*|LD_*|PERL*|PYTHON*|RUBY*|NODE_*) unset "$inherited_name" ;;
  esac
done < <(compgen -v)
unset inherited_name
umask 077
src="$1"
expected="$2"
shift 2
launch_dir="$(/usr/bin/mktemp -d /private/var/root/ushot-loopback-launch.XXXXXXXX)"
/bin/chmod 700 "$launch_dir"
copy="$launch_dir/serve-update-transition-loopback.sh"
preserve=false
cleanup_launcher() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ "$preserve" == false && -d "$launch_dir" && ! -L "$launch_dir" ]]; then
    shopt -s nullglob dotglob
    launch_entries=("$launch_dir"/*)
    shopt -u nullglob dotglob
    if [[ "${#launch_entries[@]}" == "1" && "${launch_entries[0]}" == "$copy" \
        && -f "$copy" && ! -L "$copy" ]]; then
      /bin/unlink "$copy" || status=1
      /bin/rmdir -- "$launch_dir" || status=1
    else
      status=1
      printf "error: root copy contains unexpected recovery snapshots; preserving %s\n" "$copy" >&2
    fi
  elif [[ "$preserve" == true ]]; then
    printf "root_copy_preserved=%s\n" "$copy" >&2
  fi
  exit "$status"
}
trap cleanup_launcher EXIT
trap "exit 129" HUP
trap "exit 130" INT
trap "exit 143" TERM
/usr/bin/install -o root -g wheel -m 0500 "$src" "$copy"
[[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
    && "$(/usr/bin/stat -f "%u:%g:%Lp" /usr/bin/openssl)" == "0:0:755" ]] \
  || { printf "error: system SHA-256 executable identity is not exact\n" >&2; exit 1; }
/usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C \
  /usr/bin/codesign --verify --strict \
    --test-requirement "=anchor apple and identifier \"com.apple.openssl\"" \
    /usr/bin/openssl \
  || { printf "error: system SHA-256 executable signature rejected\n" >&2; exit 1; }
actual="$(/usr/bin/env -i \
  PATH="$PATH" LC_ALL=C LANG=C OPENSSL_CONF=/dev/null \
  /usr/bin/openssl dgst -sha256 -r "$copy")" \
  || { printf "error: trusted system SHA-256 execution failed\n" >&2; exit 1; }
actual="${actual%% *}"
[[ "$actual" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] \
  || { printf "error: reviewed script hash changed before root execution.\n" >&2; exit 1; }
preserve=true
set +e
/usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C SUDO_USER="$SUDO_USER" SUDO_UID="$SUDO_UID" SUDO_GID="$SUDO_GID" \
  /bin/bash --noprofile --norc -p "$copy" --root-copy-directory "$launch_dir" "$@"
result=$?
set -e
if [[ "$result" == 0 ]]; then preserve=false; fi
exit "$result"'

  printf '%s\n' \
    "TCP 443 requires a reviewed root boundary. This command first copies the script" \
    "into a new mode-0700 root directory, verifies SHA-256, sanitizes the environment," \
    "and only then executes the immutable root-owned copy:"
  print_quoted_command \
    /usr/bin/sudo -- \
    /usr/bin/env -i \
    PATH="$PATH" \
    LANG=C \
    LC_ALL=C \
    SUDO_USER="$CURRENT_USER" \
    SUDO_UID="$CURRENT_UID" \
    SUDO_GID="$CURRENT_GID" \
    /bin/bash --noprofile --norc -p -c "$launcher" ushot-root-launcher \
    "$SCRIPT_PATH" "$ACTUAL_SCRIPT_SHA256" "${serve_arguments[@]}"
}

if [[ "$OPERATION" == "serve" ]]; then
  [[ ( -n "$FIXTURES_DIRECTORY" && -z "$CASES_DIRECTORY" ) \
      || ( -z "$FIXTURES_DIRECTORY" && -n "$CASES_DIRECTORY" ) ]] \
    || die "Choose exactly one of --fixtures-directory or --cases-directory."
  [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] \
    || die "Port must be a canonical integer from 1 through 65535."
  (( 10#$PORT <= 65535 )) || die "Port must not exceed 65535."
  [[ "$INITIAL_CASE" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "Initial case must be a safe lowercase label."
  [[ "$FEED_TRANSFER_MODE" == "normal" || "$FEED_TRANSFER_MODE" == "chunked" ]] \
    || die "Feed transfer mode must be normal or chunked."
  if [[ "$PORT" == "443" && "$SELF_TEST_ONLY" == true ]]; then
    die "--self-test on port 443 is rejected because it would not exercise system resolver/trust setup. Use a high port for transport self-test."
  fi
  if [[ "$PORT" == "443" && -n "$FIXTURES_DIRECTORY" ]]; then
    die "Exact port-443 mode requires --cases-directory with the complete seven-case manifest; --fixtures-directory is diagnostic-only."
  fi
  if [[ "$PORT" == "443" \
      && ( "$FEED_FIXTURE" != "$DEFAULT_FEED_FIXTURE" \
        || "$ARCHIVE_FIXTURE" != "$DEFAULT_ARCHIVE_FIXTURE" ) ]]; then
    die "Exact port-443 mode requires the canonical appcast and archive fixture names."
  fi
  if [[ "$PORT" == "443" && -z "$REQUEST_EVIDENCE" ]]; then
    die "Exact mode requires --request-evidence in a pre-created private mode-0700 directory."
  fi
  if [[ "$PORT" == "443" && "$CURRENT_UID" != "0" ]]; then
    print_hash_bound_launcher >&2
    exit 1
  fi
  if [[ "$PORT" != "443" && "$CURRENT_UID" == "0" ]]; then
    die "High-port diagnostic mode must run unprivileged."
  fi
elif [[ "$OPERATION" == "install-ca" ]]; then
  [[ "$CURRENT_UID" == "0" ]] || die "--install-ca requires the verified root-owned copy."
  [[ "$RECOVERY_SESSION_ID" =~ ^[0-9a-f]{16}$ \
      && "$RECOVERY_CA_SHA256" =~ ^[0-9A-F]{64}$ \
      && "$CA_CERTIFICATE_PATH" == /* ]] \
    || die "Valid --session-id, --ca-sha256 and absolute --ca-path values are required."
elif [[ "$OPERATION" == "install-hosts" ]]; then
  [[ "$CURRENT_UID" == "0" ]] || die "--install-hosts requires the verified root-owned copy."
  [[ "$RECOVERY_SESSION_ID" =~ ^[0-9a-f]{16}$ ]] || die "A valid --session-id is required."
elif [[ "$OPERATION" == "recover-cleanup" ]]; then
  [[ "$CURRENT_UID" == "0" ]] || die "--recover-cleanup requires the verified root-owned copy."
  [[ "$RECOVERY_SESSION_ID" =~ ^[0-9a-f]{16}$ \
      && "$RECOVERY_CA_SHA256" =~ ^[0-9A-F]{64}$ ]] \
    || die "Valid --session-id and uppercase --ca-sha256 values are required."
fi

RUN_UID="$CURRENT_UID"
RUN_GID="$CURRENT_GID"
RUN_USER="$CURRENT_USER"
if [[ "$CURRENT_UID" == "0" ]]; then
  RUN_UID="$SUDO_LOGIN_UID"
  RUN_GID="$SUDO_LOGIN_GID"
  RUN_USER="$SUDO_LOGIN_USER"
fi

set +e
/usr/bin/env -i PATH="$PATH" LC_ALL=C LANG=C \
  /usr/bin/ruby --disable=gems,did_you_mean,rubyopt \
    - "$OPERATION" "$SCRIPT_PATH" "$ACTUAL_SCRIPT_SHA256" \
      "$ROOT_COPY_DIRECTORY" "$RUN_UID" "$RUN_GID" \
      "$FIXTURES_DIRECTORY" "$CASES_DIRECTORY" "$FEED_FIXTURE" \
      "$ARCHIVE_FIXTURE" "$INITIAL_CASE" "$FEED_TRANSFER_MODE" \
      "$REQUEST_EVIDENCE" "$PORT" "$SELF_TEST_ONLY" \
      "$RECOVERY_SESSION_ID" "$RECOVERY_CA_SHA256" \
      "$CA_CERTIFICATE_PATH" "$RUN_USER" <<'RUBY'
bootstrap_error = lambda do |message|
  $stderr.puts("loopback: ruby-bootstrap-error=#{message}")
  exit(1)
end

expected_initial_load_path = [
  "/Library/Ruby/Site/2.6.0",
  "/Library/Ruby/Site/2.6.0/arm64e-darwin25",
  "/Library/Ruby/Site/2.6.0/universal-darwin25",
  "/Library/Ruby/Site",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/vendor_ruby/2.6.0",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/vendor_ruby/2.6.0/arm64e-darwin25",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/vendor_ruby/2.6.0/universal-darwin25",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/vendor_ruby",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/2.6.0",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/2.6.0/arm64e-darwin25",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/2.6.0/universal-darwin25"
].freeze
expected_initial_features = [
  "enumerator.so",
  "thread.rb",
  "rational.so",
  "complex.so",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/2.6.0/universal-darwin25/enc/encdb.bundle",
  "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/2.6.0/universal-darwin25/enc/trans/transdb.bundle"
].freeze
system_ruby_root = "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby"

bootstrap_error.call("initial-load-path-mismatch") \
  unless $LOAD_PATH == expected_initial_load_path
bootstrap_error.call("initial-loaded-features-mismatch") \
  unless $LOADED_FEATURES == expected_initial_features

system_load_path = expected_initial_load_path.select do |path|
  path.start_with?("#{system_ruby_root}/") && File.directory?(path)
end
bootstrap_error.call("system-load-path-count-mismatch") \
  unless system_load_path.length == 5
system_load_path.each do |path|
  current = ""
  path.split("/").reject(&:empty?).each do |component|
    current << "/#{component}"
    begin
      status = File.lstat(current)
    rescue SystemCallError
      bootstrap_error.call("system-load-path-unavailable")
    end
    bootstrap_error.call("system-load-path-identity-mismatch") \
      unless status.directory? && !status.symlink? && status.uid.zero? \
        && (status.mode & 0o022).zero?
  end
end
$LOAD_PATH.replace(system_load_path)

begin
  %w[
    openssl webrick webrick/https tmpdir fileutils json digest securerandom
    open3 time socket
  ].each { |feature| require feature }
rescue LoadError
  bootstrap_error.call("required-system-module-unavailable")
end

relative_core_features = %w[enumerator.so thread.rb rational.so complex.so].freeze
$LOADED_FEATURES.each do |path|
  next if relative_core_features.include?(path)
  bootstrap_error.call("loaded-feature-outside-system-ruby") \
    unless path.start_with?("#{system_ruby_root}/")
  begin
    status = File.lstat(path)
    canonical_path = File.realpath(path)
  rescue SystemCallError
    bootstrap_error.call("loaded-feature-unavailable")
  end
  bootstrap_error.call("loaded-feature-identity-mismatch") \
    unless status.file? && !status.symlink? && status.uid.zero? \
      && (status.mode & 0o022).zero? && canonical_path == path
end
bootstrap_error.call("required-runtime-capability-unavailable") \
  unless defined?(File::NOFOLLOW) && defined?(WEBrick::HTTPServer)

ENV.clear
ENV["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
ENV["LC_ALL"] = "C"
ENV["LANG"] = "C"

FEED_HOST = "ischeneycc.github.io"
ARCHIVE_HOST = "github.com"
FEED_ROUTE = "/ushot/updates/v1/appcast.xml"
ARCHIVE_ROUTE = "/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.zip"
HOSTS_PATH = "/private/etc/hosts"
SYSTEM_KEYCHAIN = "/Library/Keychains/System.keychain"
MAX_FEED_BYTES = 2_097_152
MAX_ARCHIVE_BYTES = 134_217_728
MAX_HOSTS_BYTES = 1_048_576
MAX_CA_CERTIFICATE_BYTES = 65_536
MAX_AUTHENTICATED_PREFIX_BYTES = 1_048_576
SIGNED_FEED_TRAILER_BYTES = 512
SIGNED_FEED_WIRE_CEILING_BYTES = 1_049_088
EXPECTED_CASE_SEQUENCE = %w[
  normal
  tampered-archive
  short-version-mismatch
  build-number-mismatch
  short-and-build-mismatch
  duplicate-build-metadata
  oversized-signed-feed
].freeze
EXPECTED_CASE_LABELS = EXPECTED_CASE_SEQUENCE.sort.freeze
EXPECTED_FIXTURE_SCRIPT_SHA256 = "75f733d24188525bbb29a9296656c5ea25cf6c1ba85a4531b2a3e7c0abf297d6"
EXPECTED_FROZEN_BUNDLE_MANIFEST_SHA256 = "bc58445256f650b040feb254ce5259dc542a2c8795a980d87d81fe9c811574a4"
EXPECTED_REVIEWED_SOURCE_MANIFEST_SHA256 = "c10e94fb61808f885e299e44786dc00499f082340ce5e4b6fe4e4dd6e683401f"
EXPECTED_RELEASE_COMMON_SHA256 = "608280e518bd010f842da932b10b050e002e9553aa21473c1c9338e8e1035684"
EXPECTED_VALIDATE_APPCAST_SHA256 = "5e5314c0059b95b36e4033ccc01ad1e55ebf3c4620d9d4aa7e94e75e524f6b9f"
EXPECTED_PUBLIC_KEY_FINGERPRINT_SHA256 = "13d0f28d6b7199fcb2399d6183d74301294c1f859db765782ed9396161e440c8"
EXPECTED_SPARKLE_ARCHIVE_SHA256 = "015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
EXPECTED_GENERATE_APPCAST_SHA256 = "669a5ed0f90ce06fb1de3e36aba35c5da8b98f66928a185fd4029174071be700"
EXPECTED_GENERATE_KEYS_SHA256 = "2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"
EXPECTED_SIGN_UPDATE_SHA256 = "bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
EXPECTED_AUTHENTICATED_APPCAST_VALIDATOR_SHA256 = "ded0593a34edc3d592871bbe8a0902e4e3c6cfe03fe043cb8f604c2e4c3825a4"
EXPECTED_PUBLIC_KEY_DERIVER_SHA256 = "ae1ab09dfcd799db9aeaee86eaa223f6cd6e10f837c1879453749ce46fd11738"
EXPECTED_EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256 = "6a7178ebcbb10b248d8899baafed1540c021b91b71afaedf19c3243c73d23ed6"
EXPECTED_RELEASE_NOTES_SHA256 = "d7f0398e99bad381502b500cc75969fc869678566199089e54ec8d0bd7ce19b5"
EXPECTED_CANDIDATE_ASSETS = [
  ["Ushot-0.1.4-arm64.dmg", "96cd69ccb204d340be5ac404a0492cf7fe998e4cf7bc6e865fc2a7708dd68628"],
  ["Ushot-0.1.4-arm64.zip", "0653d37479d4b8964a3147d92d9baf55f9f18883f1c6e0fa813bbdce50c01998"],
  ["Ushot-0.1.4-arm64.dSYM.zip", "1c26bf01ab9fb5e0ba1862d1bc4cfcd9d69cd3b0c134aa13c221c2491c6406d1"],
  ["Ushot-0.1.4-arm64.release-manifest.json", "40b91ee67253bd434ed61552c993686e2925ba07c5ebb742c8e6395df1198029"],
  ["SHA256SUMS.txt", "5e5e438133939749c9b4fc6aec355a016005c438fa5a7dc11c0fcb69460be2f0"]
].map { |name, sha256| { "name" => name, "sha256" => sha256 }.freeze }.freeze
CASES_ROOT_METADATA = ["SHA256SUMS.txt", "fixture-manifest.json"].sort.freeze
CLEAN_ENV = { "PATH" => ENV.fetch("PATH"), "LC_ALL" => "C", "LANG" => "C" }.freeze

class SafetyError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end

class DuplicateJSONKeyError < StandardError; end

class DuplicateRejectingHash < Hash
  def []=(key, value)
    raise DuplicateJSONKeyError, key if key?(key)

    super
  end
end

def fail_safely(code)
  raise SafetyError, code
end

def safe_label!(value, code)
  fail_safely(code) unless value.match?(/\A[a-z0-9][a-z0-9._-]*\z/)
  value
end

def safe_basename!(value, code)
  fail_safely(code) unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  fail_safely(code) if [".", ".."].include?(value)
  value
end

def sha256_bytes(bytes)
  Digest::SHA256.hexdigest(bytes)
end

def run_capture(*arguments)
  Open3.capture3(CLEAN_ENV, *arguments, :unsetenv_others => true)
end

def command_success?(*arguments)
  system(CLEAN_ENV, *arguments, :unsetenv_others => true,
    :in => File::NULL, :out => File::NULL, :err => File::NULL)
end

def stat_stability_tuple(stat)
  [
    stat.dev, stat.ino, stat.size, stat.uid, stat.gid, stat.mode,
    stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec
  ]
end

def read_open_file_twice!(file, maximum_size, purpose)
  before = file.stat
  fail_safely("#{purpose}-not-regular") unless before.file?
  fail_safely("#{purpose}-empty") unless before.size.positive?
  fail_safely("#{purpose}-too-large") if before.size > maximum_size
  file.rewind
  first = file.read(before.size + 1)
  middle = file.stat
  file.rewind
  second = file.read(before.size + 1)
  after = file.stat
  stable = stat_stability_tuple(before) == stat_stability_tuple(middle) &&
    stat_stability_tuple(middle) == stat_stability_tuple(after)
  fail_safely("#{purpose}-changed-during-snapshot") \
    unless stable && first.bytesize == before.size && first == second
  first
end

def read_stable_path!(path, uid:, maximum_size:, exact_mode: nil, purpose:)
  bytes = nil
  File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
    stat = file.stat
    fail_safely("#{purpose}-owner-mismatch") unless stat.uid == uid
    fail_safely("#{purpose}-writable-by-others") unless (stat.mode & 0o022).zero?
    fail_safely("#{purpose}-mode-mismatch") \
      if exact_mode && (stat.mode & 0o777) != exact_mode
    bytes = read_open_file_twice!(file, maximum_size, purpose)
  end
  bytes
rescue Errno::ELOOP
  fail_safely("#{purpose}-symbolic-link-rejected")
rescue Errno::ENOENT, Errno::EACCES
  fail_safely("#{purpose}-unavailable")
end

def validate_root_copy_directory!(path)
  fail_safely("root-copy-directory-invalid") unless Process.euid.zero? && path.start_with?("/private/var/root/ushot-loopback-launch.")
  stat = File.lstat(path)
  fail_safely("root-copy-directory-invalid") \
    unless stat.directory? && !stat.symlink? && stat.uid.zero? \
      && (stat.mode & 0o777) == 0o700 && File.realpath(path) == path
  path
rescue Errno::ENOENT, Errno::EACCES
  fail_safely("root-copy-directory-invalid")
end

def root_snapshot_path(root_copy_directory, kind, session_id)
  fail_safely("root-snapshot-kind-invalid") unless ["ca", "hosts"].include?(kind)
  fail_safely("root-snapshot-session-invalid") unless session_id.match?(/\A[0-9a-f]{16}\z/)
  File.join(validate_root_copy_directory!(root_copy_directory), "#{kind}-#{session_id}.snapshot")
end

def root_snapshot_exists?(path)
  stat = File.lstat(path)
  fail_safely("root-snapshot-identity-invalid") \
    unless stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o777) == 0o400
  true
rescue Errno::ENOENT
  false
end

def write_root_snapshot!(path, bytes)
  flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
  File.open(path, flags, 0o400) do |file|
    written = file.write(bytes)
    fail_safely("root-snapshot-short-write") unless written == bytes.bytesize
    file.flush
    file.fsync
  end
  File.chmod(0o400, path)
  root_snapshot_exists?(path) or fail_safely("root-snapshot-write-verification-failed")
end

def unlink_root_snapshot!(path)
  return false unless root_snapshot_exists?(path)
  File.unlink(path)
  fail_safely("root-snapshot-delete-verification-failed") if File.exist?(path) || File.symlink?(path)
  true
end

def active_host_tokens?(line)
  active = line.sub(/[[:space:]]*#.*/, "")
  fields = active.split
  fields.drop(1).any? { |field| field == FEED_HOST || field == ARCHIVE_HOST }
end

def hosts_block_strings(session_id)
  marker = "USHOT_UPDATE_TRANSITION_#{session_id}"
  [
    "# BEGIN #{marker}",
    "127.0.0.1 #{FEED_HOST} #{ARCHIVE_HOST}",
    "# END #{marker}"
  ]
end

def inspect_hosts(data, session_id, remove: false)
  begin_line, mapping_line, end_line = hosts_block_strings(session_id)
  lines = data.lines
  output = []
  blocks = 0
  index = 0

  while index < lines.length
    current = lines[index].sub(/\r?\n\z/, "")
    if current == begin_line
      next_mapping = lines[index + 1]&.sub(/\r?\n\z/, "")
      next_end = lines[index + 2]&.sub(/\r?\n\z/, "")
      fail_safely("hosts-partial-session-block") unless next_mapping == mapping_line && next_end == end_line
      blocks += 1
      output.concat(lines[index, 3]) unless remove
      index += 3
      next
    end
    fail_safely("hosts-orphan-session-marker") if current == end_line
    fail_safely("hosts-production-mapping-outside-session") if active_host_tokens?(lines[index])
    output << lines[index]
    index += 1
  end
  [blocks, output.join]
end

def validate_hosts_file!(file)
  stat = file.stat
  fail_safely("hosts-not-regular") unless stat.file?
  fail_safely("hosts-not-root-owned") unless stat.uid.zero?
  fail_safely("hosts-writable-by-non-root") unless (stat.mode & 0o022).zero?
  stat
end

def read_hosts_safely
  File.open(HOSTS_PATH, File::RDONLY | File::NOFOLLOW) do |file|
    file.flock(File::LOCK_SH)
    validate_hosts_file!(file)
    return read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts")
  end
rescue Errno::ELOOP
  fail_safely("hosts-symbolic-link-rejected")
end

def hosts_installed_bytes(original, session_id)
  begin_line, mapping_line, end_line = hosts_block_strings(session_id)
  separator = original.empty? || original.end_with?("\n") ? "" : "\n"
  "#{original}#{separator}#{begin_line}\n#{mapping_line}\n#{end_line}\n"
end

HOSTS_METADATA_KEYS = %w[dev ino uid gid mode flags acl_sha256 xattrs_sha256].freeze

def capture_hosts_metadata!(file)
  before = validate_hosts_file!(file)
  path_before = File.lstat(HOSTS_PATH)
  fail_safely("hosts-path-identity-mismatch") \
    unless !path_before.symlink? && path_before.dev == before.dev && path_before.ino == before.ino

  flags_output, _flags_error, flags_status = run_capture("/usr/bin/stat", "-f", "%f", HOSTS_PATH)
  fail_safely("hosts-flags-inspection-failed") unless flags_status.success? && flags_output.strip.match?(/\A[0-9]+\z/)
  acl_output, _acl_error, acl_status = run_capture("/bin/ls", "-lde", HOSTS_PATH)
  fail_safely("hosts-acl-inspection-failed") unless acl_status.success? && !acl_output.empty?
  acl_lines = acl_output.lines.drop(1).join
  xattrs_output, _xattrs_error, xattrs_status = run_capture("/usr/bin/xattr", "-l", HOSTS_PATH)
  fail_safely("hosts-xattr-inspection-failed") unless xattrs_status.success?

  after = file.stat
  path_after = File.lstat(HOSTS_PATH)
  stable = stat_stability_tuple(before) == stat_stability_tuple(after)
  fail_safely("hosts-metadata-changed-during-inspection") \
    unless stable && !path_after.symlink? \
      && path_after.dev == after.dev && path_after.ino == after.ino
  {
    "dev" => before.dev.to_s,
    "ino" => before.ino.to_s,
    "uid" => before.uid.to_s,
    "gid" => before.gid.to_s,
    "mode" => (before.mode & 0o7777).to_s,
    "flags" => flags_output.strip,
    "acl_sha256" => sha256_bytes(acl_lines),
    "xattrs_sha256" => sha256_bytes(xattrs_output)
  }
end

def encode_hosts_snapshot(metadata, original)
  fail_safely("hosts-snapshot-metadata-invalid") unless metadata.keys.sort == HOSTS_METADATA_KEYS.sort
  header = ["ushot-hosts-snapshot-v1"]
  HOSTS_METADATA_KEYS.each { |key| header << "#{key}=#{metadata.fetch(key)}" }
  header << "bytes_length=#{original.bytesize}"
  header << "bytes_sha256=#{sha256_bytes(original)}"
  "#{header.join("\n")}\n\n#{original}"
end

def decode_hosts_snapshot(payload)
  header, original = payload.split("\n\n", 2)
  fail_safely("hosts-snapshot-format-invalid") unless header && original
  lines = header.lines.map(&:chomp)
  fail_safely("hosts-snapshot-version-invalid") unless lines.shift == "ushot-hosts-snapshot-v1"
  values = {}
  lines.each do |line|
    key, value = line.split("=", 2)
    fail_safely("hosts-snapshot-format-invalid") \
      unless key && value && !values.key?(key) && value.match?(/\A[0-9a-f]+\z/i)
    values[key] = value
  end
  expected_keys = (HOSTS_METADATA_KEYS + %w[bytes_length bytes_sha256]).sort
  fail_safely("hosts-snapshot-fields-invalid") unless values.keys.sort == expected_keys
  fail_safely("hosts-snapshot-bytes-invalid") \
    unless values.fetch("bytes_length") == original.bytesize.to_s \
      && values.fetch("bytes_sha256") == sha256_bytes(original)
  metadata = values.select { |key, _value| HOSTS_METADATA_KEYS.include?(key) }
  [metadata, original]
end

def metadata_matches?(expected, actual)
  HOSTS_METADATA_KEYS.all? { |key| expected.fetch(key) == actual.fetch(key) }
end

def overwrite_open_file!(file, bytes)
  file.rewind
  written = file.write(bytes)
  fail_safely("hosts-short-write") unless written == bytes.bytesize
  file.truncate(bytes.bytesize)
  file.flush
  file.fsync
end

def install_hosts!(session_id, root_copy_directory)
  snapshot_path = root_snapshot_path(root_copy_directory, "hosts", session_id)
  fail_safely("hosts-snapshot-already-present") if root_snapshot_exists?(snapshot_path)
  flags = File::RDWR | File::NOFOLLOW
  File.open(HOSTS_PATH, flags) do |file|
    file.flock(File::LOCK_EX)
    validate_hosts_file!(file)
    original = read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts")
    blocks, = inspect_hosts(original, session_id, remove: false)
    fail_safely("hosts-session-already-present") unless blocks.zero?
    metadata = capture_hosts_metadata!(file)
    write_root_snapshot!(snapshot_path, encode_hosts_snapshot(metadata, original))
    installed = hosts_installed_bytes(original, session_id)
    fail_safely("hosts-too-large-after-install") if installed.bytesize > MAX_HOSTS_BYTES
    fail_safely("hosts-concurrent-edit-before-install") \
      unless read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts") == original \
        && metadata_matches?(metadata, capture_hosts_metadata!(file))
    overwrite_open_file!(file, installed)
    fail_safely("hosts-metadata-drift-during-install") \
      unless metadata_matches?(metadata, capture_hosts_metadata!(file))
    fail_safely("hosts-install-byte-verification-failed") \
      unless read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts") == installed
  end
  blocks, = inspect_hosts(read_hosts_safely, session_id, remove: false)
  fail_safely("hosts-install-verification-failed") unless blocks == 1
  command_success?("/usr/bin/dscacheutil", "-flushcache") \
    or fail_safely("dns-cache-flush-failed")
  command_success?("/usr/bin/killall", "-HUP", "mDNSResponder") \
    or fail_safely("dns-responder-flush-failed")
end

def remove_hosts!(session_id, root_copy_directory)
  snapshot_path = root_snapshot_path(root_copy_directory, "hosts", session_id)
  unless root_snapshot_exists?(snapshot_path)
    blocks, = inspect_hosts(read_hosts_safely, session_id, remove: false)
    fail_safely("hosts-snapshot-missing-for-installed-block") unless blocks.zero?
    return false
  end
  payload = read_stable_path!(
    snapshot_path, uid: 0, maximum_size: MAX_HOSTS_BYTES + 4096,
    exact_mode: 0o400, purpose: "hosts-root-snapshot"
  )
  expected_metadata, original = decode_hosts_snapshot(payload)
  installed = hosts_installed_bytes(original, session_id)
  restored = false
  File.open(HOSTS_PATH, File::RDWR | File::NOFOLLOW) do |file|
    file.flock(File::LOCK_EX)
    validate_hosts_file!(file)
    current = read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts")
    current_metadata = capture_hosts_metadata!(file)
    fail_safely("hosts-metadata-drift-before-cleanup") \
      unless metadata_matches?(expected_metadata, current_metadata)
    if current == original
      restored = false
    elsif current == installed
      overwrite_open_file!(file, original)
      restored = true
    else
      fail_safely("hosts-concurrent-edit-refused")
    end
    fail_safely("hosts-cleanup-byte-verification-failed") \
      unless read_open_file_twice!(file, MAX_HOSTS_BYTES, "hosts") == original
    fail_safely("hosts-metadata-drift-after-cleanup") \
      unless metadata_matches?(expected_metadata, capture_hosts_metadata!(file))
  end
  blocks, = inspect_hosts(read_hosts_safely, session_id, remove: false)
  fail_safely("hosts-cleanup-verification-failed") unless blocks.zero?
  command_success?("/usr/bin/dscacheutil", "-flushcache") \
    or fail_safely("dns-cache-cleanup-flush-failed")
  command_success?("/usr/bin/killall", "-HUP", "mDNSResponder") \
    or fail_safely("dns-responder-cleanup-flush-failed")
  unlink_root_snapshot!(snapshot_path)
  restored
end

def certificate_present?(fingerprint)
  output, _error, status = run_capture(
    "/usr/bin/security", "find-certificate", "-a", "-Z", SYSTEM_KEYCHAIN
  )
  fail_safely("system-keychain-inspection-failed") unless status.success?
  output.lines.any? { |line| line.strip == "SHA-256 hash: #{fingerprint}" }
end

def admin_trust_present?(fingerprint)
  output, error, status = run_capture("/usr/bin/security", "dump-trust-settings", "-d")
  combined = "#{output}#{error}"
  unless status.success?
    return false if combined.include?("No Trust Settings were found.")
    fail_safely("admin-trust-inspection-failed")
  end
  combined.lines.any? { |line| line.strip == "SHA-256 hash: #{fingerprint}" }
end

def parse_exact_ca!(bytes, expected_fingerprint)
  certificate = OpenSSL::X509::Certificate.new(bytes)
  fail_safely("ca-pem-not-canonical") unless certificate.to_pem == bytes
  actual = OpenSSL::Digest::SHA256.hexdigest(certificate.to_der).upcase
  fail_safely("ca-fingerprint-mismatch") unless actual == expected_fingerprint
  fail_safely("ca-not-self-issued") unless certificate.subject == certificate.issuer
  fail_safely("ca-self-signature-invalid") unless certificate.verify(certificate.public_key)
  basic_constraints = certificate.extensions.find { |extension| extension.oid == "basicConstraints" }
  fail_safely("ca-basic-constraints-invalid") \
    unless basic_constraints && basic_constraints.critical? && basic_constraints.value.include?("CA:TRUE")
  certificate
rescue OpenSSL::OpenSSLError
  fail_safely("ca-certificate-invalid")
end

def install_ca!(ca_path, session_id, fingerprint, root_copy_directory, run_uid)
  canonical_owned_directory!(File.dirname(ca_path), run_uid, required_mode: 0o700)
  bytes = read_stable_path!(
    ca_path, uid: run_uid, maximum_size: MAX_CA_CERTIFICATE_BYTES,
    exact_mode: 0o600, purpose: "ca-import-source"
  )
  parse_exact_ca!(bytes, fingerprint)
  snapshot_path = root_snapshot_path(root_copy_directory, "ca", session_id)
  if root_snapshot_exists?(snapshot_path)
    existing = read_stable_path!(
      snapshot_path, uid: 0, maximum_size: MAX_CA_CERTIFICATE_BYTES,
      exact_mode: 0o400, purpose: "ca-root-snapshot"
    )
    fail_safely("ca-root-snapshot-mismatch") unless existing == bytes
  else
    write_root_snapshot!(snapshot_path, bytes)
  end
  if admin_trust_present?(fingerprint)
    fail_safely("ca-trust-without-keychain-certificate") unless certificate_present?(fingerprint)
    return
  end
  command_success?(
    "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
    "-k", SYSTEM_KEYCHAIN, snapshot_path
  ) or fail_safely("system-ca-trust-install-failed")
  fail_safely("admin-trust-install-verification-failed") unless admin_trust_present?(fingerprint)
  fail_safely("system-ca-install-verification-failed") unless certificate_present?(fingerprint)
end

def remove_ca!(session_id, fingerprint, root_copy_directory)
  snapshot_path = root_snapshot_path(root_copy_directory, "ca", session_id)
  snapshot_present = root_snapshot_exists?(snapshot_path)
  if snapshot_present
    bytes = read_stable_path!(
      snapshot_path, uid: 0, maximum_size: MAX_CA_CERTIFICATE_BYTES,
      exact_mode: 0o400, purpose: "ca-root-snapshot"
    )
    parse_exact_ca!(bytes, fingerprint)
  end
  trust_present = admin_trust_present?(fingerprint)
  fail_safely("ca-root-snapshot-missing-for-admin-trust") if trust_present && !snapshot_present
  trust_removed = false
  if trust_present
    command_success?("/usr/bin/security", "remove-trusted-cert", "-d", snapshot_path) \
      or fail_safely("admin-trust-remove-failed")
    trust_removed = true
  end
  fail_safely("admin-trust-remove-verification-failed") if admin_trust_present?(fingerprint)
  certificate_removed = false
  if certificate_present?(fingerprint)
    command_success?(
      "/usr/bin/security", "delete-certificate", "-t", "-Z", fingerprint, SYSTEM_KEYCHAIN
    ) or fail_safely("system-ca-delete-failed")
    certificate_removed = true
  end
  fail_safely("system-ca-delete-verification-failed") if certificate_present?(fingerprint)
  unlink_root_snapshot!(snapshot_path) if snapshot_present
  [trust_removed, certificate_removed]
end

def cleanup_system!(session_id, fingerprint, root_copy_directory)
  hosts_removed = nil
  trust_removed = nil
  certificate_removed = nil
  failures = []
  begin
    hosts_removed = remove_hosts!(session_id, root_copy_directory)
  rescue StandardError => error
    failures << ["hosts", error]
  end
  begin
    trust_removed, certificate_removed = remove_ca!(session_id, fingerprint, root_copy_directory)
  rescue StandardError => error
    failures << ["certificate", error]
  end
  unless failures.empty?
    reasons = failures.map do |component, error|
      reason = error.is_a?(SafetyError) ? error.code : error.class.name
      "#{component}:#{reason}"
    end
    $stderr.puts("loopback-cleanup: result=FAIL reasons=#{reasons.join(',')}")
    fail_safely("system-cleanup-incomplete")
  end
  $stderr.puts(
    "loopback-cleanup: result=PASS hosts_restored=#{hosts_removed} " \
    "admin_trust_removed=#{trust_removed} certificate_removed=#{certificate_removed}"
  )
end

def start_cleanup_guardian(listener, root_copy_directory)
  reader, writer = IO.pipe
  reader.close_on_exec = true
  writer.close_on_exec = true
  guardian_pid = fork do
    writer.close
    listener.close
    ARGV.clear
    ENV.clear
    ENV["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    ENV["LC_ALL"] = "C"
    ENV["LANG"] = "C"
    # The service owner closes the pipe in its ensure path. Ignore terminal
    # signals here so cleanup cannot be skipped by process-group delivery.
    ["HUP", "INT", "TERM"].each { |signal| Signal.trap(signal, "IGNORE") }
    result = 0
    begin
      configuration = reader.gets
      if configuration
        fields = configuration.chomp.split("\t", -1)
        fail_safely("guardian-invalid-configuration") \
          unless fields.length == 3 && fields[0] == "CONFIG" \
            && fields[1].match?(/\A[0-9a-f]{16}\z/) \
            && fields[2].match?(/\A[0-9A-F]{64}\z/)
        reader.read
        cleanup_system!(fields[1], fields[2], root_copy_directory)
      end
    rescue SafetyError
      result = 1
    rescue StandardError => error
      $stderr.puts("loopback-cleanup: result=FAIL reason=#{error.class}")
      result = 1
    ensure
      begin
        reader.close unless reader.closed?
      rescue StandardError => error
        $stderr.puts("loopback-cleanup: result=FAIL reason=#{error.class}")
        result = 1
      end
    end
    exit!(result)
  end
  reader.close
  [guardian_pid, writer]
end

def self_test_cleanup_primitives!(listener)
  session_id = "0123456789abcdef"
  begin_line, mapping_line, end_line = hosts_block_strings(session_id)
  baseline = "127.0.0.1 localhost\n"
  complete = hosts_installed_bytes(baseline, session_id)
  blocks, cleaned = inspect_hosts(complete, session_id, remove: true)
  fail_safely("cleanup-structure-self-test-failed") unless blocks == 1 && cleaned == baseline
  _mutated_blocks, mutated_cleaned = inspect_hosts("#{complete}# concurrent edit\n", session_id, remove: true)
  fail_safely("cleanup-concurrent-edit-self-test-failed") if mutated_cleaned == baseline
  metadata = HOSTS_METADATA_KEYS.each_with_object({}) { |key, values| values[key] = "0" }
  decoded_metadata, decoded_baseline = decode_hosts_snapshot(encode_hosts_snapshot(metadata, baseline))
  fail_safely("cleanup-snapshot-roundtrip-self-test-failed") \
    unless decoded_metadata == metadata && decoded_baseline == baseline
  begin
    inspect_hosts("#{baseline}#{begin_line}\nremaining-data\n", session_id, remove: true)
    fail_safely("cleanup-partial-block-self-test-failed")
  rescue SafetyError => error
    raise unless error.code == "hosts-partial-session-block"
  end
  guardian_pid, guardian_writer = start_cleanup_guardian(listener, "")
  guardian_writer.close
  _pid, guardian_status = Process.wait2(guardian_pid)
  fail_safely("cleanup-guardian-exit-self-test-failed") unless guardian_status.success?
  $stdout.puts("loopback: cleanup-structure-and-guardian-exit-self-test=PASS")
end

def drop_root_privileges!(uid, gid)
  Process.groups = []
  Process::GID.change_privilege(gid)
  Process::UID.change_privilege(uid)
  fail_safely("privilege-drop-id-mismatch") \
    unless Process.uid == uid && Process.euid == uid \
      && Process.gid == gid && Process.egid == gid
  fail_safely("privilege-drop-supplementary-groups-remain") unless Process.groups.empty?
end

def canonical_owned_directory!(path, uid, required_mode: nil)
  fail_safely("directory-path-not-absolute") unless path.start_with?("/")
  stat = File.lstat(path)
  fail_safely("directory-is-symbolic") if stat.symlink?
  fail_safely("directory-not-directory") unless stat.directory?
  fail_safely("directory-owner-mismatch") unless stat.uid == uid
  fail_safely("directory-writable-by-others") unless (stat.mode & 0o022).zero?
  fail_safely("directory-mode-mismatch") if required_mode && (stat.mode & 0o777) != required_mode
  fail_safely("directory-path-not-canonical") unless File.realpath(path) == path
  path
rescue Errno::ENOENT, Errno::EACCES
  fail_safely("directory-unavailable")
end

def read_fixture_from_same_fd(directory, basename, uid, maximum_size)
  safe_basename!(basename, "fixture-unsafe-basename")
  path = File.join(directory, basename)
  read_stable_path!(
    path, uid: uid, maximum_size: maximum_size, purpose: "fixture"
  ).freeze
end

CaseData = Struct.new(:label, :feed, :archive, :feed_sha256, :archive_sha256, keyword_init: true)
CasesSnapshot = Struct.new(
  :cases, :manifest_sha256, :checksums_sha256, keyword_init: true
)

def snapshot_case(directory, label, feed_name, archive_name, uid, strict_entries: false)
  canonical_owned_directory!(directory, uid)
  before_stat = File.lstat(directory)
  before_entries = Dir.children(directory).sort
  if strict_entries
    expected = [feed_name, archive_name].sort
    fail_safely("case-directory-layout-invalid") unless before_entries == expected
  end
  feed = read_fixture_from_same_fd(directory, feed_name, uid, MAX_FEED_BYTES)
  archive = read_fixture_from_same_fd(directory, archive_name, uid, MAX_ARCHIVE_BYTES)
  after_stat = File.lstat(directory)
  fail_safely("case-directory-changed-during-snapshot") \
    unless before_entries == Dir.children(directory).sort \
      && stat_stability_tuple(before_stat) == stat_stability_tuple(after_stat)
  CaseData.new(
    label: label,
    feed: feed,
    archive: archive,
    feed_sha256: sha256_bytes(feed),
    archive_sha256: sha256_bytes(archive)
  )
end

def snapshot_cases(fixtures_directory, cases_directory, initial_case, feed_name, archive_name, uid)
  safe_label!(initial_case, "initial-case-invalid")
  safe_basename!(feed_name, "feed-basename-invalid")
  safe_basename!(archive_name, "archive-basename-invalid")
  fail_safely("fixture-basenames-collide") if feed_name == archive_name
  cases = {}
  if !fixtures_directory.empty?
    cases[initial_case] = snapshot_case(
      canonical_owned_directory!(fixtures_directory, uid),
      initial_case, feed_name, archive_name, uid
    )
    return CasesSnapshot.new(
      cases: cases.freeze, manifest_sha256: "diagnostic-single-fixture",
      checksums_sha256: "diagnostic-single-fixture"
    )
  else
    root = canonical_owned_directory!(cases_directory, uid)
    root_before = File.lstat(root)
    entries = Dir.children(root).sort
    expected_entries = (EXPECTED_CASE_LABELS + CASES_ROOT_METADATA).sort
    fail_safely("cases-root-layout-invalid") unless entries == expected_entries
    manifest_bytes = read_fixture_from_same_fd(
      root, "fixture-manifest.json", uid, MAX_FEED_BYTES
    )
    checksums_bytes = read_fixture_from_same_fd(
      root, "SHA256SUMS.txt", uid, MAX_FEED_BYTES
    )
    EXPECTED_CASE_LABELS.each do |label|
      directory = File.join(root, label)
      cases[label] = snapshot_case(
        directory, label, feed_name, archive_name, uid, strict_entries: true
      )
    end
    root_after = File.lstat(root)
    fail_safely("cases-root-changed-during-snapshot") \
      unless entries == Dir.children(root).sort \
        && stat_stability_tuple(root_before) == stat_stability_tuple(root_after)
    fail_safely("initial-case-absent") unless cases.key?(initial_case)

    expected_checksum_paths = EXPECTED_CASE_LABELS.flat_map do |label|
      ["#{label}/#{feed_name}", "#{label}/#{archive_name}"]
    end
    expected_checksum_paths << "fixture-manifest.json"
    checksum_rows = {}
    checksums_bytes.lines(chomp: true).each do |line|
      match = line.match(/\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._\/-]*)\z/)
      fail_safely("fixture-checksums-row-invalid") unless match
      path = match[2]
      fail_safely("fixture-checksums-path-invalid") \
        if path.split("/").any? { |component| component.empty? || [".", ".."].include?(component) }
      fail_safely("fixture-checksums-duplicate-path") if checksum_rows.key?(path)
      checksum_rows[path] = match[1]
    end
    fail_safely("fixture-checksums-allowlist-invalid") \
      unless checksum_rows.keys.sort == expected_checksum_paths.sort
    EXPECTED_CASE_LABELS.each do |label|
      item = cases.fetch(label)
      fail_safely("fixture-checksums-feed-mismatch") \
        unless checksum_rows.fetch("#{label}/#{feed_name}") == item.feed_sha256
      fail_safely("fixture-checksums-archive-mismatch") \
        unless checksum_rows.fetch("#{label}/#{archive_name}") == item.archive_sha256
    end
    manifest_sha256 = sha256_bytes(manifest_bytes)
    fail_safely("fixture-checksums-manifest-mismatch") \
      unless checksum_rows.fetch("fixture-manifest.json") == manifest_sha256

    begin
      manifest = JSON.parse(manifest_bytes, object_class: DuplicateRejectingHash)
    rescue JSON::ParserError, DuplicateJSONKeyError
      fail_safely("fixture-manifest-json-invalid")
    end
    fail_safely("fixture-manifest-root-invalid") unless manifest.is_a?(Hash)
    expected_manifest_keys = %w[
      advertisedTarget candidateInputs fixtures invariants purpose requests
      reviewedSources schemaVersion source tools
    ].sort
    fail_safely("fixture-manifest-schema-invalid") \
      unless manifest.keys.sort == expected_manifest_keys \
        && manifest["schemaVersion"] == 2 \
        && manifest["purpose"] == "isolated Ushot 0.1.3 to 0.1.4 update-transition evidence"
    fail_safely("fixture-manifest-source-invalid") \
      unless manifest["source"] == { "version" => "0.1.3", "build" => "4" }
    fail_safely("fixture-manifest-target-invalid") \
      unless manifest["advertisedTarget"] == {
        "version" => "0.1.4", "build" => "5", "tag" => "v0.1.4"
      }
    fail_safely("fixture-manifest-requests-invalid") \
      unless manifest["requests"] == {
        "appcastURL" => "https://#{FEED_HOST}#{FEED_ROUTE}",
        "enclosureURL" => "https://#{ARCHIVE_HOST}#{ARCHIVE_ROUTE}"
      }

    expected_tools = {
      "sparkleVersion" => "2.9.5",
      "sparkleReleaseArchiveSHA256" => EXPECTED_SPARKLE_ARCHIVE_SHA256,
      "sparkleGenerateAppcastSHA256" => EXPECTED_GENERATE_APPCAST_SHA256,
      "sparkleGenerateKeysSHA256" => EXPECTED_GENERATE_KEYS_SHA256,
      "sparkleSignUpdateSHA256" => EXPECTED_SIGN_UPDATE_SHA256,
      "authenticatedAppcastValidatorSHA256" => EXPECTED_AUTHENTICATED_APPCAST_VALIDATOR_SHA256,
      "publicKeyDeriverSHA256" => EXPECTED_PUBLIC_KEY_DERIVER_SHA256,
      "embeddedPublicKeyVerifierSHA256" => EXPECTED_EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256,
      "keySource" => "keychain",
      "signingPublicKeyIdentityVerified" => true,
      "keyAccount" => "io.github.ischeneycc.ushot.20260806",
      "publicKeyFingerprintSHA256" => EXPECTED_PUBLIC_KEY_FINGERPRINT_SHA256,
      "archiveAndFeedVerification" => "independent embedded-public-key verifier"
    }
    fail_safely("fixture-manifest-tools-invalid") unless manifest["tools"] == expected_tools

    expected_reviewed_sources = {
      "externalReviewedSourceManifestSHA256" => EXPECTED_REVIEWED_SOURCE_MANIFEST_SHA256,
      "frozenBundleManifestSHA256" => EXPECTED_FROZEN_BUNDLE_MANIFEST_SHA256,
      "fixtureScriptSHA256" => EXPECTED_FIXTURE_SCRIPT_SHA256,
      "releaseCommonSHA256" => EXPECTED_RELEASE_COMMON_SHA256,
      "validateAppcastSHA256" => EXPECTED_VALIDATE_APPCAST_SHA256
    }
    fail_safely("fixture-manifest-reviewed-sources-invalid") \
      unless manifest["reviewedSources"] == expected_reviewed_sources

    expected_candidate_inputs = {
      "exactAssetCount" => EXPECTED_CANDIDATE_ASSETS.length,
      "assets" => EXPECTED_CANDIDATE_ASSETS,
      "releaseNotesSHA256" => EXPECTED_RELEASE_NOTES_SHA256
    }
    fail_safely("fixture-manifest-candidate-inputs-invalid") \
      unless manifest["candidateInputs"] == expected_candidate_inputs
    expected_invariants = {
      "privateKeyWrittenByThisScript" => false,
      "deployedOrPublished" => false,
      "outputMode" => "0700",
      "archiveName" => "Ushot-0.1.4-arm64.zip"
    }
    fail_safely("fixture-manifest-invariants-invalid") \
      unless manifest["invariants"] == expected_invariants

    fixtures = manifest["fixtures"]
    fail_safely("fixture-manifest-cases-invalid") \
      unless fixtures.is_a?(Array) && fixtures.length == EXPECTED_CASE_SEQUENCE.length \
        && fixtures.map { |fixture| fixture.is_a?(Hash) ? fixture["name"] : nil } \
          == EXPECTED_CASE_SEQUENCE
    fixtures_by_name = {}
    fixtures.each do |fixture|
      fail_safely("fixture-manifest-case-invalid") unless fixture.is_a?(Hash)
      label = fixture["name"]
      fail_safely("fixture-manifest-case-name-invalid") \
        unless label.is_a?(String) && EXPECTED_CASE_LABELS.include?(label) \
          && !fixtures_by_name.key?(label)
      feed = fixture["feed"]
      archive = fixture["archive"]
      item = cases.fetch(label)
      fail_safely("fixture-manifest-feed-binding-invalid") \
        unless feed.is_a?(Hash) \
          && feed["path"] == "#{label}/#{feed_name}" \
          && feed["sha256"] == item.feed_sha256
      fail_safely("fixture-manifest-archive-binding-invalid") \
        unless archive.is_a?(Hash) \
          && archive["path"] == "#{label}/#{archive_name}" \
          && archive["sha256"] == item.archive_sha256
      fixtures_by_name[label] = fixture
    end
    fail_safely("fixture-manifest-case-allowlist-invalid") \
      unless fixtures_by_name.keys.sort == EXPECTED_CASE_LABELS

    verified_feed = lambda do |label, policy = "accepted", extra = {}|
      {
        "path" => "#{label}/#{feed_name}",
        "sha256" => cases.fetch(label).feed_sha256,
        "edDSA" => "verified",
        "authenticatedXMLPolicy" => policy
      }.merge(extra)
    end
    verified_archive = lambda do |label, version, build|
      {
        "path" => "#{label}/#{archive_name}",
        "sha256" => cases.fetch(label).archive_sha256,
        "edDSA" => "verified",
        "bundleVersion" => version,
        "bundleBuild" => build
      }
    end
    expected_fixed_fixtures = [
      {
        "name" => "normal",
        "feed" => verified_feed.call("normal"),
        "archive" => verified_archive.call("normal", "0.1.4", "5"),
        "expectedClientResult" => "atomic replacement and relaunch"
      },
      {
        "name" => "tampered-archive",
        "feed" => verified_feed.call("tampered-archive"),
        "archive" => {
          "path" => "tampered-archive/#{archive_name}",
          "sha256" => cases.fetch("tampered-archive").archive_sha256,
          "edDSA" => "rejection-proven",
          "sameByteLengthAsNormal" => true,
          "bundleVersion" => "0.1.4",
          "bundleBuild" => "5",
          "bundleAdHocSignature" => "verified-after-final-archive-extraction"
        },
        "expectedClientResult" => "archive EdDSA rejection before extraction"
      },
      {
        "name" => "short-version-mismatch",
        "feed" => verified_feed.call("short-version-mismatch"),
        "archive" => verified_archive.call("short-version-mismatch", "0.1.5", "5"),
        "expectedClientResult" => "post-extraction exact-version rejection"
      },
      {
        "name" => "build-number-mismatch",
        "feed" => verified_feed.call("build-number-mismatch"),
        "archive" => verified_archive.call("build-number-mismatch", "0.1.4", "6"),
        "expectedClientResult" => "post-extraction exact-build rejection"
      },
      {
        "name" => "short-and-build-mismatch",
        "feed" => verified_feed.call("short-and-build-mismatch"),
        "archive" => verified_archive.call("short-and-build-mismatch", "0.1.5", "6"),
        "expectedClientResult" => "post-extraction exact-version-and-build rejection"
      },
      {
        "name" => "duplicate-build-metadata",
        "feed" => verified_feed.call(
          "duplicate-build-metadata", "rejection-proven",
          { "rejectionCategory" => "invalid-version-identity" }
        ),
        "archive" => verified_archive.call("duplicate-build-metadata", "0.1.4", "5"),
        "expectedClientResult" => "authenticated raw-XML rejection before item parsing"
      }
    ]
    fail_safely("fixture-manifest-fixed-case-contract-invalid") \
      unless fixtures.first(expected_fixed_fixtures.length) == expected_fixed_fixtures

    normal_item = cases.fetch("normal")
    candidate_archive = EXPECTED_CANDIDATE_ASSETS.find do |asset|
      asset.fetch("name") == archive_name
    end
    fail_safely("fixture-manifest-candidate-archive-allowlist-invalid") \
      unless candidate_archive
    fail_safely("fixture-manifest-normal-candidate-binding-invalid") \
      unless normal_item.archive_sha256 == candidate_archive.fetch("sha256")
    %w[duplicate-build-metadata oversized-signed-feed].each do |label|
      fail_safely("fixture-manifest-candidate-archive-reuse-invalid") \
        unless cases.fetch(label).archive == normal_item.archive
    end
    tampered_item = cases.fetch("tampered-archive")
    fail_safely("fixture-manifest-tampered-archive-shape-invalid") \
      unless tampered_item.archive.bytesize == normal_item.archive.bytesize \
        && tampered_item.archive_sha256 != normal_item.archive_sha256
    oversized_item = cases.fetch("oversized-signed-feed")
    oversized_fixture = fixtures_by_name.fetch("oversized-signed-feed")
    oversized_feed = oversized_fixture.fetch("feed")
    fail_safely("fixture-manifest-wire-ceiling-invalid") \
      unless oversized_fixture.keys.sort == %w[
        archive expectedClientResults feed name
      ].sort \
        && oversized_fixture["name"] == "oversized-signed-feed" \
        && oversized_feed.keys.sort == %w[
        authenticatedPrefixBytes authenticatedXMLPolicy edDSA
        loopbackMaximumFeedBytes maximumAuthenticatedPrefixBytes
        maximumSignedFeedWireBytes path rejectionCategory sha256
        signedFeedBytes verificationMode
      ].sort \
        && oversized_feed["edDSA"] == "verified" \
        && oversized_feed["verificationMode"] == "cryptographic-only-2MiB" \
        && oversized_feed["authenticatedXMLPolicy"] == "rejection-proven" \
        && oversized_feed["rejectionCategory"] == "oversized-signed-feed" \
        && oversized_feed["maximumAuthenticatedPrefixBytes"] == MAX_AUTHENTICATED_PREFIX_BYTES \
        && oversized_feed["authenticatedPrefixBytes"].is_a?(Integer) \
        && oversized_feed["authenticatedPrefixBytes"] > MAX_AUTHENTICATED_PREFIX_BYTES \
        && oversized_feed["signedFeedBytes"].is_a?(Integer) \
        && oversized_feed["signedFeedBytes"] \
          == oversized_feed["authenticatedPrefixBytes"] + SIGNED_FEED_TRAILER_BYTES \
        && oversized_feed["signedFeedBytes"] == oversized_item.feed.bytesize \
        && oversized_feed["maximumSignedFeedWireBytes"] == SIGNED_FEED_WIRE_CEILING_BYTES \
        && oversized_item.feed.bytesize > SIGNED_FEED_WIRE_CEILING_BYTES \
        && oversized_feed["loopbackMaximumFeedBytes"] == MAX_FEED_BYTES \
        && oversized_fixture["archive"] \
          == verified_archive.call("oversized-signed-feed", "0.1.4", "5") \
        && oversized_fixture["expectedClientResults"] == {
          "contentLength" => \
            "declared Content-Length rejection before body acceptance or XML parsing",
          "chunked" => \
            "incremental wire-size rejection before signed-feed or XML parsing"
        }

    return CasesSnapshot.new(
      cases: cases.freeze,
      manifest_sha256: manifest_sha256,
      checksums_sha256: sha256_bytes(checksums_bytes)
    )
  end
end

def create_workspace(uid)
  root = File.realpath("/tmp")
  workspace = Dir.mktmpdir("ushot-update-transition-loopback.", root)
  File.chmod(0o700, workspace)
  canonical_owned_directory!(workspace, uid, required_mode: 0o700)
end

def remove_workspace(workspace, uid)
  return if workspace.nil? || !File.exist?(workspace)
  stat = File.lstat(workspace)
  fail_safely("workspace-cleanup-identity-changed") \
    unless stat.directory? && !stat.symlink? && stat.uid == uid \
      && (stat.mode & 0o777) == 0o700 \
      && File.basename(workspace).start_with?("ushot-update-transition-loopback.") \
      && File.dirname(workspace) == File.realpath("/tmp")
  FileUtils.remove_entry_secure(workspace)
end

def write_workspace_file(path, bytes)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
    written = file.write(bytes)
    fail_safely("workspace-file-short-write") unless written == bytes.bytesize
    file.flush
    file.fsync
  end
  stat = File.lstat(path)
  fail_safely("workspace-file-permission-failure") \
    unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600
end

def build_certificates(workspace, session_id)
  ca_certificate_path = File.join(workspace, "ca-certificate.pem")
  server_certificate_path = File.join(workspace, "server-certificate.pem")

  ca_key = OpenSSL::PKey::RSA.new(3072)
  ca_name = OpenSSL::X509::Name.parse("/CN=Ushot Update Transition Test Root #{session_id}")
  ca_certificate = OpenSSL::X509::Certificate.new
  ca_certificate.version = 2
  ca_certificate.serial = SecureRandom.random_number(2**127 - 1) + 1
  ca_certificate.subject = ca_name
  ca_certificate.issuer = ca_name
  ca_certificate.public_key = ca_key.public_key
  ca_certificate.not_before = Time.now - 60
  ca_certificate.not_after = Time.now + (2 * 24 * 60 * 60)
  ca_extensions = OpenSSL::X509::ExtensionFactory.new
  ca_extensions.subject_certificate = ca_certificate
  ca_extensions.issuer_certificate = ca_certificate
  ca_certificate.add_extension(ca_extensions.create_extension("basicConstraints", "CA:TRUE,pathlen:0", true))
  ca_certificate.add_extension(ca_extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
  ca_certificate.add_extension(ca_extensions.create_extension("subjectKeyIdentifier", "hash", false))
  ca_certificate.sign(ca_key, OpenSSL::Digest::SHA256.new)

  server_key = OpenSSL::PKey::RSA.new(2048)
  server_certificate = OpenSSL::X509::Certificate.new
  server_certificate.version = 2
  server_certificate.serial = SecureRandom.random_number(2**127 - 1) + 1
  server_certificate.subject = OpenSSL::X509::Name.parse("/CN=#{FEED_HOST}")
  server_certificate.issuer = ca_certificate.subject
  server_certificate.public_key = server_key.public_key
  server_certificate.not_before = Time.now - 60
  server_certificate.not_after = Time.now + (2 * 24 * 60 * 60)
  server_extensions = OpenSSL::X509::ExtensionFactory.new
  server_extensions.subject_certificate = server_certificate
  server_extensions.issuer_certificate = ca_certificate
  server_certificate.add_extension(server_extensions.create_extension("basicConstraints", "CA:FALSE", true))
  server_certificate.add_extension(server_extensions.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
  server_certificate.add_extension(server_extensions.create_extension("extendedKeyUsage", "serverAuth", false))
  server_certificate.add_extension(server_extensions.create_extension(
    "subjectAltName", "DNS:#{FEED_HOST},DNS:#{ARCHIVE_HOST}", false
  ))
  server_certificate.add_extension(server_extensions.create_extension("authorityKeyIdentifier", "keyid,issuer", false))
  server_certificate.sign(ca_key, OpenSSL::Digest::SHA256.new)

  ca_key = nil
  write_workspace_file(ca_certificate_path, ca_certificate.to_pem)
  write_workspace_file(server_certificate_path, server_certificate.to_pem)
  fail_safely("server-key-public-mismatch") \
    unless server_key.public_key.to_der == server_certificate.public_key.to_der

  store = OpenSSL::X509::Store.new
  store.add_cert(ca_certificate)
  fail_safely("server-certificate-chain-invalid") unless store.verify(server_certificate)
  fingerprint = OpenSSL::Digest::SHA256.hexdigest(ca_certificate.to_der).upcase
  parse_exact_ca!(ca_certificate.to_pem, fingerprint)
  [ca_certificate_path, server_certificate_path, server_certificate, server_key, fingerprint]
end

class ServiceFatalState
  def initialize(owner_thread)
    @owner_thread = owner_thread
    @mutex = Mutex.new
    @failure = nil
    @shutting_down = false
  end

  def capture(error, context)
    notify = false
    @mutex.synchronize do
      unless @failure
        reason = error.is_a?(SafetyError) ? error.code : error.class.name
        @failure = "#{context}:#{reason}"
        notify = !@shutting_down
      end
    end
    $stderr.puts("loopback: fatal-service-state reason=#{failure_reason}") if notify
    if notify && Thread.current != @owner_thread && @owner_thread.alive?
      @owner_thread.raise(SafetyError.new("asynchronous-service-failure"))
    end
    false
  rescue ThreadError
    false
  end

  def check!
    reason = failure_reason
    fail_safely("service-fatal-state") if reason
  end

  def begin_shutdown
    @mutex.synchronize { @shutting_down = true }
  end

  def shutting_down?
    @mutex.synchronize { @shutting_down }
  end

  def failed?
    !failure_reason.nil?
  end

  def failure_reason
    @mutex.synchronize { @failure }
  end
end

class EvidenceWriter
  def initialize(
    path, uid, session_id, script_sha256, ca_sha256, cases_snapshot, port
  )
    @mutex = Mutex.new
    @sequence = 0
    @file = nil
    return if path.empty?
    fail_safely("evidence-path-not-absolute") unless path.start_with?("/")
    parent = canonical_owned_directory!(File.dirname(path), uid, required_mode: 0o700)
    expected = File.join(parent, File.basename(path))
    fail_safely("evidence-path-not-canonical") unless expected == path
    fail_safely("evidence-target-already-exists") if File.exist?(path) || File.symlink?(path)
    @file = File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
    stat = @file.stat
    fail_safely("evidence-file-identity-invalid") \
      unless stat.file? && stat.uid == uid && stat.nlink == 1 && (stat.mode & 0o777) == 0o600
    write_row("schema", "ushot-update-transition-loopback-corroborating-v2")
    write_row("evidence_role", "corroborating-only")
    write_row("evidence_limitation", "same-uid-file-and-probe-header-are-forgeable")
    write_row("session_id", session_id)
    write_row("started_at_utc", Time.now.utc.iso8601(6))
    write_row("script_sha256", script_sha256)
    write_row("test_ca_sha256", ca_sha256)
    write_row("listener_address", "127.0.0.1")
    write_row("listener_port", port)
    write_row("exact_system_probe_required", port == 443 ? "true" : "false")
    write_row("fixture_manifest_sha256", cases_snapshot.manifest_sha256)
    write_row("fixture_checksums_sha256", cases_snapshot.checksums_sha256)
    cases = cases_snapshot.cases
    cases.keys.sort.each do |label|
      item = cases.fetch(label)
      write_row("case", label, item.feed_sha256, item.archive_sha256)
    end
    write_row(
      "columns", "kind", "sequence", "utc", "generation", "case", "feed_mode",
      "actor", "route", "method", "status", "bytes", "outcome"
    )
  end

  def event(generation:, case_label:, feed_mode:, actor:, route:, method:, status:, bytes:, outcome:)
    return unless @file
    @mutex.synchronize do
      @sequence += 1
      write_row(
        "event", @sequence, Time.now.utc.iso8601(6), generation, case_label,
        feed_mode, actor, route, method, status, bytes, outcome
      )
    end
  end

  def lifecycle(route, outcome)
    event(
      generation: 0, case_label: "-", feed_mode: "-", actor: "service",
      route: route, method: "-", status: 0, bytes: 0, outcome: outcome
    )
  end

  def close
    return unless @file
    @mutex.synchronize do
      @file.flush
      @file.fsync
      @file.close
      @file = nil
    end
  end

  private

  def write_row(*fields)
    fields.each do |field|
      fail_safely("evidence-field-not-safe") if field.to_s.match?(/[\t\r\n]/)
    end
    row = "#{fields.join("\t")}\n"
    written = @file.write(row)
    fail_safely("evidence-short-write") unless written == row.bytesize
    @file.flush
    @file.fsync
  end
end

class ActiveCaseState
  attr_reader :cases

  def initialize(cases, initial_case, feed_mode, evidence)
    @cases = cases
    @case_label = initial_case
    @feed_mode = feed_mode
    @generation = 1
    @active_requests = 0
    @generation_completed = false
    @probe_completions = {}
    @mutex = Mutex.new
    @evidence = evidence
    record_snapshot("session-start", [@case_label, @generation, @feed_mode], "service")
  end

  def snapshot_for_request(actor)
    @mutex.synchronize do
      @active_requests += 1
      @generation_completed = false if actor == "client"
      [@cases.fetch(@case_label), @generation, @feed_mode]
    end
  end

  def finish_request
    @mutex.synchronize do
      fail_safely("request-owner-underflow") unless @active_requests.positive?
      @active_requests -= 1
    end
  end

  def record_probe_completion(token, generation, label, mode, route, bytes, outcome)
    fail_safely("probe-token-invalid") unless token.match?(/\A[0-9a-f]{32}\z/)
    @mutex.synchronize do
      records = (@probe_completions[token] ||= [])
      fail_safely("probe-route-duplicate") if records.any? { |record| record[3] == route }
      records << [generation, label, mode, route, bytes, outcome]
    end
  end

  def consume_probe!(token, generation, label, mode, expected_sizes)
    records = @mutex.synchronize { @probe_completions.delete(token) }
    fail_safely("probe-service-receipt-missing") unless records.is_a?(Array)
    fail_safely("probe-service-receipt-count-invalid") unless records.length == 2
    records.each do |record_generation, record_label, record_mode, route, bytes, outcome|
      fail_safely("probe-service-receipt-binding-invalid") \
        unless record_generation == generation && record_label == label \
          && record_mode == mode && expected_sizes.key?(route) \
          && bytes == expected_sizes.fetch(route) && outcome == "COMPLETE"
    end
    fail_safely("probe-service-route-set-invalid") \
      unless records.map { |record| record[3] }.sort == expected_sizes.keys.sort
  end

  def current
    @mutex.synchronize do
      [@case_label, @generation, @feed_mode, @active_requests, @generation_completed]
    end
  end

  def complete_generation(generation)
    result = @mutex.synchronize do
      return [:busy, @active_requests] unless @active_requests.zero?
      return [:wrong_generation, @generation] unless generation == @generation
      return [:unchanged, @generation] if @generation_completed
      @generation_completed = true
      [:completed, @generation]
    end
    record_control("generation-complete")
    result
  end

  def switch_case(label)
    result = @mutex.synchronize do
      return [:busy, @active_requests] unless @active_requests.zero?
      return [:unknown, 0] unless @cases.key?(label)
      return [:unchanged, 0] if @case_label == label
      return [:incomplete, @generation] unless @generation_completed
      @case_label = label
      @generation += 1
      @generation_completed = false
      [:changed, 0]
    end
    record_control("case-switch")
    result
  end

  def switch_mode(mode)
    result = @mutex.synchronize do
      return [:busy, @active_requests] unless @active_requests.zero?
      return [:unknown, 0] unless ["normal", "chunked"].include?(mode)
      return [:unchanged, 0] if @feed_mode == mode
      return [:incomplete, @generation] unless @generation_completed
      @feed_mode = mode
      @generation += 1
      @generation_completed = false
      [:changed, 0]
    end
    record_control("mode-switch")
    result
  end


  def record_exact_system_probe
    snapshot = @mutex.synchronize { [@case_label, @generation, @feed_mode] }
    record_snapshot("exact-system-probe", snapshot, "service")
  end

  private

  def record_control(route)
    snapshot = @mutex.synchronize { [@case_label, @generation, @feed_mode] }
    record_snapshot(route, snapshot, "operator")
  end

  def record_snapshot(route, snapshot, actor)
    case_label, generation, feed_mode = snapshot
    @evidence.event(
      generation: generation, case_label: case_label, feed_mode: feed_mode,
      actor: actor, route: route, method: "-", status: 0, bytes: 0, outcome: "PASS"
    )
  end
end

def client_disconnect_error?(error)
  current = error
  6.times do
    return true if current.is_a?(Errno::EPIPE) || current.is_a?(Errno::ECONNRESET)
    if current.is_a?(IOError) || current.is_a?(OpenSSL::SSL::SSLError)
      return true if current.message.match?(/broken pipe|connection reset|closed stream|socket is not connected/i)
    end
    current = current.cause
    break unless current
  end
  false
end

def write_counted_body!(output, body)
  offset = 0
  while offset < body.bytesize
    chunk = body.byteslice(offset, [16_384, body.bytesize - offset].min)
    chunk_offset = 0
    while chunk_offset < chunk.bytesize
      piece = chunk.byteslice(chunk_offset, chunk.bytesize - chunk_offset)
      written = output.write(piece)
      fail_safely("response-write-made-no-progress") \
        unless written.is_a?(Integer) && written.positive? && written <= piece.bytesize
      yield written
      chunk_offset += written
      offset += written
    end
  end
  offset
end

def configure_response(server, state, evidence, session_id, fatal_state)
  server.mount_proc("/") do |request, response|
    method = request.request_method.to_s
    host = request["host"].to_s.sub(/:\d+\z/, "").downcase
    route = if host == FEED_HOST && request.path == FEED_ROUTE
      "feed"
    elsif host == ARCHIVE_HOST && request.path == ARCHIVE_ROUTE
      "archive"
    else
      "unmatched"
    end
    probe_value = request["x-ushot-loopback-probe"].to_s
    probe_match = probe_value.match(/\A#{Regexp.escape(session_id)}:([0-9a-f]{32})\z/)
    probe_token = probe_match && probe_match[1]
    actor = probe_token ? "claimed-internal" : "client"
    response["Cache-Control"] = "no-store"
    response["X-Content-Type-Options"] = "nosniff"

    unless ["GET", "HEAD"].include?(method)
      label, generation, feed_mode, = state.current
      response.status = 405
      response["Allow"] = "GET, HEAD"
      response["Content-Type"] = "text/plain"
      response.body = "Method Not Allowed\n"
      evidence.event(
        generation: generation, case_label: label, feed_mode: feed_mode,
        actor: actor, route: route, method: "other", status: 405,
        bytes: response.body.bytesize, outcome: "PASS"
      )
      next
    end

    if route == "unmatched"
      label, generation, feed_mode, = state.current
      response.status = 404
      response["Content-Type"] = "text/plain"
      response.body = "Not Found\n"
      evidence.event(
        generation: generation, case_label: label, feed_mode: feed_mode,
        actor: actor, route: route, method: method, status: 404,
        bytes: response.body.bytesize, outcome: "PASS"
      )
      next
    end

    item, generation, feed_mode = state.snapshot_for_request(actor)
    body = route == "feed" ? item.feed : item.archive
    response.status = 200
    response["Content-Type"] = route == "feed" ? "application/xml" : "application/zip"
    if route == "feed" && feed_mode == "chunked"
      response.chunked = true
      response.header.delete("content-length")
    else
      response.chunked = false
      response["Content-Length"] = body.bytesize.to_s
    end

    record_completion = proc do |actual_bytes, outcome|
      begin
        evidence.event(
          generation: generation, case_label: item.label, feed_mode: feed_mode,
          actor: actor, route: route, method: method, status: 200,
          bytes: actual_bytes, outcome: outcome
        )
        if probe_token
          state.record_probe_completion(
            probe_token, generation, item.label, feed_mode, route,
            actual_bytes, outcome
          )
        end
      ensure
        state.finish_request
      end
      $stderr.puts(
        "loopback: request generation=#{generation} case=#{item.label} mode=#{feed_mode} " \
        "actor=#{actor} route=#{route} method=#{method} status=200 bytes=#{actual_bytes} outcome=#{outcome}"
      )
    end

    if method == "HEAD"
      response.body = ""
      record_completion.call(0, "COMPLETE")
    else
      response.body = proc do |output|
        actual_bytes = 0
        outcome = "COMPLETE"
        failure = nil
        begin
          write_counted_body!(output, body) { |written| actual_bytes += written }
        rescue StandardError => error
          if client_disconnect_error?(error)
            outcome = if item.label == "oversized-signed-feed" && route == "feed"
              if feed_mode == "normal"
                "CLIENT_CLOSED_AFTER_HEADERS"
              elsif actual_bytes >= SIGNED_FEED_WIRE_CEILING_BYTES
                "CLIENT_CLOSED_AT_LIMIT"
              else
                "CLIENT_CLOSED_EARLY"
              end
            else
              "CLIENT_CLOSED_EARLY"
            end
          else
            outcome = "ERROR"
            failure = error
            fatal_state.capture(error, "response-write")
          end
        ensure
          begin
            record_completion.call(actual_bytes, outcome)
          rescue StandardError => completion_error
            failure ||= completion_error
            fatal_state.capture(completion_error, "request-completion")
          end
        end
        raise failure if failure
      end
    end
  rescue SafetyError => error
    fatal_state.capture(error, "request-handler")
    response.status = 500
    response["Content-Type"] = "text/plain"
    response.body = "Internal Server Error\n"
    $stderr.puts("loopback: request result=FAIL reason=#{error.code}")
  rescue StandardError => error
    fatal_state.capture(error, "request-handler")
    response.status = 500
    response["Content-Type"] = "text/plain"
    response.body = "Internal Server Error\n"
    $stderr.puts("loopback: request result=FAIL class=#{error.class}")
  end
end

def url_for(host, route, port)
  port == 443 ? "https://#{host}#{route}" : "https://#{host}:#{port}#{route}"
end

def curl_probe(
  host:, route:, port:, ca_path:, session_id:, probe_token:, workspace:, exact:, suffix:
)
  fail_safely("probe-suffix-invalid") unless suffix.match?(/\A[A-Za-z0-9._-]+\z/)
  fail_safely("probe-token-invalid") unless probe_token.match?(/\A[0-9a-f]{32}\z/)
  canonical_owned_directory!(workspace, Process.uid, required_mode: 0o700)
  requested_url = url_for(host, route, port)
  arguments = [
    "/usr/bin/curl", "--disable", "--proto", "=https", "--tlsv1.2", "--http1.1",
    "--noproxy", "*", "--silent", "--show-error", "--fail",
    "--connect-timeout", "5", "--max-time", "60",
    "--header", "X-Ushot-Loopback-Probe: #{session_id}:#{probe_token}",
    # With no redirects, curl emits one HTTP header block followed by the body.
    # Keeping both on captured stdout avoids reopening any same-UID-writable path.
    "--dump-header", "-", "--output", "-",
    "--write-out",
    "%{stderr}USHOT_CURL_META\\t%{remote_ip}\\t%{local_ip}\\t%{url_effective}\\t%{http_code}\\n"
  ]
  unless exact
    arguments.concat(["--cacert", ca_path, "--resolve", "#{host}:#{port}:127.0.0.1"])
  end
  arguments << requested_url
  wire_bytes, standard_error, status = Open3.capture3(
    CLEAN_ENV, *arguments, :unsetenv_others => true, :stdin_data => ""
  )
  wire_bytes.force_encoding(Encoding::BINARY)
  fail_safely(exact ? "exact-url-curl-failed" : "transport-curl-failed") unless status.success?
  metadata_lines = standard_error.lines(chomp: true).select do |line|
    line.start_with?("USHOT_CURL_META\t")
  end
  nonmetadata = standard_error.lines(chomp: true).reject do |line|
    line.start_with?("USHOT_CURL_META\t") || line.empty?
  end
  fail_safely("curl-probe-unexpected-stderr") unless nonmetadata.empty?
  fail_safely("curl-probe-metadata-count-invalid") unless metadata_lines.length == 1
  metadata = metadata_lines.fetch(0).split("\t", -1)
  fail_safely("curl-probe-metadata-invalid") \
    unless metadata.length == 5 && metadata[0] == "USHOT_CURL_META" \
      && metadata[1] == "127.0.0.1" && metadata[2] == "127.0.0.1" \
      && metadata[3] == requested_url && metadata[4] == "200"
  header_end = wire_bytes.index("\r\n\r\n")
  fail_safely("curl-probe-header-boundary-missing") unless header_end
  header_end += 4
  headers = wire_bytes.byteslice(0, header_end)
  body = wire_bytes.byteslice(header_end, wire_bytes.bytesize - header_end)
  fail_safely("curl-probe-headers-too-large") if headers.bytesize > 65_536
  [body, headers]
end

def verify_feed_headers!(headers, mode, expected_size)
  normalized = headers.lines.map(&:strip)
  content_lengths = normalized.grep(/\Acontent-length:/i).map { |line| line.split(":", 2)[1].strip }
  transfer_encodings = normalized.grep(/\Atransfer-encoding:/i).map { |line| line.split(":", 2)[1].strip.downcase }
  if mode == "normal"
    fail_safely("normal-feed-content-length-mismatch") unless content_lengths == [expected_size.to_s]
    fail_safely("normal-feed-unexpected-transfer-encoding") unless transfer_encodings.empty?
  else
    fail_safely("chunked-feed-exposed-content-length") unless content_lengths.empty?
    fail_safely("chunked-feed-transfer-encoding-missing") unless transfer_encodings == ["chunked"]
  end
end

def verify_active_routes!(state, port, ca_path, session_id, workspace, exact:)
  label, generation, mode, active = state.current
  fail_safely("probe-started-during-active-request") unless active.zero?
  item = state.cases.fetch(label)
  prefix = exact ? "exact-#{generation}" : "transport-#{generation}"
  probe_token = SecureRandom.hex(16)
  feed_body, feed_headers = curl_probe(
    host: FEED_HOST, route: FEED_ROUTE, port: port, ca_path: ca_path,
    session_id: session_id, probe_token: probe_token, workspace: workspace,
    exact: exact, suffix: "#{prefix}-feed"
  )
  archive_body, = curl_probe(
    host: ARCHIVE_HOST, route: ARCHIVE_ROUTE, port: port, ca_path: ca_path,
    session_id: session_id, probe_token: probe_token, workspace: workspace,
    exact: exact, suffix: "#{prefix}-archive"
  )
  unless feed_body == item.feed
    $stderr.puts(
      "loopback: probe feed mismatch expected_bytes=#{item.feed.bytesize} " \
      "actual_bytes=#{feed_body.bytesize} expected_sha256=#{item.feed_sha256} " \
      "actual_sha256=#{sha256_bytes(feed_body)}"
    )
    fail_safely("served-feed-bytes-mismatch")
  end
  unless archive_body == item.archive
    $stderr.puts(
      "loopback: probe archive mismatch expected_bytes=#{item.archive.bytesize} " \
      "actual_bytes=#{archive_body.bytesize} expected_sha256=#{item.archive_sha256} " \
      "actual_sha256=#{sha256_bytes(archive_body)}"
    )
    fail_safely("served-archive-bytes-mismatch")
  end
  verify_feed_headers!(feed_headers, mode, item.feed.bytesize)
  state.consume_probe!(
    probe_token, generation, label, mode,
    { "feed" => item.feed.bytesize, "archive" => item.archive.bytesize }
  )
  state.record_exact_system_probe if exact
  $stdout.puts(
    "loopback: probe=PASS kind=#{exact ? 'exact-system' : 'transport'} " \
    "generation=#{generation} case=#{label} mode=#{mode}"
  )
end

def verify_no_system_proxy!
  output, _error, status = run_capture("/usr/sbin/scutil", "--proxy")
  fail_safely("system-proxy-inspection-failed") unless status.success?
  enabled = output.lines.any? do |line|
    line.match?(/^[[:space:]]*(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable)[[:space:]]*:[[:space:]]*1[[:space:]]*$/)
  end
  fail_safely("system-proxy-enabled") if enabled
end

def verify_loopback_resolution!(host)
  output, _error, status = run_capture("/usr/bin/dscacheutil", "-q", "host", "-a", "name", host)
  fail_safely("system-resolution-inspection-failed") unless status.success?
  addresses = output.lines.map do |line|
    match = line.match(/^[[:space:]]*(?:ip_address|ipv6_address):[[:space:]]+([^[:space:]]+)/)
    match && match[1]
  end.compact
  fail_safely("system-resolution-not-loopback-only") \
    unless addresses.include?("127.0.0.1") && addresses.all? { |address| ["127.0.0.1", "::1"].include?(address) }
end

def verify_system_setup!(session_id, ca_fingerprint, server_certificate_path)
  blocks, = inspect_hosts(read_hosts_safely, session_id, remove: false)
  fail_safely("system-hosts-session-count-invalid") unless blocks == 1
  verify_no_system_proxy!
  verify_loopback_resolution!(FEED_HOST)
  verify_loopback_resolution!(ARCHIVE_HOST)
  fail_safely("system-admin-trust-absent") unless admin_trust_present?(ca_fingerprint)
  fail_safely("system-ca-fingerprint-absent") unless certificate_present?(ca_fingerprint)
  [FEED_HOST, ARCHIVE_HOST].each do |host|
    command_success?(
      "/usr/bin/security", "verify-cert", "-c", server_certificate_path,
      "-p", "ssl", "-n", host, "-L", "-q"
    ) or fail_safely("system-server-certificate-not-trusted")
  end
end

def start_server(listener, port, certificate, private_key, state, evidence, session_id, fatal_state)
  logger = WEBrick::Log.new($stderr, WEBrick::Log::FATAL)
  server = WEBrick::HTTPServer.new(
    :Port => port,
    :BindAddress => "127.0.0.1",
    :DoNotListen => true,
    :DoNotReverseLookup => true,
    :ServerSoftware => "UshotUpdateTransitionLoopback",
    :Logger => logger,
    :AccessLog => [],
    :SSLEnable => true,
    :SSLCertificate => certificate,
    :SSLPrivateKey => private_key
  )
  ssl_listener = OpenSSL::SSL::SSLServer.new(listener, server.ssl_context)
  ssl_listener.start_immediately = true
  server.listeners << ssl_listener
  configure_response(server, state, evidence, session_id, fatal_state)
  thread = Thread.new do
    begin
      server.start
      fatal_state.capture(SafetyError.new("server-thread-exited-unexpectedly"), "server-thread") \
        unless fatal_state.shutting_down?
    rescue StandardError => error
      fatal_state.capture(error, "server-thread")
    end
  end
  thread.abort_on_exception = false
  [server, thread]
end

def wait_for_listener!(thread, port, ca_path, session_id, workspace, state, fatal_state)
  50.times do
    fatal_state.check!
    fail_safely("server-exited-before-readiness") unless thread.alive?
    begin
      verify_active_routes!(state, port, ca_path, session_id, workspace, exact: false)
      fatal_state.check!
      return
    rescue SafetyError => error
      raise unless ["transport-curl-failed"].include?(error.code)
      sleep(0.1)
    end
  end
  fail_safely("server-readiness-timeout")
end

operation = ARGV.fetch(0)
script_path = ARGV.fetch(1)
script_sha256 = ARGV.fetch(2)
root_copy_directory = ARGV.fetch(3)
run_uid = Integer(ARGV.fetch(4), 10)
run_gid = Integer(ARGV.fetch(5), 10)
fixtures_directory = ARGV.fetch(6)
cases_directory = ARGV.fetch(7)
feed_fixture = ARGV.fetch(8)
archive_fixture = ARGV.fetch(9)
initial_case = ARGV.fetch(10)
initial_mode = ARGV.fetch(11)
request_evidence_path = ARGV.fetch(12)
port = Integer(ARGV.fetch(13), 10)
self_test_only = ARGV.fetch(14) == "true"
recovery_session_id = ARGV.fetch(15)
recovery_ca_sha256 = ARGV.fetch(16)
ca_certificate_source_path = ARGV.fetch(17)
run_user = ARGV.fetch(18)
fail_safely("run-user-invalid") \
  unless run_user.match?(/\A[A-Za-z0-9._-]+\z/)

if operation == "install-ca"
  fail_safely("install-ca-not-root") unless Process.uid.zero? && Process.euid.zero?
  install_ca!(
    ca_certificate_source_path, recovery_session_id, recovery_ca_sha256,
    root_copy_directory, run_uid
  )
  puts("session_id=#{recovery_session_id}\nca_install_result=PASS")
  exit(0)
end

if operation == "install-hosts"
  fail_safely("install-hosts-not-root") unless Process.uid.zero? && Process.euid.zero?
  install_hosts!(recovery_session_id, root_copy_directory)
  puts("session_id=#{recovery_session_id}\nhosts_install_result=PASS")
  exit(0)
end

if operation == "recover-cleanup"
  fail_safely("recovery-not-root") unless Process.uid.zero? && Process.euid.zero?
  cleanup_system!(recovery_session_id, recovery_ca_sha256, root_copy_directory)
  puts("session_id=#{recovery_session_id}\nrecovery_result=PASS")
  exit(0)
end

listener = TCPServer.new("127.0.0.1", port)
listener.close_on_exec = true
guardian_pid = nil
guardian_writer = nil
if Process.euid.zero?
  guardian_pid, guardian_writer = start_cleanup_guardian(listener, root_copy_directory)
  drop_root_privileges!(run_uid, run_gid)
else
  fail_safely("unexpected-effective-identity") unless Process.uid == run_uid && Process.gid == run_gid
end

self_test_cleanup_primitives!(listener) if self_test_only

workspace = nil
evidence = nil
state = nil
tty = nil
server = nil
server_thread = nil
fatal_state = ServiceFatalState.new(Thread.current)
clean_exit = false
begin
  workspace = create_workspace(run_uid)
  cases_snapshot = snapshot_cases(
    fixtures_directory, cases_directory, initial_case,
    feed_fixture, archive_fixture, run_uid
  )
  cases = cases_snapshot.cases
  session_id = SecureRandom.hex(8)
  ca_path, server_certificate_path, server_certificate, server_key, ca_fingerprint = \
    build_certificates(workspace, session_id)
  evidence = EvidenceWriter.new(
    request_evidence_path, run_uid, session_id, script_sha256, ca_fingerprint,
    cases_snapshot, port
  )
  state = ActiveCaseState.new(cases, initial_case, initial_mode, evidence)

  if guardian_writer
    guardian_writer.write("CONFIG\t#{session_id}\t#{ca_fingerprint}\n")
    guardian_writer.flush
  end

  puts("evidence_begin=ushot-update-transition-loopback-corroborating-v2")
  puts("session_id=#{session_id}")
  puts("script_sha256=#{script_sha256}")
  puts("listener_address=127.0.0.1")
  puts("listener_port=#{port}")
  puts("feed_host=#{FEED_HOST}")
  puts("feed_path=#{FEED_ROUTE}")
  puts("archive_host=#{ARCHIVE_HOST}")
  puts("archive_path=#{ARCHIVE_ROUTE}")
  puts("test_ca_sha256=#{ca_fingerprint}")
  puts("test_ca_path=#{ca_path}")
  puts("server_uid=#{Process.euid}")
  puts("server_gid=#{Process.egid}")
  puts("server_supplementary_groups=#{Process.groups.join(',')}")
  puts("request_evidence=#{request_evidence_path.empty? ? 'disabled' : request_evidence_path}")
  puts("request_evidence_role=corroborating-only-same-uid-forgeable")
  puts("fixture_manifest_sha256=#{cases_snapshot.manifest_sha256}")
  puts("fixture_checksums_sha256=#{cases_snapshot.checksums_sha256}")
  cases.keys.sort.each do |label|
    item = cases.fetch(label)
    puts("case=#{label}\tfeed_sha256=#{item.feed_sha256}\tarchive_sha256=#{item.archive_sha256}")
  end
  puts("system_changes_performed_by_serve_process=none")
  puts("evidence_end=ushot-update-transition-loopback-corroborating-v2")

  server, server_thread = start_server(
    listener, port, server_certificate, server_key, state, evidence, session_id, fatal_state
  )
  wait_for_listener!(server_thread, port, ca_path, session_id, workspace, state, fatal_state)

  if self_test_only
    fatal_state.check!
  else
    tty = File.open("/dev/tty", "r+")
    if port == 443
    quoted_ca = ca_path.gsub("'", %q('\''))
    quoted_script = script_path.gsub("'", %q('\''))
    quoted_root_dir = root_copy_directory.gsub("'", %q('\''))
    clean_root_prefix = \
      "/usr/bin/sudo -- /usr/bin/env -i " \
      "PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C " \
      "SUDO_USER='#{run_user}' SUDO_UID=#{run_uid} SUDO_GID=#{run_gid} " \
      "/bin/bash --noprofile --norc -p '#{quoted_script}'"
    puts
    puts("DANGER - the following explicit setup has SYSTEM-WIDE impact:")
    puts("  * all local resolution for #{FEED_HOST} and #{ARCHIVE_HOST} is redirected to loopback;")
    puts("  * the disposable root CA is trusted in the System Keychain;")
    puts("  * no actual GitHub redirect or CDN path is exercised by this fixture server.")
    puts
    puts("Run these reviewed, hash-bound setup commands in another terminal:")
    puts(
      "  #{clean_root_prefix} --install-ca " \
      "--expected-script-sha256 #{script_sha256} --root-copy-directory '#{quoted_root_dir}' " \
      "--session-id #{session_id} --ca-sha256 #{ca_fingerprint} --ca-path '#{quoted_ca}'"
    )
    puts(
      "  #{clean_root_prefix} --install-hosts " \
      "--expected-script-sha256 #{script_sha256} --root-copy-directory '#{quoted_root_dir}' " \
      "--session-id #{session_id}"
    )
    puts
    puts("Automatic cleanup guardian is active. SIGKILL recovery command:")
    puts(
      "  #{clean_root_prefix} --recover-cleanup " \
      "--expected-script-sha256 #{script_sha256} --root-copy-directory '#{quoted_root_dir}' " \
      "--session-id #{session_id} --ca-sha256 #{ca_fingerprint}"
    )
    tty.write("Press Return only after both hash-bound setup commands succeed, or Control-C to abort: ")
    tty.flush
    tty.gets or fail_safely("operator-setup-checkpoint-closed")
    verify_system_setup!(session_id, ca_fingerprint, server_certificate_path)
    verify_active_routes!(state, port, ca_path, session_id, workspace, exact: true)
      puts("loopback: exact resolver/trust/byte probe=PASS")
    end

  puts
  puts("Operator controls: complete GENERATION | case LABEL | mode normal | mode chunked | status | quit")
  puts("Case or mode switching requires zero active responses and explicit completion of the current Ushot transaction.")
  loop do
    fatal_state.check!
    tty.write("ushot-loopback> ")
    tty.flush
    input = tty.gets
    fail_safely("operator-control-closed") unless input
    command, value = input.strip.split(/[[:space:]]+/, 2)
    case command
    when "complete"
      fail_safely("operator-generation-invalid") unless value.to_s.match?(/\A[1-9][0-9]{0,19}\z/)
      result, detail = state.complete_generation(Integer(value, 10))
      puts("loopback: generation-complete result=#{result} detail=#{detail}")
    when "case"
      safe_label!(value.to_s, "operator-case-label-invalid")
      result, detail = state.switch_case(value)
      puts("loopback: case-switch result=#{result} detail=#{detail}")
      verify_active_routes!(state, port, ca_path, session_id, workspace, exact: port == 443) \
        if result == :changed
    when "mode"
      result, detail = state.switch_mode(value.to_s)
      puts("loopback: mode-switch result=#{result} detail=#{detail}")
      verify_active_routes!(state, port, ca_path, session_id, workspace, exact: port == 443) \
        if result == :changed
    when "status"
      label, generation, mode, active, completed = state.current
      puts(
        "loopback: status generation=#{generation} case=#{label} mode=#{mode} " \
        "active_requests=#{active} completed=#{completed}"
      )
    when "quit", "exit"
      _label, generation, _mode, active, completed = state.current
      if active.zero? && completed
        break
      else
        puts(
          "loopback: quit result=REJECTED generation=#{generation} " \
          "active_requests=#{active} completed=#{completed}"
        )
      end
    when "help", nil, ""
      puts("Operator controls: complete GENERATION | case LABEL | mode normal | mode chunked | status | quit")
    else
      puts("loopback: control result=REJECTED reason=unknown-command")
    end
  end
  end
  fatal_state.check!
  clean_exit = true
rescue Interrupt
  clean_exit = false
  $stderr.puts("loopback: operator abort received; cleanup will run and the command will fail.")
rescue SafetyError => error
  $stderr.puts("error: loopback failed closed: #{error.code}")
rescue StandardError => error
  $stderr.puts("error: loopback failed closed: #{error.class}")
ensure
  ensure_failures = []
  fatal_state.begin_shutdown
  if tty && !tty.closed?
    begin
      tty.close
    rescue StandardError => error
      ensure_failures << "tty-close:#{error.class}"
    end
  end
  if server
    begin
      server.shutdown
    rescue StandardError => error
      ensure_failures << "server-shutdown:#{error.class}"
    end
    if server_thread
      begin
        joined = server_thread.join(10)
        if joined.nil? || server_thread.alive?
          ensure_failures << "server-thread-shutdown-timeout"
          server_thread.kill
          killed_join = server_thread.join(1)
          ensure_failures << "server-thread-kill-timeout" \
            if killed_join.nil? || server_thread.alive?
        end
      rescue StandardError => error
        ensure_failures << "server-thread-shutdown:#{error.class}"
      end
    end
  elsif listener && !listener.closed?
    begin
      listener.close
    rescue StandardError => error
      ensure_failures << "listener-close:#{error.class}"
    end
  end

  if state
    begin
      _label, _generation, _mode, active_requests, = state.current
      ensure_failures << "active-requests-remain:#{active_requests}" unless active_requests.zero?
    rescue StandardError => error
      ensure_failures << "active-request-inspection:#{error.class}"
    end
  end
  ensure_failures << "fatal-state:#{fatal_state.failure_reason}" if fatal_state.failed?
  clean_exit = false unless ensure_failures.empty?
  if evidence
    begin
      evidence.lifecycle("service-ended", clean_exit ? "PASS" : "FAIL")
    rescue StandardError => error
      ensure_failures << "evidence-ended:#{error.class}"
      fatal_state.capture(error, "evidence-ended")
      clean_exit = false
    end
  end

  cleanup_outcome = guardian_writer ? "FAIL" : "NOT_APPLICABLE"
  if guardian_writer
    begin
      guardian_writer.close
    rescue StandardError => error
      ensure_failures << "guardian-pipe-close:#{error.class}"
      clean_exit = false
    end
    begin
      _pid, guardian_status = Process.wait2(guardian_pid)
      cleanup_outcome = guardian_status.success? ? "PASS" : "FAIL"
      unless guardian_status.success?
        ensure_failures << "guardian-cleanup-failed"
        clean_exit = false
      end
    rescue StandardError => error
      ensure_failures << "guardian-wait:#{error.class}"
      clean_exit = false
    end
  end
  if evidence
    begin
      evidence.lifecycle("cleanup", cleanup_outcome)
    rescue StandardError => error
      ensure_failures << "evidence-cleanup:#{error.class}"
      fatal_state.capture(error, "evidence-cleanup")
      clean_exit = false
    end
    begin
      evidence.close
    rescue StandardError => error
      ensure_failures << "evidence-close:#{error.class}"
      clean_exit = false
    end
  end
  if workspace
    begin
      remove_workspace(workspace, run_uid)
    rescue StandardError => error
      ensure_failures << "workspace-cleanup:#{error.class}"
      clean_exit = false
    end
  end
  if fatal_state.failed? && !ensure_failures.any? { |failure| failure.start_with?("fatal-state:") }
    ensure_failures << "fatal-state:#{fatal_state.failure_reason}"
    clean_exit = false
  end
  ensure_failures.each { |failure| $stderr.puts("loopback: shutdown result=FAIL reason=#{failure}") }
end

puts("result=#{clean_exit ? 'PASS' : 'FAIL'}")
exit(clean_exit ? 0 : 1)
RUBY
RESULT=$?
set -e

if [[ "$OPERATION" == "recover-cleanup" && "$RESULT" == "0" \
    && "$CURRENT_UID" == "0" && -n "$ROOT_COPY_DIRECTORY" ]]; then
  if [[ "$SCRIPT_DIRECTORY" == "$ROOT_COPY_DIRECTORY" \
      && -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" \
      && "$(/usr/bin/stat -f '%u' "$SCRIPT_PATH")" == "0" \
      && "$(/usr/bin/stat -f '%Lp' "$SCRIPT_PATH")" == "500" ]]; then
    shopt -s nullglob dotglob
    ROOT_ENTRIES=("$ROOT_COPY_DIRECTORY"/*)
    shopt -u nullglob dotglob
    if [[ "${#ROOT_ENTRIES[@]}" == "1" && "${ROOT_ENTRIES[0]}" == "$SCRIPT_PATH" ]]; then
      /bin/unlink "$SCRIPT_PATH" || RESULT=1
      /bin/rmdir -- "$ROOT_COPY_DIRECTORY" || RESULT=1
    else
      printf 'error: recovery succeeded but unexpected root snapshots remain; preserving recovery copy.\n' >&2
      RESULT=1
    fi
  fi
fi
exit "$RESULT"
