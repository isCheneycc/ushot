#!/bin/bash -p
set -euo pipefail
set +x

# This script eventually handles the production update-signing key. Establish a
# deterministic, privileged-shell boundary before inspecting arguments or
# invoking any external program. In particular, do not allow BASH_ENV, imported
# functions, aliases, traps, locale hooks, language runtimes or dynamic-loader
# variables from the caller to alter the reviewed signing path.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
readonly PATH
IFS=$' \t\n'
export IFS
unalias -a 2>/dev/null || true
while IFS= read -r inherited_function_declaration; do
  inherited_function_name="${inherited_function_declaration##* }"
  [[ -n "$inherited_function_name" ]] && unset -f "$inherited_function_name"
done < <(declare -F)
unset inherited_function_declaration inherited_function_name
trap - EXIT HUP INT TERM ERR DEBUG RETURN
while IFS= read -r inherited_variable_name; do
  case "$inherited_variable_name" in
    BASH_FUNC_*|DYLD_*|LD_*|LC_*|SWIFT_*|LLVM_*|CLANG_*|PERL*|RUBY*|PYTHON*|NODE_*)
      unset "$inherited_variable_name"
      ;;
  esac
done < <(compgen -v)
unset inherited_variable_name
unset \
  BASH_ENV BASH_XTRACEFD ENV CDPATH GLOBIGNORE PS4 PROMPT_COMMAND \
  PERL5OPT PERL5LIB PERLLIB PERL_LOCAL_LIB_ROOT \
  RUBYOPT RUBYLIB GEM_HOME GEM_PATH \
  PYTHONHOME PYTHONPATH PYTHONINSPECT PYTHONSTARTUP \
  NODE_OPTIONS NODE_PATH \
  DEVELOPER_DIR TOOLCHAINS SDKROOT SWIFT_EXEC \
  CC CXX CPP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS \
  MACOSX_DEPLOYMENT_TARGET ARCHFLAGS COMMAND_MODE \
  POSIXLY_CORRECT TAR_OPTIONS ZIPOPT UNZIP \
  XML_CATALOG_FILES SGML_CATALOG_FILES \
  GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT \
  CURL_HOME CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR \
  OPENSSL_CONF OPENSSL_MODULES OPENSSL_ENGINES \
  http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
  TMPDIR
LANG=C
LC_ALL=C
export LANG LC_ALL

ulimit -c 0
umask 077
unset SPARKLE_ED25519_PRIVATE_KEY SPARKLE_PRIVATE_KEY PRIVATE_KEY DERIVED_PUBLIC_KEY \
  EARLY_PRIVATE_KEY

early_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Phase A executes only after an independently supplied reviewed-source manifest
# has bound this script and every repository input that it will execute or
# compile. Phase B is admitted only from an anonymous descriptor for the exact
# root-owned script in a previously frozen bundle. The internal root phase only
# installs public artifacts and never reads a signing key.
EARLY_PHASE="prepare"
EARLY_KEY_SOURCE="keychain"
EARLY_DRY_RUN=false
EARLY_HELP_REQUESTED=false
EARLY_EXPECTED_SCRIPT_SHA256=""
EARLY_REVIEWED_SOURCE_MANIFEST=""
EARLY_REVIEWED_SOURCE_MANIFEST_SHA256=""
EARLY_PREPARED_BUNDLE=""
EARLY_FROZEN_BUNDLE=""
EARLY_EXPECTED_FREEZE_MANIFEST_SHA256=""
EARLY_ROOT_COPY_DIRECTORY=""
EARLY_PRIVATE_KEY=""
export -n EARLY_PRIVATE_KEY
EARLY_RELEASE_COMMON_DESCRIPTOR=""
export -n EARLY_RELEASE_COMMON_DESCRIPTOR
EARLY_PROJECT_ROOT=""
EARLY_PYTHON_INTERPRETER_PATH=""
EARLY_PYTHON_INTERPRETER_SHA256=""
EARLY_ARGUMENTS=("$@")
for ((argument_index = 0; argument_index < ${#EARLY_ARGUMENTS[@]}; )); do
  case "${EARLY_ARGUMENTS[$argument_index]}" in
    --phase|--key-source|--expected-script-sha256|--reviewed-source-manifest|--reviewed-source-manifest-sha256|--prepared-bundle|--frozen-bundle|--expected-freeze-manifest-sha256|--root-copy-directory|--project-root|--python-interpreter-path|--python-interpreter-sha256)
      ((argument_index + 1 < ${#EARLY_ARGUMENTS[@]})) \
        || early_die "${EARLY_ARGUMENTS[$argument_index]} requires a value."
      option_name="${EARLY_ARGUMENTS[$argument_index]}"
      option_value="${EARLY_ARGUMENTS[$((argument_index + 1))]}"
      case "$option_name" in
        --phase) EARLY_PHASE="$option_value" ;;
        --key-source) EARLY_KEY_SOURCE="$option_value" ;;
        --expected-script-sha256) EARLY_EXPECTED_SCRIPT_SHA256="$option_value" ;;
        --reviewed-source-manifest) EARLY_REVIEWED_SOURCE_MANIFEST="$option_value" ;;
        --reviewed-source-manifest-sha256) EARLY_REVIEWED_SOURCE_MANIFEST_SHA256="$option_value" ;;
        --prepared-bundle) EARLY_PREPARED_BUNDLE="$option_value" ;;
        --frozen-bundle) EARLY_FROZEN_BUNDLE="$option_value" ;;
        --expected-freeze-manifest-sha256) EARLY_EXPECTED_FREEZE_MANIFEST_SHA256="$option_value" ;;
        --root-copy-directory) EARLY_ROOT_COPY_DIRECTORY="$option_value" ;;
        --project-root) EARLY_PROJECT_ROOT="$option_value" ;;
        --python-interpreter-path) EARLY_PYTHON_INTERPRETER_PATH="$option_value" ;;
        --python-interpreter-sha256) EARLY_PYTHON_INTERPRETER_SHA256="$option_value" ;;
      esac
      argument_index=$((argument_index + 2))
      ;;
    --dry-run)
      EARLY_DRY_RUN=true
      argument_index=$((argument_index + 1))
      ;;
    --help|-h)
      EARLY_HELP_REQUESTED=true
      argument_index=$((argument_index + 1))
      ;;
    *)
      argument_index=$((argument_index + 1))
      ;;
  esac
done
unset option_name option_value argument_index

if [[ "$EARLY_HELP_REQUESTED" == "true" ]]; then
  printf '%s\n' \
    'usage:' \
    '  prepare-update-transition-fixtures.sh --phase prepare --project-root ABS --output ABS_NEW --prepared-bundle ABS_NEW --assets-directory ABS_DIR --expected-script-sha256 SHA256 --reviewed-source-manifest ABS_FILE --reviewed-source-manifest-sha256 SHA256' \
    '  # root-freeze and sign are internal, hash-bound continuation phases emitted by prepare.' \
    '' \
    'Help performs no source operation, path resolution, signing-key read or Keychain access.'
  exit 0
fi

[[ "$EARLY_PHASE" == "review-pins" || "$EARLY_PHASE" == "prepare" \
    || "$EARLY_PHASE" == "sign" || "$EARLY_PHASE" == "root-freeze" ]] \
  || early_die "--phase must be review-pins, prepare, sign or the internal root-freeze phase."
[[ "$EARLY_KEY_SOURCE" == "keychain" || "$EARLY_KEY_SOURCE" == "stdin" ]] \
  || early_die "--key-source must be keychain or stdin."

if [[ "$EARLY_PHASE" == "sign" ]]; then
  EARLY_RELEASE_COMMON_DESCRIPTOR="${USHOT_FROZEN_RELEASE_COMMON_DESCRIPTOR:-}"
  unset USHOT_FROZEN_RELEASE_COMMON_DESCRIPTOR
  export -n EARLY_RELEASE_COMMON_DESCRIPTOR
  [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/[0-9]+$ ]] \
    || early_die "The sign phase must execute the frozen worker through a verified anonymous descriptor."
  [[ "$EARLY_FROZEN_BUNDLE" == /* \
      && "$EARLY_EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_PYTHON_INTERPRETER_PATH" == /* \
      && "$EARLY_PYTHON_INTERPRETER_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_RELEASE_COMMON_DESCRIPTOR" =~ ^/dev/fd/[0-9]+$ ]] \
    || early_die "The sign phase requires the frozen bundle, external manifest SHA and fixed script/freeze/Python identities."
  SCRIPT_DIR="$EARLY_FROZEN_BUNDLE/scripts"
  PROJECT_ROOT="$EARLY_FROZEN_BUNDLE"
  # Standard input is left untouched while only function definitions are
  # parsed. The seed is read with a shell builtin only after the complete
  # frozen-bundle/external-pin/ACL admission below succeeds.
else
  if [[ "$EARLY_PHASE" == "prepare" || "$EARLY_PHASE" == "review-pins" ]]; then
    [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/[0-9]+$ \
        && "$EARLY_PROJECT_ROOT" == /* \
        && "$EARLY_EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
      || early_die "The review-pins/prepare phase requires --project-root, --expected-script-sha256 and a verified anonymous-descriptor launcher."
    [[ -d "$EARLY_PROJECT_ROOT" && ! -L "$EARLY_PROJECT_ROOT" \
        && "$(cd "$EARLY_PROJECT_ROOT" && pwd -P)" == "$EARLY_PROJECT_ROOT" ]] \
      || early_die "Credential-free project root must be canonical and must not traverse symbolic links."
    PROJECT_ROOT="$EARLY_PROJECT_ROOT"
    SCRIPT_DIR="$PROJECT_ROOT/scripts"
  else
    SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  fi
fi
unset USHOT_FROZEN_RELEASE_COMMON_DESCRIPTOR
SCRIPT_PATH="$SCRIPT_DIR/prepare-update-transition-fixtures.sh"

# The sign path must authenticate the only non-System locations in Apple's
# default Perl search list before the first Perl module import in frozen
# admission. This gate intentionally uses only shell builtins and SIP-protected
# Mach-O tools; the Perl probe uses -f and imports no modules.
verify_initial_sign_perl_runtime_boundary() {
  [[ "$EARLY_PHASE" == "sign" ]] || return 0

  local runtime_path
  local runtime_mode
  local acl_lines
  local actual_inc
  local expected_inc
  local append_hash_output
  local append_hash
  local -a library_perl_entries

  [[ "$(/usr/bin/id -u)" != "0" \
      && -f /usr/bin/perl && ! -L /usr/bin/perl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/perl)" == "0:0:755" ]] \
    || early_die "Initial signing Perl identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.perl"' \
    /usr/bin/perl \
    || early_die "Initial signing Perl failed the Apple code-signing requirement."
  acl_lines="$(/bin/ls -lde /usr/bin/perl | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
    || early_die "Could not inspect the initial signing Perl ACL."
  [[ "$acl_lines" == "1" ]] || early_die "ACL is forbidden on the initial signing Perl."

  expected_inc=$'/Library/Perl/5.34/darwin-thread-multi-2level\n/Library/Perl/5.34\n/Network/Library/Perl/5.34/darwin-thread-multi-2level\n/Network/Library/Perl/5.34\n/Library/Perl/Updates/5.34.1\n/System/Library/Perl/5.34/darwin-thread-multi-2level\n/System/Library/Perl/5.34\n/System/Library/Perl/Extras/5.34/darwin-thread-multi-2level\n/System/Library/Perl/Extras/5.34'
  actual_inc="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    /usr/bin/perl -T -f -e 'print join("\n", @INC), "\n"')" \
    || early_die "Could not inspect the initial system Perl include path."
  [[ "$actual_inc" == "$expected_inc" ]] \
    || early_die "Initial system Perl include path differs from the reviewed allowlist."

  for runtime_path in / /Library /Library/Perl /Library/Perl/5.34; do
    [[ -d "$runtime_path" && ! -L "$runtime_path" \
        && "$(/usr/bin/stat -f '%u:%g' "$runtime_path")" == "0:0" ]] \
      || early_die "Initial Perl search-path ancestry is not root-owned: $runtime_path"
    runtime_mode="$(/usr/bin/stat -f '%Lp' "$runtime_path")"
    [[ "$runtime_mode" =~ ^[0-7]+$ \
        && $((8#$runtime_mode & 8#22)) -eq 0 \
        && $((8#$runtime_mode & 8#555)) -eq $((8#555)) ]] \
      || early_die "Initial Perl search-path ancestry is writable or not traversable: $runtime_path"
    acl_lines="$(/bin/ls -lde "$runtime_path" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
      || early_die "Could not inspect initial Perl search-path ACL: $runtime_path"
    [[ "$acl_lines" == "1" ]] \
      || early_die "ACL is forbidden on initial Perl search-path ancestry: $runtime_path"
  done
  [[ ! -e /Network && ! -L /Network \
      && ! -e /Library/Perl/Updates && ! -L /Library/Perl/Updates \
      && ! -e /Library/Perl/5.34/darwin-thread-multi-2level \
      && ! -L /Library/Perl/5.34/darwin-thread-multi-2level ]] \
    || early_die "A reviewed-absent non-System Perl search path appeared before admission."

  shopt -s nullglob dotglob
  library_perl_entries=(/Library/Perl/5.34/*)
  shopt -u nullglob dotglob
  [[ "${#library_perl_entries[@]}" == "1" \
      && "${library_perl_entries[0]}" == "/Library/Perl/5.34/AppendToPath" \
      && -f /Library/Perl/5.34/AppendToPath \
      && ! -L /Library/Perl/5.34/AppendToPath \
      && "$(/usr/bin/stat -f '%u:%g:%Lp:%z' /Library/Perl/5.34/AppendToPath)" == "0:0:644:33" ]] \
    || early_die "Initial non-System Perl tree differs from the reviewed one-file tree."
  acl_lines="$(/bin/ls -lde /Library/Perl/5.34/AppendToPath | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
    || early_die "Could not inspect initial Perl AppendToPath ACL."
  [[ "$acl_lines" == "1" ]] || early_die "ACL is forbidden on Perl AppendToPath."

  [[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/openssl)" == "0:0:755" ]] \
    || early_die "Initial system SHA-256 executable identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.openssl"' \
    /usr/bin/openssl \
    || early_die "Initial SHA-256 executable failed the Apple code-signing requirement."
  acl_lines="$(/bin/ls -lde /usr/bin/openssl | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
    || early_die "Could not inspect the initial SHA-256 executable ACL."
  [[ "$acl_lines" == "1" ]] \
    || early_die "ACL is forbidden on the initial SHA-256 executable."
  append_hash_output="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    OPENSSL_CONF=/dev/null \
    /usr/bin/openssl dgst -sha256 -r /Library/Perl/5.34/AppendToPath)" \
    || early_die "Could not hash the initial Perl AppendToPath marker."
  append_hash="${append_hash_output%% *}"
  [[ "$append_hash" == "de4a3186f172be76e002ad61c156d45a7e1d9bfe4a16461f8e46cb62a1981158" \
      && "$(< /Library/Perl/5.34/AppendToPath)" == "/System/Library/Perl/Extras/5.34" ]] \
    || early_die "Initial Perl AppendToPath content differs from the reviewed marker."
}

verify_initial_sign_perl_runtime_boundary

validate_reviewed_prepare_sources() {
  [[ "$EARLY_EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_REVIEWED_SOURCE_MANIFEST" == /* \
      && "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || early_die "Prepare requires external --expected-script-sha256 and reviewed-source manifest path/SHA-256 inputs."
  USHOT_REVIEW_PROJECT_ROOT="$PROJECT_ROOT" \
  USHOT_REVIEW_MANIFEST="$EARLY_REVIEWED_SOURCE_MANIFEST" \
  USHOT_REVIEW_MANIFEST_SHA256="$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" \
  USHOT_REVIEW_MAIN_SHA256="$EARLY_EXPECTED_SCRIPT_SHA256" \
  USHOT_REVIEW_PYTHON_PATH="$EARLY_PYTHON_INTERPRETER_PATH" \
  USHOT_REVIEW_PYTHON_SHA256="$EARLY_PYTHON_INTERPRETER_SHA256" \
    /usr/bin/perl \
      -MDigest::SHA \
      -MFcntl=O_RDONLY,O_NOFOLLOW \
      -MJSON::PP \
      -MPOSIX=S_ISREG,SEEK_SET \
      -e '
        use strict;
        use warnings;
        my @expected_paths = qw(
          Config/Base.xcconfig
          Tools/AuthenticatedAppcastValidator/main.swift
          UshotCore/Sources/UshotCore/Product/ProductIdentity.swift
          UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift
          UshotCore/Sources/UshotCore/Update/UpdateChecking.swift
          scripts/derive-sparkle-public-key.swift
          scripts/download-sparkle-tools.sh
          scripts/prepare-update-transition-fixtures.sh
          scripts/release-common.sh
          scripts/validate-appcast.sh
          scripts/validate-release-assets.sh
          updates/release-notes/0.1.4.md
          updates/v1/appcast.xml
        );
        sub fail { die "reviewed source admission: $_[0]\n"; }
        sub same_string_set {
          my ($actual, $expected) = @_;
          my @left = sort(@$actual);
          my @right = sort(@$expected);
          return 0 unless @left == @right;
          for my $index (0 .. $#right) {
            return 0 unless $left[$index] eq $right[$index];
          }
          return 1;
        }
        sub identity {
          my (@stat) = @_;
          return join(",", @stat[0, 1, 2, 4, 7, 9, 10]);
        }
        sub read_bound_file {
          my ($path, $maximum, $owner_policy) = @_;
          my @path_before = lstat($path);
          fail("missing or nonregular file: $path")
            unless @path_before && S_ISREG($path_before[2]);
          sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
            or fail("cannot open with O_NOFOLLOW: $path");
          binmode($handle);
          my @descriptor_before = stat($handle);
          fail("path changed while opening: $path")
            unless @descriptor_before
              && identity(@path_before) eq identity(@descriptor_before);
          fail("untrusted owner or mode: $path")
            unless (($owner_policy eq "current" && $descriptor_before[4] == $<)
              || ($owner_policy eq "system" && $descriptor_before[4] == 0))
              && ($descriptor_before[2] & 0022) == 0;
          fail("empty or oversized file: $path")
            unless $descriptor_before[7] > 0 && $descriptor_before[7] <= $maximum;
          my $bytes = "";
          while (1) {
            my $chunk = "";
            my $count = sysread($handle, $chunk, 65536);
            fail("read failed: $path") unless defined($count);
            last if $count == 0;
            $bytes .= $chunk;
            fail("file exceeded bound: $path") if length($bytes) > $maximum;
          }
          my @descriptor_after = stat($handle);
          my @path_after = lstat($path);
          close($handle) or fail("close failed: $path");
          fail("file changed while reading: $path")
            unless @descriptor_after && @path_after
              && identity(@descriptor_before) eq identity(@descriptor_after)
              && identity(@descriptor_before) eq identity(@path_after);
          return ($bytes, Digest::SHA::sha256_hex($bytes));
        }
        my $root = $ENV{USHOT_REVIEW_PROJECT_ROOT} // fail("missing project root");
        my $manifest_path = $ENV{USHOT_REVIEW_MANIFEST} // fail("missing manifest");
        my $expected_manifest_sha = $ENV{USHOT_REVIEW_MANIFEST_SHA256} // fail("missing manifest hash");
        my $expected_main_sha = $ENV{USHOT_REVIEW_MAIN_SHA256} // fail("missing main hash");
        fail("malformed expected hashes")
          unless $expected_manifest_sha =~ /\A[0-9a-f]{64}\z/
            && $expected_main_sha =~ /\A[0-9a-f]{64}\z/;
        my ($manifest_bytes, $manifest_sha) = read_bound_file($manifest_path, 1_048_576, "current");
        fail("reviewed manifest hash mismatch") unless $manifest_sha eq $expected_manifest_sha;
        my $canonical_json = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);
        my $document = eval { $canonical_json->decode($manifest_bytes) };
        fail("reviewed manifest is invalid JSON") if $@ || ref($document) ne "HASH";
        fail("reviewed manifest is noncanonical or contains duplicate keys")
          unless $canonical_json->encode($document) eq $manifest_bytes;
        fail("reviewed manifest schema mismatch")
          unless same_string_set(
              [keys(%$document)],
              [qw(buildInputs candidateAssets credentialFreeOutputs mainScriptSHA256 purpose schemaVersion sources)]
            )
            && $document->{schemaVersion} == 2
            && $document->{purpose} eq "ushot-update-transition-credential-free-pins-v1"
            && $document->{mainScriptSHA256} eq $expected_main_sha
            && ref($document->{sources}) eq "HASH"
            && ref($document->{buildInputs}) eq "HASH"
            && ref($document->{credentialFreeOutputs}) eq "HASH"
            && ref($document->{candidateAssets}) eq "HASH";
        my @actual_paths = sort(keys(%{$document->{sources}}));
        fail("reviewed manifest source allowlist mismatch")
          unless same_string_set(\@actual_paths, \@expected_paths);
        for my $relative (@expected_paths) {
          my $expected_sha = $document->{sources}{$relative};
          fail("malformed source hash: $relative")
            unless defined($expected_sha) && !ref($expected_sha)
              && $expected_sha =~ /\A[0-9a-f]{64}\z/;
          my (undef, $actual_sha) = read_bound_file("$root/$relative", 1_048_576, "current");
          fail("reviewed source hash mismatch: $relative") unless $actual_sha eq $expected_sha;
        }
        fail("CLI main-script hash disagrees with reviewed manifest")
          unless $document->{sources}{"scripts/prepare-update-transition-fixtures.sh"} eq $expected_main_sha;
        fail("reviewed manifest build-input schema mismatch")
          unless same_string_set(
              [keys(%{$document->{buildInputs}})],
              [qw(embeddedPublicKeyVerifierSourceSHA256 pythonInterpreter sparkleReleaseArchiveSHA256 swiftCompiler)]
            )
            && ref($document->{buildInputs}{pythonInterpreter}) eq "HASH"
            && same_string_set(
              [keys(%{$document->{buildInputs}{pythonInterpreter}})], [qw(path sha256)]
            )
            && ref($document->{buildInputs}{swiftCompiler}) eq "HASH"
            && same_string_set(
              [keys(%{$document->{buildInputs}{swiftCompiler}})],
              [qw(invocationPath resolvedPath sha256)]
            );
        for my $hash (
          $document->{buildInputs}{embeddedPublicKeyVerifierSourceSHA256},
          $document->{buildInputs}{sparkleReleaseArchiveSHA256},
          $document->{buildInputs}{pythonInterpreter}{sha256},
          $document->{buildInputs}{swiftCompiler}{sha256}
        ) {
          fail("malformed build-input hash") unless defined($hash) && !ref($hash)
            && $hash =~ /\A[0-9a-f]{64}\z/;
        }
        for my $path (
          $document->{buildInputs}{pythonInterpreter}{path},
          $document->{buildInputs}{swiftCompiler}{invocationPath},
          $document->{buildInputs}{swiftCompiler}{resolvedPath}
        ) {
          fail("malformed build-input path") unless defined($path) && !ref($path)
            && $path =~ m{\A/} && $path !~ m{//|/\./|/\.\./};
        }
        my @expected_outputs = qw(
          AuthenticatedAppcastValidator EmbeddedPublicKeyVerifier SparklePublicKeyDeriver
          generate_appcast generate_keys sign_update
        );
        fail("credential-free output allowlist mismatch")
          unless same_string_set(
            [keys(%{$document->{credentialFreeOutputs}})], \@expected_outputs
          );
        for my $name (@expected_outputs) {
          my $hash = $document->{credentialFreeOutputs}{$name};
          fail("malformed credential-free output hash: $name")
            unless defined($hash) && !ref($hash) && $hash =~ /\A[0-9a-f]{64}\z/;
        }
        my @expected_assets = qw(
          SHA256SUMS.txt
          Ushot-0.1.4-arm64.dSYM.zip
          Ushot-0.1.4-arm64.dmg
          Ushot-0.1.4-arm64.release-manifest.json
          Ushot-0.1.4-arm64.zip
        );
        fail("candidate-asset allowlist mismatch")
          unless same_string_set([keys(%{$document->{candidateAssets}})], \@expected_assets);
        for my $name (@expected_assets) {
          my $hash = $document->{candidateAssets}{$name};
          fail("malformed candidate-asset hash: $name")
            unless defined($hash) && !ref($hash) && $hash =~ /\A[0-9a-f]{64}\z/;
        }
        my $python_path = $ENV{USHOT_REVIEW_PYTHON_PATH} // fail("missing expected Python path");
        my $python_sha = $ENV{USHOT_REVIEW_PYTHON_SHA256} // fail("missing expected Python hash");
        fail("CLI Python identity disagrees with reviewed manifest")
          unless $document->{buildInputs}{pythonInterpreter}{path} eq $python_path
            && $document->{buildInputs}{pythonInterpreter}{sha256} eq $python_sha;
        print $document->{sources}{"scripts/release-common.sh"}, "\n";
      ' \
    || early_die "External reviewed-source admission failed before repository code execution."
}

validate_review_pins_main() {
  [[ "$EARLY_EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || early_die "review-pins requires an externally retained main-script SHA-256."
  USHOT_EXECUTED_DESCRIPTOR="${BASH_SOURCE[0]}" \
  USHOT_REPOSITORY_MAIN="$PROJECT_ROOT/scripts/prepare-update-transition-fixtures.sh" \
  USHOT_EXPECTED_SCRIPT_SHA256="$EARLY_EXPECTED_SCRIPT_SHA256" \
    /usr/bin/perl -MDigest::SHA -MFcntl=O_RDONLY,O_NOFOLLOW -MPOSIX=S_ISREG -e '
      use strict;
      use warnings;
      my $path = $ENV{USHOT_EXECUTED_DESCRIPTOR} // die "missing executed descriptor\n";
      my $repository_main = $ENV{USHOT_REPOSITORY_MAIN} // die "missing repository main\n";
      my $expected = $ENV{USHOT_EXPECTED_SCRIPT_SHA256} // die "missing expected hash\n";
      sysopen(my $executed_handle, $path, O_RDONLY) or die "cannot open executed descriptor identity\n";
      my @executed = stat($executed_handle);
      die "executed descriptor is not a bounded regular file\n"
        unless @executed && S_ISREG($executed[2]) && $executed[7] > 0 && $executed[7] <= 1_048_576;
      my @repository_path = lstat($repository_main);
      die "repository main is not a regular file\n"
        unless @repository_path && S_ISREG($repository_path[2]);
      sysopen(my $handle, $repository_main, O_RDONLY | O_NOFOLLOW)
        or die "cannot open repository main with O_NOFOLLOW\n";
      binmode($handle);
      my @stat = stat($handle);
      die "repository main changed while opening or is not the executed inode\n"
        unless @stat && S_ISREG($stat[2])
          && $stat[0] == $repository_path[0] && $stat[1] == $repository_path[1]
          && $stat[0] == $executed[0] && $stat[1] == $executed[1]
          && $stat[7] > 0 && $stat[7] <= 1_048_576;
      my $digest = Digest::SHA->new(256);
      while (1) {
        my $chunk = "";
        my $count = sysread($handle, $chunk, 65536);
        die "executed descriptor read failed\n" unless defined($count);
        last if $count == 0;
        $digest->add($chunk);
      }
      my @after = stat($handle);
      my @path_after = lstat($repository_main);
      die "repository main changed while hashing\n" unless @after && @path_after
        && join(",", @stat[0,1,2,4,7,9,10]) eq join(",", @after[0,1,2,4,7,9,10])
        && join(",", @stat[0,1,2,4,7,9,10]) eq join(",", @path_after[0,1,2,4,7,9,10]);
      die "executed/repository main hash mismatch\n" unless $digest->hexdigest eq $expected;
    ' || early_die "review-pins main-script admission failed before repository source execution."
}

early_hash_bound_source() {
  local relative="$1"
  USHOT_SOURCE_PATH="$PROJECT_ROOT/$relative" /usr/bin/perl \
    -MDigest::SHA -MFcntl=O_RDONLY,O_NOFOLLOW -MPOSIX=S_ISREG -e '
      use strict;
      use warnings;
      my $path = $ENV{USHOT_SOURCE_PATH} // die "missing source path\n";
      my @path_before = lstat($path);
      die "source is not a regular file\n" unless @path_before && S_ISREG($path_before[2]);
      sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW) or die "cannot open source\n";
      binmode($handle);
      my @before = stat($handle);
      die "source changed while opening\n" unless @before
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @path_before[0,1,2,4,7,9,10]);
      die "source owner/mode/size is untrusted\n" unless $before[4] == $<
        && ($before[2] & 0022) == 0 && $before[7] > 0 && $before[7] <= 1_048_576;
      my $digest = Digest::SHA->new(256);
      while (1) {
        my $chunk = "";
        my $count = sysread($handle, $chunk, 65536);
        die "source read failed\n" unless defined($count);
        last if $count == 0;
        $digest->add($chunk);
      }
      my @after = stat($handle);
      my @path_after = lstat($path);
      die "source changed while hashing\n" unless @after && @path_after
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @after[0,1,2,4,7,9,10])
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @path_after[0,1,2,4,7,9,10]);
      print $digest->hexdigest, "\n";
    ' || early_die "Could not bind reviewed source: $relative"
}

emit_hash_verified_source() {
  local relative="$1"
  local expected_sha256="$2"
  local owner_policy="${3:-current}"
  USHOT_SOURCE_PATH="$PROJECT_ROOT/$relative" \
  USHOT_SOURCE_SHA256="$expected_sha256" \
  USHOT_SOURCE_OWNER_POLICY="$owner_policy" \
    /usr/bin/perl -MDigest::SHA -MFcntl=O_RDONLY,O_NOFOLLOW -MPOSIX=S_ISREG -e '
      use strict;
      use warnings;
      my $path = $ENV{USHOT_SOURCE_PATH} // die "missing source path\n";
      my $expected = $ENV{USHOT_SOURCE_SHA256} // die "missing source hash\n";
      my $owner_policy = $ENV{USHOT_SOURCE_OWNER_POLICY} // die "missing owner policy\n";
      die "malformed source hash\n" unless $expected =~ /\A[0-9a-f]{64}\z/;
      my @path_before = lstat($path);
      die "source is not a regular file\n" unless @path_before && S_ISREG($path_before[2]);
      sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW) or die "cannot open source\n";
      binmode($handle);
      my @before = stat($handle);
      die "source changed while opening\n" unless @before
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @path_before[0,1,2,4,7,9,10]);
      die "source owner/mode/size is untrusted\n"
        unless (($owner_policy eq "current" && $before[4] == $<)
          || ($owner_policy eq "system" && $before[4] == 0))
        && ($before[2] & 0022) == 0 && $before[7] > 0 && $before[7] <= 1_048_576;
      my $bytes = "";
      while (1) {
        my $chunk = "";
        my $count = sysread($handle, $chunk, 65536);
        die "source read failed\n" unless defined($count);
        last if $count == 0;
        $bytes .= $chunk;
        die "source exceeded bound\n" if length($bytes) > 1_048_576;
      }
      my @after = stat($handle);
      my @path_after = lstat($path);
      die "source changed while reading\n" unless @after && @path_after
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @after[0,1,2,4,7,9,10])
        && join(",", @before[0,1,2,4,7,9,10]) eq join(",", @path_after[0,1,2,4,7,9,10]);
      die "source hash mismatch\n" unless Digest::SHA::sha256_hex($bytes) eq $expected;
      print $bytes or die "source emit failed\n";
    '
}

validate_frozen_sign_admission() {
  USHOT_FROZEN_ROOT="$EARLY_FROZEN_BUNDLE" \
  USHOT_EXPECTED_SCRIPT_SHA256="$EARLY_EXPECTED_SCRIPT_SHA256" \
  USHOT_EXPECTED_MANIFEST_SHA256="$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256" \
  USHOT_EXPECTED_REVIEWED_MANIFEST_SHA256="$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" \
  USHOT_EXPECTED_PYTHON_PATH="$EARLY_PYTHON_INTERPRETER_PATH" \
  USHOT_EXPECTED_PYTHON_SHA256="$EARLY_PYTHON_INTERPRETER_SHA256" \
  USHOT_EXECUTED_DESCRIPTOR="${BASH_SOURCE[0]}" \
  USHOT_RELEASE_COMMON_DESCRIPTOR="$EARLY_RELEASE_COMMON_DESCRIPTOR" \
    /usr/bin/perl \
      -MDigest::SHA \
      -MFcntl=O_RDONLY,O_NOFOLLOW \
      -MJSON::PP \
      -MPOSIX=S_ISDIR,S_ISREG,SEEK_SET \
      -e '
        use strict;
        use warnings;
        sub fail { die "frozen sign admission: $_[0]\n"; }
        sub same_string_set {
          my ($actual, $expected) = @_;
          my @left = sort(@$actual);
          my @right = sort(@$expected);
          return 0 unless @left == @right;
          for my $index (0 .. $#right) {
            return 0 unless $left[$index] eq $right[$index];
          }
          return 1;
        }
        sub identity {
          my (@stat) = @_;
          return join(",", @stat[0, 1, 2, 4, 5, 7, 9, 10]);
        }
        sub reject_acl {
          my ($path) = @_;
          open(my $listing, "-|", "/bin/ls", "-lde", $path)
            or fail("cannot inspect ACL: $path");
          my $lines = 0;
          $lines++ while <$listing>;
          close($listing) or fail("ACL inspection failed: $path");
          fail("ACL is forbidden: $path") unless $lines == 1;
        }
        sub read_frozen_file {
          my ($path, $nofollow, $mode, $maximum) = @_;
          my @path_before = $nofollow ? lstat($path) : ();
          my $flags = O_RDONLY | ($nofollow ? O_NOFOLLOW : 0);
          sysopen(my $handle, $path, $flags) or fail("cannot open $path");
          binmode($handle);
          my @before = stat($handle);
          sysseek($handle, 0, SEEK_SET)
            or fail("cannot rewind descriptor before hashing: $path") unless $nofollow;
          fail("not root:wheel regular frozen input: $path")
            unless @before && S_ISREG($before[2]) && $before[4] == 0
              && $before[5] == 0 && ($before[2] & 07777) == $mode
              && $before[7] > 0 && $before[7] <= $maximum;
          fail("path changed while opening: $path")
            if $nofollow && (!@path_before || identity(@path_before) ne identity(@before));
          reject_acl($path) if $nofollow;
          my $digest = Digest::SHA->new(256);
          my $bytes = "";
          while (1) {
            my $chunk = "";
            my $count = sysread($handle, $chunk, 65536);
            fail("read failed: $path") unless defined($count);
            last if $count == 0;
            $bytes .= $chunk;
            $digest->add($chunk);
            fail("file exceeded bound: $path") if length($bytes) > $maximum;
          }
          my @after = stat($handle);
          my @path_after = $nofollow ? lstat($path) : ();
          fail("file changed while hashing: $path")
            unless @after && identity(@before) eq identity(@after)
              && (!$nofollow || (@path_after && identity(@before) eq identity(@path_after)));
          sysseek($handle, 0, SEEK_SET)
            or fail("cannot rewind descriptor after hashing: $path") unless $nofollow;
          close($handle) or fail("close failed: $path");
          return ($digest->hexdigest, \@before, $bytes);
        }
        sub stat_inherited_descriptor_without_seeking {
          my ($path, $mode, $maximum, $label) = @_;
          fail("malformed $label descriptor")
            unless defined($path) && $path =~ m{\A/dev/fd/([0-9]+)\z};
          my $fd = 0 + $1;
          open(my $handle, "<&=$fd") or fail("cannot duplicate $label descriptor");
          my @status = stat($handle);
          close($handle) or fail("cannot close duplicated $label descriptor");
          fail("$label descriptor is not an exact frozen regular file")
            unless @status && S_ISREG($status[2]) && $status[4] == 0
              && $status[5] == 0 && ($status[2] & 07777) == $mode
              && $status[7] > 0 && $status[7] <= $maximum;
          return \@status;
        }
        sub collect_tree {
          my ($root, $relative, $files, $directories) = @_;
          my $path = length($relative) ? "$root/$relative" : $root;
          my @directory_stat = lstat($path);
          fail("frozen directory is not root:wheel mode 0555: $relative")
            unless @directory_stat && S_ISDIR($directory_stat[2])
              && $directory_stat[4] == 0 && $directory_stat[5] == 0
              && ($directory_stat[2] & 07777) == 0555;
          reject_acl($path);
          opendir(my $directory, $path) or fail("cannot open directory: $path");
          my @names = sort(grep { $_ ne "." && $_ ne ".." } readdir($directory));
          closedir($directory) or fail("cannot close directory: $path");
          for my $name (@names) {
            fail("unsafe frozen entry name") if $name eq "" || $name =~ m{/} || $name eq "." || $name eq "..";
            my $child_relative = length($relative) ? "$relative/$name" : $name;
            my @stat = lstat("$root/$child_relative");
            fail("frozen entry vanished: $child_relative") unless @stat;
            if (S_ISDIR($stat[2])) {
              push @$directories, $child_relative;
              collect_tree($root, $child_relative, $files, $directories);
            } elsif (S_ISREG($stat[2])) {
              push @$files, $child_relative;
            } else {
              fail("frozen bundle contains a nonregular, nondirectory entry: $child_relative");
            }
          }
        }
        my @expected_files = qw(
          Config/Base.xcconfig
          assets/SHA256SUMS.txt
          assets/Ushot-0.1.4-arm64.dSYM.zip
          assets/Ushot-0.1.4-arm64.dmg
          assets/Ushot-0.1.4-arm64.release-manifest.json
          assets/Ushot-0.1.4-arm64.zip
          helpers/AuthenticatedAppcastValidator
          helpers/EmbeddedPublicKeyVerifier
          helpers/SparklePublicKeyDeriver
          inputs/current/appcast.kind
          inputs/current/appcast.xml
          metadata/request.json
          metadata/reviewed-source-manifest.json
          scripts/prepare-update-transition-fixtures.sh
          scripts/release-common.sh
          scripts/validate-appcast.sh
          tools/Sparkle-2.9.5/.archive.sha256
          tools/Sparkle-2.9.5/bin/generate_appcast
          tools/Sparkle-2.9.5/bin/generate_keys
          tools/Sparkle-2.9.5/bin/sign_update
          updates/release-notes/0.1.4.md
          updates/v1/appcast.xml
        );
        my %executable = map { $_ => 1 } qw(
          helpers/AuthenticatedAppcastValidator
          helpers/EmbeddedPublicKeyVerifier
          helpers/SparklePublicKeyDeriver
          scripts/prepare-update-transition-fixtures.sh
          tools/Sparkle-2.9.5/bin/generate_appcast
          tools/Sparkle-2.9.5/bin/generate_keys
          tools/Sparkle-2.9.5/bin/sign_update
        );
        my @expected_directories = qw(
          Config
          assets
          helpers
          inputs
          inputs/current
          metadata
          scripts
          tools
          tools/Sparkle-2.9.5
          tools/Sparkle-2.9.5/bin
          updates
          updates/release-notes
          updates/v1
        );
        my $root = $ENV{USHOT_FROZEN_ROOT} // fail("missing root");
        my $expected_script = $ENV{USHOT_EXPECTED_SCRIPT_SHA256} // fail("missing script hash");
        my $expected_manifest = $ENV{USHOT_EXPECTED_MANIFEST_SHA256} // fail("missing manifest hash");
        my $expected_reviewed = $ENV{USHOT_EXPECTED_REVIEWED_MANIFEST_SHA256} // fail("missing reviewed manifest hash");
        my $expected_python_path = $ENV{USHOT_EXPECTED_PYTHON_PATH} // fail("missing Python path");
        my $expected_python_sha = $ENV{USHOT_EXPECTED_PYTHON_SHA256} // fail("missing Python hash");
        my $descriptor = $ENV{USHOT_EXECUTED_DESCRIPTOR} // fail("missing descriptor");
        my $release_common_descriptor = $ENV{USHOT_RELEASE_COMMON_DESCRIPTOR} // fail("missing release-common descriptor");
        fail("malformed hashes or Python path") unless $expected_script =~ /\A[0-9a-f]{64}\z/
          && $expected_manifest =~ /\A[0-9a-f]{64}\z/
          && $expected_reviewed =~ /\A[0-9a-f]{64}\z/
          && $expected_python_sha =~ /\A[0-9a-f]{64}\z/
          && $expected_python_path =~ m{\A/}
          && $descriptor =~ m{\A/dev/fd/[0-9]+\z}
          && $release_common_descriptor =~ m{\A/dev/fd/[0-9]+\z};
        my $expected_root = "/Library/Application Support/Ushot/UpdateTransition/ushot-0.1.4-"
          . substr($expected_manifest, 0, 16);
        fail("frozen root is not the hash-bound fixed path") unless $root eq $expected_root;
        for my $parent (
          "/Library",
          "/Library/Application Support",
          "/Library/Application Support/Ushot",
          "/Library/Application Support/Ushot/UpdateTransition"
        ) {
          my @stat = lstat($parent);
          fail("frozen parent is not root-owned, traversable and ordinary-user-immutable: $parent")
            unless @stat && S_ISDIR($stat[2]) && $stat[4] == 0
              && ($stat[2] & 0022) == 0 && ($stat[2] & 0555) == 0555;
          reject_acl($parent);
        }
        my (@actual_files, @actual_directories);
        collect_tree($root, "", \@actual_files, \@actual_directories);
        my @expected_tree_files = sort(@expected_files, "freeze-manifest.json");
        fail("frozen file layout mismatch")
          unless join("\0", sort(@actual_files)) eq join("\0", @expected_tree_files);
        fail("frozen directory layout mismatch")
          unless join("\0", sort(@actual_directories)) eq join("\0", sort(@expected_directories));
        my ($manifest_sha, undef, $manifest_bytes) =
          read_frozen_file("$root/freeze-manifest.json", 1, 0444, 1_048_576);
        fail("freeze-manifest hash mismatch") unless $manifest_sha eq $expected_manifest;
        my $canonical_json = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);
        my $manifest = eval { $canonical_json->decode($manifest_bytes) };
        fail("freeze manifest is invalid JSON") if $@ || ref($manifest) ne "HASH";
        fail("freeze manifest is noncanonical or contains duplicate keys")
          unless $canonical_json->encode($manifest) eq $manifest_bytes;
        fail("freeze manifest schema mismatch")
          unless same_string_set(
              [keys(%$manifest)],
              [qw(bundlePurpose files publicKeyFingerprintSHA256 pythonInterpreter reviewedSourceManifestSHA256 schemaVersion scriptSHA256)]
            )
            && $manifest->{schemaVersion} == 2
            && $manifest->{bundlePurpose} eq "ushot-update-transition-fixtures-v1"
            && $manifest->{scriptSHA256} eq $expected_script
            && $manifest->{reviewedSourceManifestSHA256} eq $expected_reviewed
            && ref($manifest->{pythonInterpreter}) eq "HASH"
            && same_string_set(
              [keys(%{$manifest->{pythonInterpreter}})], [qw(path sha256)]
            )
            && $manifest->{pythonInterpreter}{path} eq $expected_python_path
            && $manifest->{pythonInterpreter}{sha256} eq $expected_python_sha
            && $manifest->{publicKeyFingerprintSHA256} eq "13d0f28d6b7199fcb2399d6183d74301294c1f859db765782ed9396161e440c8"
            && ref($manifest->{files}) eq "HASH";
        fail("freeze manifest file allowlist mismatch")
          unless same_string_set([keys(%{$manifest->{files}})], \@expected_files);
        my %actual_hash;
        for my $entry (@expected_files) {
          my $record = $manifest->{files}{$entry};
          fail("invalid manifest record: $entry")
            unless ref($record) eq "HASH"
              && same_string_set([keys(%$record)], [qw(mode sha256 size)])
              && $record->{sha256} =~ /\A[0-9a-f]{64}\z/
              && $record->{size} =~ /\A[1-9][0-9]*\z/
              && $record->{size} <= 268_435_456
              && (($executable{$entry} && $record->{mode} eq "0500")
                || (!$executable{$entry} && $record->{mode} eq "0400"));
          my ($sha, $stat) = read_frozen_file(
            "$root/$entry", 1, $executable{$entry} ? 0555 : 0444, 268_435_456
          );
          fail("frozen file binding mismatch: $entry")
            unless $sha eq $record->{sha256} && $stat->[7] == $record->{size};
          $actual_hash{$entry} = $sha;
        }
        my ($reviewed_sha, undef, $reviewed_bytes) = read_frozen_file(
          "$root/metadata/reviewed-source-manifest.json", 1, 0444, 1_048_576
        );
        fail("external reviewed manifest hash mismatch") unless $reviewed_sha eq $expected_reviewed;
        my $reviewed = eval { $canonical_json->decode($reviewed_bytes) };
        fail("external reviewed manifest is invalid JSON") if $@ || ref($reviewed) ne "HASH";
        fail("external reviewed manifest is noncanonical or contains duplicate keys")
          unless $canonical_json->encode($reviewed) eq $reviewed_bytes;
        fail("external reviewed manifest schema mismatch")
          unless same_string_set(
              [keys(%$reviewed)],
              [qw(buildInputs candidateAssets credentialFreeOutputs mainScriptSHA256 purpose schemaVersion sources)]
            )
            && $reviewed->{schemaVersion} == 2
            && $reviewed->{purpose} eq "ushot-update-transition-credential-free-pins-v1"
            && $reviewed->{mainScriptSHA256} eq $expected_script
            && ref($reviewed->{sources}) eq "HASH"
            && ref($reviewed->{credentialFreeOutputs}) eq "HASH"
            && ref($reviewed->{candidateAssets}) eq "HASH"
            && ref($reviewed->{buildInputs}) eq "HASH"
            && same_string_set(
              [keys(%{$reviewed->{buildInputs}})],
              [qw(embeddedPublicKeyVerifierSourceSHA256 pythonInterpreter sparkleReleaseArchiveSHA256 swiftCompiler)]
            )
            && ref($reviewed->{buildInputs}{pythonInterpreter}) eq "HASH"
            && $reviewed->{buildInputs}{pythonInterpreter}{path} eq $expected_python_path
            && $reviewed->{buildInputs}{pythonInterpreter}{sha256} eq $expected_python_sha
            && same_string_set(
              [keys(%{$reviewed->{credentialFreeOutputs}})],
              [qw(AuthenticatedAppcastValidator EmbeddedPublicKeyVerifier SparklePublicKeyDeriver generate_appcast generate_keys sign_update)]
            );
        my %source_map = (
          "Config/Base.xcconfig" => "Config/Base.xcconfig",
          "scripts/prepare-update-transition-fixtures.sh" => "scripts/prepare-update-transition-fixtures.sh",
          "scripts/release-common.sh" => "scripts/release-common.sh",
          "scripts/validate-appcast.sh" => "scripts/validate-appcast.sh",
          "updates/release-notes/0.1.4.md" => "updates/release-notes/0.1.4.md",
          "updates/v1/appcast.xml" => "updates/v1/appcast.xml",
        );
        while (my ($entry, $pin) = each(%source_map)) {
          fail("external source pin mismatch: $entry")
            unless $actual_hash{$entry} eq ($reviewed->{sources}{$pin} // "");
        }
        my %output_map = (
          "helpers/AuthenticatedAppcastValidator" => "AuthenticatedAppcastValidator",
          "helpers/EmbeddedPublicKeyVerifier" => "EmbeddedPublicKeyVerifier",
          "helpers/SparklePublicKeyDeriver" => "SparklePublicKeyDeriver",
          "tools/Sparkle-2.9.5/bin/generate_appcast" => "generate_appcast",
          "tools/Sparkle-2.9.5/bin/generate_keys" => "generate_keys",
          "tools/Sparkle-2.9.5/bin/sign_update" => "sign_update",
        );
        while (my ($entry, $pin) = each(%output_map)) {
          fail("external output pin mismatch: $entry")
            unless $actual_hash{$entry} eq ($reviewed->{credentialFreeOutputs}{$pin} // "");
        }
        my %asset_map = (
          "assets/Ushot-0.1.4-arm64.dmg" => "Ushot-0.1.4-arm64.dmg",
          "assets/Ushot-0.1.4-arm64.zip" => "Ushot-0.1.4-arm64.zip",
          "assets/Ushot-0.1.4-arm64.dSYM.zip" => "Ushot-0.1.4-arm64.dSYM.zip",
          "assets/Ushot-0.1.4-arm64.release-manifest.json" => "Ushot-0.1.4-arm64.release-manifest.json",
          "assets/SHA256SUMS.txt" => "SHA256SUMS.txt",
        );
        while (my ($entry, $pin) = each(%asset_map)) {
          fail("external asset pin mismatch: $entry")
            unless $actual_hash{$entry} eq ($reviewed->{candidateAssets}{$pin} // "");
        }
        my (undef, undef, $archive_marker) = read_frozen_file(
          "$root/tools/Sparkle-2.9.5/.archive.sha256", 1, 0444, 256
        );
        fail("external Sparkle archive pin mismatch")
          unless $archive_marker eq ($reviewed->{buildInputs}{sparkleReleaseArchiveSHA256} // "");
        my ($script_sha, $script_stat) =
          read_frozen_file("$root/scripts/prepare-update-transition-fixtures.sh", 1, 0555, 1_048_576);
        fail("frozen script hash mismatch") unless $script_sha eq $expected_script;
        my $descriptor_stat =
          stat_inherited_descriptor_without_seeking($descriptor, 0555, 1_048_576, "executed script");
        fail("anonymous descriptor does not name the frozen script")
          unless identity(@$descriptor_stat) eq identity(@$script_stat);
        my ($release_common_sha, $release_common_stat) = read_frozen_file(
          "$root/scripts/release-common.sh", 1, 0444, 1_048_576
        );
        my ($release_common_descriptor_sha, $release_common_descriptor_stat) =
          read_frozen_file($release_common_descriptor, 0, 0444, 1_048_576);
        fail("anonymous descriptor does not name frozen release-common")
          unless $release_common_descriptor_sha eq $release_common_sha
            && $release_common_descriptor_stat->[0] == $release_common_stat->[0]
            && $release_common_descriptor_stat->[1] == $release_common_stat->[1]
            && $release_common_sha eq $actual_hash{"scripts/release-common.sh"};
        print $release_common_sha, "\n";
      ' \
    || early_die "Frozen sign admission failed before loading release-common or reading a key."
}

EARLY_RELEASE_COMMON_SHA256=""
case "$EARLY_PHASE" in
  review-pins)
    validate_review_pins_main
    [[ "$(early_hash_bound_source scripts/prepare-update-transition-fixtures.sh)" == "$EARLY_EXPECTED_SCRIPT_SHA256" ]] \
      || early_die "Repository main script disagrees with the anonymously executed reviewed bytes."
    EARLY_RELEASE_COMMON_SHA256="$(early_hash_bound_source scripts/release-common.sh)"
    ;;
  prepare)
    [[ "$EARLY_PYTHON_INTERPRETER_PATH" == /* \
        && "$EARLY_PYTHON_INTERPRETER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
      || early_die "Prepare requires the externally retained Python interpreter path and SHA-256."
    validate_review_pins_main
    EARLY_RELEASE_COMMON_SHA256="$(validate_reviewed_prepare_sources)"
    [[ "$EARLY_RELEASE_COMMON_SHA256" =~ ^[0-9a-f]{64}$ ]] \
      || early_die "Reviewed-source admission did not return a canonical release-common hash."
    ;;
  sign)
    EARLY_RELEASE_COMMON_SHA256="$(validate_frozen_sign_admission)"
    [[ "$EARLY_RELEASE_COMMON_SHA256" =~ ^[0-9a-f]{64}$ ]] \
      || early_die "Frozen sign admission did not return the bound release-common hash."
    ;;
  root-freeze) : ;;
esac
if [[ "$EARLY_PHASE" == "sign" ]]; then
  readonly EARLY_RELEASE_COMMON_DESCRIPTOR EARLY_RELEASE_COMMON_SHA256
fi

# The root-freeze phase runs only from the independently hash-bound root copy.
# It executes only this shell and the SIP-protected system Perl runtime.
# Prepared bytes are data: no prepared executable, Xcode output, repository
# source or signing key is ever launched or read by this phase.
run_root_freeze_phase() {
  [[ "$EUID" == "0" ]] || early_die "The internal root-freeze phase requires root."
  [[ "$EARLY_KEY_SOURCE" == "keychain" ]] \
    || early_die "The root-freeze phase refuses every explicit stdin key source."
  exec </dev/null

  [[ "$EARLY_ROOT_COPY_DIRECTORY" == /* \
      && "$EARLY_PREPARED_BUNDLE" == /* \
      && "$EARLY_FROZEN_BUNDLE" == /* \
      && "$EARLY_EXPECTED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$EARLY_PYTHON_INTERPRETER_PATH" == /* \
      && "$EARLY_PYTHON_INTERPRETER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || early_die "Root freeze is missing fixed path/hash/build-input identities."
  [[ -n "${SUDO_UID:-}" && "$SUDO_UID" =~ ^[1-9][0-9]*$ \
      && -n "${SUDO_GID:-}" && "$SUDO_GID" =~ ^[0-9]+$ ]] \
    || early_die "The root-freeze phase must be entered through sudo by the Phase-A owner."

  local expected_root_copy_directory="/private/var/root/ushot-update-transition-freezer-${EARLY_EXPECTED_SCRIPT_SHA256:0:16}-${EARLY_EXPECTED_FREEZE_MANIFEST_SHA256:0:16}"
  local root_script="$EARLY_ROOT_COPY_DIRECTORY/prepare-update-transition-fixtures.sh"
  local actual_sha256
  local acl_lines
  local system_path

  [[ "$EARLY_ROOT_COPY_DIRECTORY" == "$expected_root_copy_directory" \
      && -d "$EARLY_ROOT_COPY_DIRECTORY" && ! -L "$EARLY_ROOT_COPY_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' "$EARLY_ROOT_COPY_DIRECTORY")" == "0:0:700" \
      && "$root_script" == "$EARLY_ROOT_COPY_DIRECTORY/prepare-update-transition-fixtures.sh" ]] \
    || early_die "Root-copy directory identity is not exact."

  reject_root_freeze_acl() {
    local path="$1"
    acl_lines="$(/bin/ls -lde "$path" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
      || early_die "Could not inspect root-freeze ACL: $path"
    [[ "$acl_lines" == "1" ]] \
      || early_die "ACL is forbidden on root-freeze path: $path"
  }

  for system_path in /private /private/var /private/var/root; do
    [[ -d "$system_path" && ! -L "$system_path" \
        && "$(/usr/bin/stat -f '%u' "$system_path")" == "0" \
        && $((8#$(/usr/bin/stat -f '%Lp' "$system_path") & 8#22)) -eq 0 ]] \
      || early_die "Root-copy ancestry is not root-owned and immutable: $system_path"
    reject_root_freeze_acl "$system_path"
  done
  reject_root_freeze_acl "$EARLY_ROOT_COPY_DIRECTORY"
  [[ -f "$root_script" && ! -L "$root_script" \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' "$root_script")" == "0:0:500" ]] \
    || early_die "Root-copy script identity is not exact."
  [[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/openssl)" == "0:0:755" ]] \
    || early_die "System SHA-256 executable identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.openssl"' \
    /usr/bin/openssl \
    || early_die "System SHA-256 executable failed the Apple code-signing requirement."
  if [[ "$EARLY_PHASE" == "sign" ]]; then
    reject_sign_runtime_acl /usr/bin/openssl
  fi
  reject_root_freeze_acl /usr/bin/openssl
  actual_sha256="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    OPENSSL_CONF=/dev/null \
    /usr/bin/openssl dgst -sha256 -r "$root_script")" \
    || early_die "Could not hash the root-copy script with the trusted system executable."
  actual_sha256="${actual_sha256%% *}"
  [[ "$actual_sha256" =~ ^[0-9a-f]{64}$ \
      && "$actual_sha256" == "$EARLY_EXPECTED_SCRIPT_SHA256" ]] \
    || early_die "Root-copy script hash mismatch."
  reject_root_freeze_acl "$root_script"

  [[ -f /usr/bin/perl && ! -L /usr/bin/perl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/perl)" == "0:0:755" ]] \
    || early_die "System Perl identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.perl"' \
    /usr/bin/perl \
    || early_die "System Perl failed the Apple code-signing requirement."
  reject_root_freeze_acl /usr/bin/perl
  for system_path in \
    /System \
    /System/Library \
    /System/Library/Perl \
    /System/Library/Perl/5.34 \
    /System/Library/Perl/5.34/darwin-thread-multi-2level; do
    [[ -d "$system_path" && ! -L "$system_path" \
        && "$(/usr/bin/stat -f '%u' "$system_path")" == "0" \
        && $((8#$(/usr/bin/stat -f '%Lp' "$system_path") & 8#22)) -eq 0 ]] \
      || early_die "System Perl module ancestry is not root-owned and immutable: $system_path"
    reject_root_freeze_acl "$system_path"
  done

  reject_root_freeze_acl /Library
  reject_root_freeze_acl "/Library/Application Support"
  if [[ -e "/Library/Application Support/Ushot" || -L "/Library/Application Support/Ushot" ]]; then
    [[ -d "/Library/Application Support/Ushot" \
        && ! -L "/Library/Application Support/Ushot" \
        && "$(/usr/bin/stat -f '%u' "/Library/Application Support/Ushot")" == "0" \
        && $((8#$(/usr/bin/stat -f '%Lp' "/Library/Application Support/Ushot") & 8#22)) -eq 0 \
        && $((8#$(/usr/bin/stat -f '%Lp' "/Library/Application Support/Ushot") & 8#555)) -eq $((8#555)) ]] \
      || early_die "Existing Ushot support directory is not root-owned, immutable and traversable."
    reject_root_freeze_acl "/Library/Application Support/Ushot"
  fi
  if [[ -e "/Library/Application Support/Ushot/UpdateTransition" \
      || -L "/Library/Application Support/Ushot/UpdateTransition" ]]; then
    [[ -d "/Library/Application Support/Ushot/UpdateTransition" \
        && ! -L "/Library/Application Support/Ushot/UpdateTransition" \
        && "$(/usr/bin/stat -f '%u' "/Library/Application Support/Ushot/UpdateTransition")" == "0" \
        && $((8#$(/usr/bin/stat -f '%Lp' "/Library/Application Support/Ushot/UpdateTransition") & 8#22)) -eq 0 \
        && $((8#$(/usr/bin/stat -f '%Lp' "/Library/Application Support/Ushot/UpdateTransition") & 8#555)) -eq $((8#555)) ]] \
      || early_die "Existing UpdateTransition directory is not root-owned, immutable and traversable."
    reject_root_freeze_acl "/Library/Application Support/Ushot/UpdateTransition"
  fi

  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    /usr/bin/perl -T -f -e '
BEGIN {
  @INC = qw(
    /System/Library/Perl/5.34/darwin-thread-multi-2level
    /System/Library/Perl/5.34
  );
  %ENV = (
    PATH => "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG => "C",
    LC_ALL => "C",
  );
}
use strict;
use warnings;
use Digest::SHA ();
use DynaLoader ();
use Fcntl qw(O_RDONLY O_RDWR O_CREAT O_EXCL O_NOFOLLOW O_DIRECTORY F_GETFD F_SETFD FD_CLOEXEC);
use IO::Handle ();
use JSON::PP ();
use POSIX qw(S_ISDIR S_ISREG SEEK_SET);

use constant MAXIMUM_FILE_BYTES => 268_435_456;
use constant MAXIMUM_JSON_BYTES => 1_048_576;
my $destination_uid = 0;
my $destination_gid = 0;

sub fail { die "root freeze: $_[0]\n"; }
sub canonical_hash { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[0-9a-f]{64}\z/; }
sub untaint_hash {
  my ($value, $label) = @_;
  fail("malformed $label") unless defined($value) && !ref($value)
    && $value =~ /\A([0-9a-f]{64})\z/;
  return $1;
}
sub exact_keys {
  my ($value, $expected, $label) = @_;
  fail("$label is not an object") unless ref($value) eq "HASH";
  my @actual = sort(keys(%$value));
  my @wanted = sort(@$expected);
  fail("$label keys differ") unless @actual == @wanted;
  for my $index (0 .. $#wanted) {
    fail("$label keys differ") unless $actual[$index] eq $wanted[$index];
  }
}
sub identity {
  my (@value) = @_;
  return join(",", @value[0, 1, 2, 4, 5, 7, 9, 10]);
}
sub publication_identity {
  my (@value) = @_;
  return join(",", @value[0, 1, 2, 4, 5, 7]);
}
sub read_exact_descriptor {
  my ($handle, $maximum, $capture) = @_;
  my $digest = Digest::SHA->new(256);
  my $bytes = "";
  my $counted = 0;
  while (1) {
    my $chunk = "";
    my $count = sysread($handle, $chunk, 65536);
    if (!defined($count)) {
      next if $!{EINTR};
      fail("descriptor read failed");
    }
    last if $count == 0;
    $counted += $count;
    fail("descriptor exceeded its byte bound") if $counted > $maximum;
    $digest->add($chunk);
    $bytes .= $chunk if $capture;
  }
  return ($digest->hexdigest, $counted, $bytes);
}
sub write_all {
  my ($handle, $bytes) = @_;
  my $offset = 0;
  while ($offset < length($bytes)) {
    my $written = syswrite($handle, $bytes, length($bytes) - $offset, $offset);
    if (!defined($written)) {
      next if $!{EINTR};
      fail("destination write failed");
    }
    fail("destination write made no progress") if $written == 0;
    $offset += $written;
  }
}
sub protect_handle {
  my ($handle, $label) = @_;
  fcntl($handle, F_SETFD, FD_CLOEXEC) or fail("cannot set close-on-exec for $label");
  my $flags = fcntl($handle, F_GETFD, 0);
  fail("cannot read close-on-exec state for $label") unless defined($flags);
  fail("close-on-exec did not stick for $label")
    unless ($flags & FD_CLOEXEC) == FD_CLOEXEC;
}
sub sync_handle {
  my ($handle, $label) = @_;
  $handle->sync() or fail("cannot fsync $label");
}
sub set_handle_identity {
  my ($handle, $mode, $label) = @_;
  chown($destination_uid, $destination_gid, $handle) == 1 or fail("cannot chown $label");
  chmod($mode, $handle) == 1 or fail("cannot chmod $label");
}
sub canonical_absolute_path {
  my ($value, $label) = @_;
  fail("$label is not an absolute path") unless defined($value) && !ref($value)
    && $value =~ m{\A/[^\0\r\n]+\z} && $value ne "/" && $value !~ m{//};
  for my $component (split(m{/}, $value, -1)) {
    next if $component eq "";
    fail("$label has a noncanonical component") if $component eq "." || $component eq "..";
  }
  $value =~ m{\A(.*)\z}s or fail("cannot untaint $label");
  return $1;
}
sub verify_system_runtime_path {
  my ($path) = @_;
  fail("Perl loaded a non-System module")
    unless defined($path) && $path =~ m{\A/System/Library/Perl/5\.34(?:/|\z)};
  my $current = "";
  my @components = grep { length($_) } split(m{/}, $path);
  for my $index (0 .. $#components) {
    $current .= "/$components[$index]";
    my @status = lstat($current);
    fail("System Perl runtime path vanished") unless @status && $status[4] == 0
      && ($status[2] & 0022) == 0;
    if ($index == $#components) {
      fail("System Perl runtime module is not regular") unless S_ISREG($status[2]);
    } else {
      fail("System Perl runtime ancestor is not a directory") unless S_ISDIR($status[2]);
    }
  }
}
sub verify_system_runtime {
  fail("Perl include path was broadened") unless join("\0", @INC) eq join("\0", qw(
    /System/Library/Perl/5.34/darwin-thread-multi-2level
    /System/Library/Perl/5.34
  ));
  verify_system_runtime_path($_) for values(%INC);
  verify_system_runtime_path($_) for @DynaLoader::dl_shared_objects;
}

verify_system_runtime();
my ($prepared, $requested_frozen, $expected_script, $expected_freeze,
    $expected_reviewed, $expected_python_path, $expected_python_sha,
    $prepared_uid, $prepared_gid) = @ARGV;
fail("unexpected root-freeze arguments") unless @ARGV == 9;
$prepared = canonical_absolute_path($prepared, "prepared root");
$requested_frozen = canonical_absolute_path($requested_frozen, "frozen root");
$expected_python_path = canonical_absolute_path($expected_python_path, "Python identity path");
$expected_script = untaint_hash($expected_script, "script hash");
$expected_freeze = untaint_hash($expected_freeze, "freeze hash");
$expected_reviewed = untaint_hash($expected_reviewed, "reviewed-manifest hash");
$expected_python_sha = untaint_hash($expected_python_sha, "Python hash");
fail("malformed prepared owner") unless defined($prepared_uid) && $prepared_uid =~ /\A([1-9][0-9]*)\z/;
$prepared_uid = 0 + $1;
fail("malformed prepared group") unless defined($prepared_gid) && $prepared_gid =~ /\A([0-9]+)\z/;
$prepared_gid = 0 + $1;
my $final_frozen = "/Library/Application Support/Ushot/UpdateTransition/ushot-0.1.4-"
  . substr($expected_freeze, 0, 16);
fail("frozen destination identity mismatch") unless $requested_frozen eq $final_frozen;
my $frozen;

my @expected_files = qw(
  Config/Base.xcconfig
  assets/SHA256SUMS.txt
  assets/Ushot-0.1.4-arm64.dSYM.zip
  assets/Ushot-0.1.4-arm64.dmg
  assets/Ushot-0.1.4-arm64.release-manifest.json
  assets/Ushot-0.1.4-arm64.zip
  helpers/AuthenticatedAppcastValidator
  helpers/EmbeddedPublicKeyVerifier
  helpers/SparklePublicKeyDeriver
  inputs/current/appcast.kind
  inputs/current/appcast.xml
  metadata/request.json
  metadata/reviewed-source-manifest.json
  scripts/prepare-update-transition-fixtures.sh
  scripts/release-common.sh
  scripts/validate-appcast.sh
  tools/Sparkle-2.9.5/.archive.sha256
  tools/Sparkle-2.9.5/bin/generate_appcast
  tools/Sparkle-2.9.5/bin/generate_keys
  tools/Sparkle-2.9.5/bin/sign_update
  updates/release-notes/0.1.4.md
  updates/v1/appcast.xml
);
my @expected_directories = qw(
  Config assets helpers inputs inputs/current metadata scripts tools
  tools/Sparkle-2.9.5 tools/Sparkle-2.9.5/bin updates
  updates/release-notes updates/v1
);
my %executable = map { $_ => 1 } qw(
  helpers/AuthenticatedAppcastValidator
  helpers/EmbeddedPublicKeyVerifier
  helpers/SparklePublicKeyDeriver
  scripts/prepare-update-transition-fixtures.sh
  tools/Sparkle-2.9.5/bin/generate_appcast
  tools/Sparkle-2.9.5/bin/generate_keys
  tools/Sparkle-2.9.5/bin/sign_update
);
my %children = (
  "" => [qw(Config assets freeze-manifest.json helpers inputs metadata scripts tools updates)],
  Config => [qw(Base.xcconfig)],
  assets => [qw(SHA256SUMS.txt Ushot-0.1.4-arm64.dSYM.zip Ushot-0.1.4-arm64.dmg Ushot-0.1.4-arm64.release-manifest.json Ushot-0.1.4-arm64.zip)],
  helpers => [qw(AuthenticatedAppcastValidator EmbeddedPublicKeyVerifier SparklePublicKeyDeriver)],
  inputs => [qw(current)],
  "inputs/current" => [qw(appcast.kind appcast.xml)],
  metadata => [qw(request.json reviewed-source-manifest.json)],
  scripts => [qw(prepare-update-transition-fixtures.sh release-common.sh validate-appcast.sh)],
  tools => [qw(Sparkle-2.9.5)],
  "tools/Sparkle-2.9.5" => [qw(.archive.sha256 bin)],
  "tools/Sparkle-2.9.5/bin" => [qw(generate_appcast generate_keys sign_update)],
  updates => [qw(release-notes v1)],
  "updates/release-notes" => [qw(0.1.4.md)],
  "updates/v1" => [qw(appcast.xml)],
);

sub source_path { return $_[0] eq "" ? $prepared : "$prepared/$_[0]"; }
sub assert_source_directory {
  my ($relative) = @_;
  my $path = source_path($relative);
  my @before = lstat($path);
  fail("prepared directory is not exact: $relative") unless @before
    && S_ISDIR($before[2]) && $before[4] == $prepared_uid && $before[5] == $prepared_gid
    && ($before[2] & 07777) == 0700;
  sysopen(my $bound, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fail("cannot bind prepared directory: $relative");
  protect_handle($bound, "prepared directory $relative");
  my @opened = stat($bound);
  fail("prepared directory changed while opening: $relative")
    unless @opened && identity(@before) eq identity(@opened);
  opendir(my $listing, $path) or fail("cannot list prepared directory: $relative");
  my @listed = stat($listing);
  fail("prepared directory changed while listing: $relative")
    unless @listed && identity(@opened) eq identity(@listed);
  my @names = sort(grep { $_ ne "." && $_ ne ".." } readdir($listing));
  closedir($listing) or fail("cannot close prepared directory listing: $relative");
  fail("prepared directory allowlist mismatch: $relative")
    unless join("\0", @names) eq join("\0", sort(@{$children{$relative}}));
  my @after = stat($bound);
  my @path_after = lstat($path);
  close($bound) or fail("cannot close prepared directory: $relative");
  fail("prepared directory changed during inspection: $relative")
    unless @after && @path_after && identity(@opened) eq identity(@after)
      && identity(@opened) eq identity(@path_after);
}
sub read_bound_source {
  my ($relative, $mode, $expected_size, $expected_hash, $maximum, $capture) = @_;
  my $path = source_path($relative);
  my @before = lstat($path);
  fail("prepared file is not exact: $relative") unless @before && S_ISREG($before[2])
    && $before[4] == $prepared_uid && $before[5] == $prepared_gid
    && ($before[2] & 07777) == $mode && $before[7] > 0 && $before[7] <= $maximum
    && (!defined($expected_size) || $before[7] == $expected_size);
  sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
    or fail("cannot open prepared file: $relative");
  protect_handle($handle, "prepared file $relative");
  binmode($handle);
  my @opened = stat($handle);
  fail("prepared file changed while opening: $relative")
    unless @opened && identity(@before) eq identity(@opened);
  my ($hash, $size, $bytes) = read_exact_descriptor($handle, $maximum, $capture);
  my @after = stat($handle);
  my @path_after = lstat($path);
  close($handle) or fail("cannot close prepared file: $relative");
  fail("prepared file changed while reading: $relative")
    unless @after && @path_after && identity(@opened) eq identity(@after)
      && identity(@opened) eq identity(@path_after);
  fail("prepared file size mismatch: $relative") if defined($expected_size) && $size != $expected_size;
  fail("prepared file hash mismatch: $relative") if defined($expected_hash) && $hash ne $expected_hash;
  return ($hash, $size, $bytes);
}

assert_source_directory($_) for ("", @expected_directories);
my ($freeze_hash, $freeze_size, $freeze_bytes) = read_bound_source(
  "freeze-manifest.json", 0400, undef, $expected_freeze, MAXIMUM_JSON_BYTES, 1
);
my $codec = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);
my $freeze = eval { $codec->decode($freeze_bytes) };
fail("freeze manifest is invalid JSON") if $@ || ref($freeze) ne "HASH";
fail("freeze manifest is not canonical or has duplicate keys")
  unless $codec->encode($freeze) eq $freeze_bytes;
exact_keys($freeze, [qw(bundlePurpose files publicKeyFingerprintSHA256 pythonInterpreter reviewedSourceManifestSHA256 schemaVersion scriptSHA256)], "freeze manifest");
fail("freeze manifest identity mismatch") unless $freeze->{schemaVersion} == 2
  && $freeze->{bundlePurpose} eq "ushot-update-transition-fixtures-v1"
  && $freeze->{scriptSHA256} eq $expected_script
  && $freeze->{reviewedSourceManifestSHA256} eq $expected_reviewed
  && $freeze->{publicKeyFingerprintSHA256} eq "13d0f28d6b7199fcb2399d6183d74301294c1f859db765782ed9396161e440c8";
exact_keys($freeze->{pythonInterpreter}, [qw(path sha256)], "freeze Python");
fail("freeze Python identity mismatch")
  unless $freeze->{pythonInterpreter}{path} eq $expected_python_path
    && $freeze->{pythonInterpreter}{sha256} eq $expected_python_sha;
exact_keys($freeze->{files}, \@expected_files, "freeze files");
my %records;
for my $relative (@expected_files) {
  my $record = $freeze->{files}{$relative};
  exact_keys($record, [qw(mode sha256 size)], "freeze record $relative");
  my $expected_mode = $executable{$relative} ? "0500" : "0400";
  fail("freeze record mode mismatch: $relative") unless $record->{mode} eq $expected_mode;
  fail("freeze record hash malformed: $relative") unless canonical_hash($record->{sha256});
  fail("freeze record size malformed: $relative") unless defined($record->{size}) && !ref($record->{size})
    && $record->{size} =~ /\A[1-9][0-9]*\z/ && $record->{size} <= MAXIMUM_FILE_BYTES;
  $records{$relative} = $record;
}
fail("frozen script pin mismatch")
  unless $records{"scripts/prepare-update-transition-fixtures.sh"}{sha256} eq $expected_script;
fail("frozen reviewed manifest pin mismatch")
  unless $records{"metadata/reviewed-source-manifest.json"}{sha256} eq $expected_reviewed;

my (undef, undef, $reviewed_bytes) = read_bound_source(
  "metadata/reviewed-source-manifest.json", 0400,
  $records{"metadata/reviewed-source-manifest.json"}{size}, $expected_reviewed,
  MAXIMUM_JSON_BYTES, 1
);
my $reviewed = eval { $codec->decode($reviewed_bytes) };
fail("reviewed manifest is invalid JSON") if $@ || ref($reviewed) ne "HASH";
fail("reviewed manifest is not canonical or has duplicate keys")
  unless $codec->encode($reviewed) eq $reviewed_bytes;
exact_keys($reviewed, [qw(buildInputs candidateAssets credentialFreeOutputs mainScriptSHA256 purpose schemaVersion sources)], "reviewed manifest");
fail("reviewed manifest identity mismatch") unless $reviewed->{schemaVersion} == 2
  && $reviewed->{purpose} eq "ushot-update-transition-credential-free-pins-v1"
  && $reviewed->{mainScriptSHA256} eq $expected_script;
my @source_names = qw(
  Config/Base.xcconfig
  Tools/AuthenticatedAppcastValidator/main.swift
  UshotCore/Sources/UshotCore/Product/ProductIdentity.swift
  UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift
  UshotCore/Sources/UshotCore/Update/UpdateChecking.swift
  scripts/derive-sparkle-public-key.swift
  scripts/download-sparkle-tools.sh
  scripts/prepare-update-transition-fixtures.sh
  scripts/release-common.sh
  scripts/validate-appcast.sh
  scripts/validate-release-assets.sh
  updates/release-notes/0.1.4.md
  updates/v1/appcast.xml
);
my @output_names = qw(
  AuthenticatedAppcastValidator EmbeddedPublicKeyVerifier SparklePublicKeyDeriver
  generate_appcast generate_keys sign_update
);
my @asset_names = qw(
  SHA256SUMS.txt Ushot-0.1.4-arm64.dSYM.zip Ushot-0.1.4-arm64.dmg
  Ushot-0.1.4-arm64.release-manifest.json Ushot-0.1.4-arm64.zip
);
exact_keys($reviewed->{sources}, \@source_names, "reviewed sources");
exact_keys($reviewed->{credentialFreeOutputs}, \@output_names, "reviewed outputs");
exact_keys($reviewed->{candidateAssets}, \@asset_names, "reviewed assets");
exact_keys($reviewed->{buildInputs}, [qw(embeddedPublicKeyVerifierSourceSHA256 pythonInterpreter sparkleReleaseArchiveSHA256 swiftCompiler)], "reviewed build inputs");
for my $hash (values(%{$reviewed->{sources}}), values(%{$reviewed->{credentialFreeOutputs}}),
              values(%{$reviewed->{candidateAssets}}),
              $reviewed->{buildInputs}{embeddedPublicKeyVerifierSourceSHA256},
              $reviewed->{buildInputs}{sparkleReleaseArchiveSHA256}) {
  fail("reviewed manifest contains a malformed hash") unless canonical_hash($hash);
}
exact_keys($reviewed->{buildInputs}{pythonInterpreter}, [qw(path sha256)], "reviewed Python");
exact_keys($reviewed->{buildInputs}{swiftCompiler}, [qw(invocationPath resolvedPath sha256)], "reviewed Swift compiler");
fail("reviewed Python identity mismatch")
  unless $reviewed->{buildInputs}{pythonInterpreter}{path} eq $expected_python_path
    && $reviewed->{buildInputs}{pythonInterpreter}{sha256} eq $expected_python_sha;
fail("reviewed Swift compiler hash malformed")
  unless canonical_hash($reviewed->{buildInputs}{swiftCompiler}{sha256});
my %source_map = (
  "Config/Base.xcconfig" => "Config/Base.xcconfig",
  "scripts/prepare-update-transition-fixtures.sh" => "scripts/prepare-update-transition-fixtures.sh",
  "scripts/release-common.sh" => "scripts/release-common.sh",
  "scripts/validate-appcast.sh" => "scripts/validate-appcast.sh",
  "updates/release-notes/0.1.4.md" => "updates/release-notes/0.1.4.md",
  "updates/v1/appcast.xml" => "updates/v1/appcast.xml",
);
my %output_map = (
  "helpers/AuthenticatedAppcastValidator" => "AuthenticatedAppcastValidator",
  "helpers/EmbeddedPublicKeyVerifier" => "EmbeddedPublicKeyVerifier",
  "helpers/SparklePublicKeyDeriver" => "SparklePublicKeyDeriver",
  "tools/Sparkle-2.9.5/bin/generate_appcast" => "generate_appcast",
  "tools/Sparkle-2.9.5/bin/generate_keys" => "generate_keys",
  "tools/Sparkle-2.9.5/bin/sign_update" => "sign_update",
);
my %asset_map = (
  "assets/SHA256SUMS.txt" => "SHA256SUMS.txt",
  "assets/Ushot-0.1.4-arm64.dSYM.zip" => "Ushot-0.1.4-arm64.dSYM.zip",
  "assets/Ushot-0.1.4-arm64.dmg" => "Ushot-0.1.4-arm64.dmg",
  "assets/Ushot-0.1.4-arm64.release-manifest.json" => "Ushot-0.1.4-arm64.release-manifest.json",
  "assets/Ushot-0.1.4-arm64.zip" => "Ushot-0.1.4-arm64.zip",
);
for my $relative (keys(%source_map)) {
  fail("reviewed source disagrees with freeze record: $relative")
    unless $records{$relative}{sha256} eq $reviewed->{sources}{$source_map{$relative}};
}
for my $relative (keys(%output_map)) {
  fail("reviewed output disagrees with freeze record: $relative")
    unless $records{$relative}{sha256} eq $reviewed->{credentialFreeOutputs}{$output_map{$relative}};
}
for my $relative (keys(%asset_map)) {
  fail("reviewed asset disagrees with freeze record: $relative")
    unless $records{$relative}{sha256} eq $reviewed->{candidateAssets}{$asset_map{$relative}};
}
my (undef, undef, $archive_marker) = read_bound_source(
  "tools/Sparkle-2.9.5/.archive.sha256", 0400,
  $records{"tools/Sparkle-2.9.5/.archive.sha256"}{size},
  $records{"tools/Sparkle-2.9.5/.archive.sha256"}{sha256}, 256, 1
);
fail("Sparkle archive marker disagrees with reviewed input")
  unless $archive_marker eq $reviewed->{buildInputs}{sparkleReleaseArchiveSHA256};

sub assert_fixed_root_directory {
  my ($path, $exact_mode) = @_;
  my @before = lstat($path);
  fail("root destination directory is missing: $path") unless @before && S_ISDIR($before[2])
    && $before[4] == $destination_uid && ($before[2] & 0022) == 0
    && (!defined($exact_mode) || ($before[2] & 07777) == $exact_mode);
  sysopen(my $handle, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fail("cannot bind root destination directory: $path");
  protect_handle($handle, "root destination directory $path");
  my @opened = stat($handle);
  fail("root destination directory changed while opening: $path")
    unless @opened && identity(@before) eq identity(@opened);
  return $handle;
}
sub ensure_root_parent {
  my ($path, $parent_path) = @_;
  my @status = lstat($path);
  if (!@status) {
    fail("cannot establish root parent absence: $path") unless $!{ENOENT};
    mkdir($path, 0700) or fail("cannot create root parent: $path");
    my $new = assert_fixed_root_directory($path, 0700);
    set_handle_identity($new, 0755, $path);
    sync_handle($new, $path);
    close($new) or fail("cannot close new root parent: $path");
    my $parent = assert_fixed_root_directory($parent_path, undef);
    sync_handle($parent, "parent of $path");
    close($parent) or fail("cannot close parent of new root directory: $path");
  }
  my $bound = assert_fixed_root_directory($path, undef);
  my @bound_status = stat($bound);
  fail("root parent is not readable and traversable by the signing user: $path")
    unless @bound_status && ($bound_status[2] & 0555) == 0555;
  close($bound) or fail("cannot close root parent: $path");
}

my $library = assert_fixed_root_directory("/Library", undef);
close($library) or fail("cannot close /Library");
my $application_support = assert_fixed_root_directory("/Library/Application Support", undef);
close($application_support) or fail("cannot close Application Support");
ensure_root_parent(
  "/Library/Application Support/Ushot",
  "/Library/Application Support"
);
ensure_root_parent(
  "/Library/Application Support/Ushot/UpdateTransition",
  "/Library/Application Support/Ushot"
);
my @existing = lstat($final_frozen);
my $reuse_existing = 0;
if (@existing) {
  # A prior invocation may have completed the atomic rename and then lost its
  # process before parent fsync, ACL admission or PASS output. Never overwrite
  # that path. The common verification below must prove every byte and inode
  # policy again before this invocation can report success.
  $frozen = $final_frozen;
  $reuse_existing = 1;
} else {
  fail("cannot establish frozen destination absence") unless $!{ENOENT};
  my $staging_prefix = "/Library/Application Support/Ushot/UpdateTransition/.ushot-0.1.4-"
    . substr($expected_freeze, 0, 16) . ".staging.$$";
  for my $counter (0 .. 99) {
    my $candidate = "$staging_prefix.$counter";
    my @candidate_status = lstat($candidate);
    next if @candidate_status;
    fail("cannot establish staging destination absence") unless $!{ENOENT};
    if (mkdir($candidate, 0700)) {
      $frozen = $candidate;
      last;
    }
    next if $!{EEXIST};
    fail("cannot create unique frozen staging destination");
  }
  fail("could not allocate a unique frozen staging destination") unless defined($frozen);
  my $frozen_handle = assert_fixed_root_directory($frozen, 0700);
  set_handle_identity($frozen_handle, 0700, "frozen root");
  sync_handle($frozen_handle, "frozen root");
  close($frozen_handle) or fail("cannot close frozen root");
  my $initial_transition_parent = assert_fixed_root_directory(
    "/Library/Application Support/Ushot/UpdateTransition", undef
  );
  sync_handle($initial_transition_parent, "UpdateTransition parent after frozen-root creation");
  close($initial_transition_parent)
    or fail("cannot close UpdateTransition parent after frozen-root creation");

  for my $relative (sort {
    (($a =~ tr{/}{/}) <=> ($b =~ tr{/}{/})) || ($a cmp $b)
  } @expected_directories) {
    my $path = "$frozen/$relative";
    mkdir($path, 0700) or fail("cannot create frozen directory: $relative");
    my $handle = assert_fixed_root_directory($path, 0700);
    set_handle_identity($handle, 0700, "frozen directory $relative");
    sync_handle($handle, "frozen directory $relative");
    close($handle) or fail("cannot close frozen directory: $relative");
  }
}

sub copy_bound_source {
  my ($relative, $record, $destination_relative, $destination_mode) = @_;
  my $source = source_path($relative);
  my $destination = "$frozen/$destination_relative";
  my $source_mode = oct($record->{mode});
  my @before = lstat($source);
  fail("copy source is not exact: $relative") unless @before && S_ISREG($before[2])
    && $before[4] == $prepared_uid && $before[5] == $prepared_gid
    && ($before[2] & 07777) == $source_mode && $before[7] == $record->{size};
  sysopen(my $input, $source, O_RDONLY | O_NOFOLLOW)
    or fail("cannot bind copy source: $relative");
  protect_handle($input, "copy source $relative");
  binmode($input);
  my @opened = stat($input);
  fail("copy source changed while opening: $relative")
    unless @opened && identity(@before) eq identity(@opened);
  sysopen(my $output, $destination,
          O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or fail("cannot create frozen file: $destination_relative");
  protect_handle($output, "frozen file $destination_relative");
  binmode($output);
  my @created = stat($output);
  fail("frozen file creation identity mismatch: $destination_relative")
    unless @created && S_ISREG($created[2]) && $created[4] == $destination_uid
      && ($created[2] & 07777) == 0600 && $created[7] == 0;
  my $digest = Digest::SHA->new(256);
  my $copied = 0;
  while (1) {
    my $chunk = "";
    my $count = sysread($input, $chunk, 65536);
    if (!defined($count)) {
      next if $!{EINTR};
      fail("copy source read failed: $relative");
    }
    last if $count == 0;
    $copied += $count;
    fail("copy source exceeded manifest size: $relative") if $copied > $record->{size};
    $digest->add($chunk);
    write_all($output, $chunk);
  }
  fail("copy source size mismatch: $relative") unless $copied == $record->{size};
  fail("copy source hash mismatch: $relative") unless $digest->hexdigest eq $record->{sha256};
  my @source_after = stat($input);
  my @source_path_after = lstat($source);
  fail("copy source changed during copy: $relative")
    unless @source_after && @source_path_after
      && identity(@opened) eq identity(@source_after)
      && identity(@opened) eq identity(@source_path_after);
  set_handle_identity($output, $destination_mode, "frozen file $destination_relative");
  sync_handle($output, "frozen file $destination_relative");
  sysseek($output, 0, SEEK_SET) or fail("cannot rewind frozen file: $destination_relative");
  my ($output_hash, $output_size) = read_exact_descriptor(
    $output, $record->{size}, 0
  );
  fail("frozen file reread mismatch: $destination_relative")
    unless $output_size == $record->{size} && $output_hash eq $record->{sha256};
  my @output_after = stat($output);
  my @output_path_after = lstat($destination);
  fail("frozen file identity changed: $destination_relative")
    unless @output_after && @output_path_after && identity(@output_after) eq identity(@output_path_after)
      && $output_after[4] == $destination_uid && $output_after[5] == $destination_gid
      && ($output_after[2] & 07777) == $destination_mode;
  close($input) or fail("cannot close copy source: $relative");
  close($output) or fail("cannot close frozen file: $destination_relative");
}

if (!$reuse_existing) {
  for my $relative (@expected_files) {
    copy_bound_source(
      $relative,
      $records{$relative},
      $relative,
      $executable{$relative} ? 0555 : 0444
    );
  }
  copy_bound_source(
    "freeze-manifest.json",
    { mode => "0400", sha256 => $expected_freeze, size => $freeze_size },
    "freeze-manifest.json",
    0444
  );

  for my $relative (sort {
    (($b =~ tr{/}{/}) <=> ($a =~ tr{/}{/})) || ($b cmp $a)
  } @expected_directories) {
    my $path = "$frozen/$relative";
    my $handle = assert_fixed_root_directory($path, 0700);
    set_handle_identity($handle, 0555, "frozen directory $relative");
    sync_handle($handle, "frozen directory $relative");
    close($handle) or fail("cannot finalize frozen directory: $relative");
  }
  my $final_root = assert_fixed_root_directory($frozen, 0700);
  set_handle_identity($final_root, 0555, "frozen root");
  sync_handle($final_root, "frozen root");
  close($final_root) or fail("cannot finalize frozen root");
  my $transition_parent = assert_fixed_root_directory(
    "/Library/Application Support/Ushot/UpdateTransition", undef
  );
  sync_handle($transition_parent, "UpdateTransition parent");
  close($transition_parent) or fail("cannot close UpdateTransition parent");
}

sub assert_frozen_directory {
  my ($relative) = @_;
  my $path = $relative eq "" ? $frozen : "$frozen/$relative";
  my @before = lstat($path);
  fail("final frozen directory is not exact: $relative") unless @before
    && S_ISDIR($before[2]) && $before[4] == $destination_uid && $before[5] == $destination_gid
    && ($before[2] & 07777) == 0555;
  opendir(my $listing, $path) or fail("cannot list final frozen directory: $relative");
  my @opened = stat($listing);
  fail("final frozen directory changed while opening: $relative")
    unless @opened && identity(@before) eq identity(@opened);
  my @names = sort(grep { $_ ne "." && $_ ne ".." } readdir($listing));
  closedir($listing) or fail("cannot close final frozen listing: $relative");
  fail("final frozen directory allowlist mismatch: $relative")
    unless join("\0", @names) eq join("\0", sort(@{$children{$relative}}));
  my @after = lstat($path);
  fail("final frozen directory changed during listing: $relative")
    unless @after && identity(@before) eq identity(@after);
}
assert_frozen_directory($_) for ("", @expected_directories);
for my $relative (@expected_files) {
  my $record = $records{$relative};
  my $mode = $executable{$relative} ? 0555 : 0444;
  my $path = "$frozen/$relative";
  my @before = lstat($path);
  fail("final frozen file is not exact: $relative") unless @before && S_ISREG($before[2])
    && $before[4] == $destination_uid && $before[5] == $destination_gid && ($before[2] & 07777) == $mode
    && $before[7] == $record->{size};
  sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
    or fail("cannot open final frozen file: $relative");
  protect_handle($handle, "final frozen file $relative");
  my @opened = stat($handle);
  fail("final frozen file changed while opening: $relative")
    unless @opened && identity(@before) eq identity(@opened);
  my ($hash, $size) = read_exact_descriptor($handle, $record->{size}, 0);
  my @after = stat($handle);
  my @path_after = lstat($path);
  close($handle) or fail("cannot close final frozen file: $relative");
  fail("final frozen file verification failed: $relative")
    unless $hash eq $record->{sha256} && $size == $record->{size}
      && @after && @path_after && identity(@opened) eq identity(@after)
      && identity(@opened) eq identity(@path_after);
}
my $manifest_record = { mode => "0400", sha256 => $expected_freeze, size => $freeze_size };
my $manifest_path = "$frozen/freeze-manifest.json";
my @manifest_status = lstat($manifest_path);
fail("final freeze manifest identity mismatch") unless @manifest_status
  && S_ISREG($manifest_status[2]) && $manifest_status[4] == $destination_uid && $manifest_status[5] == $destination_gid
  && ($manifest_status[2] & 07777) == 0444 && $manifest_status[7] == $freeze_size;
sysopen(my $manifest_handle, $manifest_path, O_RDONLY | O_NOFOLLOW)
  or fail("cannot open final freeze manifest");
protect_handle($manifest_handle, "final freeze manifest");
my ($final_manifest_hash, $final_manifest_size) = read_exact_descriptor(
  $manifest_handle, $freeze_size, 0
);
close($manifest_handle) or fail("cannot close final freeze manifest");
fail("final freeze manifest content mismatch")
  unless $final_manifest_hash eq $expected_freeze && $final_manifest_size == $freeze_size;

assert_source_directory($_) for ("", @expected_directories);
verify_system_runtime();
if (!$reuse_existing) {
  my @staging_before_publish = lstat($frozen);
  fail("verified staging root changed before publication") unless @staging_before_publish
    && S_ISDIR($staging_before_publish[2])
    && $staging_before_publish[4] == $destination_uid
    && $staging_before_publish[5] == $destination_gid
    && ($staging_before_publish[2] & 07777) == 0555;
  my @final_before_publish = lstat($final_frozen);
  fail("frozen destination appeared before publication") if @final_before_publish;
  fail("cannot re-establish frozen destination absence before publication") unless $!{ENOENT};
  rename($frozen, $final_frozen) or fail("cannot atomically publish verified frozen destination");
  my @published = lstat($final_frozen);
  fail("published frozen destination identity mismatch")
    unless @published
      && publication_identity(@published) eq publication_identity(@staging_before_publish)
      && S_ISDIR($published[2]) && ($published[2] & 07777) == 0555;
  $frozen = $final_frozen;
}
my $published_parent = assert_fixed_root_directory(
  "/Library/Application Support/Ushot/UpdateTransition", undef
);
sync_handle(
  $published_parent,
  $reuse_existing
    ? "UpdateTransition parent after idempotent frozen verification"
    : "UpdateTransition parent after atomic publication"
);
close($published_parent) or fail("cannot close UpdateTransition parent after final verification");
print "result=SYSTEM_PERL_ROOT_FREEZE_VERIFIED_PENDING_ACL\n";
' \
      "$EARLY_PREPARED_BUNDLE" \
      "$EARLY_FROZEN_BUNDLE" \
      "$EARLY_EXPECTED_SCRIPT_SHA256" \
      "$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256" \
      "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" \
      "$EARLY_PYTHON_INTERPRETER_PATH" \
      "$EARLY_PYTHON_INTERPRETER_SHA256" \
      "$SUDO_UID" \
      "$SUDO_GID" \
    || early_die "SIP-protected system Perl root freeze failed closed; no signing key was requested."

  reject_root_freeze_acl "/Library/Application Support/Ushot"
  reject_root_freeze_acl "/Library/Application Support/Ushot/UpdateTransition"
  reject_root_freeze_acl "$EARLY_FROZEN_BUNDLE"
  local frozen_relative
  local -a frozen_acl_allowlist=(
    Config
    Config/Base.xcconfig
    assets
    assets/SHA256SUMS.txt
    assets/Ushot-0.1.4-arm64.dSYM.zip
    assets/Ushot-0.1.4-arm64.dmg
    assets/Ushot-0.1.4-arm64.release-manifest.json
    assets/Ushot-0.1.4-arm64.zip
    freeze-manifest.json
    helpers
    helpers/AuthenticatedAppcastValidator
    helpers/EmbeddedPublicKeyVerifier
    helpers/SparklePublicKeyDeriver
    inputs
    inputs/current
    inputs/current/appcast.kind
    inputs/current/appcast.xml
    metadata
    metadata/request.json
    metadata/reviewed-source-manifest.json
    scripts
    scripts/prepare-update-transition-fixtures.sh
    scripts/release-common.sh
    scripts/validate-appcast.sh
    tools
    tools/Sparkle-2.9.5
    tools/Sparkle-2.9.5/.archive.sha256
    tools/Sparkle-2.9.5/bin
    tools/Sparkle-2.9.5/bin/generate_appcast
    tools/Sparkle-2.9.5/bin/generate_keys
    tools/Sparkle-2.9.5/bin/sign_update
    updates
    updates/release-notes
    updates/release-notes/0.1.4.md
    updates/v1
    updates/v1/appcast.xml
  )
  for frozen_relative in "${frozen_acl_allowlist[@]}"; do
    reject_root_freeze_acl "$EARLY_FROZEN_BUNDLE/$frozen_relative"
  done
  unset frozen_relative frozen_acl_allowlist

  printf 'frozen_bundle=%s\nfreeze_manifest_sha256=%s\nreviewed_source_manifest_sha256=%s\nresult=ROOT_FREEZE_PASS\n' \
    "$EARLY_FROZEN_BUNDLE" \
    "$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256" \
    "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256"
}
if [[ "$EARLY_PHASE" == "root-freeze" ]]; then
  run_root_freeze_phase
  exit 0
fi

early_trusted_openssl_sha256() {
  local target_path="$1"
  local digest_output
  local digest

  [[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/openssl)" == "0:0:755" ]] \
    || early_die "System SHA-256 executable identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.openssl"' \
    /usr/bin/openssl \
    || early_die "System SHA-256 executable failed the Apple code-signing requirement."
  digest_output="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    OPENSSL_CONF=/dev/null \
    /usr/bin/openssl dgst -sha256 -r "$target_path")" \
    || early_die "Trusted system SHA-256 execution failed."
  digest="${digest_output%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || early_die "Trusted system SHA-256 output is malformed."
  printf '%s\n' "$digest"
}

early_rewind_descriptor() {
  local descriptor_fd="$1"

  [[ "$descriptor_fd" =~ ^[0-9]+$ ]] \
    || early_die "Cannot rewind a malformed descriptor identity."
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    /usr/bin/perl -T -f -e '
BEGIN {
  @INC = qw(
    /System/Library/Perl/5.34/darwin-thread-multi-2level
    /System/Library/Perl/5.34
  );
  %ENV = (
    PATH => "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG => "C",
    LC_ALL => "C",
  );
}
my $fd = shift(@ARGV);
die "bad fd\n" unless defined($fd) && !@ARGV && $fd =~ /\A([0-9]+)\z/;
$fd = 0 + $1;
open(my $handle, "<&=$fd") or die "dup failed\n";
sysseek($handle, 0, 0) or die "rewind failed\n";
' "$descriptor_fd" \
    || early_die "Could not rewind anonymous release-common descriptor."
}

reject_sign_runtime_acl() {
  local runtime_path="$1"
  local acl_lines

  acl_lines="$(/bin/ls -lde "$runtime_path" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" \
    || early_die "Could not inspect signing-runtime ACL: $runtime_path"
  [[ "$acl_lines" == "1" ]] \
    || early_die "ACL is forbidden on signing-runtime path: $runtime_path"
}

verify_sign_perl_runtime_boundary() {
  [[ "$EARLY_PHASE" == "sign" ]] || return 0

  local runtime_path
  local runtime_mode
  local actual_inc
  local expected_inc
  local append_to_path_sha
  local -a library_perl_entries

  [[ "$(/usr/bin/id -u)" != "0" ]] \
    || early_die "The signing phase must not run as root."
  [[ -f /usr/bin/perl && ! -L /usr/bin/perl \
      && "$(/usr/bin/stat -f '%u:%g:%Lp' /usr/bin/perl)" == "0:0:755" ]] \
    || early_die "System Perl identity is not exact."
  /usr/bin/codesign --verify --strict \
    --test-requirement '=anchor apple and identifier "com.apple.perl"' \
    /usr/bin/perl \
    || early_die "System Perl failed the Apple code-signing requirement."
  reject_sign_runtime_acl /usr/bin/perl

  expected_inc=$'/Library/Perl/5.34/darwin-thread-multi-2level\n/Library/Perl/5.34\n/Network/Library/Perl/5.34/darwin-thread-multi-2level\n/Network/Library/Perl/5.34\n/Library/Perl/Updates/5.34.1\n/System/Library/Perl/5.34/darwin-thread-multi-2level\n/System/Library/Perl/5.34\n/System/Library/Perl/Extras/5.34/darwin-thread-multi-2level\n/System/Library/Perl/Extras/5.34'
  actual_inc="$(/usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    /usr/bin/perl -T -f -e 'print join("\n", @INC), "\n"')" \
    || early_die "Could not inspect the system Perl include path."
  [[ "$actual_inc" == "$expected_inc" ]] \
    || early_die "System Perl default include path differs from the reviewed allowlist."

  for runtime_path in / /Library /Library/Perl /Library/Perl/5.34; do
    [[ -d "$runtime_path" && ! -L "$runtime_path" \
        && "$(/usr/bin/stat -f '%u:%g' "$runtime_path")" == "0:0" ]] \
      || early_die "Signing Perl search-path ancestry is not root-owned: $runtime_path"
    runtime_mode="$(/usr/bin/stat -f '%Lp' "$runtime_path")"
    [[ "$runtime_mode" =~ ^[0-7]+$ \
        && $((8#$runtime_mode & 8#22)) -eq 0 \
        && $((8#$runtime_mode & 8#555)) -eq $((8#555)) ]] \
      || early_die "Signing Perl search-path ancestry is writable or not traversable: $runtime_path"
    reject_sign_runtime_acl "$runtime_path"
  done
  [[ ! -e /Network && ! -L /Network \
      && ! -e /Library/Perl/Updates && ! -L /Library/Perl/Updates \
      && ! -e /Library/Perl/5.34/darwin-thread-multi-2level \
      && ! -L /Library/Perl/5.34/darwin-thread-multi-2level ]] \
    || early_die "A reviewed-absent non-System Perl search path appeared."

  shopt -s nullglob dotglob
  library_perl_entries=(/Library/Perl/5.34/*)
  shopt -u nullglob dotglob
  [[ "${#library_perl_entries[@]}" == "1" \
      && "${library_perl_entries[0]}" == "/Library/Perl/5.34/AppendToPath" ]] \
    || early_die "The non-System Perl 5.34 directory is not the exact reviewed one-entry tree."
  [[ -f /Library/Perl/5.34/AppendToPath \
      && ! -L /Library/Perl/5.34/AppendToPath \
      && "$(/usr/bin/stat -f '%u:%g:%Lp:%z' /Library/Perl/5.34/AppendToPath)" == "0:0:644:33" ]] \
    || early_die "The system-owned Perl AppendToPath marker identity differs."
  reject_sign_runtime_acl /Library/Perl/5.34/AppendToPath
  append_to_path_sha="$(early_trusted_openssl_sha256 /Library/Perl/5.34/AppendToPath)"
  [[ "$append_to_path_sha" == "de4a3186f172be76e002ad61c156d45a7e1d9bfe4a16461f8e46cb62a1981158" \
      && "$(< /Library/Perl/5.34/AppendToPath)" == "/System/Library/Perl/Extras/5.34" ]] \
    || early_die "The system-owned Perl AppendToPath marker content differs."
}

verify_sign_perl_runtime_boundary

# shellcheck source=release-common.sh
RELEASE_COMMON_SOURCE_DESCRIPTOR=""
RELEASE_COMMON_SOURCE_FD=""
if [[ "$EARLY_PHASE" == "sign" ]]; then
  # The sign launcher opened this exact root-owned frozen inode with
  # O_NOFOLLOW. Admission has already matched its dev/ino/hash to the frozen
  # allowlist. Source directly from that immutable descriptor; never copy it
  # into an inode writable by the signing user.
  exec 7< "$EARLY_RELEASE_COMMON_DESCRIPTOR"
  RELEASE_COMMON_SOURCE_DESCRIPTOR="/dev/fd/7"
  RELEASE_COMMON_SOURCE_FD="7"
else
  RELEASE_COMMON_ANONYMOUS_ROOT="$(/usr/bin/mktemp -d /private/tmp/ushot-release-common.XXXXXXXX)" \
    || early_die "Could not create private release-common staging."
  /bin/chmod 700 "$RELEASE_COMMON_ANONYMOUS_ROOT" \
    || early_die "Could not protect private release-common staging."
  RELEASE_COMMON_ANONYMOUS_PATH="$RELEASE_COMMON_ANONYMOUS_ROOT/release-common.sh"
  emit_hash_verified_source \
    scripts/release-common.sh \
    "$EARLY_RELEASE_COMMON_SHA256" \
    current \
    > "$RELEASE_COMMON_ANONYMOUS_PATH" \
    || early_die "Could not materialize fully hash-verified release-common bytes."
  /bin/chmod 400 "$RELEASE_COMMON_ANONYMOUS_PATH" \
    || early_die "Could not protect release-common anonymous snapshot."
  exec 7< "$RELEASE_COMMON_ANONYMOUS_PATH"
  /bin/rm "$RELEASE_COMMON_ANONYMOUS_PATH" \
    || early_die "Could not unlink release-common snapshot before execution."
  /bin/rmdir "$RELEASE_COMMON_ANONYMOUS_ROOT" \
    || early_die "Could not remove release-common staging directory."
  RELEASE_COMMON_SOURCE_DESCRIPTOR="/dev/fd/7"
  RELEASE_COMMON_SOURCE_FD="7"
fi
[[ "$RELEASE_COMMON_SOURCE_DESCRIPTOR" =~ ^/dev/fd/[0-9]+$ \
    && "$RELEASE_COMMON_SOURCE_FD" =~ ^[0-9]+$ ]] \
  || early_die "Release-common descriptor identity is malformed."
RELEASE_COMMON_FD_SHA256="$(early_trusted_openssl_sha256 "$RELEASE_COMMON_SOURCE_DESCRIPTOR")"
[[ "$RELEASE_COMMON_FD_SHA256" == "$EARLY_RELEASE_COMMON_SHA256" ]] \
  || early_die "Anonymous release-common descriptor hash mismatch before execution."
early_rewind_descriptor "$RELEASE_COMMON_SOURCE_FD"
RELEASE_COMMON_SOURCE_STATUS=0
builtin source "$RELEASE_COMMON_SOURCE_DESCRIPTOR" || RELEASE_COMMON_SOURCE_STATUS=$?
early_rewind_descriptor "$RELEASE_COMMON_SOURCE_FD"
RELEASE_COMMON_FD_SHA256="$(early_trusted_openssl_sha256 "$RELEASE_COMMON_SOURCE_DESCRIPTOR")"
[[ "$RELEASE_COMMON_SOURCE_STATUS" == "0" \
    && "$RELEASE_COMMON_FD_SHA256" == "$EARLY_RELEASE_COMMON_SHA256" ]] \
  || early_die "Anonymous release-common source failed or changed during execution."
exec 7<&-
if [[ "$EARLY_PHASE" != "sign" ]]; then
  unset EARLY_RELEASE_COMMON_DESCRIPTOR
fi
unset RELEASE_COMMON_ANONYMOUS_ROOT RELEASE_COMMON_ANONYMOUS_PATH RELEASE_COMMON_SOURCE_DESCRIPTOR \
  RELEASE_COMMON_SOURCE_FD RELEASE_COMMON_FD_SHA256 RELEASE_COMMON_SOURCE_STATUS
if [[ "$EARLY_PHASE" == "sign" ]]; then
  # The reviewed release-common helper uses the platform shasum/awk pair.
  # Replace it for the key-bearing phase with the already authenticated native
  # Apple OpenSSL path and its clean configuration environment.
  release_sha256() {
    early_trusted_openssl_sha256 "$1"
  }
fi
readonly TRANSITION_SOURCE_VERSION="0.1.3"
readonly TRANSITION_SOURCE_BUILD="4"
readonly FIXTURE_VERSION="0.1.4"
readonly FIXTURE_BUILD="5"
readonly FIXTURE_TAG="v0.1.4"
readonly SHORT_MISMATCH_VERSION="0.1.5"
readonly BUILD_MISMATCH_BUILD="6"
readonly ARCHIVE_NAME="$USHOT_PRODUCT_NAME-$FIXTURE_VERSION-$USHOT_ARCHITECTURE.zip"
readonly CANONICAL_ENCLOSURE_URL="https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/$FIXTURE_TAG/$ARCHIVE_NAME"
readonly LOOPBACK_MAX_FEED_FIXTURE_BYTES="2097152"
readonly OVERSIZED_FEED_PADDING_BYTES="1100000"
readonly SIGNED_FEED_WIRE_CEILING_BYTES="1049088"
readonly VALIDATOR_POLICY_EXIT_STATUS="65"
readonly RAW_XML_REJECTION_CATEGORY="invalid-version-identity"
readonly OVERSIZED_FEED_REJECTION_CATEGORY="oversized-signed-feed"
readonly SAFE_ARCHIVE_MAX_BYTES="134217728"
readonly SAFE_ARCHIVE_MAX_UNCOMPRESSED_BYTES="268435456"
readonly SAFE_ARCHIVE_MAX_ENTRY_BYTES="67108864"
readonly SAFE_ARCHIVE_MAX_ENTRIES="100000"
readonly SAFE_SYMLINK_TARGET_BYTES="4096"

OUTPUT_DIRECTORY=""
ASSETS_DIRECTORY=""
PHASE="$EARLY_PHASE"
KEY_SOURCE="$EARLY_KEY_SOURCE"
DRY_RUN="$EARLY_DRY_RUN"
EXPECTED_SCRIPT_SHA256="$EARLY_EXPECTED_SCRIPT_SHA256"
REVIEWED_SOURCE_MANIFEST="$EARLY_REVIEWED_SOURCE_MANIFEST"
REVIEWED_SOURCE_MANIFEST_SHA256="$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256"
PREPARED_BUNDLE_DIRECTORY="$EARLY_PREPARED_BUNDLE"
FROZEN_BUNDLE_DIRECTORY="$EARLY_FROZEN_BUNDLE"
EXPECTED_FREEZE_MANIFEST_SHA256="$EARLY_EXPECTED_FREEZE_MANIFEST_SHA256"
ROOT_COPY_DIRECTORY="$EARLY_ROOT_COPY_DIRECTORY"
PARSED_PROJECT_ROOT="$EARLY_PROJECT_ROOT"
PYTHON_INTERPRETER_PATH="$EARLY_PYTHON_INTERPRETER_PATH"
PYTHON_INTERPRETER_SHA256="$EARLY_PYTHON_INTERPRETER_SHA256"
WORKSPACE=""
WORKSPACE_PARENT=""
OUTPUT_STAGING=""
OUTPUT_PARENT=""
OUTPUT_CLEANUP_PATH=""
PREPARED_STAGING=""
PREPARED_CLEANUP_PATH=""

usage() {
  printf '%s\n' \
    "usage:" \
    "  $0 --phase review-pins --project-root ABS --output ABS_NEW_FILE --assets-directory ABS_DIR --expected-script-sha256 SHA256" \
    "  $0 --phase prepare --project-root ABS --output ABS_NEW --prepared-bundle ABS_NEW --assets-directory ABS_DIR --expected-script-sha256 SHA256 --reviewed-source-manifest ABS_FILE --reviewed-source-manifest-sha256 SHA256 --python-interpreter-path ABS --python-interpreter-sha256 SHA256" \
    "  # After explicit sudo freeze, run the printed anonymous-FD sign launcher." \
    "" \
    "Options:" \
    "  --phase PHASE            review-pins, prepare (default) or sign; root-freeze is internal." \
    "  --assets-directory PATH  Required exact 0.1.4/build 5 five-asset candidate directory." \
    "  --prepared-bundle PATH   Fresh Phase-A staging bundle to freeze as root." \
    "  --frozen-bundle PATH     Root-owned bundle used only by the sign launcher." \
    "  --expected-script-sha256 SHA256  Independently reviewed main-script hash." \
    "  --reviewed-source-manifest PATH  External exact source allowlist/hash manifest." \
    "  --reviewed-source-manifest-sha256 SHA256  Independently reviewed manifest hash." \
    "  --project-root PATH      Canonical repository root for credential-free phases." \
    "  --python-interpreter-path PATH  Externally pinned resolved Python interpreter." \
    "  --python-interpreter-sha256 SHA256  Externally pinned Python binary hash." \
    "  --expected-freeze-manifest-sha256 SHA256  Printed Phase-A freeze-manifest hash." \
    "  --key-source SOURCE      sign phase only: keychain (default) or stdin." \
    "  --dry-run                Phase-A admission/static checks only; never signs." \
    "  --help, -h               Show this help." \
    "" \
    "Prepare never reads a key. It snapshots/validates inputs, compiles helpers, emits a" \
    "hash-bound sudo freeze command, and returns PENDING_ROOT_FREEZE. The root phase" \
    "installs public bytes only and never reads a key. The current user then executes" \
    "the root-owned worker through a verified anonymous descriptor to create:" \
    "  normal, tampered-archive, short-version-mismatch, build-number-mismatch," \
    "  short-and-build-mismatch, duplicate-build-metadata, and oversized-signed-feed." \
    "Every case directly contains appcast.xml and $ARCHIVE_NAME so it can be passed" \
    "to serve-update-transition-loopback.sh. Feeds retain the exact production feed" \
    "URL and canonical GitHub enclosure URL; nothing is deployed or published." \
    "" \
    "Key handling:" \
    "  keychain uses only Sparkle's fixed account $USHOT_SPARKLE_KEY_ACCOUNT in sign." \
    "  stdin captures one canonical private seed in shell memory, closes stdin, and" \
    "  pipes it only to the reviewed deriver and checksum-pinned Sparkle tools." \
    "  The key is never printed, exported, written to disk or included in fixtures." \
    "" \
    "The duplicate-build-metadata case is deliberately well-formed XML with a valid" \
    "signed-feed EdDSA signature, but noncanonical authenticated metadata. The script" \
    "requires the app-identical policy validator to reject it; it is negative evidence," \
    "never a deployable appcast. If official sign_update cannot re-sign and verify the" \
    "variant, preparation fails instead of emitting a simulated raw-XML fixture. The" \
    "remaining raw-XML structures stay covered by SignedAppcastPolicy tests."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:?--phase requires a value}"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || release_die "--output requires a value."
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --assets-directory)
      [[ $# -ge 2 ]] || release_die "--assets-directory requires a value."
      ASSETS_DIRECTORY="$2"
      shift 2
      ;;
    --prepared-bundle) PREPARED_BUNDLE_DIRECTORY="${2:?--prepared-bundle requires a value}"; shift 2 ;;
    --frozen-bundle) FROZEN_BUNDLE_DIRECTORY="${2:?--frozen-bundle requires a value}"; shift 2 ;;
    --expected-script-sha256) EXPECTED_SCRIPT_SHA256="${2:?--expected-script-sha256 requires a value}"; shift 2 ;;
    --reviewed-source-manifest) REVIEWED_SOURCE_MANIFEST="${2:?--reviewed-source-manifest requires a value}"; shift 2 ;;
    --reviewed-source-manifest-sha256) REVIEWED_SOURCE_MANIFEST_SHA256="${2:?--reviewed-source-manifest-sha256 requires a value}"; shift 2 ;;
    --expected-freeze-manifest-sha256) EXPECTED_FREEZE_MANIFEST_SHA256="${2:?--expected-freeze-manifest-sha256 requires a value}"; shift 2 ;;
    --root-copy-directory) ROOT_COPY_DIRECTORY="${2:?--root-copy-directory requires a value}"; shift 2 ;;
    --project-root) PARSED_PROJECT_ROOT="${2:?--project-root requires a value}"; shift 2 ;;
    --python-interpreter-path) PYTHON_INTERPRETER_PATH="${2:?--python-interpreter-path requires a value}"; shift 2 ;;
    --python-interpreter-sha256) PYTHON_INTERPRETER_SHA256="${2:?--python-interpreter-sha256 requires a value}"; shift 2 ;;
    --key-source)
      [[ $# -ge 2 ]] || release_die "--key-source requires a value."
      KEY_SOURCE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      release_die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$OUTPUT_DIRECTORY" ]] || { usage >&2; exit 1; }
[[ "$PHASE" == "$EARLY_PHASE" ]] || release_die "Phase preflight disagreed with parsed arguments."
[[ "$PHASE" == "review-pins" || "$PHASE" == "prepare" || "$PHASE" == "sign" ]] \
  || release_die "Only review-pins, prepare and sign phases may reach the ordinary-user worker."
[[ "$KEY_SOURCE" == "keychain" || "$KEY_SOURCE" == "stdin" ]] \
  || release_die "--key-source must be keychain or stdin."
[[ "$KEY_SOURCE" == "$EARLY_KEY_SOURCE" ]] \
  || release_die "Key-source preflight disagreed with parsed arguments."
[[ "$DRY_RUN" == "$EARLY_DRY_RUN" ]] \
  || release_die "Dry-run preflight disagreed with parsed arguments."
[[ "$PARSED_PROJECT_ROOT" == "$EARLY_PROJECT_ROOT" \
    && "$PYTHON_INTERPRETER_PATH" == "$EARLY_PYTHON_INTERPRETER_PATH" \
    && "$PYTHON_INTERPRETER_SHA256" == "$EARLY_PYTHON_INTERPRETER_SHA256" ]] \
  || release_die "Project-root/Python preflight disagreed with parsed arguments."
unset EARLY_ARGUMENTS EARLY_DRY_RUN EARLY_HELP_REQUESTED EARLY_KEY_SOURCE

canonical_new_directory_path() {
  local requested_path="$1"
  local description="$2"
  local parent
  local canonical_parent
  local basename_value
  local canonical_path

  case "$requested_path" in
    /*) ;;
    *) release_die "$description path must be absolute." ;;
  esac
  parent="$(/usr/bin/dirname "$requested_path")"
  basename_value="$(/usr/bin/basename "$requested_path")"
  [[ -n "$basename_value" && "$basename_value" != "." && "$basename_value" != ".." ]] \
    || release_die "$description has an invalid basename."
  [[ -d "$parent" && ! -L "$parent" ]] \
    || release_die "$description parent must be an existing real directory."
  canonical_parent="$(cd "$parent" && pwd -P)"
  canonical_path="$canonical_parent/$basename_value"
  [[ "$requested_path" == "$canonical_path" ]] \
    || release_die "$description path must be canonical and may not traverse symbolic links, dot components or parent components."
  [[ ! -e "$canonical_path" && ! -L "$canonical_path" ]] \
    || release_die "Refusing to reuse or overwrite existing $description path: $canonical_path"
  printf '%s\n' "$canonical_path"
}

canonical_new_file_path() {
  local requested_path="$1"
  local description="$2"
  local parent
  local canonical_parent
  local basename_value
  local canonical_path

  case "$requested_path" in
    /*) ;;
    *) release_die "$description path must be absolute." ;;
  esac
  parent="$(/usr/bin/dirname "$requested_path")"
  basename_value="$(/usr/bin/basename "$requested_path")"
  [[ -n "$basename_value" && "$basename_value" != "." && "$basename_value" != ".." ]] \
    || release_die "$description has an invalid basename."
  [[ -d "$parent" && ! -L "$parent" ]] \
    || release_die "$description parent must be an existing real directory."
  canonical_parent="$(cd "$parent" && pwd -P)"
  canonical_path="$canonical_parent/$basename_value"
  [[ "$requested_path" == "$canonical_path" ]] \
    || release_die "$description path must be canonical and may not traverse symbolic links, dot components or parent components."
  [[ ! -e "$canonical_path" && ! -L "$canonical_path" ]] \
    || release_die "Refusing to reuse or overwrite existing $description path: $canonical_path"
  printf '%s\n' "$canonical_path"
}

canonical_existing_directory_path() {
  local requested_path="$1"
  local description="$2"

  case "$requested_path" in
    /*) ;;
    *) release_die "$description path must be absolute." ;;
  esac
  [[ -d "$requested_path" && ! -L "$requested_path" ]] \
    || release_die "$description must be an existing real, non-symbolic-link directory."
  [[ "$(cd "$requested_path" && pwd -P)" == "$requested_path" ]] \
    || release_die "$description path must be canonical and may not traverse symbolic links."
  printf '%s\n' "$requested_path"
}

if [[ "$PHASE" == "review-pins" ]]; then
  OUTPUT_DIRECTORY="$(canonical_new_file_path "$OUTPUT_DIRECTORY" "reviewed pin manifest output")"
else
  OUTPUT_DIRECTORY="$(canonical_new_directory_path "$OUTPUT_DIRECTORY" "fixture output")"
fi
OUTPUT_PARENT="$(/usr/bin/dirname "$OUTPUT_DIRECTORY")"
if [[ "$PHASE" == "review-pins" ]]; then
  [[ -n "$ASSETS_DIRECTORY" ]] \
    || release_die "review-pins requires the exact five-asset candidate directory."
  ASSETS_DIRECTORY="$(canonical_existing_directory_path "$ASSETS_DIRECTORY" "candidate assets directory")"
  [[ -z "$PREPARED_BUNDLE_DIRECTORY" && -z "$FROZEN_BUNDLE_DIRECTORY" \
      && -z "$REVIEWED_SOURCE_MANIFEST" && -z "$REVIEWED_SOURCE_MANIFEST_SHA256" ]] \
    || release_die "review-pins does not accept prepared/frozen bundle or reviewed-manifest inputs."
  [[ "$KEY_SOURCE" == "keychain" ]] \
    || release_die "review-pins rejects every explicit key input."
elif [[ "$PHASE" == "prepare" ]]; then
  [[ -n "$ASSETS_DIRECTORY" ]] \
    || release_die "The prepare phase requires --assets-directory; it never builds an unreviewed candidate implicitly."
  [[ -n "$PREPARED_BUNDLE_DIRECTORY" ]] \
    || release_die "The prepare phase requires a fresh --prepared-bundle destination."
  ASSETS_DIRECTORY="$(canonical_existing_directory_path "$ASSETS_DIRECTORY" "candidate assets directory")"
  PREPARED_BUNDLE_DIRECTORY="$(canonical_new_directory_path "$PREPARED_BUNDLE_DIRECTORY" "prepared freeze bundle")"
  [[ "$KEY_SOURCE" == "keychain" ]] \
    || release_die "The prepare phase rejects --key-source stdin because it never reads a key."
  [[ "$REVIEWED_SOURCE_MANIFEST_SHA256" == "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" \
      && "$PYTHON_INTERPRETER_PATH" == /* \
      && "$PYTHON_INTERPRETER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Prepare manifest/Python pins disagreed with early admission."
else
  [[ -z "$ASSETS_DIRECTORY" && -z "$PREPARED_BUNDLE_DIRECTORY" \
      && -z "$REVIEWED_SOURCE_MANIFEST" ]] \
    || release_die "The sign phase accepts inputs only from the admitted root-owned frozen bundle."
  FROZEN_BUNDLE_DIRECTORY="$(canonical_existing_directory_path "$FROZEN_BUNDLE_DIRECTORY" "root-owned frozen bundle")"
  [[ "$FROZEN_BUNDLE_DIRECTORY" == "$EARLY_FROZEN_BUNDLE" ]] \
    || release_die "Frozen bundle preflight disagreed with the parsed path."
  [[ "$REVIEWED_SOURCE_MANIFEST_SHA256" == "$EARLY_REVIEWED_SOURCE_MANIFEST_SHA256" \
      && "$REVIEWED_SOURCE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$PYTHON_INTERPRETER_PATH" == "$EARLY_PYTHON_INTERPRETER_PATH" \
      && "$PYTHON_INTERPRETER_SHA256" == "$EARLY_PYTHON_INTERPRETER_SHA256" ]] \
    || release_die "Sign manifest/Python pins disagreed with early admission."
fi

[[ "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" == "$TRANSITION_SOURCE_VERSION" \
    && "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" == "$TRANSITION_SOURCE_BUILD" ]] \
  || release_die "Published source-transition constants drifted from 0.1.3 (build 4)."
[[ "$USHOT_FIRST_FEED_VERSION" == "$FIXTURE_VERSION" \
    && "$USHOT_FIRST_FEED_BUILD" == "$FIXTURE_BUILD" ]] \
  || release_die "First-feed constants drifted from the fixed 0.1.4 (build 5) fixture identity."
[[ "$USHOT_MAX_SIGNED_APPCAST_BYTES" == "$SIGNED_FEED_WIRE_CEILING_BYTES" \
    && "$USHOT_SIGNED_APPCAST_TRAILER_ALLOWANCE_BYTES" == "512" \
    && $((10#$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES + 10#$USHOT_SIGNED_APPCAST_TRAILER_ALLOWANCE_BYTES)) \
      -eq 10#$SIGNED_FEED_WIRE_CEILING_BYTES ]] \
  || release_die "Signed-feed wire ceiling drifted from the reviewed 1,049,088-byte boundary."
release_validate_feed_release_identity "$FIXTURE_VERSION" "$FIXTURE_BUILD"
release_validate_tag "$FIXTURE_TAG" "$FIXTURE_VERSION"
if [[ "$PHASE" == "review-pins" || "$PHASE" == "prepare" ]]; then
  release_validate_source_settings "$PROJECT_ROOT" "$FIXTURE_VERSION" "$FIXTURE_BUILD"
fi
RELEASE_NOTES_SOURCE="$PROJECT_ROOT/updates/release-notes/$FIXTURE_VERSION.md"
release_validate_release_notes_source "$RELEASE_NOTES_SOURCE"
[[ "$USHOT_APPCAST_URL" == "https://ischeneycc.github.io/ushot/updates/v1/appcast.xml" ]] \
  || release_die "Production appcast URL drifted from the reviewed v1 endpoint."
[[ "$CANONICAL_ENCLOSURE_URL" == "https://github.com/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.zip" ]] \
  || release_die "Canonical fixture enclosure URL drifted from the reviewed first-feed asset."

for command_name in \
  codesign \
  cmp \
  curl \
  ditto \
  find \
  grep \
  jq \
  perl \
  sandbox-exec \
  shasum \
  stat \
  tail \
  tr \
  wc \
  xcrun \
  xmllint \
  zipinfo; do
  release_require_command "$command_name"
done
/usr/bin/perl \
  -MCompress::Raw::Zlib \
  -MIO::Compress::Zip \
  -MIO::Uncompress::RawInflate \
  -e 'exit 0' \
  || release_die "Required system Perl ZIP validation modules are unavailable."

if [[ "$DRY_RUN" == "true" ]]; then
  [[ "$PHASE" == "prepare" ]] \
    || release_die "--dry-run is restricted to the key-free prepare phase."
  release_log "Dry-run passed: source=$TRANSITION_SOURCE_VERSION/$TRANSITION_SOURCE_BUILD target=$FIXTURE_VERSION/$FIXTURE_BUILD."
  release_log "Dry-run passed: feed_url=$USHOT_APPCAST_URL"
  release_log "Dry-run passed: enclosure_url=$CANONICAL_ENCLOSURE_URL"
  release_log "Dry-run will reuse and fully validate candidate assets from $ASSETS_DIRECTORY."
  release_log "Dry-run performed no build, download, network request, signing, output creation or key access."
  printf 'result=DRY_RUN_PASS\n'
  exit 0
fi

if [[ "$PHASE" == "prepare" ]]; then
  WORKSPACE_PARENT="$PROJECT_ROOT/build"
else
  WORKSPACE_PARENT="$OUTPUT_PARENT"
fi
[[ ! -L "$WORKSPACE_PARENT" ]] \
  || release_die "Build workspace root must not be a symbolic link: $WORKSPACE_PARENT"
/bin/mkdir -p "$WORKSPACE_PARENT"
WORKSPACE_PARENT="$(cd "$WORKSPACE_PARENT" && pwd -P)"

cleanup_private_directory() {
  local directory_path="$1"
  local expected_parent="$2"
  local expected_prefix="$3"
  local canonical_parent=""

  [[ -n "$directory_path" && -d "$directory_path" && ! -L "$directory_path" ]] \
    || return 0
  canonical_parent="$(cd "$(/usr/bin/dirname "$directory_path")" 2>/dev/null && pwd -P)" || return 0
  if [[ "$canonical_parent" == "$expected_parent" \
      && "$(/usr/bin/basename "$directory_path")" == "$expected_prefix".* \
      && "$(/usr/bin/stat -f '%u' "$directory_path" 2>/dev/null)" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$directory_path" 2>/dev/null)" == "700" ]]; then
    /bin/rm -rf -- "$directory_path"
  else
    release_warn "Refused to remove a temporary directory whose identity or permissions changed: $directory_path"
  fi
}

cleanup_final_output_on_failure() {
  local directory_path="$1"

  [[ -n "$directory_path" \
      && "$directory_path" == "$OUTPUT_DIRECTORY" \
      && -d "$directory_path" \
      && ! -L "$directory_path" \
      && "$(cd "$(/usr/bin/dirname "$directory_path")" && pwd -P)/$(/usr/bin/basename "$directory_path")" == "$OUTPUT_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u' "$directory_path")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$directory_path")" == "700" ]] \
    || return 0
  /bin/rm -rf -- "$directory_path"
}

cleanup_prepared_bundle_on_failure() {
  local directory_path="$1"

  [[ -n "$directory_path" \
      && "$directory_path" == "$PREPARED_BUNDLE_DIRECTORY" \
      && -d "$directory_path" \
      && ! -L "$directory_path" \
      && "$(cd "$(/usr/bin/dirname "$directory_path")" && pwd -P)/$(/usr/bin/basename "$directory_path")" == "$PREPARED_BUNDLE_DIRECTORY" \
      && "$(/usr/bin/stat -f '%u' "$directory_path")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$directory_path")" == "700" ]] \
    || return 0
  /bin/rm -rf -- "$directory_path"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  unset PRIVATE_KEY DERIVED_PUBLIC_KEY
  if [[ -n "${OUTPUT_CLEANUP_PATH:-}" ]]; then
    cleanup_final_output_on_failure "$OUTPUT_CLEANUP_PATH"
  fi
  if [[ -n "${PREPARED_CLEANUP_PATH:-}" ]]; then
    cleanup_prepared_bundle_on_failure "$PREPARED_CLEANUP_PATH"
  fi
  if [[ -n "${OUTPUT_STAGING:-}" ]]; then
    cleanup_private_directory \
      "$OUTPUT_STAGING" \
      "$OUTPUT_PARENT" \
      ".ushot-update-transition-fixtures"
  fi
  if [[ -n "${PREPARED_STAGING:-}" ]]; then
    cleanup_private_directory \
      "$PREPARED_STAGING" \
      "$(/usr/bin/dirname "$PREPARED_BUNDLE_DIRECTORY")" \
      ".ushot-freeze-prepared"
  fi
  if [[ -n "${WORKSPACE:-}" ]]; then
    local workspace_prefix="update-transition-fixtures"
    if [[ "$PHASE" == "review-pins" ]]; then
      workspace_prefix=".ushot-update-transition-review-pins"
    elif [[ "$PHASE" != "prepare" ]]; then
      workspace_prefix=".ushot-update-transition-sign"
    fi
    cleanup_private_directory \
      "$WORKSPACE" \
      "$WORKSPACE_PARENT" \
      "$workspace_prefix"
  fi
  exit "$status"
}

signal_exit() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}

trap cleanup EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

if [[ "$PHASE" == "prepare" ]]; then
  WORKSPACE="$(/usr/bin/mktemp -d "$WORKSPACE_PARENT/update-transition-fixtures.XXXXXXXX")"
elif [[ "$PHASE" == "review-pins" ]]; then
  WORKSPACE="$(/usr/bin/mktemp -d "$WORKSPACE_PARENT/.ushot-update-transition-review-pins.XXXXXXXX")"
else
  WORKSPACE="$(/usr/bin/mktemp -d "$WORKSPACE_PARENT/.ushot-update-transition-sign.XXXXXXXX")"
fi
/bin/chmod 700 "$WORKSPACE"
[[ -d "$WORKSPACE" && ! -L "$WORKSPACE" \
    && "$(/usr/bin/dirname "$WORKSPACE")" == "$WORKSPACE_PARENT" \
    && "$(/usr/bin/stat -f '%u' "$WORKSPACE")" == "$(/usr/bin/id -u)" \
    && "$(/usr/bin/stat -f '%Lp' "$WORKSPACE")" == "700" ]] \
  || release_die "Could not establish a mode-0700 canonical fixture workspace."
[[ -z "$(/usr/bin/find "$WORKSPACE" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || release_die "Fresh fixture workspace was unexpectedly nonempty."
[[ ! -e "$WORKSPACE/-" && ! -L "$WORKSPACE/-" ]] \
  || release_die "Fresh fixture workspace unexpectedly contains a dash-named entry."

TMPDIR="$WORKSPACE/tmp"
/bin/mkdir -m 700 "$TMPDIR"
export TMPDIR

capture_regular_file_binding() {
  local file_path="$1"
  local maximum_bytes="$2"
  local binding_label="$3"
  local owner_policy="${4:-current}"

  [[ "$file_path" == /* \
      && "$maximum_bytes" =~ ^[1-9][0-9]*$ \
      && "$binding_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
      && ("$owner_policy" == "current" || "$owner_policy" == "system") ]] \
    || release_die "Invalid regular-file binding request for $binding_label."
  USHOT_BOUND_FILE="$file_path" \
  USHOT_BOUND_MAXIMUM_BYTES="$maximum_bytes" \
  USHOT_BOUND_LABEL="$binding_label" \
  USHOT_BOUND_OWNER_POLICY="$owner_policy" \
    /usr/bin/perl \
      -MDigest::SHA \
      -MFcntl=O_RDONLY,O_NOFOLLOW \
      -MPOSIX=S_ISREG,SEEK_SET \
      -e '
        use strict;
        use warnings;

        sub fail {
          die "file binding $ENV{USHOT_BOUND_LABEL}: $_[0]\n";
        }
        sub identity {
          my (@stat) = @_;
          return join(",", @stat[0, 1, 2, 4, 7, 9, 10]);
        }
        sub digest_handle {
          my ($handle) = @_;
          seek($handle, 0, SEEK_SET) or fail("cannot rewind file descriptor");
          my $digest = Digest::SHA->new(256);
          while (1) {
            my $buffer = "";
            my $read_count = sysread($handle, $buffer, 65536);
            fail("cannot read file descriptor") unless defined($read_count);
            last if $read_count == 0;
            $digest->add($buffer);
          }
          return $digest->hexdigest;
        }

        my $path = $ENV{USHOT_BOUND_FILE} // fail("missing path");
        my $maximum = $ENV{USHOT_BOUND_MAXIMUM_BYTES} // fail("missing size limit");
        my $owner_policy = $ENV{USHOT_BOUND_OWNER_POLICY} // fail("missing owner policy");
        my @path_before = lstat($path);
        fail("path is absent") unless @path_before;
        fail("path is not a regular file") unless S_ISREG($path_before[2]);
        sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
          or fail("cannot open with O_NOFOLLOW");
        binmode($handle);
        my @descriptor_before = stat($handle);
        fail("cannot stat opened descriptor") unless @descriptor_before;
        fail("path changed while opening")
          unless identity(@path_before) eq identity(@descriptor_before);
        fail("opened descriptor is not regular") unless S_ISREG($descriptor_before[2]);
        fail("file owner is not trusted")
          unless ($owner_policy eq "current" && $descriptor_before[4] == $<)
            || ($owner_policy eq "system" && $descriptor_before[4] == 0);
        fail("file is group- or world-writable") if ($descriptor_before[2] & 0022) != 0;
        fail("file is empty or oversized")
          unless $descriptor_before[7] > 0 && $descriptor_before[7] <= $maximum;
        my $digest = digest_handle($handle);
        my @descriptor_after = stat($handle);
        my @path_after = lstat($path);
        fail("descriptor changed while hashing")
          unless @descriptor_after
            && identity(@descriptor_before) eq identity(@descriptor_after);
        fail("path changed while hashing")
          unless @path_after
            && identity(@descriptor_before) eq identity(@path_after);
        close($handle) or fail("cannot close descriptor");
        printf(
          "dev=%s,inode=%s,size=%s,mtime=%s,ctime=%s,mode=%04o,uid=%s,sha256=%s\n",
          $descriptor_before[0],
          $descriptor_before[1],
          $descriptor_before[7],
          $descriptor_before[9],
          $descriptor_before[10],
          $descriptor_before[2] & 07777,
          $descriptor_before[4],
          $digest
        );
      '
}

snapshot_regular_file_no_follow() {
  local source_path="$1"
  local destination_path="$2"
  local maximum_bytes="$3"
  local snapshot_label="$4"
  local owner_policy="${5:-current}"

  [[ "$source_path" == /* \
      && "$destination_path" == /* \
      && "$maximum_bytes" =~ ^[1-9][0-9]*$ \
      && "$snapshot_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
      && ("$owner_policy" == "current" || "$owner_policy" == "system") ]] \
    || release_die "Invalid private snapshot request for $snapshot_label."
  USHOT_SNAPSHOT_SOURCE="$source_path" \
  USHOT_SNAPSHOT_DESTINATION="$destination_path" \
  USHOT_SNAPSHOT_MAXIMUM_BYTES="$maximum_bytes" \
  USHOT_SNAPSHOT_LABEL="$snapshot_label" \
  USHOT_SNAPSHOT_OWNER_POLICY="$owner_policy" \
    /usr/bin/perl \
      -MDigest::SHA \
      -MFcntl=O_RDONLY,O_WRONLY,O_CREAT,O_EXCL,O_NOFOLLOW \
      -MIO::Handle \
      -MPOSIX=S_ISREG,SEEK_SET \
      -e '
        use strict;
        use warnings;

        sub fail {
          die "file snapshot $ENV{USHOT_SNAPSHOT_LABEL}: $_[0]\n";
        }
        sub identity {
          my (@stat) = @_;
          return join(",", @stat[0, 1, 2, 4, 7, 9, 10]);
        }
        sub digest_handle {
          my ($handle) = @_;
          seek($handle, 0, SEEK_SET) or fail("cannot rewind file descriptor");
          my $digest = Digest::SHA->new(256);
          while (1) {
            my $buffer = "";
            my $read_count = sysread($handle, $buffer, 65536);
            fail("cannot read file descriptor") unless defined($read_count);
            last if $read_count == 0;
            $digest->add($buffer);
          }
          return $digest->hexdigest;
        }
        sub write_all {
          my ($handle, $buffer) = @_;
          my $offset = 0;
          while ($offset < length($buffer)) {
            my $written = syswrite(
              $handle,
              $buffer,
              length($buffer) - $offset,
              $offset
            );
            fail("cannot write destination descriptor")
              unless defined($written) && $written > 0;
            $offset += $written;
          }
        }

        my $source = $ENV{USHOT_SNAPSHOT_SOURCE} // fail("missing source path");
        my $destination = $ENV{USHOT_SNAPSHOT_DESTINATION} // fail("missing destination path");
        my $maximum = $ENV{USHOT_SNAPSHOT_MAXIMUM_BYTES} // fail("missing size limit");
        my $owner_policy = $ENV{USHOT_SNAPSHOT_OWNER_POLICY} // fail("missing owner policy");
        my @path_before = lstat($source);
        fail("source is absent") unless @path_before;
        fail("source is not a regular file") unless S_ISREG($path_before[2]);
        sysopen(my $input, $source, O_RDONLY | O_NOFOLLOW)
          or fail("cannot open source with O_NOFOLLOW");
        binmode($input);
        my @descriptor_before = stat($input);
        fail("cannot stat source descriptor") unless @descriptor_before;
        fail("source path changed while opening")
          unless identity(@path_before) eq identity(@descriptor_before);
        fail("source owner is not trusted")
          unless ($owner_policy eq "current" && $descriptor_before[4] == $<)
            || ($owner_policy eq "system" && $descriptor_before[4] == 0);
        fail("source is group- or world-writable") if ($descriptor_before[2] & 0022) != 0;
        fail("source is empty or oversized")
          unless $descriptor_before[7] > 0 && $descriptor_before[7] <= $maximum;
        my $digest_before = digest_handle($input);
        seek($input, 0, SEEK_SET) or fail("cannot rewind source for snapshot");
        sysopen(
          my $output,
          $destination,
          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
          0600
        ) or fail("cannot create fresh destination with O_NOFOLLOW");
        binmode($output);
        my $copy_digest = Digest::SHA->new(256);
        my $copied_bytes = 0;
        while (1) {
          my $buffer = "";
          my $read_count = sysread($input, $buffer, 65536);
          fail("cannot read source while snapshotting") unless defined($read_count);
          last if $read_count == 0;
          $copied_bytes += $read_count;
          fail("source exceeded its bound size while snapshotting")
            if $copied_bytes > $descriptor_before[7];
          $copy_digest->add($buffer);
          write_all($output, $buffer);
        }
        $output->flush() or fail("cannot flush destination");
        $output->sync() or fail("cannot synchronize destination");
        close($output) or fail("cannot close destination");
        my $digest_after = $copy_digest->hexdigest;
        fail("source digest changed between binding and snapshot")
          unless $digest_after eq $digest_before;
        fail("source byte count changed while snapshotting")
          unless $copied_bytes == $descriptor_before[7];
        my @descriptor_after = stat($input);
        my @path_after = lstat($source);
        fail("source descriptor changed while snapshotting")
          unless @descriptor_after
            && identity(@descriptor_before) eq identity(@descriptor_after);
        fail("source path changed while snapshotting")
          unless @path_after
            && identity(@descriptor_before) eq identity(@path_after);
        close($input) or fail("cannot close source descriptor");
        chmod(0400, $destination) == 1 or fail("cannot make destination read-only");
        sysopen(my $verification, $destination, O_RDONLY | O_NOFOLLOW)
          or fail("cannot reopen destination with O_NOFOLLOW");
        binmode($verification);
        my @destination_stat = stat($verification);
        fail("destination is not the expected private regular file")
          unless @destination_stat
            && S_ISREG($destination_stat[2])
            && $destination_stat[4] == $<
            && ($destination_stat[2] & 07777) == 0400
            && $destination_stat[7] == $descriptor_before[7];
        my $destination_digest = digest_handle($verification);
        close($verification) or fail("cannot close verification descriptor");
        fail("destination digest differs from bound source")
          unless $destination_digest eq $digest_before;
        my @destination_path_stat = lstat($destination);
        fail("destination path changed after verification")
          unless @destination_path_stat
            && identity(@destination_stat) eq identity(@destination_path_stat);
        printf(
          "dev=%s,inode=%s,size=%s,mtime=%s,ctime=%s,mode=%04o,uid=%s,sha256=%s\n",
          $descriptor_before[0],
          $descriptor_before[1],
          $descriptor_before[7],
          $descriptor_before[9],
          $descriptor_before[10],
          $descriptor_before[2] & 07777,
          $descriptor_before[4],
          $digest_before
        );
      '
}

binding_sha256() {
  local binding="$1"
  local digest="${binding##*sha256=}"

  [[ "$binding" == *",sha256=$digest" && "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Could not parse a regular-file SHA-256 binding."
  printf '%s\n' "$digest"
}

verify_bound_regular_file() {
  local file_path="$1"
  local maximum_bytes="$2"
  local binding_label="$3"
  local expected_binding="$4"
  local owner_policy="${5:-current}"
  local actual_binding

  actual_binding="$(
    capture_regular_file_binding \
      "$file_path" \
      "$maximum_bytes" \
      "$binding_label" \
      "$owner_policy"
  )" || release_die "$binding_label could not be rebound."
  [[ "$actual_binding" == "$expected_binding" ]] \
    || release_die "$binding_label changed after its reviewed binding."
}

# The historical one-phase implementation below remains temporarily enclosed so
# the reviewed archive-construction functions later in this file can stay
# unchanged while the signing boundary is replaced by the explicit Phase A/B
# setup that follows it. No statement in this block executes.
if [[ "disabled-one-phase-boundary" == "enabled" ]]; then
FIXTURE_SCRIPT_PATH="$SCRIPT_DIR/prepare-update-transition-fixtures.sh"
RELEASE_COMMON_SOURCE_PATH="$SCRIPT_DIR/release-common.sh"
DOWNLOAD_TOOLS_SOURCE_PATH="$SCRIPT_DIR/download-sparkle-tools.sh"
GENERATE_APPCAST_SOURCE_PATH="$SCRIPT_DIR/generate-appcast.sh"
VALIDATE_APPCAST_SOURCE_PATH="$SCRIPT_DIR/validate-appcast.sh"
VALIDATE_ASSETS_SOURCE_PATH="$SCRIPT_DIR/validate-release-assets.sh"
FETCH_APPCAST_SOURCE_PATH="$SCRIPT_DIR/fetch-current-appcast.sh"
PUBLIC_KEY_DERIVER_SOURCE_PATH="$SCRIPT_DIR/derive-sparkle-public-key.swift"
PRODUCT_IDENTITY_SOURCE_PATH="$PROJECT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"
UPDATE_CHECKING_SOURCE_PATH="$PROJECT_ROOT/UshotCore/Sources/UshotCore/Update/UpdateChecking.swift"
SIGNED_APPCAST_POLICY_SOURCE_PATH="$PROJECT_ROOT/UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift"
AUTHENTICATED_VALIDATOR_SOURCE_PATH="$PROJECT_ROOT/Tools/AuthenticatedAppcastValidator/main.swift"
BASE_CONFIG_SOURCE_PATH="$PROJECT_ROOT/Config/Base.xcconfig"
APPCAST_SEED_SOURCE_PATH="$PROJECT_ROOT/updates/v1/appcast.xml"

FIXTURE_SCRIPT_BINDING="$(capture_regular_file_binding "$FIXTURE_SCRIPT_PATH" 1048576 fixture-script)"
RELEASE_COMMON_SOURCE_BINDING="$(capture_regular_file_binding "$RELEASE_COMMON_SOURCE_PATH" 1048576 release-common-source)"
DOWNLOAD_TOOLS_SOURCE_BINDING="$(capture_regular_file_binding "$DOWNLOAD_TOOLS_SOURCE_PATH" 1048576 download-tools-source)"
GENERATE_APPCAST_SOURCE_BINDING="$(capture_regular_file_binding "$GENERATE_APPCAST_SOURCE_PATH" 1048576 generate-appcast-source)"
VALIDATE_APPCAST_SOURCE_BINDING="$(capture_regular_file_binding "$VALIDATE_APPCAST_SOURCE_PATH" 1048576 validate-appcast-source)"
VALIDATE_ASSETS_SOURCE_BINDING="$(capture_regular_file_binding "$VALIDATE_ASSETS_SOURCE_PATH" 1048576 validate-assets-source)"
FETCH_APPCAST_SOURCE_BINDING="$(capture_regular_file_binding "$FETCH_APPCAST_SOURCE_PATH" 1048576 fetch-appcast-source)"
PUBLIC_KEY_DERIVER_SOURCE_BINDING="$(capture_regular_file_binding "$PUBLIC_KEY_DERIVER_SOURCE_PATH" 1048576 public-key-deriver-source)"
PRODUCT_IDENTITY_SOURCE_BINDING="$(capture_regular_file_binding "$PRODUCT_IDENTITY_SOURCE_PATH" 1048576 product-identity-source)"
UPDATE_CHECKING_SOURCE_BINDING="$(capture_regular_file_binding "$UPDATE_CHECKING_SOURCE_PATH" 1048576 update-checking-source)"
SIGNED_APPCAST_POLICY_SOURCE_BINDING="$(capture_regular_file_binding "$SIGNED_APPCAST_POLICY_SOURCE_PATH" 1048576 signed-appcast-policy-source)"
AUTHENTICATED_VALIDATOR_SOURCE_BINDING="$(capture_regular_file_binding "$AUTHENTICATED_VALIDATOR_SOURCE_PATH" 1048576 authenticated-validator-source)"
BASE_CONFIG_SOURCE_BINDING="$(capture_regular_file_binding "$BASE_CONFIG_SOURCE_PATH" 1048576 base-config-source)"
APPCAST_SEED_SOURCE_BINDING="$(capture_regular_file_binding "$APPCAST_SEED_SOURCE_PATH" 1048576 appcast-seed-source)"

FIXTURE_SCRIPT_SHA256="$(binding_sha256 "$FIXTURE_SCRIPT_BINDING")"
RELEASE_COMMON_SOURCE_SHA256="$(binding_sha256 "$RELEASE_COMMON_SOURCE_BINDING")"
DOWNLOAD_TOOLS_SOURCE_SHA256="$(binding_sha256 "$DOWNLOAD_TOOLS_SOURCE_BINDING")"
GENERATE_APPCAST_SOURCE_SHA256="$(binding_sha256 "$GENERATE_APPCAST_SOURCE_BINDING")"
VALIDATE_APPCAST_SOURCE_SHA256="$(binding_sha256 "$VALIDATE_APPCAST_SOURCE_BINDING")"
VALIDATE_ASSETS_SOURCE_SHA256="$(binding_sha256 "$VALIDATE_ASSETS_SOURCE_BINDING")"
FETCH_APPCAST_SOURCE_SHA256="$(binding_sha256 "$FETCH_APPCAST_SOURCE_BINDING")"
PUBLIC_KEY_DERIVER_SOURCE_SHA256="$(binding_sha256 "$PUBLIC_KEY_DERIVER_SOURCE_BINDING")"
PRODUCT_IDENTITY_SOURCE_SHA256="$(binding_sha256 "$PRODUCT_IDENTITY_SOURCE_BINDING")"
UPDATE_CHECKING_SOURCE_SHA256="$(binding_sha256 "$UPDATE_CHECKING_SOURCE_BINDING")"
SIGNED_APPCAST_POLICY_SOURCE_SHA256="$(binding_sha256 "$SIGNED_APPCAST_POLICY_SOURCE_BINDING")"
AUTHENTICATED_VALIDATOR_SOURCE_SHA256="$(binding_sha256 "$AUTHENTICATED_VALIDATOR_SOURCE_BINDING")"
BASE_CONFIG_SOURCE_SHA256="$(binding_sha256 "$BASE_CONFIG_SOURCE_BINDING")"
APPCAST_SEED_SOURCE_SHA256="$(binding_sha256 "$APPCAST_SEED_SOURCE_BINDING")"

verify_critical_source_bindings() {
  verify_bound_regular_file "$FIXTURE_SCRIPT_PATH" 1048576 fixture-script "$FIXTURE_SCRIPT_BINDING"
  verify_bound_regular_file "$RELEASE_COMMON_SOURCE_PATH" 1048576 release-common-source "$RELEASE_COMMON_SOURCE_BINDING"
  verify_bound_regular_file "$DOWNLOAD_TOOLS_SOURCE_PATH" 1048576 download-tools-source "$DOWNLOAD_TOOLS_SOURCE_BINDING"
  verify_bound_regular_file "$GENERATE_APPCAST_SOURCE_PATH" 1048576 generate-appcast-source "$GENERATE_APPCAST_SOURCE_BINDING"
  verify_bound_regular_file "$VALIDATE_APPCAST_SOURCE_PATH" 1048576 validate-appcast-source "$VALIDATE_APPCAST_SOURCE_BINDING"
  verify_bound_regular_file "$VALIDATE_ASSETS_SOURCE_PATH" 1048576 validate-assets-source "$VALIDATE_ASSETS_SOURCE_BINDING"
  verify_bound_regular_file "$FETCH_APPCAST_SOURCE_PATH" 1048576 fetch-appcast-source "$FETCH_APPCAST_SOURCE_BINDING"
  verify_bound_regular_file "$PUBLIC_KEY_DERIVER_SOURCE_PATH" 1048576 public-key-deriver-source "$PUBLIC_KEY_DERIVER_SOURCE_BINDING"
  verify_bound_regular_file "$PRODUCT_IDENTITY_SOURCE_PATH" 1048576 product-identity-source "$PRODUCT_IDENTITY_SOURCE_BINDING"
  verify_bound_regular_file "$UPDATE_CHECKING_SOURCE_PATH" 1048576 update-checking-source "$UPDATE_CHECKING_SOURCE_BINDING"
  verify_bound_regular_file "$SIGNED_APPCAST_POLICY_SOURCE_PATH" 1048576 signed-appcast-policy-source "$SIGNED_APPCAST_POLICY_SOURCE_BINDING"
  verify_bound_regular_file "$AUTHENTICATED_VALIDATOR_SOURCE_PATH" 1048576 authenticated-validator-source "$AUTHENTICATED_VALIDATOR_SOURCE_BINDING"
  verify_bound_regular_file "$BASE_CONFIG_SOURCE_PATH" 1048576 base-config-source "$BASE_CONFIG_SOURCE_BINDING"
  verify_bound_regular_file "$APPCAST_SEED_SOURCE_PATH" 1048576 appcast-seed-source "$APPCAST_SEED_SOURCE_BINDING"
}

verify_critical_source_bindings

SWIFTC_DISCOVERED_PATH="$(/usr/bin/xcrun --find swiftc)" \
  || release_die "Could not locate the selected Swift compiler."
[[ "$SWIFTC_DISCOVERED_PATH" == /* ]] \
  || release_die "The selected Swift compiler path is not absolute."
SWIFTC_RESOLVED_PATH="$(
  /usr/bin/perl -MCwd=abs_path -e '
    use strict;
    use warnings;
    my $path = shift @ARGV;
    die "unexpected arguments\n" if !defined($path) || @ARGV;
    my $resolved = abs_path($path);
    die "could not resolve compiler\n" unless defined($resolved);
    print $resolved;
  ' "$SWIFTC_DISCOVERED_PATH"
)" || release_die "Could not resolve the selected Swift compiler."
SWIFTC_BINDING="$(capture_regular_file_binding "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary system)"
SWIFTC_SHA256="$(binding_sha256 "$SWIFTC_BINDING")"
/usr/bin/codesign --verify --strict "$SWIFTC_RESOLVED_PATH" \
  || release_die "The selected Swift compiler failed strict code-signature validation."
verify_bound_regular_file "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary "$SWIFTC_BINDING" system
SWIFTC_VERSION_OUTPUT="$(/usr/bin/xcrun swiftc --version 2>&1)" \
  || release_die "Could not capture the selected Swift compiler version."
[[ -n "$SWIFTC_VERSION_OUTPUT" && ${#SWIFTC_VERSION_OUTPUT} -le 4096 ]] \
  || release_die "The selected Swift compiler returned an invalid version identity."
XCODE_DEVELOPER_DIRECTORY="$(/usr/bin/xcode-select -p)" \
  || release_die "Could not resolve the active Xcode developer directory."
[[ "$XCODE_DEVELOPER_DIRECTORY" == /* \
    && -d "$XCODE_DEVELOPER_DIRECTORY" \
    && ! -L "$XCODE_DEVELOPER_DIRECTORY" \
    && "$(cd "$XCODE_DEVELOPER_DIRECTORY" && pwd -P)" == "$XCODE_DEVELOPER_DIRECTORY" ]] \
  || release_die "The active Xcode developer directory is not canonical."

SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256="$(
  USHOT_BOUND_PUBLIC_KEY="$USHOT_SPARKLE_PUBLIC_ED_KEY" \
    /usr/bin/perl -MDigest::SHA=sha256_hex -MMIME::Base64=decode_base64,encode_base64 -e '
      use strict;
      use warnings;
      my $encoded = $ENV{USHOT_BOUND_PUBLIC_KEY} // die "missing public key\n";
      die "noncanonical public key\n" unless $encoded =~ /\A[A-Za-z0-9+\/]+={0,2}\z/;
      my $decoded = decode_base64($encoded);
      die "invalid public-key length\n" unless length($decoded) == 32;
      die "noncanonical public-key encoding\n" unless encode_base64($decoded, "") eq $encoded;
      print sha256_hex($decoded);
    '
)" || release_die "Could not derive the nonsecret Sparkle public-key fingerprint."
[[ "$SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || release_die "Sparkle public-key fingerprint is malformed."

HELPER_ROOT="$WORKSPACE/reviewed-helpers"
/bin/mkdir -m 700 "$HELPER_ROOT"
AUTHENTICATED_APPCAST_VALIDATOR="$HELPER_ROOT/AuthenticatedAppcastValidator"
PUBLIC_KEY_DERIVER="$HELPER_ROOT/SparklePublicKeyDeriver"
release_log "Compiling the candidate-identical authenticated XML validator before signing."
/usr/bin/xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  "$PRODUCT_IDENTITY_SOURCE_PATH" \
  "$UPDATE_CHECKING_SOURCE_PATH" \
  "$SIGNED_APPCAST_POLICY_SOURCE_PATH" \
  "$AUTHENTICATED_VALIDATOR_SOURCE_PATH" \
  -o "$AUTHENTICATED_APPCAST_VALIDATOR"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -O \
  "$PUBLIC_KEY_DERIVER_SOURCE_PATH" \
  -o "$PUBLIC_KEY_DERIVER"
for helper_path in "$AUTHENTICATED_APPCAST_VALIDATOR" "$PUBLIC_KEY_DERIVER"; do
  [[ -f "$helper_path" && ! -L "$helper_path" && -x "$helper_path" ]] \
    || release_die "Swift did not produce the required regular helper executable: $helper_path"
  /usr/bin/codesign --force --sign - "$helper_path" >/dev/null 2>&1 \
    || release_die "Could not ad-hoc sign required helper: $helper_path"
  /usr/bin/codesign --verify --strict "$helper_path" \
    || release_die "Required helper failed strict code-signature validation: $helper_path"
done
AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")"
PUBLIC_KEY_DERIVER_SHA256="$(release_sha256 "$PUBLIC_KEY_DERIVER")"
[[ "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" =~ ^[0-9a-f]{64}$ \
    && "$PUBLIC_KEY_DERIVER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || release_die "Could not bind the locally compiled fixture helpers."
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR="$AUTHENTICATED_APPCAST_VALIDATOR"
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$AUTHENTICATED_APPCAST_VALIDATOR_SHA256"

if [[ -z "$ASSETS_DIRECTORY" ]]; then
  CANDIDATE_BUILD_ROOT="$WORKSPACE/release"
  release_log "Building a fresh public-adhoc $FIXTURE_VERSION (build $FIXTURE_BUILD) candidate."
  BUILD_ROOT="$CANDIDATE_BUILD_ROOT" \
    "$SCRIPT_DIR/build-release.sh" \
      --mode public-adhoc \
      --version "$FIXTURE_VERSION" \
      --build-number "$FIXTURE_BUILD"
  BUILD_ROOT="$CANDIDATE_BUILD_ROOT" \
    "$SCRIPT_DIR/package-release.sh" \
      --mode public-adhoc \
      --version "$FIXTURE_VERSION" \
      --build-number "$FIXTURE_BUILD" \
      --tag "$FIXTURE_TAG"
  ASSETS_DIRECTORY="$CANDIDATE_BUILD_ROOT/public-adhoc/artifacts"
  ASSETS_DIRECTORY="$(canonical_existing_directory_path "$ASSETS_DIRECTORY" "fresh candidate assets directory")"
else
  release_log "Preparing a private snapshot of the supplied public-adhoc candidate assets."
fi

ASSET_SNAPSHOT_ROOT="$WORKSPACE/candidate-assets"
/bin/mkdir -m 700 "$ASSET_SNAPSHOT_ROOT"
ASSET_SOURCE_BINDINGS_PATH="$WORKSPACE/candidate-asset-source-bindings.tsv"
: > "$ASSET_SOURCE_BINDINGS_PATH"
/bin/chmod 600 "$ASSET_SOURCE_BINDINGS_PATH"
ASSET_NAMES=(
  "$USHOT_PRODUCT_NAME-$FIXTURE_VERSION-$USHOT_ARCHITECTURE.dmg"
  "$ARCHIVE_NAME"
  "$USHOT_PRODUCT_NAME-$FIXTURE_VERSION-$USHOT_ARCHITECTURE.dSYM.zip"
  "$USHOT_PRODUCT_NAME-$FIXTURE_VERSION-$USHOT_ARCHITECTURE.release-manifest.json"
  "SHA256SUMS.txt"
)
ASSET_MAXIMUM_BYTES=(
  "$SAFE_ARCHIVE_MAX_BYTES"
  "$SAFE_ARCHIVE_MAX_BYTES"
  "$SAFE_ARCHIVE_MAX_BYTES"
  "1048576"
  "1048576"
)
ASSET_SNAPSHOT_BINDINGS=()
for ((asset_index = 0; asset_index < ${#ASSET_NAMES[@]}; asset_index++)); do
  asset_name="${ASSET_NAMES[$asset_index]}"
  asset_maximum_bytes="${ASSET_MAXIMUM_BYTES[$asset_index]}"
  asset_source_binding="$(
    snapshot_regular_file_no_follow \
      "$ASSETS_DIRECTORY/$asset_name" \
      "$ASSET_SNAPSHOT_ROOT/$asset_name" \
      "$asset_maximum_bytes" \
      "candidate-asset-$asset_index"
  )" || release_die "Could not snapshot candidate asset $asset_name."
  printf '%s\t%s\n' "$asset_name" "$asset_source_binding" \
    >> "$ASSET_SOURCE_BINDINGS_PATH"
  ASSET_SNAPSHOT_BINDINGS[$asset_index]="$(
    capture_regular_file_binding \
      "$ASSET_SNAPSHOT_ROOT/$asset_name" \
      "$asset_maximum_bytes" \
      "candidate-asset-snapshot-$asset_index"
  )"
done
/bin/chmod 400 "$ASSET_SOURCE_BINDINGS_PATH"

verify_candidate_asset_snapshots() {
  local candidate_index
  local candidate_name

  [[ -d "$ASSET_SNAPSHOT_ROOT" \
      && ! -L "$ASSET_SNAPSHOT_ROOT" \
      && "$(cd "$ASSET_SNAPSHOT_ROOT" && pwd -P)" == "$ASSET_SNAPSHOT_ROOT" \
      && "$(/usr/bin/stat -f '%u' "$ASSET_SNAPSHOT_ROOT")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$ASSET_SNAPSHOT_ROOT")" == "700" ]] \
    || release_die "Private candidate-asset snapshot root changed identity or permissions."
  USHOT_SNAPSHOT_DIRECTORY="$ASSET_SNAPSHOT_ROOT" \
  USHOT_EXPECTED_ASSET_NAMES="$(printf '%s\n' "${ASSET_NAMES[@]}")" \
    /usr/bin/perl -e '
      use strict;
      use warnings;
      my $directory = $ENV{USHOT_SNAPSHOT_DIRECTORY} // die "missing snapshot directory\n";
      my $expected_text = $ENV{USHOT_EXPECTED_ASSET_NAMES} // die "missing expected names\n";
      my @expected = sort(split(/\n/, $expected_text, -1));
      opendir(my $handle, $directory) or die "cannot open snapshot directory\n";
      my @actual = sort(grep { $_ ne "." && $_ ne ".." } readdir($handle));
      closedir($handle) or die "cannot close snapshot directory\n";
      die "candidate snapshot does not contain the exact five-name allowlist\n"
        unless @actual == 5
          && @expected == 5
          && join("\0", @actual) eq join("\0", @expected);
    ' \
    || release_die "Private candidate snapshot no longer contains exactly the five reviewed assets."
  for ((candidate_index = 0; candidate_index < ${#ASSET_NAMES[@]}; candidate_index++)); do
    candidate_name="${ASSET_NAMES[$candidate_index]}"
    verify_bound_regular_file \
      "$ASSET_SNAPSHOT_ROOT/$candidate_name" \
      "${ASSET_MAXIMUM_BYTES[$candidate_index]}" \
      "candidate-asset-snapshot-$candidate_index" \
      "${ASSET_SNAPSHOT_BINDINGS[$candidate_index]}"
  done
}

verify_candidate_asset_snapshots
release_log "Validating only the exact five private candidate-asset snapshots."
"$VALIDATE_ASSETS_SOURCE_PATH" \
  --directory "$ASSET_SNAPSHOT_ROOT" \
  --mode public-adhoc \
  --version "$FIXTURE_VERSION" \
  --build-number "$FIXTURE_BUILD" \
  --tag "$FIXTURE_TAG"
verify_candidate_asset_snapshots
ASSETS_DIRECTORY="$ASSET_SNAPSHOT_ROOT"
NORMAL_ARCHIVE_SOURCE="$ASSET_SNAPSHOT_ROOT/$ARCHIVE_NAME"

CANDIDATE_INPUT_ROOT="$WORKSPACE/candidate-input"
/bin/mkdir -m 700 "$CANDIDATE_INPUT_ROOT"
SNAPSHOT_RELEASE_NOTES="$CANDIDATE_INPUT_ROOT/$FIXTURE_VERSION.md"
RELEASE_NOTES_SOURCE_BINDING="$(
  snapshot_regular_file_no_follow \
    "$RELEASE_NOTES_SOURCE" \
    "$SNAPSHOT_RELEASE_NOTES" \
    1048576 \
    release-notes
)" || release_die "Could not snapshot the reviewed release notes."
SNAPSHOT_RELEASE_NOTES_BINDING="$(
  capture_regular_file_binding \
    "$SNAPSHOT_RELEASE_NOTES" \
    1048576 \
    release-notes-snapshot
)"
RELEASE_NOTES_SOURCE_SHA256="$(binding_sha256 "$RELEASE_NOTES_SOURCE_BINDING")"
RELEASE_NOTES_SOURCE="$SNAPSHOT_RELEASE_NOTES"

TOOLS_ROOT="$WORKSPACE/tools"
/bin/mkdir -m 700 "$TOOLS_ROOT"
TOOL_BOUNDARY_HOME="$WORKSPACE/tool-boundary-home"
TOOL_BOUNDARY_TMP="$WORKSPACE/tool-boundary-tmp"
/bin/mkdir -m 700 "$TOOL_BOUNDARY_HOME" "$TOOL_BOUNDARY_TMP"
verify_critical_source_bindings
SPARKLE_DOWNLOAD_OUTPUT="$(
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$TOOL_BOUNDARY_HOME" \
    TMPDIR="$TOOL_BOUNDARY_TMP" \
    LANG=C \
    LC_ALL=C \
    TOOLS_ROOT="$TOOLS_ROOT" \
    /bin/bash -p "$DOWNLOAD_TOOLS_SOURCE_PATH"
)" || release_die "Clean Sparkle-tool download boundary failed."
SPARKLE_BIN="${SPARKLE_DOWNLOAD_OUTPUT##*$'\n'}"
unset SPARKLE_DOWNLOAD_OUTPUT
EXPECTED_SPARKLE_INSTALL_ROOT="$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION"
EXPECTED_SPARKLE_BIN="$EXPECTED_SPARKLE_INSTALL_ROOT/bin"
[[ "$SPARKLE_BIN" == "$EXPECTED_SPARKLE_BIN" ]] \
  || release_die "Sparkle-tool helper escaped the exact private install path."
SPARKLE_BIN="$(canonical_existing_directory_path "$SPARKLE_BIN" "checksum-pinned Sparkle bin directory")"
[[ "$SPARKLE_BIN" == "$EXPECTED_SPARKLE_BIN" \
    && -d "$EXPECTED_SPARKLE_INSTALL_ROOT" \
    && ! -L "$EXPECTED_SPARKLE_INSTALL_ROOT" \
    && "$(cd "$EXPECTED_SPARKLE_INSTALL_ROOT" && pwd -P)" == "$EXPECTED_SPARKLE_INSTALL_ROOT" ]] \
  || release_die "Sparkle-tool install root is not the exact private versioned directory."
release_log "Bound checksum-pinned Sparkle $USHOT_SPARKLE_VERSION tools inside the private fixture workspace."
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
SPARKLE_ARCHIVE_MARKER="$EXPECTED_SPARKLE_INSTALL_ROOT/.archive.sha256"
SPARKLE_ARCHIVE_MARKER_BINDING="$(
  capture_regular_file_binding \
    "$SPARKLE_ARCHIVE_MARKER" \
    256 \
    sparkle-archive-marker
)"
SPARKLE_ARCHIVE_MARKER_CONTENT_SHA256="$(
  USHOT_PINNED_ARCHIVE_SHA256="$USHOT_SPARKLE_ARCHIVE_SHA256" \
    /usr/bin/perl -MDigest::SHA=sha256_hex -e '
      use strict;
      use warnings;
      my $value = $ENV{USHOT_PINNED_ARCHIVE_SHA256} // die "missing pinned hash\n";
      die "malformed pinned hash\n" unless $value =~ /\A[0-9a-f]{64}\z/;
      print sha256_hex($value);
    '
)" || release_die "Could not bind the expected Sparkle archive-marker contents."

verify_sparkle_archive_marker_contents() {
  USHOT_ARCHIVE_MARKER_PATH="$SPARKLE_ARCHIVE_MARKER" \
  USHOT_EXPECTED_ARCHIVE_SHA256="$USHOT_SPARKLE_ARCHIVE_SHA256" \
    /usr/bin/perl \
      -MFcntl=O_RDONLY,O_NOFOLLOW \
      -MPOSIX=S_ISREG \
      -e '
        use strict;
        use warnings;
        sub identity {
          my (@stat) = @_;
          return join(",", @stat[0, 1, 2, 4, 7, 9, 10]);
        }
        my $path = $ENV{USHOT_ARCHIVE_MARKER_PATH} // die "missing archive marker path\n";
        my $expected = $ENV{USHOT_EXPECTED_ARCHIVE_SHA256} // die "missing pinned archive hash\n";
        die "malformed pinned archive hash\n" unless $expected =~ /\A[0-9a-f]{64}\z/;
        my @path_before = lstat($path);
        die "archive marker is absent or nonregular\n"
          unless @path_before && S_ISREG($path_before[2]);
        sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
          or die "cannot open archive marker with O_NOFOLLOW\n";
        binmode($handle);
        my @descriptor_before = stat($handle);
        die "archive marker changed while opening\n"
          unless @descriptor_before
            && identity(@descriptor_before) eq identity(@path_before);
        my $contents = "";
        while (1) {
          my $buffer = "";
          my $count = sysread($handle, $buffer, 256);
          die "cannot read archive marker\n" unless defined($count);
          last if $count == 0;
          $contents .= $buffer;
          die "archive marker is oversized\n" if length($contents) > 64;
        }
        my @descriptor_after = stat($handle);
        my @path_after = lstat($path);
        close($handle) or die "cannot close archive marker\n";
        die "archive marker changed while reading\n"
          unless @descriptor_after
            && @path_after
            && identity(@descriptor_before) eq identity(@descriptor_after)
            && identity(@descriptor_before) eq identity(@path_after);
        die "archive marker does not equal the pinned archive hash\n"
          unless $contents eq $expected;
      ' \
    || release_die "Private Sparkle-tool cache marker failed exact no-follow content validation."
}

verify_sparkle_archive_marker_contents
[[ "$(binding_sha256 "$SPARKLE_ARCHIVE_MARKER_BINDING")" == "$SPARKLE_ARCHIVE_MARKER_CONTENT_SHA256" ]] \
  || release_die "Private Sparkle-tool cache marker does not contain the pinned archive SHA-256."
verify_bound_regular_file \
  "$SPARKLE_ARCHIVE_MARKER" \
  256 \
  sparkle-archive-marker \
  "$SPARKLE_ARCHIVE_MARKER_BINDING"
GENERATE_APPCAST_BINDING="$(capture_regular_file_binding "$GENERATE_APPCAST" 134217728 sparkle-generate-appcast)"
GENERATE_KEYS_BINDING="$(capture_regular_file_binding "$GENERATE_KEYS" 134217728 sparkle-generate-keys)"
SIGN_UPDATE_BINDING="$(capture_regular_file_binding "$SIGN_UPDATE" 134217728 sparkle-sign-update)"
GENERATE_APPCAST_SHA256="$(binding_sha256 "$GENERATE_APPCAST_BINDING")"
GENERATE_KEYS_SHA256="$(binding_sha256 "$GENERATE_KEYS_BINDING")"
SIGN_UPDATE_SHA256="$(binding_sha256 "$SIGN_UPDATE_BINDING")"

verify_sparkle_toolchain() {
  [[ "$SPARKLE_BIN" == "$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION/bin" \
      && -d "$TOOLS_ROOT" \
      && ! -L "$TOOLS_ROOT" \
      && "$(/usr/bin/stat -f '%u' "$TOOLS_ROOT")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$TOOLS_ROOT")" == "700" \
      && -d "$EXPECTED_SPARKLE_INSTALL_ROOT" \
      && ! -L "$EXPECTED_SPARKLE_INSTALL_ROOT" \
      && -d "$SPARKLE_BIN" \
      && ! -L "$SPARKLE_BIN" ]] \
    || release_die "Private Sparkle toolchain directory changed identity or permissions."
  verify_bound_regular_file \
    "$SPARKLE_ARCHIVE_MARKER" \
    256 \
    sparkle-archive-marker \
    "$SPARKLE_ARCHIVE_MARKER_BINDING"
  verify_sparkle_archive_marker_contents
  [[ "$(binding_sha256 "$SPARKLE_ARCHIVE_MARKER_BINDING")" == "$SPARKLE_ARCHIVE_MARKER_CONTENT_SHA256" ]] \
    || release_die "Private Sparkle archive marker drifted from the pinned hash."

  [[ -x "$GENERATE_APPCAST" && -x "$GENERATE_KEYS" && -x "$SIGN_UPDATE" ]] \
    || release_die "A bound Sparkle signing tool lost its executable mode."
  verify_bound_regular_file "$GENERATE_APPCAST" 134217728 sparkle-generate-appcast "$GENERATE_APPCAST_BINDING"
  /usr/bin/codesign --verify --strict "$GENERATE_APPCAST" \
    || release_die "Bound Sparkle generate_appcast failed strict code-signature validation."
  verify_bound_regular_file "$GENERATE_APPCAST" 134217728 sparkle-generate-appcast "$GENERATE_APPCAST_BINDING"
  verify_bound_regular_file "$GENERATE_KEYS" 134217728 sparkle-generate-keys "$GENERATE_KEYS_BINDING"
  /usr/bin/codesign --verify --strict "$GENERATE_KEYS" \
    || release_die "Bound Sparkle generate_keys failed strict code-signature validation."
  verify_bound_regular_file "$GENERATE_KEYS" 134217728 sparkle-generate-keys "$GENERATE_KEYS_BINDING"
  verify_bound_regular_file "$SIGN_UPDATE" 134217728 sparkle-sign-update "$SIGN_UPDATE_BINDING"
  /usr/bin/codesign --verify --strict "$SIGN_UPDATE" \
    || release_die "Bound Sparkle sign_update failed strict code-signature validation."
  verify_bound_regular_file "$SIGN_UPDATE" 134217728 sparkle-sign-update "$SIGN_UPDATE_BINDING"
}

AUTHENTICATED_APPCAST_VALIDATOR_BINDING="$(
  capture_regular_file_binding \
    "$AUTHENTICATED_APPCAST_VALIDATOR" \
    134217728 \
    authenticated-appcast-validator
)"
PUBLIC_KEY_DERIVER_BINDING="$(
  capture_regular_file_binding \
    "$PUBLIC_KEY_DERIVER" \
    134217728 \
    sparkle-public-key-deriver
)"
[[ "$(binding_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_BINDING")" == "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
    && "$(binding_sha256 "$PUBLIC_KEY_DERIVER_BINDING")" == "$PUBLIC_KEY_DERIVER_SHA256" ]] \
  || release_die "Compiled helper SHA-256 bindings changed before the signing boundary."

verify_reviewed_helpers() {
  verify_bound_regular_file \
    "$AUTHENTICATED_APPCAST_VALIDATOR" \
    134217728 \
    authenticated-appcast-validator \
    "$AUTHENTICATED_APPCAST_VALIDATOR_BINDING"
  /usr/bin/codesign --verify --strict "$AUTHENTICATED_APPCAST_VALIDATOR" \
    || release_die "Bound authenticated-appcast validator failed strict code-signature validation."
  verify_bound_regular_file \
    "$AUTHENTICATED_APPCAST_VALIDATOR" \
    134217728 \
    authenticated-appcast-validator \
    "$AUTHENTICATED_APPCAST_VALIDATOR_BINDING"
  verify_bound_regular_file \
    "$PUBLIC_KEY_DERIVER" \
    134217728 \
    sparkle-public-key-deriver \
    "$PUBLIC_KEY_DERIVER_BINDING"
  /usr/bin/codesign --verify --strict "$PUBLIC_KEY_DERIVER" \
    || release_die "Bound public-key deriver failed strict code-signature validation."
  verify_bound_regular_file \
    "$PUBLIC_KEY_DERIVER" \
    134217728 \
    sparkle-public-key-deriver \
    "$PUBLIC_KEY_DERIVER_BINDING"
}

verify_signing_boundary() {
  verify_sign_perl_runtime_boundary
  verify_critical_source_bindings
  verify_candidate_asset_snapshots
  verify_bound_regular_file \
    "$RELEASE_NOTES_SOURCE" \
    1048576 \
    release-notes-snapshot \
    "$SNAPSHOT_RELEASE_NOTES_BINDING"
  verify_reviewed_helpers
  verify_sparkle_toolchain
}

verify_signing_boundary
fi

FIXTURE_SCRIPT_PATH="$SCRIPT_DIR/prepare-update-transition-fixtures.sh"
RELEASE_COMMON_SOURCE_PATH="$SCRIPT_DIR/release-common.sh"
VALIDATE_APPCAST_SOURCE_PATH="$SCRIPT_DIR/validate-appcast.sh"

phase_source_hash_for() {
  case "$1" in
    Config/Base.xcconfig) printf '%s\n' "$SOURCE_SHA_BASE_CONFIG" ;;
    Tools/AuthenticatedAppcastValidator/main.swift) printf '%s\n' "$SOURCE_SHA_AUTHENTICATED_VALIDATOR" ;;
    UshotCore/Sources/UshotCore/Product/ProductIdentity.swift) printf '%s\n' "$SOURCE_SHA_PRODUCT_IDENTITY" ;;
    UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift) printf '%s\n' "$SOURCE_SHA_SIGNED_APPCAST_POLICY" ;;
    UshotCore/Sources/UshotCore/Update/UpdateChecking.swift) printf '%s\n' "$SOURCE_SHA_UPDATE_CHECKING" ;;
    scripts/derive-sparkle-public-key.swift) printf '%s\n' "$SOURCE_SHA_PUBLIC_KEY_DERIVER" ;;
    scripts/download-sparkle-tools.sh) printf '%s\n' "$SOURCE_SHA_DOWNLOAD_TOOLS" ;;
    scripts/prepare-update-transition-fixtures.sh) printf '%s\n' "$SOURCE_SHA_FIXTURE_SCRIPT" ;;
    scripts/release-common.sh) printf '%s\n' "$SOURCE_SHA_RELEASE_COMMON" ;;
    scripts/validate-appcast.sh) printf '%s\n' "$SOURCE_SHA_VALIDATE_APPCAST" ;;
    scripts/validate-release-assets.sh) printf '%s\n' "$SOURCE_SHA_VALIDATE_ASSETS" ;;
    updates/release-notes/0.1.4.md) printf '%s\n' "$SOURCE_SHA_RELEASE_NOTES" ;;
    updates/v1/appcast.xml) printf '%s\n' "$SOURCE_SHA_APPCAST_SEED" ;;
    *) release_die "Unknown reviewed source: $1" ;;
  esac
}

emit_phase_source() {
  local relative="$1"
  local expected_sha256
  expected_sha256="$(phase_source_hash_for "$relative")"
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Missing reviewed source pin: $relative"
  emit_hash_verified_source "$relative" "$expected_sha256"
}

read_reviewed_manifest_value() {
  local jq_expression="$1"
  local value

  verify_bound_regular_file \
    "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT" \
    1048576 \
    reviewed-source-manifest-snapshot \
    "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT_BINDING"
  value="$(/usr/bin/jq -er "$jq_expression | strings" "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT")" \
    || release_die "Reviewed-source manifest is missing required value: $jq_expression"
  verify_bound_regular_file \
    "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT" \
    1048576 \
    reviewed-source-manifest-snapshot \
    "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT_BINDING"
  printf '%s\n' "$value"
}

initialize_source_hashes_for_review_pins() {
  SOURCE_SHA_BASE_CONFIG="$(early_hash_bound_source Config/Base.xcconfig)"
  SOURCE_SHA_AUTHENTICATED_VALIDATOR="$(early_hash_bound_source Tools/AuthenticatedAppcastValidator/main.swift)"
  SOURCE_SHA_PRODUCT_IDENTITY="$(early_hash_bound_source UshotCore/Sources/UshotCore/Product/ProductIdentity.swift)"
  SOURCE_SHA_SIGNED_APPCAST_POLICY="$(early_hash_bound_source UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift)"
  SOURCE_SHA_UPDATE_CHECKING="$(early_hash_bound_source UshotCore/Sources/UshotCore/Update/UpdateChecking.swift)"
  SOURCE_SHA_PUBLIC_KEY_DERIVER="$(early_hash_bound_source scripts/derive-sparkle-public-key.swift)"
  SOURCE_SHA_DOWNLOAD_TOOLS="$(early_hash_bound_source scripts/download-sparkle-tools.sh)"
  SOURCE_SHA_FIXTURE_SCRIPT="$(early_hash_bound_source scripts/prepare-update-transition-fixtures.sh)"
  SOURCE_SHA_RELEASE_COMMON="$(early_hash_bound_source scripts/release-common.sh)"
  SOURCE_SHA_VALIDATE_APPCAST="$(early_hash_bound_source scripts/validate-appcast.sh)"
  SOURCE_SHA_VALIDATE_ASSETS="$(early_hash_bound_source scripts/validate-release-assets.sh)"
  SOURCE_SHA_RELEASE_NOTES="$(early_hash_bound_source updates/release-notes/0.1.4.md)"
  SOURCE_SHA_APPCAST_SEED="$(early_hash_bound_source updates/v1/appcast.xml)"
  [[ "$SOURCE_SHA_FIXTURE_SCRIPT" == "$EXPECTED_SCRIPT_SHA256" \
      && "$SOURCE_SHA_RELEASE_COMMON" == "$EARLY_RELEASE_COMMON_SHA256" ]] \
    || release_die "review-pins source snapshot disagrees with its admitted main/release-common bytes."
}

initialize_source_hashes_from_reviewed_manifest() {
  SOURCE_SHA_BASE_CONFIG="$(read_reviewed_manifest_value '.sources["Config/Base.xcconfig"]')"
  SOURCE_SHA_AUTHENTICATED_VALIDATOR="$(read_reviewed_manifest_value '.sources["Tools/AuthenticatedAppcastValidator/main.swift"]')"
  SOURCE_SHA_PRODUCT_IDENTITY="$(read_reviewed_manifest_value '.sources["UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"]')"
  SOURCE_SHA_SIGNED_APPCAST_POLICY="$(read_reviewed_manifest_value '.sources["UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift"]')"
  SOURCE_SHA_UPDATE_CHECKING="$(read_reviewed_manifest_value '.sources["UshotCore/Sources/UshotCore/Update/UpdateChecking.swift"]')"
  SOURCE_SHA_PUBLIC_KEY_DERIVER="$(read_reviewed_manifest_value '.sources["scripts/derive-sparkle-public-key.swift"]')"
  SOURCE_SHA_DOWNLOAD_TOOLS="$(read_reviewed_manifest_value '.sources["scripts/download-sparkle-tools.sh"]')"
  SOURCE_SHA_FIXTURE_SCRIPT="$(read_reviewed_manifest_value '.sources["scripts/prepare-update-transition-fixtures.sh"]')"
  SOURCE_SHA_RELEASE_COMMON="$(read_reviewed_manifest_value '.sources["scripts/release-common.sh"]')"
  SOURCE_SHA_VALIDATE_APPCAST="$(read_reviewed_manifest_value '.sources["scripts/validate-appcast.sh"]')"
  SOURCE_SHA_VALIDATE_ASSETS="$(read_reviewed_manifest_value '.sources["scripts/validate-release-assets.sh"]')"
  SOURCE_SHA_RELEASE_NOTES="$(read_reviewed_manifest_value '.sources["updates/release-notes/0.1.4.md"]')"
  SOURCE_SHA_APPCAST_SEED="$(read_reviewed_manifest_value '.sources["updates/v1/appcast.xml"]')"
  [[ "$SOURCE_SHA_FIXTURE_SCRIPT" == "$EXPECTED_SCRIPT_SHA256" \
      && "$SOURCE_SHA_RELEASE_COMMON" == "$EARLY_RELEASE_COMMON_SHA256" ]] \
    || release_die "Reviewed source pins disagree with the admitted main/release-common bytes."
}

compile_anonymous_swift_source_snapshot() {
  local primary_output="$1"
  local secondary_output="$2"
  shift 2
  [[ "${1:-}" == "--" ]] || release_die "Internal anonymous Swift compile separator is absent."
  shift

  verify_bound_regular_file "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary "$SWIFTC_BINDING" system
  USHOT_BOUND_SWIFTC="$SWIFTC_RESOLVED_PATH" \
  USHOT_SWIFTC_ARGV0="$SWIFTC_DISCOVERED_PATH" \
  USHOT_BOUND_SDK="$SDK_RESOLVED_PATH" \
  USHOT_PRIMARY_OUTPUT="$primary_output" \
  USHOT_SECONDARY_OUTPUT="$secondary_output" \
    /usr/bin/perl -MFile::Temp -MFcntl=SEEK_SET -e '
      use strict;
      use warnings;
      my $compiler = $ENV{USHOT_BOUND_SWIFTC} // die "missing bound compiler\n";
      my $argv0 = $ENV{USHOT_SWIFTC_ARGV0} // die "missing compiler argv0\n";
      my $sdk = $ENV{USHOT_BOUND_SDK} // die "missing bound SDK\n";
      my @outputs = grep { length($_) } (
        $ENV{USHOT_PRIMARY_OUTPUT} // "",
        $ENV{USHOT_SECONDARY_OUTPUT} // ""
      );
      die "invalid output count\n" unless @outputs == 1 || @outputs == 2;
      my $bytes = "";
      while (1) {
        my $chunk = "";
        my $count = sysread(STDIN, $chunk, 65536);
        die "could not read reviewed Swift source stream\n" unless defined($count);
        last if $count == 0;
        $bytes .= $chunk;
        die "reviewed Swift source stream exceeded bound\n" if length($bytes) > 4_194_304;
      }
      die "reviewed Swift source stream is empty\n" unless length($bytes);
      my $snapshot = File::Temp->new(TEMPLATE => "ushot-swift-source-XXXXXXXX", TMPDIR => 1, UNLINK => 0);
      binmode($snapshot);
      print {$snapshot} $bytes or die "could not write anonymous Swift source snapshot\n";
      $snapshot->flush or die "could not flush anonymous Swift source snapshot\n";
      chmod(0400, $snapshot->filename) == 1 or die "could not protect anonymous Swift source snapshot\n";
      unlink($snapshot->filename) or die "could not unlink Swift source snapshot before compilation\n";
      for my $output (@outputs) {
        sysseek($snapshot, 0, SEEK_SET) or die "could not rewind anonymous Swift source snapshot\n";
        open(STDIN, "<&", fileno($snapshot)) or die "could not bind compiler stdin to anonymous source\n";
        my $status = system {$compiler} $argv0, "-sdk", $sdk, @ARGV, "-", "-o", $output;
        die "could not execute bound compiler\n" if $status == -1;
        die "bound compiler terminated by signal\n" if $status & 127;
        die "bound compiler rejected anonymous reviewed source\n" if ($status >> 8) != 0;
      }
    ' -- "$@" \
    || release_die "Bound Swift compiler failed for the anonymous reviewed source snapshot."
  verify_bound_regular_file "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary "$SWIFTC_BINDING" system
}

compile_phase_a_helpers() {
  local secondary_helper_root=""
  local secondary_authenticated_validator=""
  local secondary_public_key_deriver=""
  local secondary_embedded_verifier=""

  SWIFTC_DISCOVERED_PATH="$(/usr/bin/xcrun --find swiftc)" \
    || release_die "Could not locate the selected Swift compiler."
  [[ "$SWIFTC_DISCOVERED_PATH" == /* ]] \
    || release_die "The selected Swift compiler path is not absolute."
  SWIFTC_RESOLVED_PATH="$(
    /usr/bin/perl -MCwd=abs_path -e '
      use strict;
      use warnings;
      my $path = shift @ARGV;
      die "unexpected arguments\n" if !defined($path) || @ARGV;
      my $resolved = abs_path($path);
      die "could not resolve compiler\n" unless defined($resolved);
      print $resolved;
    ' "$SWIFTC_DISCOVERED_PATH"
  )" || release_die "Could not resolve the selected Swift compiler."
  SWIFTC_BINDING="$(capture_regular_file_binding "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary system)"
  SWIFTC_SHA256="$(binding_sha256 "$SWIFTC_BINDING")"
  /usr/bin/codesign --verify --strict "$SWIFTC_RESOLVED_PATH" \
    || release_die "The selected Swift compiler failed strict code-signature validation."
  verify_bound_regular_file "$SWIFTC_RESOLVED_PATH" 1073741824 swiftc-binary "$SWIFTC_BINDING" system
  if [[ "$PHASE" == "prepare" ]]; then
    [[ "$SWIFTC_DISCOVERED_PATH" == "$(read_reviewed_manifest_value '.buildInputs.swiftCompiler.invocationPath')" \
        && "$SWIFTC_RESOLVED_PATH" == "$(read_reviewed_manifest_value '.buildInputs.swiftCompiler.resolvedPath')" \
        && "$SWIFTC_SHA256" == "$(read_reviewed_manifest_value '.buildInputs.swiftCompiler.sha256')" ]] \
      || release_die "Selected Swift compiler identity disagrees with the externally reviewed pins."
  fi
  SDK_DISCOVERED_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
    || release_die "Could not locate the selected macOS SDK."
  [[ "$SDK_DISCOVERED_PATH" == /* && -d "$SDK_DISCOVERED_PATH" ]] \
    || release_die "The selected macOS SDK path is invalid."
  SDK_RESOLVED_PATH="$(cd "$SDK_DISCOVERED_PATH" && pwd -P)"
  [[ "$SDK_RESOLVED_PATH" == /* && -d "$SDK_RESOLVED_PATH" \
      && "$(/usr/bin/stat -f '%u' "$SDK_RESOLVED_PATH")" == "0" \
      && $((8#$(/usr/bin/stat -f '%Lp' "$SDK_RESOLVED_PATH") & 8#22)) -eq 0 ]] \
    || release_die "The selected macOS SDK is not a root-owned, ordinary-user-immutable directory."

  HELPER_ROOT="$WORKSPACE/reviewed-helpers"
  /bin/mkdir -m 700 "$HELPER_ROOT"
  AUTHENTICATED_APPCAST_VALIDATOR="$HELPER_ROOT/AuthenticatedAppcastValidator"
  PUBLIC_KEY_DERIVER="$HELPER_ROOT/SparklePublicKeyDeriver"
  EMBEDDED_PUBLIC_KEY_VERIFIER="$HELPER_ROOT/EmbeddedPublicKeyVerifier"
  if [[ "$PHASE" == "review-pins" ]]; then
    secondary_helper_root="$WORKSPACE/reviewed-helpers-second-build"
    /bin/mkdir -m 700 "$secondary_helper_root"
    secondary_authenticated_validator="$secondary_helper_root/AuthenticatedAppcastValidator"
    secondary_public_key_deriver="$secondary_helper_root/SparklePublicKeyDeriver"
    secondary_embedded_verifier="$secondary_helper_root/EmbeddedPublicKeyVerifier"
  fi

  release_log "Compiling key-free helpers only from full-hash-verified anonymous source snapshots."
  {
    emit_phase_source UshotCore/Sources/UshotCore/Product/ProductIdentity.swift
    emit_phase_source UshotCore/Sources/UshotCore/Update/UpdateChecking.swift
    emit_phase_source UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift
    emit_phase_source Tools/AuthenticatedAppcastValidator/main.swift
  } | compile_anonymous_swift_source_snapshot \
    "$AUTHENTICATED_APPCAST_VALIDATOR" \
    "$secondary_authenticated_validator" \
    -- -parse-as-library -swift-version 5 -O
  emit_phase_source scripts/derive-sparkle-public-key.swift | \
    compile_anonymous_swift_source_snapshot \
      "$PUBLIC_KEY_DERIVER" \
      "$secondary_public_key_deriver" \
      -- -swift-version 5 -O

  emit_embedded_public_key_verifier_source() {
    /bin/cat <<'SWIFT'
import CryptoKit
import Darwin
import Foundation

private let embeddedPublicKeyBase64 = "+zRL11/2yYePt5O+OetThnLGwyvAvFtPPXxiBBOTTjE="
private let maximumArchiveBytes = 268_435_456
private let maximumAuthenticatedFeedBytes = 1_048_576
private let maximumSignedFeedBytes = 1_049_088
private let maximumCryptographicOnlySignedFeedBytes = 2_097_152

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("embedded public verifier: \(message)\n".utf8))
    exit(1)
}

private func decodeCanonicalSignature(_ encoded: String) -> Data {
    guard let decoded = Data(base64Encoded: encoded),
          decoded.count == 64,
          decoded.base64EncodedString() == encoded else {
        fail("signature is not canonical Ed25519 base64")
    }
    return decoded
}

private func readBoundFile(_ path: String, maximumBytes: Int) -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { fail("cannot open input with O_NOFOLLOW") }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
          (before.st_mode & S_IFMT) == S_IFREG,
          before.st_size > 0,
          before.st_size <= off_t(maximumBytes) else {
        fail("input is not a bounded regular file")
    }
    let expectedSize = Int(before.st_size)
    var data = Data(count: expectedSize)
    let didReadAllBytes = data.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else { return false }
        var offset = 0
        while offset < expectedSize {
            let count = Darwin.read(descriptor, base.advanced(by: offset), expectedSize - offset)
            if count <= 0 { return false }
            offset += count
        }
        var extra: UInt8 = 0
        return Darwin.read(descriptor, &extra, 1) == 0
    }
    guard didReadAllBytes else { fail("could not read the exact input bytes") }

    var after = stat()
    var currentPath = stat()
    guard fstat(descriptor, &after) == 0,
          lstat(path, &currentPath) == 0,
          before.st_dev == after.st_dev,
          before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
          before.st_dev == currentPath.st_dev,
          before.st_ino == currentPath.st_ino else {
        fail("input identity changed while reading")
    }
    return data
}

private let publicKey: Curve25519.Signing.PublicKey = {
    guard let raw = Data(base64Encoded: embeddedPublicKeyBase64),
          raw.count == 32,
          raw.base64EncodedString() == embeddedPublicKeyBase64 else {
        fail("embedded public key is malformed")
    }
    do {
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    } catch {
        fail("embedded public key is invalid")
    }
}()

private func verifyArchive(path: String, signatureText: String) {
    let archive = readBoundFile(path, maximumBytes: maximumArchiveBytes)
    let signature = decodeCanonicalSignature(signatureText)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fail("archive signature rejected")
    }
}

private func verifyFeed(path: String, cryptographicOnly: Bool) {
    let feed = readBoundFile(
        path,
        maximumBytes: cryptographicOnly
            ? maximumCryptographicOnlySignedFeedBytes
            : maximumSignedFeedBytes
    )
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let markerRange = feed.range(of: marker, options: [.backwards]) else {
        fail("signed-feed trailer marker is absent")
    }
    let authenticatedLength = markerRange.lowerBound
    guard authenticatedLength > 0,
          feed.count - authenticatedLength > 0,
          feed.count - authenticatedLength <= 512 else {
        fail("signed-feed size boundary rejected")
    }
    if !cryptographicOnly {
        guard authenticatedLength <= maximumAuthenticatedFeedBytes else {
            fail("signed-feed size boundary rejected")
        }
    }
    let trailerBytes = feed.subdata(in: authenticatedLength..<feed.count)
    guard let trailer = String(data: trailerBytes, encoding: .utf8) else {
        fail("signed-feed trailer is not UTF-8")
    }
    let pattern = #"\A<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([1-9][0-9]*)\n-->\n?\z"#
    let expression: NSRegularExpression
    do {
        expression = try NSRegularExpression(pattern: pattern)
    } catch {
        fail("internal trailer expression failed")
    }
    let range = NSRange(trailer.startIndex..<trailer.endIndex, in: trailer)
    guard let match = expression.firstMatch(in: trailer, range: range), match.range == range,
          let signatureRange = Range(match.range(at: 1), in: trailer),
          let lengthRange = Range(match.range(at: 2), in: trailer),
          let declaredLength = Int(trailer[lengthRange]),
          declaredLength == authenticatedLength else {
        fail("signed-feed trailer is noncanonical")
    }
    let signature = decodeCanonicalSignature(String(trailer[signatureRange]))
    let authenticated = feed.subdata(in: 0..<authenticatedLength)
    guard publicKey.isValidSignature(signature, for: authenticated) else {
        fail("feed signature rejected")
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: EmbeddedPublicKeyVerifier archive PATH SIGNATURE | feed PATH | feed-cryptographic-only PATH")
}
switch arguments[1] {
case "archive":
    guard arguments.count == 4 else { fail("archive mode requires path and signature") }
    verifyArchive(path: arguments[2], signatureText: arguments[3])
case "feed":
    guard arguments.count == 3 else { fail("feed mode requires one path") }
    verifyFeed(path: arguments[2], cryptographicOnly: false)
case "feed-cryptographic-only":
    guard arguments.count == 3 else { fail("feed-cryptographic-only mode requires one path") }
    verifyFeed(path: arguments[2], cryptographicOnly: true)
default:
    fail("unknown verification mode")
}
SWIFT
  }

  EMBEDDED_PUBLIC_KEY_VERIFIER_SOURCE_SHA256="$(
    emit_embedded_public_key_verifier_source | early_trusted_openssl_sha256 /dev/stdin
  )"
  [[ "$EMBEDDED_PUBLIC_KEY_VERIFIER_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Embedded public verifier source hash is malformed."
  if [[ "$PHASE" == "prepare" ]]; then
    [[ "$EMBEDDED_PUBLIC_KEY_VERIFIER_SOURCE_SHA256" == \
        "$(read_reviewed_manifest_value '.buildInputs.embeddedPublicKeyVerifierSourceSHA256')" ]] \
      || release_die "Embedded public verifier source disagrees with the externally reviewed pin."
  fi
  emit_embedded_public_key_verifier_source | \
    compile_anonymous_swift_source_snapshot \
      "$EMBEDDED_PUBLIC_KEY_VERIFIER" \
      "$secondary_embedded_verifier" \
      -- -swift-version 5 -O

  for helper_path in \
    "$AUTHENTICATED_APPCAST_VALIDATOR" \
    "$PUBLIC_KEY_DERIVER" \
    "$EMBEDDED_PUBLIC_KEY_VERIFIER"; do
    [[ -f "$helper_path" && ! -L "$helper_path" && -x "$helper_path" ]] \
      || release_die "Swift did not produce a required regular helper: $helper_path"
    /usr/bin/codesign --force --sign - "$helper_path" >/dev/null 2>&1 \
      || release_die "Could not ad-hoc sign required helper: $helper_path"
    /usr/bin/codesign --verify --strict "$helper_path" \
      || release_die "Required helper failed strict code-signature validation: $helper_path"
  done
  if [[ "$PHASE" == "review-pins" ]]; then
    for helper_path in \
      "$secondary_authenticated_validator" \
      "$secondary_public_key_deriver" \
      "$secondary_embedded_verifier"; do
      [[ -f "$helper_path" && ! -L "$helper_path" && -x "$helper_path" ]] \
        || release_die "Second credential-free build did not produce a required helper: $helper_path"
      /usr/bin/codesign --force --sign - "$helper_path" >/dev/null 2>&1 \
        || release_die "Could not ad-hoc sign second-build helper: $helper_path"
      /usr/bin/codesign --verify --strict "$helper_path" \
        || release_die "Second-build helper failed strict code-signature validation: $helper_path"
    done
    [[ "$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")" == \
          "$(release_sha256 "$secondary_authenticated_validator")" \
        && "$(release_sha256 "$PUBLIC_KEY_DERIVER")" == \
          "$(release_sha256 "$secondary_public_key_deriver")" \
        && "$(release_sha256 "$EMBEDDED_PUBLIC_KEY_VERIFIER")" == \
          "$(release_sha256 "$secondary_embedded_verifier")" ]] \
      || release_die "Credential-free helper builds are nondeterministic; refusing to create reviewed pins."
  fi
  AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")"
  PUBLIC_KEY_DERIVER_SHA256="$(release_sha256 "$PUBLIC_KEY_DERIVER")"
  EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256="$(release_sha256 "$EMBEDDED_PUBLIC_KEY_VERIFIER")"
  if [[ "$PHASE" == "prepare" ]]; then
    [[ "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" == \
          "$(read_reviewed_manifest_value '.credentialFreeOutputs.AuthenticatedAppcastValidator')" \
        && "$PUBLIC_KEY_DERIVER_SHA256" == \
          "$(read_reviewed_manifest_value '.credentialFreeOutputs.SparklePublicKeyDeriver')" \
        && "$EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256" == \
          "$(read_reviewed_manifest_value '.credentialFreeOutputs.EmbeddedPublicKeyVerifier')" ]] \
      || release_die "Credential-free helper outputs disagree with the externally reviewed pins."
  fi
}

run_phase_shell_helper() {
  local helper_relative="$1"
  shift
  local helper_sha256
  local helper_status=0
  local snapshot_root
  local common_path
  local helper_path
  local common_fd_sha256
  local helper_fd_sha256

  helper_sha256="$(phase_source_hash_for "$helper_relative")"
  snapshot_root="$(/usr/bin/mktemp -d "$WORKSPACE/.anonymous-shell-helper.XXXXXXXX")" \
    || release_die "Could not create anonymous shell-helper staging."
  /bin/chmod 700 "$snapshot_root"
  common_path="$snapshot_root/release-common.sh"
  helper_path="$snapshot_root/helper.sh"
  emit_phase_source scripts/release-common.sh > "$common_path" \
    || release_die "Could not materialize reviewed release-common helper input."
  emit_phase_source "$helper_relative" > "$helper_path" \
    || release_die "Could not materialize reviewed shell-helper input: $helper_relative"
  /bin/chmod 400 "$common_path" "$helper_path"
  exec 8< "$common_path"
  exec 9< "$helper_path"
  /bin/rm "$common_path" "$helper_path"
  /bin/rmdir "$snapshot_root"
  common_fd_sha256="$(early_trusted_openssl_sha256 /dev/fd/8)"
  helper_fd_sha256="$(early_trusted_openssl_sha256 /dev/fd/9)"
  [[ "$common_fd_sha256" == "$SOURCE_SHA_RELEASE_COMMON" \
      && "$helper_fd_sha256" == "$helper_sha256" ]] \
    || release_die "Anonymous shell-helper descriptor hash mismatch before execution: $helper_relative"
  early_rewind_descriptor 8
  early_rewind_descriptor 9
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="${TOOL_BOUNDARY_HOME:-$WORKSPACE}" \
    TMPDIR="${TOOL_BOUNDARY_TMP:-$TMPDIR}" \
    LANG=C \
    LC_ALL=C \
    TOOLS_ROOT="${TOOLS_ROOT:-}" \
    USHOT_EXPECTED_HELPER_SHA256="$helper_sha256" \
    /bin/bash -p -c '
      set -euo pipefail
      source() {
        [[ "$#" == "1" && ( "$1" == "/dev/fd/release-common.sh" || "$1" == "/dev/release-common.sh" ) ]] \
          || { printf "error: anonymous helper attempted an unexpected source: %s\n" "${1:-<missing>}" >&2; return 1; }
        builtin source /dev/fd/8
      }
      builtin source /dev/fd/9 "$@"
    ' anonymous-reviewed-helper "$@" || helper_status=$?
  early_rewind_descriptor 8
  early_rewind_descriptor 9
  common_fd_sha256="$(early_trusted_openssl_sha256 /dev/fd/8)"
  helper_fd_sha256="$(early_trusted_openssl_sha256 /dev/fd/9)"
  exec 8<&-
  exec 9<&-
  [[ "$common_fd_sha256" == "$SOURCE_SHA_RELEASE_COMMON" \
      && "$helper_fd_sha256" == "$helper_sha256" ]] \
    || release_die "Anonymous shell-helper descriptor changed during execution: $helper_relative"
  return "$helper_status"
}

snapshot_and_bind_candidate_assets() {
  local asset_index
  local asset_name
  local actual_sha256
  local expected_sha256

  ASSET_SNAPSHOT_ROOT="$WORKSPACE/candidate-assets"
  /bin/mkdir -m 700 "$ASSET_SNAPSHOT_ROOT"
  ASSET_NAMES=(
    "Ushot-0.1.4-arm64.dmg"
    "Ushot-0.1.4-arm64.zip"
    "Ushot-0.1.4-arm64.dSYM.zip"
    "Ushot-0.1.4-arm64.release-manifest.json"
    "SHA256SUMS.txt"
  )
  ASSET_MAXIMUM_BYTES=(
    "$SAFE_ARCHIVE_MAX_BYTES" "$SAFE_ARCHIVE_MAX_BYTES" "$SAFE_ARCHIVE_MAX_BYTES" 1048576 1048576
  )
  ASSET_SNAPSHOT_BINDINGS=()
  for ((asset_index = 0; asset_index < ${#ASSET_NAMES[@]}; asset_index++)); do
    asset_name="${ASSET_NAMES[$asset_index]}"
    snapshot_regular_file_no_follow \
      "$ASSETS_DIRECTORY/$asset_name" \
      "$ASSET_SNAPSHOT_ROOT/$asset_name" \
      "${ASSET_MAXIMUM_BYTES[$asset_index]}" \
      "credential-free-asset-$asset_index" >/dev/null
    ASSET_SNAPSHOT_BINDINGS[$asset_index]="$(
      capture_regular_file_binding \
        "$ASSET_SNAPSHOT_ROOT/$asset_name" \
        "${ASSET_MAXIMUM_BYTES[$asset_index]}" \
        "credential-free-asset-snapshot-$asset_index"
    )"
    actual_sha256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[$asset_index]}")"
    if [[ "$PHASE" == "prepare" ]]; then
      expected_sha256="$(read_reviewed_manifest_value ".candidateAssets[\"$asset_name\"]")"
      [[ "$actual_sha256" == "$expected_sha256" ]] \
        || release_die "Candidate asset disagrees with the externally reviewed pin: $asset_name"
    fi
  done
  run_phase_shell_helper scripts/validate-release-assets.sh \
    --directory "$ASSET_SNAPSHOT_ROOT" \
    --mode public-adhoc \
    --version "$FIXTURE_VERSION" \
    --build-number "$FIXTURE_BUILD" \
    --tag "$FIXTURE_TAG" \
    || release_die "Anonymous reviewed release-asset validator rejected the candidate set."
}

download_and_bind_sparkle_tools() {
  local tool_name
  local tool_path
  local tool_sha256

  TOOLS_ROOT="$WORKSPACE/tools"
  TOOL_BOUNDARY_HOME="$WORKSPACE/tool-boundary-home"
  TOOL_BOUNDARY_TMP="$WORKSPACE/tool-boundary-tmp"
  /bin/mkdir -m 700 "$TOOLS_ROOT" "$TOOL_BOUNDARY_HOME" "$TOOL_BOUNDARY_TMP"
  SPARKLE_DOWNLOAD_OUTPUT="$(
    run_phase_shell_helper scripts/download-sparkle-tools.sh
  )" || release_die "Clean anonymous Sparkle-tool download boundary failed."
  SPARKLE_BIN="${SPARKLE_DOWNLOAD_OUTPUT##*$'\n'}"
  unset SPARKLE_DOWNLOAD_OUTPUT
  [[ "$SPARKLE_BIN" == "$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION/bin" ]] \
    || release_die "Sparkle-tool download escaped the private credential-free directory."
  [[ "$(<"$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION/.archive.sha256")" == "$USHOT_SPARKLE_ARCHIVE_SHA256" ]] \
    || release_die "Downloaded Sparkle archive marker drifted from the checksum-pinned official archive."
  for tool_name in generate_appcast generate_keys sign_update; do
    tool_path="$SPARKLE_BIN/$tool_name"
    [[ -f "$tool_path" && ! -L "$tool_path" && -x "$tool_path" ]] \
      || release_die "Downloaded Sparkle tool is unavailable: $tool_name"
    /usr/bin/codesign --verify --strict "$tool_path" \
      || release_die "Downloaded Sparkle tool failed strict code-signature validation: $tool_name"
    tool_sha256="$(release_sha256 "$tool_path")"
    case "$tool_name" in
      generate_appcast) GENERATE_APPCAST_SHA256="$tool_sha256" ;;
      generate_keys) GENERATE_KEYS_SHA256="$tool_sha256" ;;
      sign_update) SIGN_UPDATE_SHA256="$tool_sha256" ;;
    esac
    if [[ "$PHASE" == "prepare" ]]; then
      [[ "$tool_sha256" == "$(read_reviewed_manifest_value ".credentialFreeOutputs.$tool_name")" ]] \
        || release_die "Official Sparkle tool disagrees with the externally reviewed pin: $tool_name"
    fi
  done
}

resolve_and_verify_python_interpreter() {
  local discovered_path
  local resolved_path
  local binding
  local actual_sha256

  discovered_path="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')" \
    || release_die "Could not resolve the system-selected Python interpreter."
  [[ "$discovered_path" == /* ]] \
    || release_die "Resolved Python interpreter path is not absolute."
  resolved_path="$(/usr/bin/perl -MCwd=abs_path -e 'my $p=abs_path(shift); die "resolve failed\n" unless defined $p; print $p' "$discovered_path")" \
    || release_die "Could not canonicalize the resolved Python interpreter."
  binding="$(capture_regular_file_binding "$resolved_path" 1073741824 python-interpreter system)"
  actual_sha256="$(binding_sha256 "$binding")"
  /usr/bin/codesign --verify --strict "$resolved_path" \
    || release_die "Resolved Python interpreter failed strict code-signature validation."
  verify_bound_regular_file "$resolved_path" 1073741824 python-interpreter "$binding" system
  if [[ "$PHASE" == "prepare" ]]; then
    [[ "$resolved_path" == "$PYTHON_INTERPRETER_PATH" \
        && "$actual_sha256" == "$PYTHON_INTERPRETER_SHA256" \
        && "$resolved_path" == "$(read_reviewed_manifest_value '.buildInputs.pythonInterpreter.path')" \
        && "$actual_sha256" == "$(read_reviewed_manifest_value '.buildInputs.pythonInterpreter.sha256')" ]] \
      || release_die "Resolved Python interpreter disagrees with the externally reviewed CLI/manifest pins."
  fi
  RESOLVED_PYTHON_INTERPRETER_PATH="$resolved_path"
  RESOLVED_PYTHON_INTERPRETER_SHA256="$actual_sha256"
}

run_review_pins_phase() {
  local staging_manifest="$WORKSPACE/reviewed-pins-v2.json"
  local raw_manifest="$WORKSPACE/reviewed-pins-v2.raw.json"
  local relative

  initialize_source_hashes_for_review_pins
  resolve_and_verify_python_interpreter
  compile_phase_a_helpers
  snapshot_and_bind_candidate_assets
  download_and_bind_sparkle_tools

  for relative in \
    Config/Base.xcconfig \
    Tools/AuthenticatedAppcastValidator/main.swift \
    UshotCore/Sources/UshotCore/Product/ProductIdentity.swift \
    UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift \
    UshotCore/Sources/UshotCore/Update/UpdateChecking.swift \
    scripts/derive-sparkle-public-key.swift \
    scripts/download-sparkle-tools.sh \
    scripts/prepare-update-transition-fixtures.sh \
    scripts/release-common.sh \
    scripts/validate-appcast.sh \
    scripts/validate-release-assets.sh \
    updates/release-notes/0.1.4.md \
    updates/v1/appcast.xml; do
    emit_phase_source "$relative" >/dev/null \
      || release_die "Reviewed source changed before pin-manifest creation: $relative"
  done

  /usr/bin/jq -n \
    --arg main "$EXPECTED_SCRIPT_SHA256" \
    --arg baseConfig "$SOURCE_SHA_BASE_CONFIG" \
    --arg authenticatedValidatorSource "$SOURCE_SHA_AUTHENTICATED_VALIDATOR" \
    --arg productIdentity "$SOURCE_SHA_PRODUCT_IDENTITY" \
    --arg signedAppcastPolicy "$SOURCE_SHA_SIGNED_APPCAST_POLICY" \
    --arg updateChecking "$SOURCE_SHA_UPDATE_CHECKING" \
    --arg publicKeyDeriverSource "$SOURCE_SHA_PUBLIC_KEY_DERIVER" \
    --arg downloadTools "$SOURCE_SHA_DOWNLOAD_TOOLS" \
    --arg fixtureScript "$SOURCE_SHA_FIXTURE_SCRIPT" \
    --arg releaseCommon "$SOURCE_SHA_RELEASE_COMMON" \
    --arg validateAppcast "$SOURCE_SHA_VALIDATE_APPCAST" \
    --arg validateAssets "$SOURCE_SHA_VALIDATE_ASSETS" \
    --arg releaseNotes "$SOURCE_SHA_RELEASE_NOTES" \
    --arg appcastSeed "$SOURCE_SHA_APPCAST_SEED" \
    --arg swiftInvocation "$SWIFTC_DISCOVERED_PATH" \
    --arg swiftResolved "$SWIFTC_RESOLVED_PATH" \
    --arg swiftSHA "$SWIFTC_SHA256" \
    --arg pythonPath "$RESOLVED_PYTHON_INTERPRETER_PATH" \
    --arg pythonSHA "$RESOLVED_PYTHON_INTERPRETER_SHA256" \
    --arg verifierSourceSHA "$EMBEDDED_PUBLIC_KEY_VERIFIER_SOURCE_SHA256" \
    --arg sparkleArchiveSHA "$USHOT_SPARKLE_ARCHIVE_SHA256" \
    --arg authenticatedValidator "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
    --arg publicKeyDeriver "$PUBLIC_KEY_DERIVER_SHA256" \
    --arg embeddedVerifier "$EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256" \
    --arg generateAppcast "$GENERATE_APPCAST_SHA256" \
    --arg generateKeys "$GENERATE_KEYS_SHA256" \
    --arg signUpdate "$SIGN_UPDATE_SHA256" \
    --arg dmg "$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[0]}")" \
    --arg zip "$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[1]}")" \
    --arg dsym "$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[2]}")" \
    --arg releaseManifest "$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[3]}")" \
    --arg checksums "$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[4]}")" \
    '{
      schemaVersion: 2,
      purpose: "ushot-update-transition-credential-free-pins-v1",
      mainScriptSHA256: $main,
      sources: {
        "Config/Base.xcconfig": $baseConfig,
        "Tools/AuthenticatedAppcastValidator/main.swift": $authenticatedValidatorSource,
        "UshotCore/Sources/UshotCore/Product/ProductIdentity.swift": $productIdentity,
        "UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift": $signedAppcastPolicy,
        "UshotCore/Sources/UshotCore/Update/UpdateChecking.swift": $updateChecking,
        "scripts/derive-sparkle-public-key.swift": $publicKeyDeriverSource,
        "scripts/download-sparkle-tools.sh": $downloadTools,
        "scripts/prepare-update-transition-fixtures.sh": $fixtureScript,
        "scripts/release-common.sh": $releaseCommon,
        "scripts/validate-appcast.sh": $validateAppcast,
        "scripts/validate-release-assets.sh": $validateAssets,
        "updates/release-notes/0.1.4.md": $releaseNotes,
        "updates/v1/appcast.xml": $appcastSeed
      },
      buildInputs: {
        swiftCompiler: {invocationPath: $swiftInvocation, resolvedPath: $swiftResolved, sha256: $swiftSHA},
        pythonInterpreter: {path: $pythonPath, sha256: $pythonSHA},
        sparkleReleaseArchiveSHA256: $sparkleArchiveSHA,
        embeddedPublicKeyVerifierSourceSHA256: $verifierSourceSHA
      },
      credentialFreeOutputs: {
        AuthenticatedAppcastValidator: $authenticatedValidator,
        SparklePublicKeyDeriver: $publicKeyDeriver,
        EmbeddedPublicKeyVerifier: $embeddedVerifier,
        generate_appcast: $generateAppcast,
        generate_keys: $generateKeys,
        sign_update: $signUpdate
      },
      candidateAssets: {
        "Ushot-0.1.4-arm64.dmg": $dmg,
        "Ushot-0.1.4-arm64.zip": $zip,
        "Ushot-0.1.4-arm64.dSYM.zip": $dsym,
        "Ushot-0.1.4-arm64.release-manifest.json": $releaseManifest,
        "SHA256SUMS.txt": $checksums
      }
    }' > "$raw_manifest"
  USHOT_RAW_REVIEW_MANIFEST="$raw_manifest" \
  USHOT_CANONICAL_REVIEW_MANIFEST="$staging_manifest" \
    /usr/bin/perl \
      -MFcntl=O_RDONLY,O_WRONLY,O_CREAT,O_EXCL,O_NOFOLLOW \
      -MJSON::PP \
      -e '
        use strict;
        use warnings;
        my $input = $ENV{USHOT_RAW_REVIEW_MANIFEST} // die "missing raw manifest\n";
        my $output = $ENV{USHOT_CANONICAL_REVIEW_MANIFEST} // die "missing canonical manifest\n";
        sysopen(my $source, $input, O_RDONLY | O_NOFOLLOW)
          or die "cannot open raw manifest\n";
        binmode($source);
        local $/;
        my $bytes = <$source>;
        close($source) or die "cannot close raw manifest\n";
        my $codec = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);
        my $document = $codec->decode($bytes);
        my $canonical = $codec->encode($document);
        sysopen(my $destination, $output,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0400)
          or die "cannot create canonical manifest\n";
        binmode($destination);
        print {$destination} $canonical or die "cannot write canonical manifest\n";
        close($destination) or die "cannot close canonical manifest\n";
      ' \
    || release_die "Could not canonicalize the reviewed pin manifest."
  /bin/chmod 400 "$staging_manifest"
  [[ ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] \
    || release_die "Reviewed pin-manifest output appeared during credential-free preparation."
  /bin/mv "$staging_manifest" "$OUTPUT_DIRECTORY"
  [[ -f "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" \
      && "$(/usr/bin/stat -f '%Lp' "$OUTPUT_DIRECTORY")" == "400" ]] \
    || release_die "Reviewed pin manifest did not retain exact regular-file/mode identity."
  printf 'reviewed_source_manifest=%s\nreviewed_source_manifest_sha256=%s\npython_interpreter_path=%s\npython_interpreter_sha256=%s\nresult=REVIEW_PINS_PASS\n' \
    "$OUTPUT_DIRECTORY" \
    "$(release_sha256 "$OUTPUT_DIRECTORY")" \
    "$RESOLVED_PYTHON_INTERPRETER_PATH" \
    "$RESOLVED_PYTHON_INTERPRETER_SHA256"
}

verify_sandbox_direct_write_rejection() {
  local allowed_root="$WORKSPACE/sandbox-allowed"
  local forbidden_target="$WORKSPACE/sandbox-forbidden-output"
  local source_file="$WORKSPACE/sandbox-source"
  local escaped_allowed_root
  local profile

  /bin/mkdir -m 700 "$allowed_root"
  /usr/bin/perl -MFcntl=O_WRONLY,O_CREAT,O_EXCL,O_NOFOLLOW -e '
    use strict;
    use warnings;
    my $path = shift @ARGV;
    sysopen(my $handle, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
      or die "cannot create sandbox test source\n";
    print {$handle} "sandbox-confinement-negative\n" or die "cannot write sandbox source\n";
    close($handle) or die "cannot close sandbox source\n";
  ' "$source_file"
  escaped_allowed_root="$(
    USHOT_SANDBOX_PATH="$allowed_root" /usr/bin/perl -e '
      use strict;
      use warnings;
      my $path = $ENV{USHOT_SANDBOX_PATH} // die "missing path\n";
      $path =~ s/([\\"])/\\$1/g;
      print $path;
    '
  )"
  profile="(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)(allow file-read*)(allow file-write* (subpath \"$escaped_allowed_root\"))"
  if /usr/bin/sandbox-exec -p "$profile" /usr/bin/ditto "$source_file" "$forbidden_target" >/dev/null 2>&1; then
    release_die "Sandbox confinement negative unexpectedly allowed a direct write outside the extraction root."
  fi
  [[ ! -e "$forbidden_target" && ! -L "$forbidden_target" ]] \
    || release_die "Sandbox confinement negative created forbidden output despite rejection."
  release_log "Direct sandbox confinement negative passed before any signing key access."
}

write_prepared_freeze_manifest() {
  local prepared_root="$1"
  local output_path="$prepared_root/freeze-manifest.json"

  USHOT_PREPARED_ROOT="$prepared_root" \
  USHOT_FREEZE_MANIFEST_OUTPUT="$output_path" \
  USHOT_EXPECTED_SCRIPT_SHA256="$EXPECTED_SCRIPT_SHA256" \
  USHOT_PUBLIC_KEY_FINGERPRINT_SHA256="$SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256" \
  USHOT_REVIEWED_MANIFEST_SHA256="$REVIEWED_SOURCE_MANIFEST_SHA256" \
  USHOT_PYTHON_INTERPRETER_PATH="$PYTHON_INTERPRETER_PATH" \
  USHOT_PYTHON_INTERPRETER_SHA256="$PYTHON_INTERPRETER_SHA256" \
    /usr/bin/perl \
      -MDigest::SHA \
      -MFcntl=O_RDONLY,O_WRONLY,O_CREAT,O_EXCL,O_NOFOLLOW \
      -MJSON::PP \
      -MPOSIX=S_ISREG \
      -e '
        use strict;
        use warnings;
        my @files = qw(
          Config/Base.xcconfig
          assets/SHA256SUMS.txt
          assets/Ushot-0.1.4-arm64.dSYM.zip
          assets/Ushot-0.1.4-arm64.dmg
          assets/Ushot-0.1.4-arm64.release-manifest.json
          assets/Ushot-0.1.4-arm64.zip
          helpers/AuthenticatedAppcastValidator
          helpers/EmbeddedPublicKeyVerifier
          helpers/SparklePublicKeyDeriver
          inputs/current/appcast.kind
          inputs/current/appcast.xml
          metadata/request.json
          metadata/reviewed-source-manifest.json
          scripts/prepare-update-transition-fixtures.sh
          scripts/release-common.sh
          scripts/validate-appcast.sh
          tools/Sparkle-2.9.5/.archive.sha256
          tools/Sparkle-2.9.5/bin/generate_appcast
          tools/Sparkle-2.9.5/bin/generate_keys
          tools/Sparkle-2.9.5/bin/sign_update
          updates/release-notes/0.1.4.md
          updates/v1/appcast.xml
        );
        my %executable = map { $_ => 1 } qw(
          helpers/AuthenticatedAppcastValidator
          helpers/EmbeddedPublicKeyVerifier
          helpers/SparklePublicKeyDeriver
          scripts/prepare-update-transition-fixtures.sh
          tools/Sparkle-2.9.5/bin/generate_appcast
          tools/Sparkle-2.9.5/bin/generate_keys
          tools/Sparkle-2.9.5/bin/sign_update
        );
        my $root = $ENV{USHOT_PREPARED_ROOT} // die "missing prepared root\n";
        my $output = $ENV{USHOT_FREEZE_MANIFEST_OUTPUT} // die "missing output\n";
        my $script_sha = $ENV{USHOT_EXPECTED_SCRIPT_SHA256} // die "missing script hash\n";
        my $public_fingerprint = $ENV{USHOT_PUBLIC_KEY_FINGERPRINT_SHA256} // die "missing public fingerprint\n";
        my $reviewed_manifest_sha = $ENV{USHOT_REVIEWED_MANIFEST_SHA256} // die "missing reviewed manifest hash\n";
        my $python_path = $ENV{USHOT_PYTHON_INTERPRETER_PATH} // die "missing Python path\n";
        my $python_sha = $ENV{USHOT_PYTHON_INTERPRETER_SHA256} // die "missing Python hash\n";
        die "malformed fixed hashes or Python path\n" unless $script_sha =~ /\A[0-9a-f]{64}\z/
          && $public_fingerprint =~ /\A[0-9a-f]{64}\z/
          && $reviewed_manifest_sha =~ /\A[0-9a-f]{64}\z/
          && $python_sha =~ /\A[0-9a-f]{64}\z/
          && $python_path =~ m{\A/} && $python_path !~ m{//|/\./|/\.\./};
        my %records;
        for my $relative (@files) {
          my $path = "$root/$relative";
          my @before = lstat($path);
          die "missing prepared file: $relative\n" unless @before && S_ISREG($before[2]);
          my $expected_mode = $executable{$relative} ? 0500 : 0400;
          die "prepared mode mismatch: $relative\n"
            unless $before[4] == $< && ($before[2] & 07777) == $expected_mode
              && $before[7] > 0 && $before[7] <= 268_435_456;
          sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW)
            or die "cannot open prepared file: $relative\n";
          binmode($handle);
          my @opened = stat($handle);
          die "prepared file changed while opening: $relative\n"
            unless @opened && join(",", @opened[0,1,2,4,5,7,9,10])
              eq join(",", @before[0,1,2,4,5,7,9,10]);
          my $digest = Digest::SHA->new(256);
          while (1) {
            my $chunk = "";
            my $count = sysread($handle, $chunk, 65536);
            die "cannot read prepared file: $relative\n" unless defined($count);
            last if $count == 0;
            $digest->add($chunk);
          }
          my @after = stat($handle);
          close($handle) or die "cannot close prepared file: $relative\n";
          die "prepared file changed while hashing: $relative\n"
            unless @after && join(",", @opened[0,1,2,4,5,7,9,10])
              eq join(",", @after[0,1,2,4,5,7,9,10]);
          $records{$relative} = {
            mode => $executable{$relative} ? "0500" : "0400",
            sha256 => $digest->hexdigest,
            size => 0 + $opened[7],
          };
        }
        my $document = {
          schemaVersion => 2,
          bundlePurpose => "ushot-update-transition-fixtures-v1",
          scriptSHA256 => $script_sha,
          publicKeyFingerprintSHA256 => $public_fingerprint,
          reviewedSourceManifestSHA256 => $reviewed_manifest_sha,
          pythonInterpreter => {
            path => $python_path,
            sha256 => $python_sha,
          },
          files => \%records,
        };
        my $bytes = JSON::PP->new->canonical(1)->pretty(1)->encode($document);
        sysopen(my $output_handle, $output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0400)
          or die "cannot create freeze manifest\n";
        binmode($output_handle);
        print {$output_handle} $bytes or die "cannot write freeze manifest\n";
        close($output_handle) or die "cannot close freeze manifest\n";
      ' \
    || release_die "Could not create the exact prepared freeze manifest."
}

print_freeze_and_sign_commands() {
  local prepared_root="$1"
  local manifest_sha="$2"
  local frozen_root="$3"
  local root_copy_directory="/private/var/root/ushot-update-transition-freezer-${EXPECTED_SCRIPT_SHA256:0:16}-${manifest_sha:0:16}"
  local root_copy_script="$root_copy_directory/prepare-update-transition-fixtures.sh"
  local root_launcher
  local sign_launcher
  local freeze_owner_uid
  local freeze_owner_gid
  local sign_user
  local sign_home="$HOME"

  freeze_owner_uid="$(/usr/bin/id -u)"
  freeze_owner_gid="$(/usr/bin/id -g)"
  sign_user="$(/usr/bin/id -un)"
root_launcher='set -euo pipefail
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
source_script="$1"
root_copy_directory="$2"
root_copy_script="$3"
expected_script_sha="$4"
prepared_bundle="$5"
frozen_bundle="$6"
expected_manifest_sha="$7"
expected_reviewed_manifest_sha="$8"
python_interpreter_path="$9"
python_interpreter_sha="${10}"
expected_root_copy_directory="/private/var/root/ushot-update-transition-freezer-${expected_script_sha:0:16}-${expected_manifest_sha:0:16}"
[[ "$root_copy_directory" == "$expected_root_copy_directory" \
    && "$root_copy_script" == "$root_copy_directory/prepare-update-transition-fixtures.sh" \
    && "$expected_script_sha" =~ ^[0-9a-f]{64}$ ]] || { printf "error: root-copy path/hash is not bound\n" >&2; exit 1; }
[[ "${SUDO_UID:-}" =~ ^[1-9][0-9]*$ && "${SUDO_GID:-}" =~ ^[0-9]+$ \
    && -f "$source_script" && ! -L "$source_script" \
    && "$(/usr/bin/stat -f "%u:%g:%Lp" "$source_script")" == "$SUDO_UID:$SUDO_GID:500" ]] \
  || { printf "error: prepared main-script source identity is not exact\n" >&2; exit 1; }
[[ ! -e "$root_copy_directory" && ! -L "$root_copy_directory" ]] || { printf "error: root-copy directory already exists: %s\n" "$root_copy_directory" >&2; exit 1; }
/bin/mkdir -m 0700 "$root_copy_directory"
cleanup_root_copy() {
  if [[ -e "$root_copy_script" || -L "$root_copy_script" ]]; then
    [[ -f "$root_copy_script" && ! -L "$root_copy_script" \
        && "$(/usr/bin/stat -f "%u:%g" "$root_copy_script")" == "0:0" ]] \
      || { printf "error: refusing to clean an unexpected root-copy entry\n" >&2; return 1; }
    /bin/rm -- "$root_copy_script"
  fi
  /bin/rmdir "$root_copy_directory"
}
trap cleanup_root_copy EXIT
trap "exit 129" HUP
trap "exit 130" INT
trap "exit 143" TERM
/usr/bin/install -o root -g wheel -m 0500 "$source_script" "$root_copy_script"
[[ -f /usr/bin/openssl && ! -L /usr/bin/openssl \
    && "$(/usr/bin/stat -f "%u:%g:%Lp" /usr/bin/openssl)" == "0:0:755" ]] \
  || { printf "error: system SHA-256 executable identity is not exact\n" >&2; exit 1; }
/usr/bin/codesign --verify --strict \
  --test-requirement "=anchor apple and identifier \"com.apple.openssl\"" \
  /usr/bin/openssl \
  || { printf "error: system SHA-256 executable signature rejected\n" >&2; exit 1; }
actual_sha="$(/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=C \
  LC_ALL=C \
  OPENSSL_CONF=/dev/null \
  /usr/bin/openssl dgst -sha256 -r "$root_copy_script")" \
  || { printf "error: trusted system SHA-256 execution failed\n" >&2; exit 1; }
actual_sha="${actual_sha%% *}"
[[ "$actual_sha" =~ ^[0-9a-f]{64}$ ]] \
  || { printf "error: trusted system SHA-256 output is malformed\n" >&2; exit 1; }
[[ "$actual_sha" == "$expected_script_sha" ]] || { printf "error: root-copy script hash mismatch\n" >&2; exit 1; }
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=C \
  LC_ALL=C \
  SUDO_UID="$SUDO_UID" \
  SUDO_GID="$SUDO_GID" \
  /bin/bash --noprofile --norc -p "$root_copy_script" --phase root-freeze --expected-script-sha256 "$expected_script_sha" --prepared-bundle "$prepared_bundle" --frozen-bundle "$frozen_bundle" --expected-freeze-manifest-sha256 "$expected_manifest_sha" --reviewed-source-manifest-sha256 "$expected_reviewed_manifest_sha" --python-interpreter-path "$python_interpreter_path" --python-interpreter-sha256 "$python_interpreter_sha" --root-copy-directory "$root_copy_directory"'
  sign_launcher='BEGIN {
  @INC = qw(
    /System/Library/Perl/5.34/darwin-thread-multi-2level
    /System/Library/Perl/5.34
  );
  %ENV = (
    PATH => "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG => "C",
    LC_ALL => "C",
  );
}
use strict;
use warnings;
use Digest::SHA ();
use DynaLoader ();
use Fcntl qw(O_RDONLY O_NOFOLLOW F_GETFD F_SETFD FD_CLOEXEC);
use POSIX qw(S_ISDIR S_ISREG SEEK_SET);

sub fail { die "sign launcher: $_[0]\n"; }
sub identity { return join(",", @_[0, 1, 2, 4, 5, 7, 9, 10]); }
sub untaint_hash {
  my ($value, $label) = @_;
  fail("malformed $label") unless defined($value) && $value =~ /\A([0-9a-f]{64})\z/;
  return $1;
}
sub untaint_absolute_path {
  my ($value, $label) = @_;
  fail("malformed $label") unless defined($value)
    && $value =~ m{\A(/[^\0\r\n]+)\z} && $value ne "/" && $value !~ m{//};
  my $captured = $1;
  for my $component (split(m{/}, $captured, -1)) {
    next if $component eq "";
    fail("noncanonical $label") if $component eq "." || $component eq "..";
  }
  return $captured;
}
sub verify_system_runtime_path {
  my ($path) = @_;
  fail("Perl loaded a non-System module")
    unless defined($path) && $path =~ m{\A/System/Library/Perl/5\.34(?:/|\z)};
  my $current = "";
  my @components = grep { length($_) } split(m{/}, $path);
  for my $index (0 .. $#components) {
    $current .= "/$components[$index]";
    my @status = lstat($current);
    fail("System Perl runtime path vanished") unless @status && $status[4] == 0
      && ($status[2] & 0022) == 0;
    if ($index == $#components) {
      fail("System Perl runtime module is not regular") unless S_ISREG($status[2]);
    } else {
      fail("System Perl runtime ancestor is not a directory") unless S_ISDIR($status[2]);
    }
  }
}
sub verify_system_runtime {
  my @expected_inc = (
    "/System/Library/Perl/5.34/darwin-thread-multi-2level",
    "/System/Library/Perl/5.34",
  );
  fail("Perl include path count differs") unless @INC == @expected_inc;
  for my $index (0 .. $#expected_inc) {
    fail("Perl include path was broadened") unless $INC[$index] eq $expected_inc[$index];
  }
  verify_system_runtime_path($_) for values(%INC);
  verify_system_runtime_path($_) for @DynaLoader::dl_shared_objects;
}
sub protect_inherited_descriptor {
  my ($handle, $label) = @_;
  fcntl($handle, F_SETFD, 0) or fail("cannot preserve $label descriptor");
  my $flags = fcntl($handle, F_GETFD, 0);
  fail("$label descriptor inheritance did not stick")
    unless defined($flags) && ($flags & FD_CLOEXEC) == 0;
}

verify_system_runtime();
fail("unexpected arguments") unless @ARGV == 9;
my $root = untaint_absolute_path($ARGV[0], "frozen root");
my $expected_script = untaint_hash($ARGV[1], "script hash");
my $expected_manifest = untaint_hash($ARGV[2], "freeze-manifest hash");
my $expected_reviewed = untaint_hash($ARGV[3], "reviewed-manifest hash");
my $python_path = untaint_absolute_path($ARGV[4], "Python path");
my $python_sha = untaint_hash($ARGV[5], "Python hash");
my $output = untaint_absolute_path($ARGV[6], "output path");
my $home = untaint_absolute_path($ARGV[7], "home path");
fail("malformed user") unless defined($ARGV[8]) && $ARGV[8] =~ /\A([A-Za-z0-9._-]+)\z/;
my $user = $1;
my $expected_root = "/Library/Application Support/Ushot/UpdateTransition/ushot-0.1.4-"
  . substr($expected_manifest, 0, 16);
fail("frozen root is not the fixed hash-bound path") unless $root eq $expected_root;

my $path = "$root/scripts/prepare-update-transition-fixtures.sh";
my @path_stat = lstat($path);
fail("frozen worker is not a root-owned mode-0555 regular file")
  unless @path_stat && S_ISREG($path_stat[2]) && $path_stat[4] == 0
    && $path_stat[5] == 0 && ($path_stat[2] & 07777) == 0555
    && $path_stat[7] > 0 && $path_stat[7] <= 16_777_216;
sysopen(my $worker, $path, O_RDONLY | O_NOFOLLOW)
  or fail("cannot open worker with O_NOFOLLOW");
binmode($worker);
my @descriptor_stat = stat($worker);
fail("worker path changed while opening")
  unless @descriptor_stat && identity(@path_stat) eq identity(@descriptor_stat);
my $digest = Digest::SHA->new(256);
my $worker_size = 0;
while (1) {
  my $chunk = "";
  my $count = sysread($worker, $chunk, 65536);
  if (!defined($count)) {
    next if $!{EINTR};
    fail("worker read failed");
  }
  last if $count == 0;
  $worker_size += $count;
  fail("worker exceeded byte bound") if $worker_size > 16_777_216;
  $digest->add($chunk);
}
my @worker_after = stat($worker);
my @worker_path_after = lstat($path);
fail("worker changed while hashing") unless @worker_after && @worker_path_after
  && identity(@descriptor_stat) eq identity(@worker_after)
  && identity(@descriptor_stat) eq identity(@worker_path_after)
  && $worker_size == $descriptor_stat[7];
fail("worker hash mismatch") unless $digest->hexdigest eq $expected_script;
sysseek($worker, 0, SEEK_SET) or fail("cannot rewind worker");
protect_inherited_descriptor($worker, "worker");
my $descriptor_path = "/dev/fd/" . fileno($worker);

my $common_path = "$root/scripts/release-common.sh";
my @common_path_stat = lstat($common_path);
fail("frozen release-common is not a root-owned mode-0444 regular file")
  unless @common_path_stat && S_ISREG($common_path_stat[2])
    && $common_path_stat[4] == 0 && $common_path_stat[5] == 0
    && ($common_path_stat[2] & 07777) == 0444
    && $common_path_stat[7] > 0 && $common_path_stat[7] <= 1_048_576;
sysopen(my $common, $common_path, O_RDONLY | O_NOFOLLOW)
  or fail("cannot open release-common with O_NOFOLLOW");
binmode($common);
my @common_descriptor_stat = stat($common);
my @common_path_after = lstat($common_path);
fail("release-common path changed while opening")
  unless @common_descriptor_stat && @common_path_after
    && identity(@common_path_stat) eq identity(@common_descriptor_stat)
    && identity(@common_descriptor_stat) eq identity(@common_path_after);
protect_inherited_descriptor($common, "release-common");
my $common_descriptor_path = "/dev/fd/" . fileno($common);
exec {"/usr/bin/env"} "/usr/bin/env", "-i",
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=$home", "USER=$user", "LOGNAME=$user",
  "LANG=C", "LC_ALL=C", "USHOT_FROZEN_RELEASE_COMMON_DESCRIPTOR=$common_descriptor_path",
  "/bin/bash", "--noprofile", "--norc", "-p", $descriptor_path,
  "--phase", "sign", "--output", $output, "--frozen-bundle", $root,
  "--expected-script-sha256", $expected_script,
  "--expected-freeze-manifest-sha256", $expected_manifest,
  "--reviewed-source-manifest-sha256", $expected_reviewed,
  "--python-interpreter-path", $python_path,
  "--python-interpreter-sha256", $python_sha,
  "--key-source", "keychain";
fail("exec failed");'

  printf '%s\n' \
    'Phase A is complete. Review the hashes, then run this explicit root-only public-byte freeze command:'
  printf '  '
  printf '%q ' \
    /usr/bin/sudo -- \
    /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=C \
    LC_ALL=C \
    SUDO_UID="$freeze_owner_uid" \
    SUDO_GID="$freeze_owner_gid" \
    /bin/bash --noprofile --norc -p -c "$root_launcher" ushot-freeze \
    "$prepared_root/scripts/prepare-update-transition-fixtures.sh" \
    "$root_copy_directory" \
    "$root_copy_script" \
    "$EXPECTED_SCRIPT_SHA256" \
    "$prepared_root" \
    "$frozen_root" \
    "$manifest_sha" \
    "$REVIEWED_SOURCE_MANIFEST_SHA256" \
    "$PYTHON_INTERPRETER_PATH" \
    "$PYTHON_INTERPRETER_SHA256"
  printf '\n%s\n' 'Only after that command reports ROOT_FREEZE_PASS, run this current-user anonymous-FD keychain command:'
  printf '  '
  printf '%q ' \
    /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$sign_home" \
    USER="$sign_user" \
    LOGNAME="$sign_user" \
    LANG=C \
    LC_ALL=C \
    /usr/bin/perl -T -f \
    -e "$sign_launcher" \
    "$frozen_root" \
    "$EXPECTED_SCRIPT_SHA256" \
    "$manifest_sha" \
    "$REVIEWED_SOURCE_MANIFEST_SHA256" \
    "$PYTHON_INTERPRETER_PATH" \
    "$PYTHON_INTERPRETER_SHA256" \
    "$OUTPUT_DIRECTORY" \
    "$sign_home" \
    "$sign_user"
  printf '\n'
}

prepare_key_free_frozen_bundle() {
  local prepared_parent
  local prepared_root
  local request_path
  local freeze_manifest_sha
  local frozen_root
  local relative
  local source_path
  local maximum
  local executable
  local destination
  local -a freeze_entries=()

  REVIEWED_SOURCE_MANIFEST_SNAPSHOT="$WORKSPACE/reviewed-source-manifest-v2.json"
  snapshot_regular_file_no_follow \
    "$REVIEWED_SOURCE_MANIFEST" \
    "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT" \
    1048576 \
    reviewed-source-manifest-v2 >/dev/null
  /bin/chmod 400 "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT"
  REVIEWED_SOURCE_MANIFEST_SNAPSHOT_BINDING="$(
    capture_regular_file_binding \
      "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT" \
      1048576 \
      reviewed-source-manifest-snapshot
  )"
  [[ "$(binding_sha256 "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT_BINDING")" == "$REVIEWED_SOURCE_MANIFEST_SHA256" ]] \
    || release_die "Reviewed-source manifest changed after early admission."
  initialize_source_hashes_from_reviewed_manifest

  SOURCE_SNAPSHOT_ROOT="$WORKSPACE/reviewed-source-snapshots"
  /bin/mkdir -p -m 700 \
    "$SOURCE_SNAPSHOT_ROOT/Config" \
    "$SOURCE_SNAPSHOT_ROOT/scripts" \
    "$SOURCE_SNAPSHOT_ROOT/updates/release-notes" \
    "$SOURCE_SNAPSHOT_ROOT/updates/v1"
  materialize_phase_source_snapshot() {
    local relative="$1"
    local destination="$2"
    local expected_sha256
    expected_sha256="$(phase_source_hash_for "$relative")"
    emit_phase_source "$relative" > "$destination" \
      || release_die "Could not materialize reviewed source snapshot: $relative"
    /bin/chmod 400 "$destination"
    [[ "$(release_sha256 "$destination")" == "$expected_sha256" ]] \
      || release_die "Reviewed source snapshot hash mismatch: $relative"
  }
  FIXTURE_SCRIPT_PATH="$SOURCE_SNAPSHOT_ROOT/scripts/prepare-update-transition-fixtures.sh"
  RELEASE_COMMON_SOURCE_PATH="$SOURCE_SNAPSHOT_ROOT/scripts/release-common.sh"
  VALIDATE_APPCAST_SOURCE_PATH="$SOURCE_SNAPSHOT_ROOT/scripts/validate-appcast.sh"
  BASE_CONFIG_SOURCE_PATH="$SOURCE_SNAPSHOT_ROOT/Config/Base.xcconfig"
  RELEASE_NOTES_SOURCE="$SOURCE_SNAPSHOT_ROOT/updates/release-notes/0.1.4.md"
  APPCAST_SEED_SOURCE_PATH="$SOURCE_SNAPSHOT_ROOT/updates/v1/appcast.xml"
  materialize_phase_source_snapshot scripts/prepare-update-transition-fixtures.sh "$FIXTURE_SCRIPT_PATH"
  materialize_phase_source_snapshot scripts/release-common.sh "$RELEASE_COMMON_SOURCE_PATH"
  materialize_phase_source_snapshot scripts/validate-appcast.sh "$VALIDATE_APPCAST_SOURCE_PATH"
  materialize_phase_source_snapshot Config/Base.xcconfig "$BASE_CONFIG_SOURCE_PATH"
  materialize_phase_source_snapshot updates/release-notes/0.1.4.md "$RELEASE_NOTES_SOURCE"
  materialize_phase_source_snapshot updates/v1/appcast.xml "$APPCAST_SEED_SOURCE_PATH"

  FIXTURE_SCRIPT_BINDING="$(capture_regular_file_binding "$FIXTURE_SCRIPT_PATH" 1048576 fixture-script-snapshot)"
  RELEASE_COMMON_SOURCE_BINDING="$(capture_regular_file_binding "$RELEASE_COMMON_SOURCE_PATH" 1048576 release-common-snapshot)"
  VALIDATE_APPCAST_SOURCE_BINDING="$(capture_regular_file_binding "$VALIDATE_APPCAST_SOURCE_PATH" 1048576 validate-appcast-snapshot)"
  BASE_CONFIG_SOURCE_BINDING="$(capture_regular_file_binding "$BASE_CONFIG_SOURCE_PATH" 1048576 base-config-snapshot)"
  RELEASE_NOTES_SOURCE_BINDING="$(capture_regular_file_binding "$RELEASE_NOTES_SOURCE" 1048576 release-notes-snapshot)"
  APPCAST_SEED_SOURCE_BINDING="$(capture_regular_file_binding "$APPCAST_SEED_SOURCE_PATH" 1048576 appcast-seed-snapshot)"

  verify_phase_a_source_bindings() {
    verify_bound_regular_file "$FIXTURE_SCRIPT_PATH" 1048576 fixture-script-snapshot "$FIXTURE_SCRIPT_BINDING"
    verify_bound_regular_file "$RELEASE_COMMON_SOURCE_PATH" 1048576 release-common-snapshot "$RELEASE_COMMON_SOURCE_BINDING"
    verify_bound_regular_file "$VALIDATE_APPCAST_SOURCE_PATH" 1048576 validate-appcast-snapshot "$VALIDATE_APPCAST_SOURCE_BINDING"
    verify_bound_regular_file "$BASE_CONFIG_SOURCE_PATH" 1048576 base-config-snapshot "$BASE_CONFIG_SOURCE_BINDING"
    verify_bound_regular_file "$RELEASE_NOTES_SOURCE" 1048576 release-notes-snapshot "$RELEASE_NOTES_SOURCE_BINDING"
    verify_bound_regular_file "$APPCAST_SEED_SOURCE_PATH" 1048576 appcast-seed-snapshot "$APPCAST_SEED_SOURCE_BINDING"
    verify_bound_regular_file "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT" 1048576 reviewed-source-manifest-snapshot "$REVIEWED_SOURCE_MANIFEST_SNAPSHOT_BINDING"
    for relative in \
      Tools/AuthenticatedAppcastValidator/main.swift \
      UshotCore/Sources/UshotCore/Product/ProductIdentity.swift \
      UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift \
      UshotCore/Sources/UshotCore/Update/UpdateChecking.swift \
      scripts/derive-sparkle-public-key.swift \
      scripts/download-sparkle-tools.sh \
      scripts/validate-release-assets.sh; do
      emit_phase_source "$relative" >/dev/null \
        || release_die "Reviewed source changed during Phase A: $relative"
    done
  }
  verify_phase_a_source_bindings

  resolve_and_verify_python_interpreter
  [[ "$(read_reviewed_manifest_value '.buildInputs.sparkleReleaseArchiveSHA256')" == "$USHOT_SPARKLE_ARCHIVE_SHA256" ]] \
    || release_die "Reviewed Sparkle archive pin disagrees with release-common."

  SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256="$(
    USHOT_BOUND_PUBLIC_KEY="$USHOT_SPARKLE_PUBLIC_ED_KEY" \
      /usr/bin/perl -MDigest::SHA=sha256_hex -MMIME::Base64=decode_base64,encode_base64 -e '
        use strict;
        use warnings;
        my $encoded = $ENV{USHOT_BOUND_PUBLIC_KEY} // die "missing public key\n";
        my $decoded = decode_base64($encoded);
        die "invalid public key\n" unless length($decoded) == 32 && encode_base64($decoded, "") eq $encoded;
        print sha256_hex($decoded);
      '
  )"
  verify_phase_a_source_bindings
  compile_phase_a_helpers
  verify_sandbox_direct_write_rejection
  snapshot_and_bind_candidate_assets
  verify_phase_a_source_bindings
  download_and_bind_sparkle_tools

  CURRENT_APPCAST="$WORKSPACE/current-appcast.xml"
  CURRENT_APPCAST_KIND_PATH="$WORKSPACE/current-appcast.kind"
  verify_phase_a_source_bindings
  /usr/bin/xmllint --noout "$APPCAST_SEED_SOURCE_PATH"
  [[ "$(/usr/bin/xmllint --xpath 'string(/*[local-name()="rss"]/@version)' "$APPCAST_SEED_SOURCE_PATH")" == "2.0" \
      && "$(/usr/bin/xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"])' "$APPCAST_SEED_SOURCE_PATH")" == "1" \
      && "$(/usr/bin/xmllint --xpath 'count(//*[local-name()="item"])' "$APPCAST_SEED_SOURCE_PATH")" == "0" ]] \
    || release_die "Externally reviewed first-feed seed is not the exact zero-item RSS structure."
  release_validate_canonical_appcast_channel "$APPCAST_SEED_SOURCE_PATH"
  CURRENT_APPCAST_DOWNLOAD="$WORKSPACE/current-appcast-download"
  CURRENT_APPCAST_HTTP_STATUS="$(
    /usr/bin/curl --silent --show-error \
      --proto '=https' \
      --tlsv1.2 \
      --max-filesize "$USHOT_MAX_SIGNED_APPCAST_BYTES" \
      --user-agent 'UshotReleasePipeline/1' \
      --output "$CURRENT_APPCAST_DOWNLOAD" \
      --write-out '%{http_code}' \
      "$USHOT_APPCAST_URL"
  )" || release_die "Could not perform bounded HTTPS status check for the production appcast."
  [[ "$CURRENT_APPCAST_HTTP_STATUS" == "404" ]] \
    || release_die "Phase A requires the v1 production endpoint to remain HTTP 404; observed $CURRENT_APPCAST_HTTP_STATUS."
  /usr/bin/ditto "$APPCAST_SEED_SOURCE_PATH" "$CURRENT_APPCAST"
  printf 'seed' > "$CURRENT_APPCAST_KIND_PATH"
  /usr/bin/cmp "$CURRENT_APPCAST" "$APPCAST_SEED_SOURCE_PATH" \
    || release_die "First-feed input is not byte-identical to the externally reviewed seed."
  verify_phase_a_source_bindings

  prepared_parent="$(/usr/bin/dirname "$PREPARED_BUNDLE_DIRECTORY")"
  PREPARED_STAGING="$(/usr/bin/mktemp -d "$prepared_parent/.ushot-freeze-prepared.XXXXXXXX")"
  /bin/chmod 700 "$PREPARED_STAGING"
  prepared_root="$PREPARED_STAGING"
  for relative in \
    Config \
    assets \
    helpers \
    inputs \
    inputs/current \
    metadata \
    scripts \
    tools \
    "tools/Sparkle-$USHOT_SPARKLE_VERSION" \
    "tools/Sparkle-$USHOT_SPARKLE_VERSION/bin" \
    updates \
    updates/release-notes \
    updates/v1; do
    /bin/mkdir -m 700 "$prepared_root/$relative"
  done

  freeze_entries=(
    "Config/Base.xcconfig|$BASE_CONFIG_SOURCE_PATH|1048576|false"
    "assets/SHA256SUMS.txt|$ASSET_SNAPSHOT_ROOT/SHA256SUMS.txt|1048576|false"
    "assets/Ushot-0.1.4-arm64.dSYM.zip|$ASSET_SNAPSHOT_ROOT/Ushot-0.1.4-arm64.dSYM.zip|$SAFE_ARCHIVE_MAX_BYTES|false"
    "assets/Ushot-0.1.4-arm64.dmg|$ASSET_SNAPSHOT_ROOT/Ushot-0.1.4-arm64.dmg|$SAFE_ARCHIVE_MAX_BYTES|false"
    "assets/Ushot-0.1.4-arm64.release-manifest.json|$ASSET_SNAPSHOT_ROOT/Ushot-0.1.4-arm64.release-manifest.json|1048576|false"
    "assets/Ushot-0.1.4-arm64.zip|$ASSET_SNAPSHOT_ROOT/Ushot-0.1.4-arm64.zip|$SAFE_ARCHIVE_MAX_BYTES|false"
    "helpers/AuthenticatedAppcastValidator|$AUTHENTICATED_APPCAST_VALIDATOR|134217728|true"
    "helpers/EmbeddedPublicKeyVerifier|$EMBEDDED_PUBLIC_KEY_VERIFIER|134217728|true"
    "helpers/SparklePublicKeyDeriver|$PUBLIC_KEY_DERIVER|134217728|true"
    "inputs/current/appcast.kind|$CURRENT_APPCAST_KIND_PATH|64|false"
    "inputs/current/appcast.xml|$CURRENT_APPCAST|1049088|false"
    "metadata/reviewed-source-manifest.json|$REVIEWED_SOURCE_MANIFEST_SNAPSHOT|1048576|false"
    "scripts/prepare-update-transition-fixtures.sh|$FIXTURE_SCRIPT_PATH|1048576|true"
    "scripts/release-common.sh|$RELEASE_COMMON_SOURCE_PATH|1048576|false"
    "scripts/validate-appcast.sh|$VALIDATE_APPCAST_SOURCE_PATH|1048576|false"
    "tools/Sparkle-$USHOT_SPARKLE_VERSION/.archive.sha256|$TOOLS_ROOT/Sparkle-$USHOT_SPARKLE_VERSION/.archive.sha256|256|false"
    "tools/Sparkle-$USHOT_SPARKLE_VERSION/bin/generate_appcast|$SPARKLE_BIN/generate_appcast|134217728|true"
    "tools/Sparkle-$USHOT_SPARKLE_VERSION/bin/generate_keys|$SPARKLE_BIN/generate_keys|134217728|true"
    "tools/Sparkle-$USHOT_SPARKLE_VERSION/bin/sign_update|$SPARKLE_BIN/sign_update|134217728|true"
    "updates/release-notes/0.1.4.md|$RELEASE_NOTES_SOURCE|1048576|false"
    "updates/v1/appcast.xml|$APPCAST_SEED_SOURCE_PATH|1048576|false"
  )
  for entry in "${freeze_entries[@]}"; do
    IFS='|' read -r relative source_path maximum executable <<< "$entry"
    destination="$prepared_root/$relative"
    snapshot_regular_file_no_follow \
      "$source_path" "$destination" "$maximum" "freeze-${relative//\//-}" >/dev/null
    if [[ "$executable" == "true" ]]; then
      /bin/chmod 500 "$destination"
    fi
  done

  request_path="$prepared_root/metadata/request.json"
  /usr/bin/jq -n \
    --arg outputDirectory "$OUTPUT_DIRECTORY" \
    --arg sourceVersion "$TRANSITION_SOURCE_VERSION" \
    --arg sourceBuild "$TRANSITION_SOURCE_BUILD" \
    --arg targetVersion "$FIXTURE_VERSION" \
    --arg targetBuild "$FIXTURE_BUILD" \
    --arg tag "$FIXTURE_TAG" \
    --arg scriptSHA256 "$EXPECTED_SCRIPT_SHA256" \
    --arg reviewedSourceManifestSHA256 "$REVIEWED_SOURCE_MANIFEST_SHA256" \
    --arg pythonInterpreterPath "$PYTHON_INTERPRETER_PATH" \
    --arg pythonInterpreterSHA256 "$PYTHON_INTERPRETER_SHA256" \
    '{schemaVersion: 2, outputDirectory: $outputDirectory, sourceVersion: $sourceVersion, sourceBuild: $sourceBuild, targetVersion: $targetVersion, targetBuild: $targetBuild, tag: $tag, scriptSHA256: $scriptSHA256, reviewedSourceManifestSHA256: $reviewedSourceManifestSHA256, pythonInterpreter: {path: $pythonInterpreterPath, sha256: $pythonInterpreterSHA256}}' \
    > "$request_path"
  /bin/chmod 400 "$request_path"
  write_prepared_freeze_manifest "$prepared_root"
  PREPARED_OWNER_UID="$(/usr/bin/id -u)"
  PREPARED_OWNER_GID="$(/usr/bin/id -g)"
  [[ "$PREPARED_OWNER_UID" =~ ^[1-9][0-9]*$ && "$PREPARED_OWNER_GID" =~ ^[0-9]+$ ]] \
    || release_die "Could not resolve canonical prepared-bundle owner identity."
  [[ "$(/usr/bin/find "$prepared_root" -type l -print -quit)" == "" ]] \
    || release_die "Prepared bundle acquired a symbolic link before group normalization."
  /usr/bin/find "$prepared_root" -exec /usr/bin/chgrp "$PREPARED_OWNER_GID" {} + \
    || release_die "Could not normalize the exact prepared tree to the caller's primary group."
  USHOT_PREPARED_ROOT="$prepared_root" \
  USHOT_PREPARED_UID="$PREPARED_OWNER_UID" \
  USHOT_PREPARED_GID="$PREPARED_OWNER_GID" \
    /usr/bin/perl -MFile::Find -MPOSIX=S_ISDIR,S_ISREG -e '
      use strict;
      use warnings;
      my $root = $ENV{USHOT_PREPARED_ROOT} // die "missing prepared root\n";
      my $uid = 0 + ($ENV{USHOT_PREPARED_UID} // die "missing uid\n");
      my $gid = 0 + ($ENV{USHOT_PREPARED_GID} // die "missing gid\n");
      File::Find::find({
        no_chdir => 1,
        follow => 0,
        wanted => sub {
          my @stat = lstat($_);
          die "prepared entry vanished\n" unless @stat;
          die "prepared owner/group mismatch: $_\n" unless $stat[4] == $uid && $stat[5] == $gid;
          if (S_ISDIR($stat[2])) {
            die "prepared directory mode mismatch: $_\n" unless ($stat[2] & 07777) == 0700;
          } elsif (S_ISREG($stat[2])) {
            my $mode = $stat[2] & 07777;
            die "prepared file mode mismatch: $_\n" unless $mode == 0400 || $mode == 0500;
          } else {
            die "prepared tree contains nonregular entry: $_\n";
          }
        }
      }, $root);
    ' || release_die "Prepared tree failed exact uid/gid/mode normalization."
  freeze_manifest_sha="$(release_sha256 "$prepared_root/freeze-manifest.json")"
  [[ "$freeze_manifest_sha" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Prepared freeze-manifest SHA-256 is malformed."
  frozen_root="/Library/Application Support/Ushot/UpdateTransition/ushot-0.1.4-${freeze_manifest_sha:0:16}"

  [[ ! -e "$PREPARED_BUNDLE_DIRECTORY" && ! -L "$PREPARED_BUNDLE_DIRECTORY" ]] \
    || release_die "Prepared bundle destination appeared during Phase A."
  /bin/mv "$prepared_root" "$PREPARED_BUNDLE_DIRECTORY"
  PREPARED_STAGING=""
  PREPARED_CLEANUP_PATH="$PREPARED_BUNDLE_DIRECTORY"
  [[ "$(release_sha256 "$PREPARED_BUNDLE_DIRECTORY/freeze-manifest.json")" == "$freeze_manifest_sha" ]] \
    || release_die "Prepared freeze manifest changed after final placement."
  print_freeze_and_sign_commands "$PREPARED_BUNDLE_DIRECTORY" "$freeze_manifest_sha" "$frozen_root"
  printf 'prepared_bundle=%s\nfrozen_bundle=%s\nscript_sha256=%s\nfreeze_manifest_sha256=%s\nresult=PENDING_ROOT_FREEZE\n' \
    "$PREPARED_BUNDLE_DIRECTORY" \
    "$frozen_root" \
    "$EXPECTED_SCRIPT_SHA256" \
    "$freeze_manifest_sha"
  PREPARED_CLEANUP_PATH=""
}

if [[ "$PHASE" == "review-pins" ]]; then
  run_review_pins_phase
  exit 0
fi

if [[ "$PHASE" == "prepare" ]]; then
  prepare_key_free_frozen_bundle
  exit 0
fi

# Phase B runs only after validate_frozen_sign_admission has checked every byte
# and directory in the root-owned bundle. From here on no mutable repository
# path participates in signing or verification.
FIXTURE_SCRIPT_PATH="$FROZEN_BUNDLE_DIRECTORY/scripts/prepare-update-transition-fixtures.sh"
RELEASE_COMMON_SOURCE_PATH="$FROZEN_BUNDLE_DIRECTORY/scripts/release-common.sh"
VALIDATE_APPCAST_SOURCE_PATH="$FROZEN_BUNDLE_DIRECTORY/scripts/validate-appcast.sh"
BASE_CONFIG_SOURCE_PATH="$FROZEN_BUNDLE_DIRECTORY/Config/Base.xcconfig"
APPCAST_SEED_SOURCE_PATH="$FROZEN_BUNDLE_DIRECTORY/updates/v1/appcast.xml"
RELEASE_NOTES_SOURCE="$FROZEN_BUNDLE_DIRECTORY/updates/release-notes/$FIXTURE_VERSION.md"
ASSETS_DIRECTORY="$FROZEN_BUNDLE_DIRECTORY/assets"
CURRENT_APPCAST="$FROZEN_BUNDLE_DIRECTORY/inputs/current/appcast.xml"
CURRENT_APPCAST_KIND_PATH="$FROZEN_BUNDLE_DIRECTORY/inputs/current/appcast.kind"
CURRENT_APPCAST_KIND="$(<"$CURRENT_APPCAST_KIND_PATH")"
[[ "$CURRENT_APPCAST_KIND" == "seed" ]] \
  || release_die "Frozen transition input is not the exact first-feed seed."
SPARKLE_BIN="$FROZEN_BUNDLE_DIRECTORY/tools/Sparkle-$USHOT_SPARKLE_VERSION/bin"
EXPECTED_SPARKLE_INSTALL_ROOT="$FROZEN_BUNDLE_DIRECTORY/tools/Sparkle-$USHOT_SPARKLE_VERSION"
SPARKLE_ARCHIVE_MARKER="$EXPECTED_SPARKLE_INSTALL_ROOT/.archive.sha256"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
AUTHENTICATED_APPCAST_VALIDATOR="$FROZEN_BUNDLE_DIRECTORY/helpers/AuthenticatedAppcastValidator"
PUBLIC_KEY_DERIVER="$FROZEN_BUNDLE_DIRECTORY/helpers/SparklePublicKeyDeriver"
EMBEDDED_PUBLIC_KEY_VERIFIER="$FROZEN_BUNDLE_DIRECTORY/helpers/EmbeddedPublicKeyVerifier"

validate_frozen_request() {
  local request="$FROZEN_BUNDLE_DIRECTORY/metadata/request.json"
  /usr/bin/jq -e \
    --arg outputDirectory "$OUTPUT_DIRECTORY" \
    --arg sourceVersion "$TRANSITION_SOURCE_VERSION" \
    --arg sourceBuild "$TRANSITION_SOURCE_BUILD" \
    --arg targetVersion "$FIXTURE_VERSION" \
    --arg targetBuild "$FIXTURE_BUILD" \
    --arg tag "$FIXTURE_TAG" \
    --arg scriptSHA256 "$EXPECTED_SCRIPT_SHA256" \
    --arg reviewedSourceManifestSHA256 "$REVIEWED_SOURCE_MANIFEST_SHA256" \
    --arg pythonInterpreterPath "$PYTHON_INTERPRETER_PATH" \
    --arg pythonInterpreterSHA256 "$PYTHON_INTERPRETER_SHA256" \
    'keys == ["outputDirectory","pythonInterpreter","reviewedSourceManifestSHA256","schemaVersion","scriptSHA256","sourceBuild","sourceVersion","tag","targetBuild","targetVersion"] and .schemaVersion == 2 and .outputDirectory == $outputDirectory and .sourceVersion == $sourceVersion and .sourceBuild == $sourceBuild and .targetVersion == $targetVersion and .targetBuild == $targetBuild and .tag == $tag and .scriptSHA256 == $scriptSHA256 and .reviewedSourceManifestSHA256 == $reviewedSourceManifestSHA256 and .pythonInterpreter == {path: $pythonInterpreterPath, sha256: $pythonInterpreterSHA256}' \
    "$request" >/dev/null \
    || release_die "Frozen request identity does not authorize this exact output and transition."
}
validate_frozen_request

ASSET_SNAPSHOT_ROOT="$WORKSPACE/candidate-assets"
/bin/mkdir -m 700 "$ASSET_SNAPSHOT_ROOT"
ASSET_NAMES=(
  "Ushot-0.1.4-arm64.dmg"
  "Ushot-0.1.4-arm64.zip"
  "Ushot-0.1.4-arm64.dSYM.zip"
  "Ushot-0.1.4-arm64.release-manifest.json"
  "SHA256SUMS.txt"
)
ASSET_MAXIMUM_BYTES=(
  "$SAFE_ARCHIVE_MAX_BYTES" "$SAFE_ARCHIVE_MAX_BYTES" "$SAFE_ARCHIVE_MAX_BYTES" 1048576 1048576
)
ASSET_SNAPSHOT_BINDINGS=()
for ((asset_index = 0; asset_index < ${#ASSET_NAMES[@]}; asset_index++)); do
  asset_name="${ASSET_NAMES[$asset_index]}"
  snapshot_regular_file_no_follow \
    "$ASSETS_DIRECTORY/$asset_name" \
    "$ASSET_SNAPSHOT_ROOT/$asset_name" \
    "${ASSET_MAXIMUM_BYTES[$asset_index]}" \
    "frozen-asset-$asset_index" \
    system >/dev/null
  ASSET_SNAPSHOT_BINDINGS[$asset_index]="$(
    capture_regular_file_binding \
      "$ASSET_SNAPSHOT_ROOT/$asset_name" \
      "${ASSET_MAXIMUM_BYTES[$asset_index]}" \
      "frozen-asset-snapshot-$asset_index"
  )"
done
NORMAL_ARCHIVE_SOURCE="$ASSET_SNAPSHOT_ROOT/$ARCHIVE_NAME"

CANDIDATE_INPUT_ROOT="$WORKSPACE/candidate-input"
/bin/mkdir -m 700 "$CANDIDATE_INPUT_ROOT"
SNAPSHOT_RELEASE_NOTES="$CANDIDATE_INPUT_ROOT/$FIXTURE_VERSION.md"
snapshot_regular_file_no_follow \
  "$RELEASE_NOTES_SOURCE" "$SNAPSHOT_RELEASE_NOTES" 1048576 frozen-release-notes system >/dev/null
RELEASE_NOTES_SOURCE="$SNAPSHOT_RELEASE_NOTES"
SNAPSHOT_RELEASE_NOTES_BINDING="$(capture_regular_file_binding "$RELEASE_NOTES_SOURCE" 1048576 release-notes-snapshot)"

GENERATE_APPCAST_BINDING="$(capture_regular_file_binding "$GENERATE_APPCAST" 134217728 sparkle-generate-appcast system)"
GENERATE_KEYS_BINDING="$(capture_regular_file_binding "$GENERATE_KEYS" 134217728 sparkle-generate-keys system)"
SIGN_UPDATE_BINDING="$(capture_regular_file_binding "$SIGN_UPDATE" 134217728 sparkle-sign-update system)"
SPARKLE_ARCHIVE_MARKER_BINDING="$(capture_regular_file_binding "$SPARKLE_ARCHIVE_MARKER" 256 sparkle-archive-marker system)"
AUTHENTICATED_APPCAST_VALIDATOR_BINDING="$(capture_regular_file_binding "$AUTHENTICATED_APPCAST_VALIDATOR" 134217728 authenticated-appcast-validator system)"
PUBLIC_KEY_DERIVER_BINDING="$(capture_regular_file_binding "$PUBLIC_KEY_DERIVER" 134217728 sparkle-public-key-deriver system)"
EMBEDDED_PUBLIC_KEY_VERIFIER_BINDING="$(capture_regular_file_binding "$EMBEDDED_PUBLIC_KEY_VERIFIER" 134217728 embedded-public-key-verifier system)"
AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$(binding_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_BINDING")"
PUBLIC_KEY_DERIVER_SHA256="$(binding_sha256 "$PUBLIC_KEY_DERIVER_BINDING")"
EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256="$(binding_sha256 "$EMBEDDED_PUBLIC_KEY_VERIFIER_BINDING")"
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR="$AUTHENTICATED_APPCAST_VALIDATOR"
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$AUTHENTICATED_APPCAST_VALIDATOR_SHA256"

verify_candidate_asset_snapshots() {
  local index
  for ((index = 0; index < ${#ASSET_NAMES[@]}; index++)); do
    verify_bound_regular_file \
      "$ASSET_SNAPSHOT_ROOT/${ASSET_NAMES[$index]}" \
      "${ASSET_MAXIMUM_BYTES[$index]}" \
      "frozen-asset-snapshot-$index" \
      "${ASSET_SNAPSHOT_BINDINGS[$index]}"
  done
}

verify_sparkle_toolchain() {
  [[ "$(<"$SPARKLE_ARCHIVE_MARKER")" == "$USHOT_SPARKLE_ARCHIVE_SHA256" ]] \
    || release_die "Frozen Sparkle archive marker does not equal the pinned checksum."
  verify_bound_regular_file "$SPARKLE_ARCHIVE_MARKER" 256 sparkle-archive-marker "$SPARKLE_ARCHIVE_MARKER_BINDING" system
  verify_bound_regular_file "$GENERATE_APPCAST" 134217728 sparkle-generate-appcast "$GENERATE_APPCAST_BINDING" system
  /usr/bin/codesign --verify --strict "$GENERATE_APPCAST" \
    || release_die "Bound Sparkle generate_appcast failed strict code-signature validation."
  verify_bound_regular_file "$GENERATE_KEYS" 134217728 sparkle-generate-keys "$GENERATE_KEYS_BINDING" system
  /usr/bin/codesign --verify --strict "$GENERATE_KEYS" \
    || release_die "Bound Sparkle generate_keys failed strict code-signature validation."
  verify_bound_regular_file "$SIGN_UPDATE" 134217728 sparkle-sign-update "$SIGN_UPDATE_BINDING" system
  /usr/bin/codesign --verify --strict "$SIGN_UPDATE" \
    || release_die "Bound Sparkle sign_update failed strict code-signature validation."
}

verify_reviewed_helpers() {
  verify_bound_regular_file "$AUTHENTICATED_APPCAST_VALIDATOR" 134217728 authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR_BINDING" system
  /usr/bin/codesign --verify --strict "$AUTHENTICATED_APPCAST_VALIDATOR" \
    || release_die "Bound authenticated-appcast validator failed strict code-signature validation."
  verify_bound_regular_file "$PUBLIC_KEY_DERIVER" 134217728 sparkle-public-key-deriver "$PUBLIC_KEY_DERIVER_BINDING" system
  /usr/bin/codesign --verify --strict "$PUBLIC_KEY_DERIVER" \
    || release_die "Bound public-key deriver failed strict code-signature validation."
  verify_bound_regular_file "$EMBEDDED_PUBLIC_KEY_VERIFIER" 134217728 embedded-public-key-verifier "$EMBEDDED_PUBLIC_KEY_VERIFIER_BINDING" system
  /usr/bin/codesign --verify --strict "$EMBEDDED_PUBLIC_KEY_VERIFIER" \
    || release_die "Bound embedded public verifier failed strict code-signature validation."
}

verify_signing_boundary() {
  verify_sign_perl_runtime_boundary
  validate_frozen_sign_admission >/dev/null
  validate_frozen_request
  verify_candidate_asset_snapshots
  verify_bound_regular_file "$RELEASE_NOTES_SOURCE" 1048576 release-notes-snapshot "$SNAPSHOT_RELEASE_NOTES_BINDING"
  verify_reviewed_helpers
  verify_sparkle_toolchain
  [[ ! -e "$WORKSPACE/-" && ! -L "$WORKSPACE/-" ]] \
    || release_die "Signing workspace acquired a forbidden dash-named entry."
}

verify_signing_boundary

PRIVATE_CHILD_ROOT="$WORKSPACE/key-bearing-children"
/bin/mkdir -m 700 "$PRIVATE_CHILD_ROOT"

create_private_child_directory() {
  local child
  child="$(/usr/bin/mktemp -d "$PRIVATE_CHILD_ROOT/key-child.XXXXXXXX")"
  /bin/chmod 700 "$child"
  [[ -d "$child" && ! -L "$child" \
      && "$(/usr/bin/stat -f '%u' "$child")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$child")" == "700" \
      && -z "$(/usr/bin/find "$child" -mindepth 1 -maxdepth 1 -print -quit)" \
      && ! -e "$child/-" && ! -L "$child/-" ]] \
    || release_die "Could not establish a fresh empty mode-0700 key-bearing child directory."
  printf '%s\n' "$child"
}

finish_private_child_directory() {
  local child="$1"
  [[ -d "$child" && ! -L "$child" \
      && "$(/usr/bin/stat -f '%u' "$child")" == "$(/usr/bin/id -u)" \
      && "$(/usr/bin/stat -f '%Lp' "$child")" == "700" \
      && ! -e "$child/-" && ! -L "$child/-" \
      && -z "$(/usr/bin/find "$child" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || release_die "A key-bearing child changed cwd identity or created an unexpected entry."
  /bin/rmdir "$child"
}

derive_and_require_embedded_public_identity() {
  local child
  local derived
  local status=0

  verify_signing_boundary
  child="$(create_private_child_directory)"
  if [[ "$KEY_SOURCE" == "stdin" ]]; then
    derived="$(
      cd "$child"
      printf '%s' "$PRIVATE_KEY" | "$PUBLIC_KEY_DERIVER"
    )" || status=$?
  else
    derived="$(
      cd "$child"
      "$GENERATE_KEYS" --account "$USHOT_SPARKLE_KEY_ACCOUNT" -p
    )" || status=$?
  fi
  finish_private_child_directory "$child"
  ((status == 0)) \
    || release_die "Could not derive the public identity for the fixed signing key."
  [[ "$derived" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
    || release_die "The selected signing key does not match Ushot's embedded public key."
  unset derived
  verify_signing_boundary
}

sign_archive() {
  local archive_path="$1"
  local signature=""
  local child
  local status=0

  verify_signing_boundary
  derive_and_require_embedded_public_identity
  child="$(create_private_child_directory)"
  if [[ "$KEY_SOURCE" == "stdin" ]]; then
    signature="$(
      cd "$child"
      printf '%s' "$PRIVATE_KEY" | \
        "$SIGN_UPDATE" \
          --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
          --ed-key-file - \
          -p \
          "$archive_path"
    )" || status=$?
  else
    signature="$(
      cd "$child"
      "$SIGN_UPDATE" \
        --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
        -p \
        "$archive_path"
    )" || status=$?
  fi
  derive_and_require_embedded_public_identity
  finish_private_child_directory "$child"
  ((status == 0)) \
    || release_die "Sparkle could not sign fixture archive ${archive_path##*/}."
  [[ "$signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
    || release_die "Sparkle returned a malformed archive signature."
  printf '%s\n' "$signature"
}

verify_archive_signature() {
  local archive_path="$1"
  local signature="$2"
  local verifier_status=0

  verify_signing_boundary
  "$EMBEDDED_PUBLIC_KEY_VERIFIER" archive "$archive_path" "$signature" \
    || verifier_status=$?
  verify_signing_boundary
  return "$verifier_status"
}

sign_feed() {
  local feed_path="$1"
  local child
  local status=0

  verify_signing_boundary
  derive_and_require_embedded_public_identity
  child="$(create_private_child_directory)"
  if [[ "$KEY_SOURCE" == "stdin" ]]; then
    (
      cd "$child"
      printf '%s' "$PRIVATE_KEY" | \
        "$SIGN_UPDATE" \
          --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
          --ed-key-file - \
          --disable-signing-warning \
          "$feed_path" \
          >/dev/null
    ) || status=$?
  else
    (
      cd "$child"
      "$SIGN_UPDATE" \
        --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
        --disable-signing-warning \
        "$feed_path" \
        >/dev/null
    ) || status=$?
  fi
  derive_and_require_embedded_public_identity
  finish_private_child_directory "$child"
  ((status == 0)) || release_die "Sparkle could not sign fixture feed."
}

verify_feed_signature() {
  local feed_path="$1"
  local verifier_status=0

  verify_signing_boundary
  "$EMBEDDED_PUBLIC_KEY_VERIFIER" feed "$feed_path" \
    || verifier_status=$?
  verify_signing_boundary
  return "$verifier_status"
}

verify_oversized_feed_signature() {
  local feed_path="$1"
  local verifier_status=0

  verify_signing_boundary
  "$EMBEDDED_PUBLIC_KEY_VERIFIER" feed-cryptographic-only "$feed_path" \
    || verifier_status=$?
  verify_signing_boundary
  return "$verifier_status"
}

extract_enclosure_signature() {
  local feed_path="$1"
  /usr/bin/xmllint --xpath \
    "string((/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])[1]/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" \
    "$feed_path"
}

assert_fixture_feed_identity() {
  local feed_path="$1"
  local item_xpath="(/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])[1]"
  local actual_feed_link
  local actual_enclosure_url

  /usr/bin/xmllint --noout "$feed_path"
  [[ "$(/usr/bin/xmllint --xpath "count(/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])" "$feed_path")" == "1" ]] \
    || release_die "Fixture feed must contain exactly one canonical item."
  [[ "$(/usr/bin/xmllint --xpath "string($item_xpath/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$feed_path")" == "$FIXTURE_VERSION" ]] \
    || release_die "Fixture feed does not advertise exact version $FIXTURE_VERSION."
  [[ "$(/usr/bin/xmllint --xpath "string($item_xpath/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$feed_path")" == "$FIXTURE_BUILD" ]] \
    || release_die "Fixture feed does not advertise exact build $FIXTURE_BUILD."
  actual_feed_link="$(/usr/bin/xmllint --xpath "string(/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='link' and namespace-uri()=''])" "$feed_path")"
  [[ "$actual_feed_link" == "$USHOT_APPCAST_URL" ]] \
    || release_die "Fixture feed channel escaped the exact production URL: $actual_feed_link"
  actual_enclosure_url="$(/usr/bin/xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@url)" "$feed_path")"
  [[ "$actual_enclosure_url" == "$CANONICAL_ENCLOSURE_URL" ]] \
    || release_die "Fixture enclosure escaped the canonical GitHub URL: $actual_enclosure_url"
}

FROZEN_CURRENT_APPCAST="$CURRENT_APPCAST"
CURRENT_APPCAST="$WORKSPACE/current-appcast.xml"
snapshot_regular_file_no_follow \
  "$FROZEN_CURRENT_APPCAST" "$CURRENT_APPCAST" 1049088 frozen-current-appcast system >/dev/null
/usr/bin/cmp "$CURRENT_APPCAST" "$APPCAST_SEED_SOURCE_PATH" \
  || release_die "Frozen current appcast is not byte-identical to the frozen reviewed seed."

cd "$WORKSPACE"
[[ "$(pwd -P)" == "$WORKSPACE" \
    && "$(/usr/bin/stat -f '%Lp' .)" == "700" \
    && ! -e ./- && ! -L ./- ]] \
  || release_die "The key-owning shell could not enter its exact fresh mode-0700 workspace."
if [[ "$KEY_SOURCE" == "stdin" ]]; then
  IFS= read -r EARLY_PRIVATE_KEY || true
  export -n EARLY_PRIVATE_KEY
  exec </dev/null
  PRIVATE_KEY="${EARLY_PRIVATE_KEY:-}"
  unset EARLY_PRIVATE_KEY
  [[ -n "$PRIVATE_KEY" ]] \
    || release_die "No canonical private seed was captured by the frozen worker."
else
  PRIVATE_KEY=""
  exec </dev/null
fi
export -n PRIVATE_KEY
/usr/bin/perl -e '
  exit((exists($ENV{EARLY_PRIVATE_KEY}) || exists($ENV{PRIVATE_KEY})) ? 1 : 0);
' || release_die "A captured signing seed retained an inherited export attribute."
derive_and_require_embedded_public_identity
release_log "Verified the selected signing identity against the embedded Ushot public key."

NORMAL_GENERATION_WORKSPACE="$WORKSPACE/normal-generation"
/bin/mkdir -m 700 "$NORMAL_GENERATION_WORKSPACE"
NORMAL_GENERATION_ARCHIVE="$NORMAL_GENERATION_WORKSPACE/$ARCHIVE_NAME"
NORMAL_GENERATION_NOTES="$NORMAL_GENERATION_WORKSPACE/Ushot-$FIXTURE_VERSION-arm64.md"
NORMAL_GENERATED_FEED="$NORMAL_GENERATION_WORKSPACE/appcast.xml"
/usr/bin/ditto "$NORMAL_ARCHIVE_SOURCE" "$NORMAL_GENERATION_ARCHIVE"
/usr/bin/ditto "$RELEASE_NOTES_SOURCE" "$NORMAL_GENERATION_NOTES"
/usr/bin/ditto "$CURRENT_APPCAST" "$NORMAL_GENERATED_FEED"
# Freeze snapshots seed inputs as mode 0444; ditto preserves that mode. Official
# generate_appcast must overwrite the staged seed path as -o, so restore owner write
# before signing without weakening the frozen source identity.
/bin/chmod u+w "$NORMAL_GENERATED_FEED" \
  || release_die "Could not make the staged seed appcast writable for generate_appcast."
[[ "$(/usr/bin/stat -f '%Lp' "$NORMAL_GENERATED_FEED")" =~ ^[2367][0-7]{2}$ ]] \
  || release_die "Staged seed appcast is not owner-writable after chmod."

generate_normal_signed_feed() {
  local child
  local status=0
  local -a arguments=(
    --account "$USHOT_SPARKLE_KEY_ACCOUNT"
    --download-url-prefix "https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/$FIXTURE_TAG/"
    --embed-release-notes
    --versions "$FIXTURE_BUILD"
    --maximum-versions 5
    --maximum-deltas 0
    -o "$NORMAL_GENERATED_FEED"
  )

  verify_signing_boundary
  derive_and_require_embedded_public_identity
  child="$(create_private_child_directory)"
  if [[ "$KEY_SOURCE" == "stdin" ]]; then
    (
      cd "$child"
      printf '%s' "$PRIVATE_KEY" | \
        "$GENERATE_APPCAST" --ed-key-file - "${arguments[@]}" "$NORMAL_GENERATION_WORKSPACE"
    ) || status=$?
  else
    (
      cd "$child"
      "$GENERATE_APPCAST" "${arguments[@]}" "$NORMAL_GENERATION_WORKSPACE"
    ) || status=$?
  fi
  derive_and_require_embedded_public_identity
  finish_private_child_directory "$child"
  ((status == 0)) \
    || release_die "Frozen official Sparkle generate_appcast could not create the normal fixture."
}

release_log "Generating the normal first-feed fixture directly with frozen official Sparkle tooling."
generate_normal_signed_feed
[[ -f "$NORMAL_GENERATED_FEED" && ! -L "$NORMAL_GENERATED_FEED" && -s "$NORMAL_GENERATED_FEED" ]] \
  || release_die "Frozen official Sparkle tooling did not create the expected appcast."
assert_fixture_feed_identity "$NORMAL_GENERATED_FEED"
verify_feed_signature "$NORMAL_GENERATED_FEED" \
  || release_die "Normal fixture feed failed embedded-public EdDSA verification."
NORMAL_ARCHIVE_SIGNATURE="$(extract_enclosure_signature "$NORMAL_GENERATED_FEED")"
[[ -n "$NORMAL_ARCHIVE_SIGNATURE" ]] \
  || release_die "Normal fixture feed has no archive EdDSA signature."
verify_archive_signature "$NORMAL_ARCHIVE_SOURCE" "$NORMAL_ARCHIVE_SIGNATURE" \
  || release_die "Normal fixture archive failed embedded-public EdDSA verification."
/bin/bash -p "$VALIDATE_APPCAST_SOURCE_PATH" \
  --appcast "$NORMAL_GENERATED_FEED" \
  --archive "$NORMAL_ARCHIVE_SOURCE" \
  --release-notes "$RELEASE_NOTES_SOURCE" \
  --version "$FIXTURE_VERSION" \
  --build-number "$FIXTURE_BUILD" \
  --tag "$FIXTURE_TAG"

FIXTURES_ROOT="$WORKSPACE/fixture-output"
/bin/mkdir -m 700 "$FIXTURES_ROOT"
create_fixture_directory() {
  local case_name="$1"
  local case_directory="$FIXTURES_ROOT/$case_name"

  [[ "$case_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || release_die "Fixture case name is not a safe basename: $case_name"
  [[ ! -e "$case_directory" && ! -L "$case_directory" ]] \
    || release_die "Fixture case directory already exists: $case_name"
  /bin/mkdir -m 700 "$case_directory"
  printf '%s\n' "$case_directory"
}

prevalidate_archive_bytes() {
  local archive_path="$1"

  USHOT_SAFE_APP_BUNDLE="$USHOT_APP_BUNDLE" \
  USHOT_SAFE_EXECUTABLE="$USHOT_EXECUTABLE_NAME" \
  USHOT_SAFE_MAX_ARCHIVE_BYTES="$SAFE_ARCHIVE_MAX_BYTES" \
  USHOT_SAFE_MAX_UNCOMPRESSED_BYTES="$SAFE_ARCHIVE_MAX_UNCOMPRESSED_BYTES" \
  USHOT_SAFE_MAX_ENTRY_BYTES="$SAFE_ARCHIVE_MAX_ENTRY_BYTES" \
  USHOT_SAFE_MAX_ENTRIES="$SAFE_ARCHIVE_MAX_ENTRIES" \
  USHOT_SAFE_MAX_SYMLINK_BYTES="$SAFE_SYMLINK_TARGET_BYTES" \
    /usr/bin/perl - "$archive_path" <<'PERL'
use strict;
use warnings;
use Compress::Raw::Zlib ();
use IO::Uncompress::RawInflate qw($RawInflateError);

sub fail {
    die "archive preflight: $_[0]\n";
}

sub unsigned32 {
    return $_[0] & 0xffffffff;
}

sub validate_extra {
    my ($extra) = @_;
    my %seen;
    while (length($extra) > 0) {
        fail("malformed extra field") if length($extra) < 4;
        my ($identifier, $length) = unpack("vv", substr($extra, 0, 4));
        fail("truncated extra field") if length($extra) < 4 + $length;
        fail("unreviewed extra field") unless $identifier == 0x5855;
        fail("duplicate extra field") if $seen{$identifier}++;
        substr($extra, 0, 4 + $length, "");
    }
}

sub validate_entry_name {
    my ($raw_name, $app_bundle) = @_;
    fail("entry name is empty or oversized")
        if length($raw_name) == 0 || length($raw_name) > 4096;
    fail("entry name is not printable ASCII")
        unless $raw_name =~ /\A[\x20-\x7e]+\z/;
    fail("entry path is absolute or noncanonical")
        if $raw_name =~ m{\A/} || $raw_name =~ /\\/ || $raw_name =~ m{//};
    my $trimmed = $raw_name;
    $trimmed =~ s{/$}{};
    fail("entry path is empty") if length($trimmed) == 0;
    my @components = split(m{/}, $trimmed, -1);
    for my $component (@components) {
        fail("entry path contains an empty, dot or parent component")
            if $component eq "" || $component eq "." || $component eq "..";
    }
    my $app_prefix = "$app_bundle/";
    my $metadata_root = "__MACOSX";
    my $metadata_app = "$metadata_root/$app_bundle";
    fail("entry path escapes the reviewed application roots")
        unless $trimmed eq $app_bundle
            || index($trimmed, $app_prefix) == 0
            || $trimmed eq $metadata_root
            || $trimmed eq $metadata_app
            || index($trimmed, "$metadata_app/") == 0;
    return $trimmed;
}

sub validate_symlink_target {
    my ($target) = @_;
    fail("symlink target is empty or oversized")
        if length($target) == 0
            || length($target) > $ENV{USHOT_SAFE_MAX_SYMLINK_BYTES};
    fail("symlink target is not printable ASCII")
        unless $target =~ /\A[\x20-\x7e]+\z/;
    fail("symlink target is absolute or noncanonical")
        if $target =~ m{\A/}
            || $target =~ /\\/
            || $target =~ m{//}
            || $target =~ m{/$};
    my @components = split(m{/}, $target, -1);
    for my $component (@components) {
        fail("symlink target contains an empty, dot or parent component")
            if $component eq "" || $component eq "." || $component eq "..";
    }
}

sub validated_payload {
    my ($compressed, $method, $expected_size, $expected_crc, $capture) = @_;
    my $actual_size = 0;
    my $actual_crc = 0;
    my $captured = "";
    if ($method == 0) {
        $actual_size = length($compressed);
        fail("stored payload size mismatch")
            unless $actual_size == $expected_size;
        $actual_crc = Compress::Raw::Zlib::crc32($compressed);
        $captured = $compressed if $capture;
    } elsif ($method == 8) {
        my $inflater = IO::Uncompress::RawInflate->new(
            \$compressed,
            Strict => 1,
            Transparent => 0
        ) or fail("invalid deflate stream");
        while (1) {
            my $chunk = "";
            my $count = $inflater->read($chunk, 65536);
            fail("deflate stream read failed")
                unless defined($count) && $count >= 0;
            last if $count == 0;
            $actual_size += length($chunk);
            fail("deflate stream exceeds declared or per-entry size")
                if $actual_size > $expected_size
                    || $actual_size > $ENV{USHOT_SAFE_MAX_ENTRY_BYTES};
            $actual_crc = Compress::Raw::Zlib::crc32($chunk, $actual_crc);
            $captured .= $chunk if $capture;
        }
        fail("deflate stream did not reach a clean end")
            unless $inflater->eof();
        fail("deflate stream has trailing compressed bytes")
            if length($inflater->trailingData()) != 0;
    } else {
        fail("unsupported compression method");
    }
    fail("uncompressed payload size mismatch")
        unless $actual_size == $expected_size;
    fail("payload CRC mismatch")
        unless unsigned32($actual_crc) == unsigned32($expected_crc);
    return $captured;
}

my $archive_path = shift @ARGV // fail("missing archive path");
fail("unexpected parser arguments") if @ARGV;
my $app_bundle =
    $ENV{USHOT_SAFE_APP_BUNDLE} // fail("missing application bundle identity");
my $executable =
    $ENV{USHOT_SAFE_EXECUTABLE} // fail("missing executable identity");
for my $limit_name (
    qw(
        USHOT_SAFE_MAX_ARCHIVE_BYTES
        USHOT_SAFE_MAX_UNCOMPRESSED_BYTES
        USHOT_SAFE_MAX_ENTRY_BYTES
        USHOT_SAFE_MAX_ENTRIES
        USHOT_SAFE_MAX_SYMLINK_BYTES
    )
) {
    fail("invalid parser limit")
        unless defined($ENV{$limit_name})
            && $ENV{$limit_name} =~ /\A[1-9][0-9]*\z/;
}

open(my $archive, "<:raw", $archive_path)
    or fail("cannot open archive");
my $archive_size = -s $archive;
fail("archive is empty or oversized")
    unless defined($archive_size)
        && $archive_size > 0
        && $archive_size <= $ENV{USHOT_SAFE_MAX_ARCHIVE_BYTES};
local $/;
my $data = <$archive>;
close($archive) or fail("cannot close archive");
fail("archive read was incomplete")
    unless defined($data) && length($data) == $archive_size;

my $eocd_offset = rindex($data, "PK\x05\x06");
fail("end-of-central-directory record is absent")
    if $eocd_offset < 0 || $eocd_offset + 22 > $archive_size;
my (
    $disk_number,
    $central_disk,
    $disk_entries,
    $entry_count,
    $central_size,
    $central_offset,
    $comment_length
) = unpack("vvvvVVv", substr($data, $eocd_offset + 4, 18));
fail("multi-disk, ZIP64 or commented archives are forbidden")
    if $disk_number != 0
        || $central_disk != 0
        || $disk_entries != $entry_count
        || $entry_count == 0
        || $entry_count == 0xffff
        || $central_size == 0xffffffff
        || $central_offset == 0xffffffff
        || $comment_length != 0;
fail("archive contains too many entries")
    if $entry_count > $ENV{USHOT_SAFE_MAX_ENTRIES};
fail("end-of-central-directory placement is noncanonical")
    unless $eocd_offset + 22 == $archive_size;
fail("central directory placement is noncanonical")
    unless $central_offset + $central_size == $eocd_offset
        && $central_offset < $eocd_offset;

my $cursor = $central_offset;
my @records;
my %exact_names;
my %folded_names;
my %trimmed_names;
my %types_by_trimmed_name;
my $total_uncompressed = 0;
my $symlink_count = 0;
my $executable_count = 0;
my $root_directory_count = 0;
for (my $index = 0; $index < $entry_count; $index++) {
    fail("truncated central-directory record")
        if $cursor + 46 > $eocd_offset;
    fail("invalid central-directory signature")
        unless substr($data, $cursor, 4) eq "PK\x01\x02";
    my (
        $version_made,
        $version_needed,
        $flags,
        $method,
        $mod_time,
        $mod_date,
        $crc,
        $compressed_size,
        $uncompressed_size,
        $name_length,
        $extra_length,
        $file_comment_length,
        $disk_start,
        $internal_attributes,
        $external_attributes,
        $local_offset
    ) = unpack("v6V3v5V2", substr($data, $cursor + 4, 42));
    my $record_end =
        $cursor + 46 + $name_length + $extra_length + $file_comment_length;
    fail("central-directory record exceeds its declared boundary")
        if $record_end > $eocd_offset;
    fail("central-directory entry is non-Unix, commented, split or ZIP64")
        if (($version_made >> 8) != 3)
            || $file_comment_length != 0
            || $disk_start != 0
            || $compressed_size == 0xffffffff
            || $uncompressed_size == 0xffffffff
            || $local_offset == 0xffffffff;
    fail("unsupported general-purpose flags or compression pairing")
        unless ($flags == 0 && $method == 0)
            || ($flags == 8 && ($method == 0 || $method == 8));
    fail("entry exceeds the per-entry size limit")
        if $uncompressed_size > $ENV{USHOT_SAFE_MAX_ENTRY_BYTES};
    $total_uncompressed += $uncompressed_size;
    fail("archive exceeds the total uncompressed size limit")
        if $total_uncompressed > $ENV{USHOT_SAFE_MAX_UNCOMPRESSED_BYTES};

    my $raw_name = substr($data, $cursor + 46, $name_length);
    my $trimmed_name = validate_entry_name($raw_name, $app_bundle);
    validate_extra(
        substr($data, $cursor + 46 + $name_length, $extra_length)
    );
    fail("duplicate archive entry") if $exact_names{$raw_name}++;
    fail("file and directory forms collide at one archive path")
        if $trimmed_names{$trimmed_name}++;
    my $folded_name = lc($trimmed_name);
    fail("case-folding archive path collision")
        if $folded_names{$folded_name}++;

    my $mode = ($external_attributes >> 16) & 0xffff;
    my $file_type = $mode & 0170000;
    fail("set-id or sticky archive entry is forbidden")
        if ($mode & 07000) != 0;
    my $type;
    if ($file_type == 0040000) {
        $type = "directory";
        fail("directory path or payload is inconsistent")
            unless $raw_name =~ m{/$}
                && $compressed_size == 0
                && $uncompressed_size == 0
                && $crc == 0
                && $method == 0;
    } elsif ($file_type == 0100000) {
        $type = "regular";
        fail("regular file path ends in a slash") if $raw_name =~ m{/$};
    } elsif ($file_type == 0120000) {
        $type = "symlink";
        fail("symlink path ends in a slash or appears in metadata")
            if $raw_name =~ m{/$}
                || index($trimmed_name, "__MACOSX/") == 0;
        fail("symlink target declaration is oversized")
            if $uncompressed_size == 0
                || $uncompressed_size > $ENV{USHOT_SAFE_MAX_SYMLINK_BYTES};
        $symlink_count++;
    } else {
        fail("special or unknown archive entry type is forbidden");
    }
    $types_by_trimmed_name{$trimmed_name} = $type;
    $root_directory_count++
        if $trimmed_name eq $app_bundle && $type eq "directory";
    $executable_count++
        if $trimmed_name eq "$app_bundle/Contents/MacOS/$executable"
            && $type eq "regular";

    fail("local header offset is outside the file-data region")
        if $local_offset + 30 > $central_offset;
    fail("invalid local-file-header signature")
        unless substr($data, $local_offset, 4) eq "PK\x03\x04";
    my (
        $local_version,
        $local_flags,
        $local_method,
        $local_time,
        $local_date,
        $local_crc,
        $local_compressed_size,
        $local_uncompressed_size,
        $local_name_length,
        $local_extra_length
    ) = unpack("v5V3v2", substr($data, $local_offset + 4, 26));
    my $data_offset =
        $local_offset + 30 + $local_name_length + $local_extra_length;
    fail("local-file-header fields disagree with the central directory")
        unless $local_flags == $flags
            && $local_method == $method
            && $local_name_length == $name_length
            && substr($data, $local_offset + 30, $local_name_length)
                eq $raw_name;
    fail("local extra field exceeds file-data boundary")
        if $data_offset > $central_offset;
    validate_extra(
        substr(
            $data,
            $local_offset + 30 + $local_name_length,
            $local_extra_length
        )
    );
    if ($flags == 0) {
        fail("local stored metadata disagrees with the central directory")
            unless $local_crc == $crc
                && $local_compressed_size == $compressed_size
                && $local_uncompressed_size == $uncompressed_size;
    } else {
        fail("descriptor-based local header must contain zero sizes and CRC")
            unless $local_crc == 0
                && $local_compressed_size == 0
                && $local_uncompressed_size == 0;
    }

    my $data_end = $data_offset + $compressed_size;
    fail("compressed payload exceeds the file-data region")
        if $data_end > $central_offset;
    my $record_extent_end = $data_end;
    if ($flags == 8) {
        fail("signed data descriptor is truncated or absent")
            if $data_end + 16 > $central_offset
                || substr($data, $data_end, 4) ne "PK\x07\x08";
        my (
            $descriptor_crc,
            $descriptor_compressed,
            $descriptor_uncompressed
        ) = unpack("VVV", substr($data, $data_end + 4, 12));
        fail("data descriptor disagrees with the central directory")
            unless $descriptor_crc == $crc
                && $descriptor_compressed == $compressed_size
                && $descriptor_uncompressed == $uncompressed_size;
        $record_extent_end += 16;
    }

    my $captured = validated_payload(
        substr($data, $data_offset, $compressed_size),
        $method,
        $uncompressed_size,
        $crc,
        $type eq "symlink"
    );
    validate_symlink_target($captured) if $type eq "symlink";
    push @records, {
        local_offset => $local_offset,
        extent_end => $record_extent_end,
        trimmed_name => $trimmed_name,
        type => $type,
    };
    $cursor = $record_end;
}

fail("central-directory size or entry count is inconsistent")
    unless $cursor == $eocd_offset;
fail("application root or executable entry is ambiguous")
    unless $root_directory_count == 1 && $executable_count == 1;

@records = sort { $a->{local_offset} <=> $b->{local_offset} } @records;
my $expected_offset = 0;
for my $record (@records) {
    fail("local records overlap or contain hidden gaps")
        unless $record->{local_offset} == $expected_offset;
    fail("local record extent is invalid")
        unless $record->{extent_end} > $record->{local_offset};
    $expected_offset = $record->{extent_end};
}
fail("file-data region does not end at the central directory")
    unless $expected_offset == $central_offset;

for my $record (@records) {
    my $name = $record->{trimmed_name};
    my @components = split(m{/}, $name, -1);
    pop @components;
    my $prefix = "";
    for my $component (@components) {
        $prefix = length($prefix) == 0
            ? $component
            : "$prefix/$component";
        if (
            exists($types_by_trimmed_name{$prefix})
                && $types_by_trimmed_name{$prefix} ne "directory"
        ) {
            fail("non-directory archive entry is a parent of another entry");
        }
    }
}

print "entries=$entry_count\n";
print "symlinks=$symlink_count\n";
print "uncompressed_bytes=$total_uncompressed\n";
PERL
}

safe_extract_archive() {
  local archive_path="$1"
  local extraction_root="$2"
  local archive_label="$3"
  local extraction_parent
  local extraction_basename
  local canonical_archive_parent
  local archive_snapshot
  local archive_source_binding
  local archive_binding_before
  local archive_binding_after_preflight
  local archive_binding_after_ditto
  local archive_binding_log
  local preflight_summary
  local sandbox_profile

  [[ "$archive_label" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || { release_warn "Safe archive extraction label is invalid."; return 1; }
  [[ "$archive_path" == /* \
      && -f "$archive_path" \
      && ! -L "$archive_path" \
      && -s "$archive_path" ]] \
    || { release_warn "$archive_label archive is missing, empty, symbolic or non-absolute."; return 1; }
  canonical_archive_parent="$(cd "$(/usr/bin/dirname "$archive_path")" && pwd -P)" \
    || { release_warn "$archive_label archive parent could not be canonicalized."; return 1; }
  [[ "$archive_path" == "$canonical_archive_parent/$(/usr/bin/basename "$archive_path")" ]] \
    || { release_warn "$archive_label archive path is noncanonical."; return 1; }
  [[ "$extraction_root" == /* ]] \
    || { release_warn "$archive_label extraction root must be absolute."; return 1; }
  extraction_parent="$(/usr/bin/dirname "$extraction_root")"
  extraction_basename="$(/usr/bin/basename "$extraction_root")"
  [[ "$extraction_basename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
      && "$extraction_basename" != "." \
      && "$extraction_basename" != ".." \
      && -d "$extraction_parent" \
      && ! -L "$extraction_parent" \
      && "$(cd "$extraction_parent" && pwd -P)" == "$extraction_parent" \
      && ! -e "$extraction_root" \
      && ! -L "$extraction_root" ]] \
    || { release_warn "$archive_label extraction root is not a fresh canonical child directory."; return 1; }
  preflight_summary="$extraction_parent/.$extraction_basename.archive-preflight.txt"
  sandbox_profile="$extraction_parent/.$extraction_basename.archive-extraction.sb"
  archive_snapshot="$extraction_parent/.$extraction_basename.$archive_label.archive-snapshot.zip"
  archive_binding_log="$extraction_parent/.$extraction_basename.$archive_label.archive-bindings.txt"
  [[ ! -e "$archive_snapshot" \
      && ! -L "$archive_snapshot" \
      && ! -e "$archive_binding_log" \
      && ! -L "$archive_binding_log" \
      && ! -e "$preflight_summary" \
      && ! -L "$preflight_summary" \
      && ! -e "$sandbox_profile" \
      && ! -L "$sandbox_profile" ]] \
    || { release_warn "$archive_label extraction preflight paths already exist."; return 1; }

  archive_source_binding="$(
    snapshot_regular_file_no_follow \
      "$archive_path" \
      "$archive_snapshot" \
      "$SAFE_ARCHIVE_MAX_BYTES" \
      "$archive_label-archive"
  )" || { release_warn "$archive_label archive could not enter a private no-follow snapshot."; return 1; }
  archive_binding_before="$(
    capture_regular_file_binding \
      "$archive_snapshot" \
      "$SAFE_ARCHIVE_MAX_BYTES" \
      "$archive_label-archive-snapshot"
  )" || { release_warn "$archive_label private archive snapshot could not be bound."; return 1; }
  printf 'source\t%s\nbefore-preflight\t%s\n' \
    "$archive_source_binding" \
    "$archive_binding_before" \
    > "$archive_binding_log"
  /bin/chmod 600 "$archive_binding_log"

  if ! prevalidate_archive_bytes "$archive_snapshot" > "$preflight_summary"; then
    archive_binding_after_preflight="$(
      capture_regular_file_binding \
        "$archive_snapshot" \
        "$SAFE_ARCHIVE_MAX_BYTES" \
        "$archive_label-archive-snapshot"
    )" || { release_warn "$archive_label private archive snapshot disappeared during preflight."; return 1; }
    printf 'after-preflight\t%s\n' "$archive_binding_after_preflight" \
      >> "$archive_binding_log"
    [[ "$archive_binding_after_preflight" == "$archive_binding_before" ]] \
      || { release_warn "$archive_label private archive snapshot changed during rejected preflight."; return 1; }
    release_warn "$archive_label archive failed raw central-directory, type, payload or symlink prevalidation."
    return 1
  fi
  /bin/chmod 600 "$preflight_summary"
  archive_binding_after_preflight="$(
    capture_regular_file_binding \
      "$archive_snapshot" \
      "$SAFE_ARCHIVE_MAX_BYTES" \
      "$archive_label-archive-snapshot"
  )" || { release_warn "$archive_label private archive snapshot disappeared after preflight."; return 1; }
  printf 'after-preflight\t%s\n' "$archive_binding_after_preflight" \
    >> "$archive_binding_log"
  [[ "$archive_binding_after_preflight" == "$archive_binding_before" ]] \
    || { release_warn "$archive_label private archive snapshot changed during preflight."; return 1; }
  [[ "$(/usr/bin/grep -Ec '^entries=[1-9][0-9]*$' "$preflight_summary")" == "1" \
      && "$(/usr/bin/grep -Ec '^symlinks=[0-9]+$' "$preflight_summary")" == "1" \
      && "$(/usr/bin/grep -Ec '^uncompressed_bytes=[1-9][0-9]*$' "$preflight_summary")" == "1" \
      && "$(/usr/bin/wc -l < "$preflight_summary" | /usr/bin/tr -d '[:space:]')" == "3" ]] \
    || { release_warn "$archive_label archive preflight did not emit the exact bounded summary."; return 1; }

  printf '%s\n' \
    '(version 1)' \
    '(deny default)' \
    '(allow process-exec (literal "/usr/bin/ditto"))' \
    '(allow file-read*)' \
    '(allow file-write* (subpath (param "EXTRACTION_ROOT")))' \
    > "$sandbox_profile"
  /bin/chmod 600 "$sandbox_profile"
  /bin/mkdir -m 700 "$extraction_root"
  [[ -d "$extraction_root" \
      && ! -L "$extraction_root" \
      && "$(cd "$extraction_root" && pwd -P)" == "$extraction_root" \
      && "$(/usr/bin/stat -f '%Lp' "$extraction_root")" == "700" ]] \
    || { release_warn "$archive_label extraction root could not be established safely."; return 1; }
  if ! (
    umask 022
    /usr/bin/sandbox-exec \
      -D "EXTRACTION_ROOT=$extraction_root" \
      -f "$sandbox_profile" \
      /usr/bin/ditto \
        -x \
        -k \
        --noextattr \
        --noqtn \
        --noacl \
        --norsrc \
        --nopersistRootless \
        "$archive_snapshot" \
        "$extraction_root"
  ); then
    archive_binding_after_ditto="$(
      capture_regular_file_binding \
        "$archive_snapshot" \
        "$SAFE_ARCHIVE_MAX_BYTES" \
        "$archive_label-archive-snapshot"
    )" || { release_warn "$archive_label private archive snapshot disappeared after failed extraction."; return 1; }
    printf 'after-failed-ditto\t%s\n' "$archive_binding_after_ditto" \
      >> "$archive_binding_log"
    /bin/chmod 400 "$archive_binding_log"
    [[ "$archive_binding_after_ditto" == "$archive_binding_before" ]] \
      || { release_warn "$archive_label private archive snapshot changed during failed extraction."; return 1; }
    release_warn "$archive_label archive failed write-confined ditto extraction."
    return 1
  fi
  archive_binding_after_ditto="$(
    capture_regular_file_binding \
      "$archive_snapshot" \
      "$SAFE_ARCHIVE_MAX_BYTES" \
      "$archive_label-archive-snapshot"
  )" || { release_warn "$archive_label private archive snapshot disappeared after extraction."; return 1; }
  printf 'after-ditto\t%s\n' "$archive_binding_after_ditto" \
    >> "$archive_binding_log"
  /bin/chmod 400 "$archive_binding_log"
  [[ "$archive_binding_after_ditto" == "$archive_binding_before" ]] \
    || { release_warn "$archive_label private archive snapshot changed during extraction."; return 1; }
  release_log "Safely extracted $archive_label after raw ZIP prevalidation and write confinement."
}

verify_safe_extraction_rejects_symlink_escape() {
  local negative_root="$WORKSPACE/safe-extraction-negative"
  local malicious_archive="$negative_root/malicious-symlink-escape.zip"
  local extraction_root="$negative_root/extracted"
  local outside_directory="$negative_root/outside"
  local outside_marker="$outside_directory/marker"
  local rejection_log="$negative_root/rejection.log"

  [[ ! -e "$negative_root" && ! -L "$negative_root" ]] \
    || release_die "Safe-extraction negative-test root already exists."
  /bin/mkdir -m 700 "$negative_root" "$outside_directory"
  /usr/bin/perl -MIO::Compress::Zip=:all -e '
    my $archive_path = shift @ARGV;
    die "unexpected arguments\n" if !defined($archive_path) || @ARGV;
    my $zip = IO::Compress::Zip->new(
      $archive_path,
      Name => "Ushot.app/",
      Method => ZIP_CM_STORE,
      ExtAttr => (0040755 << 16)
    ) or die "could not create malicious ZIP\n";
    $zip->print("");
    my @members = (
      ["Ushot.app/Contents/", "", 0040755],
      ["Ushot.app/Contents/MacOS/", "", 0040755],
      ["Ushot.app/Contents/MacOS/Ushot", "fixture", 0100755],
      ["Ushot.app/escape", "../../outside", 0120777],
      ["Ushot.app/escape/marker", "outside-write", 0100644],
    );
    for my $member (@members) {
      $zip->newStream(
        Name => $member->[0],
        Method => ZIP_CM_STORE,
        ExtAttr => ($member->[2] << 16)
      ) or die "could not add malicious ZIP member\n";
      $zip->print($member->[1]);
    }
    $zip->close() or die "could not close malicious ZIP\n";
  ' "$malicious_archive" \
    || release_die "Could not construct the safe-extraction symlink-escape negative fixture."
  /bin/chmod 600 "$malicious_archive"
  [[ -f "$malicious_archive" \
      && ! -L "$malicious_archive" \
      && -s "$malicious_archive" \
      && ! -e "$outside_marker" \
      && ! -L "$outside_marker" ]] \
    || release_die "Symlink-escape negative fixture precondition failed."

  if safe_extract_archive \
    "$malicious_archive" \
    "$extraction_root" \
    malicious-symlink-escape \
    >"$rejection_log" \
    2>&1; then
    release_die "Safe extraction unexpectedly accepted the symlink-escape archive."
  fi
  /bin/chmod 600 "$rejection_log"
  /usr/bin/grep -Fx \
    'archive preflight: symlink target contains an empty, dot or parent component' \
    "$rejection_log" \
    >/dev/null \
    || release_die "Symlink-escape archive did not reach the exact raw-target rejection."
  [[ ! -e "$outside_marker" \
      && ! -L "$outside_marker" \
      && ! -e "$extraction_root" \
      && ! -L "$extraction_root" ]] \
    || release_die "Symlink-escape negative archive wrote outside or reached extraction."
  release_log "Safe-extraction negative passed: parent symlink target rejected before ditto and no outside marker was written."
}

verify_safe_extraction_rejects_symlink_escape

validate_final_archive_bundle() {
  local archive_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local archive_label="$4"
  local validation_root="$WORKSPACE/final-archive-validation-$archive_label"
  local extraction_root="$validation_root/extracted"
  local extracted_app="$extraction_root/$USHOT_APP_BUNDLE"
  local symlinks_path="$validation_root/bundle-symlinks.paths.nul"
  local symlink_path
  local symlink_target

  [[ "$archive_label" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || release_die "Final archive validation label is not a safe basename: $archive_label"
  [[ -f "$archive_path" && ! -L "$archive_path" && -s "$archive_path" ]] \
    || release_die "$archive_label final archive is missing, empty or symbolic."
  [[ ! -e "$validation_root" && ! -L "$validation_root" ]] \
    || release_die "$archive_label final archive validation root already exists."
  /bin/mkdir -m 700 "$validation_root"
  safe_extract_archive "$archive_path" "$extraction_root" "$archive_label" \
    || release_die "Could not safely extract $archive_label final archive bytes."
  [[ -d "$extracted_app" && ! -L "$extracted_app" ]] \
    || release_die "$archive_label final archive did not extract one real $USHOT_APP_BUNDLE."
  /usr/bin/find "$extracted_app" -type l -print0 > "$symlinks_path" \
    || release_die "Could not enumerate $archive_label extracted bundle symlinks."
  while IFS= read -r -d '' symlink_path; do
    symlink_target="$(/usr/bin/readlink "$symlink_path")"
    [[ -n "$symlink_target" \
        && "$symlink_target" != /* \
        && "$symlink_target" != *\\* \
        && "$symlink_target" != *$'\n'* \
        && "$symlink_target" != *$'\r'* \
        && "$symlink_target" != *$'\t'* ]] \
      || release_die "$archive_label extracted bundle contains an empty, absolute or noncanonical symlink."
    case "/$symlink_target/" in
      */../*|*/./*|*//*) release_die "$archive_label extracted bundle contains a symlink that may escape its canonical relative path." ;;
    esac
  done < "$symlinks_path"
  release_validate_app_identity "$extracted_app" "$expected_version" "$expected_build"
  release_verify_signature_mode "$extracted_app" public-adhoc
}

NORMAL_CASE="$(create_fixture_directory normal)"
/usr/bin/ditto "$NORMAL_GENERATED_FEED" "$NORMAL_CASE/appcast.xml"
/usr/bin/ditto "$NORMAL_ARCHIVE_SOURCE" "$NORMAL_CASE/$ARCHIVE_NAME"
/usr/bin/cmp "$NORMAL_GENERATED_FEED" "$NORMAL_CASE/appcast.xml" \
  || release_die "Normal final feed copy differs from the generated signed feed."
/usr/bin/cmp "$NORMAL_ARCHIVE_SOURCE" "$NORMAL_CASE/$ARCHIVE_NAME" \
  || release_die "Normal final archive copy differs from the validated candidate archive."
assert_fixture_feed_identity "$NORMAL_CASE/appcast.xml"
verify_feed_signature "$NORMAL_CASE/appcast.xml" \
  || release_die "Normal final feed copy failed official Sparkle EdDSA verification."
NORMAL_FINAL_ARCHIVE_SIGNATURE="$(extract_enclosure_signature "$NORMAL_CASE/appcast.xml")"
[[ "$NORMAL_FINAL_ARCHIVE_SIGNATURE" == "$NORMAL_ARCHIVE_SIGNATURE" ]] \
  || release_die "Normal final feed copy changed the archive signature binding."
verify_archive_signature "$NORMAL_CASE/$ARCHIVE_NAME" "$NORMAL_FINAL_ARCHIVE_SIGNATURE" \
  || release_die "Normal final archive copy failed official Sparkle EdDSA verification."
/bin/bash -p "$VALIDATE_APPCAST_SOURCE_PATH" \
  --appcast "$NORMAL_CASE/appcast.xml" \
  --archive "$NORMAL_CASE/$ARCHIVE_NAME" \
  --release-notes "$RELEASE_NOTES_SOURCE" \
  --version "$FIXTURE_VERSION" \
  --build-number "$FIXTURE_BUILD" \
  --tag "$FIXTURE_TAG"
validate_final_archive_bundle \
  "$NORMAL_CASE/$ARCHIVE_NAME" \
  "$FIXTURE_VERSION" \
  "$FIXTURE_BUILD" \
  normal

TAMPERED_CASE="$(create_fixture_directory tampered-archive)"
/usr/bin/ditto "$NORMAL_GENERATED_FEED" "$TAMPERED_CASE/appcast.xml"
/usr/bin/ditto "$NORMAL_ARCHIVE_SOURCE" "$TAMPERED_CASE/$ARCHIVE_NAME"
/usr/bin/cmp "$NORMAL_GENERATED_FEED" "$TAMPERED_CASE/appcast.xml" \
  || release_die "Tampered-archive case changed the normal signed feed bytes."
TAMPERED_ORIGINAL_SIZE="$(release_file_size "$TAMPERED_CASE/$ARCHIVE_NAME")"
/usr/bin/perl -0777pi -e '
  my $central_directory_offset = index($_, "PK\x01\x02");
  die "central directory signature is absent\n" if $central_directory_offset < 0;
  my $metadata_byte_offset = $central_directory_offset + 12;
  die "central directory metadata byte is truncated\n" if $metadata_byte_offset >= length($_);
  my $original_byte = ord(substr($_, $metadata_byte_offset, 1));
  substr($_, $metadata_byte_offset, 1) = chr($original_byte ^ 0x01);
' "$TAMPERED_CASE/$ARCHIVE_NAME" \
  || release_die "Could not apply the fixed-length ZIP metadata mutation."
[[ "$(release_file_size "$TAMPERED_CASE/$ARCHIVE_NAME")" == "$TAMPERED_ORIGINAL_SIZE" \
    && "$TAMPERED_ORIGINAL_SIZE" == "$(release_file_size "$NORMAL_CASE/$ARCHIVE_NAME")" ]] \
  || release_die "Tampered archive mutation changed the ZIP byte length."
[[ "$(release_sha256 "$TAMPERED_CASE/$ARCHIVE_NAME")" != "$(release_sha256 "$NORMAL_CASE/$ARCHIVE_NAME")" ]] \
  || release_die "Tampered archive fixture did not change the normal archive bytes."
validate_final_archive_bundle \
  "$TAMPERED_CASE/$ARCHIVE_NAME" \
  "$FIXTURE_VERSION" \
  "$FIXTURE_BUILD" \
  tampered-archive
if verify_archive_signature \
  "$TAMPERED_CASE/$ARCHIVE_NAME" \
  "$NORMAL_ARCHIVE_SIGNATURE" \
  >/dev/null 2>&1; then
  release_die "Official Sparkle verification unexpectedly accepted the tampered archive fixture."
fi
verify_feed_signature "$TAMPERED_CASE/appcast.xml" \
  || release_die "Tampered-archive case changed the independently signed feed."

replace_enclosure_binding() {
  local feed_path="$1"
  local new_archive_signature="$2"
  local new_archive_length="$3"
  local old_archive_length

  old_archive_length="$(/usr/bin/xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@length)" "$feed_path")"
  [[ "$old_archive_length" =~ ^[1-9][0-9]*$ \
      && "$new_archive_length" =~ ^[1-9][0-9]*$ ]] \
    || release_die "Fixture feed contains a malformed enclosure length."
  USHOT_FIXTURE_OLD_SIGNATURE="$NORMAL_ARCHIVE_SIGNATURE" \
  USHOT_FIXTURE_NEW_SIGNATURE="$new_archive_signature" \
  USHOT_FIXTURE_OLD_LENGTH="$old_archive_length" \
  USHOT_FIXTURE_NEW_LENGTH="$new_archive_length" \
    /usr/bin/perl -0777pi -e '
      my $old_signature = $ENV{"USHOT_FIXTURE_OLD_SIGNATURE"};
      my $new_signature = $ENV{"USHOT_FIXTURE_NEW_SIGNATURE"};
      my $old_length = $ENV{"USHOT_FIXTURE_OLD_LENGTH"};
      my $new_length = $ENV{"USHOT_FIXTURE_NEW_LENGTH"};
      my $signature_count = s/\Qsparkle:edSignature="$old_signature"\E/sparkle:edSignature="$new_signature"/g;
      my $length_count = s/\Qlength="$old_length"\E/length="$new_length"/g;
      die "expected exactly one enclosure signature replacement\n" unless $signature_count == 1;
      die "expected exactly one enclosure length replacement\n" unless $length_count == 1;
    ' "$feed_path" \
    || release_die "Could not bind the mismatch feed to its independently signed archive."
  [[ "$(extract_enclosure_signature "$feed_path")" == "$new_archive_signature" ]] \
    || release_die "Mismatch feed did not retain the replacement archive signature."
  [[ "$(/usr/bin/xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@length)" "$feed_path")" == "$new_archive_length" ]] \
    || release_die "Mismatch feed did not retain the replacement archive length."
}

prepare_mismatch_case() {
  local case_name="$1"
  local archive_version="$2"
  local archive_build="$3"
  local case_directory
  local mutation_root="$WORKSPACE/mutation-$case_name"
  local extracted_app
  local fixture_archive
  local fixture_feed
  local fixture_signature
  local archive_entries
  local unexpected_entries

  case_directory="$(create_fixture_directory "$case_name")"
  safe_extract_archive \
    "$NORMAL_ARCHIVE_SOURCE" \
    "$mutation_root" \
    "mismatch-source-$case_name" \
    || release_die "Could not safely extract the normal candidate for $case_name."
  extracted_app="$mutation_root/$USHOT_APP_BUNDLE"
  [[ -d "$extracted_app" && ! -L "$extracted_app" ]] \
    || release_die "Could not extract the normal candidate for $case_name."
  release_validate_app_identity "$extracted_app" "$FIXTURE_VERSION" "$FIXTURE_BUILD"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $archive_version" \
    "$extracted_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $archive_build" \
    "$extracted_app/Contents/Info.plist"
  /usr/bin/codesign --force --sign - "$extracted_app" >/dev/null 2>&1 \
    || release_die "Could not ad-hoc sign the mismatch fixture application."
  release_validate_app_identity "$extracted_app" "$archive_version" "$archive_build"
  release_verify_signature_mode "$extracted_app" public-adhoc

  fixture_archive="$case_directory/$ARCHIVE_NAME"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$extracted_app" "$fixture_archive"
  archive_entries="$(/usr/bin/zipinfo -1 "$fixture_archive")"
  unexpected_entries="$(
    printf '%s\n' "$archive_entries" \
      | /usr/bin/grep -Ev "^($USHOT_APP_BUNDLE/|__MACOSX/$|__MACOSX/$USHOT_APP_BUNDLE/)" \
      || true
  )"
  [[ -z "$unexpected_entries" ]] \
    || release_die "$case_name archive contains paths outside $USHOT_APP_BUNDLE."
  printf '%s\n' "$archive_entries" \
    | /usr/bin/grep "^$USHOT_APP_BUNDLE/Contents/MacOS/$USHOT_EXECUTABLE_NAME$" \
    >/dev/null \
    || release_die "$case_name archive is missing the Ushot executable."

  fixture_signature="$(sign_archive "$fixture_archive")"
  verify_archive_signature "$fixture_archive" "$fixture_signature" \
    || release_die "$case_name archive did not retain a valid EdDSA signature."
  fixture_feed="$case_directory/appcast.xml"
  /usr/bin/ditto "$NORMAL_GENERATED_FEED" "$fixture_feed"
  replace_enclosure_binding \
    "$fixture_feed" \
    "$fixture_signature" \
    "$(release_file_size "$fixture_archive")"
  sign_feed "$fixture_feed" \
    || release_die "Official Sparkle could not re-sign $case_name feed."
  verify_feed_signature "$fixture_feed" \
    || release_die "$case_name feed failed official Sparkle EdDSA verification."
  assert_fixture_feed_identity "$fixture_feed"
  /bin/bash -p "$VALIDATE_APPCAST_SOURCE_PATH" \
    --appcast "$fixture_feed" \
    --archive "$fixture_archive" \
    --release-notes "$RELEASE_NOTES_SOURCE" \
    --version "$FIXTURE_VERSION" \
    --build-number "$FIXTURE_BUILD" \
    --tag "$FIXTURE_TAG"
  validate_final_archive_bundle \
    "$fixture_archive" \
    "$archive_version" \
    "$archive_build" \
    "$case_name"
  release_log "Prepared $case_name: feed=$FIXTURE_VERSION/$FIXTURE_BUILD archive=$archive_version/$archive_build with valid independent EdDSA signatures."
}

prepare_mismatch_case \
  short-version-mismatch \
  "$SHORT_MISMATCH_VERSION" \
  "$FIXTURE_BUILD"
prepare_mismatch_case \
  build-number-mismatch \
  "$FIXTURE_VERSION" \
  "$BUILD_MISMATCH_BUILD"
prepare_mismatch_case \
  short-and-build-mismatch \
  "$SHORT_MISMATCH_VERSION" \
  "$BUILD_MISMATCH_BUILD"

RAW_XML_CASE="$(create_fixture_directory duplicate-build-metadata)"
/usr/bin/ditto "$NORMAL_ARCHIVE_SOURCE" "$RAW_XML_CASE/$ARCHIVE_NAME"
/usr/bin/ditto "$NORMAL_GENERATED_FEED" "$RAW_XML_CASE/appcast.xml"
RAW_CHANNEL_XPATH="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"
RAW_ITEM_XPATH="($RAW_CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])[1]"
[[ "$(/usr/bin/xmllint --xpath "count($RAW_ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$RAW_XML_CASE/appcast.xml")" == "1" \
    && "$(/usr/bin/xmllint --xpath "count(//*[local-name()='version'])" "$RAW_XML_CASE/appcast.xml")" == "1" ]] \
  || release_die "Normal feed does not have exactly one direct canonical build-version element before raw-XML mutation."
USHOT_FIXTURE_BUILD="$FIXTURE_BUILD" \
  /usr/bin/perl -0777pi -e '
    my $element = "<sparkle:version>$ENV{\"USHOT_FIXTURE_BUILD\"}</sparkle:version>";
    my $replacement = "$element\n            $element";
    my $count = s/\Q$element\E/$replacement/g;
    die "expected exactly one build-version injection point\n" unless $count == 1;
  ' "$RAW_XML_CASE/appcast.xml" \
  || release_die "Could not create the duplicate authenticated-metadata fixture."
/usr/bin/xmllint --noout "$RAW_XML_CASE/appcast.xml"
sign_feed "$RAW_XML_CASE/appcast.xml" \
  || release_die "Official Sparkle could not sign the duplicate authenticated-metadata fixture."
/usr/bin/xmllint --noout "$RAW_XML_CASE/appcast.xml"
[[ "$(/usr/bin/xmllint --xpath "count($RAW_ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$RAW_XML_CASE/appcast.xml")" == "2" \
    && "$(/usr/bin/xmllint --xpath "count(//*[local-name()='version'])" "$RAW_XML_CASE/appcast.xml")" == "2" ]] \
  || release_die "Signed duplicate authenticated-metadata fixture must contain exactly two direct canonical build-version elements and no other version nodes."
verify_feed_signature "$RAW_XML_CASE/appcast.xml" \
  || release_die "Duplicate authenticated-metadata fixture failed official signed-feed verification."
verify_archive_signature "$RAW_XML_CASE/$ARCHIVE_NAME" "$NORMAL_ARCHIVE_SIGNATURE" \
  || release_die "Duplicate authenticated-metadata case changed the normal archive signature boundary."
/usr/bin/cmp "$NORMAL_ARCHIVE_SOURCE" "$RAW_XML_CASE/$ARCHIVE_NAME" \
  || release_die "Duplicate authenticated-metadata case changed the normal archive bytes."
RAW_VALIDATOR_STDOUT="$WORKSPACE/raw-xml-policy-validator.stdout"
RAW_VALIDATOR_STDERR="$WORKSPACE/raw-xml-policy-validator.stderr"
RAW_VALIDATOR_EXPECTED_STDERR="$WORKSPACE/raw-xml-policy-validator.expected.stderr"
printf 'error: authenticated appcast violates Ushot runtime policy: %s\n' \
  "$RAW_XML_REJECTION_CATEGORY" > "$RAW_VALIDATOR_EXPECTED_STDERR"
set +e
"$AUTHENTICATED_APPCAST_VALIDATOR" \
  "$RAW_XML_CASE/appcast.xml" \
  >"$RAW_VALIDATOR_STDOUT" \
  2>"$RAW_VALIDATOR_STDERR"
RAW_VALIDATOR_STATUS=$?
set -e
[[ "$RAW_VALIDATOR_STATUS" == "$VALIDATOR_POLICY_EXIT_STATUS" \
    && ! -s "$RAW_VALIDATOR_STDOUT" ]] \
  || release_die "App-identical authenticated XML validator did not return the exact policy-rejection status for duplicate build metadata."
/usr/bin/cmp "$RAW_VALIDATOR_STDERR" "$RAW_VALIDATOR_EXPECTED_STDERR" \
  || release_die "App-identical authenticated XML validator returned an unexpected duplicate-metadata diagnostic."
validate_final_archive_bundle \
  "$RAW_XML_CASE/$ARCHIVE_NAME" \
  "$FIXTURE_VERSION" \
  "$FIXTURE_BUILD" \
  duplicate-build-metadata
release_log "Prepared duplicate-build-metadata with valid feed/archive EdDSA and proven authenticated-XML policy rejection."

OVERSIZED_CASE="$(create_fixture_directory oversized-signed-feed)"
/usr/bin/ditto "$NORMAL_ARCHIVE_SOURCE" "$OVERSIZED_CASE/$ARCHIVE_NAME"
/usr/bin/ditto "$NORMAL_GENERATED_FEED" "$OVERSIZED_CASE/appcast.xml"
/usr/bin/cmp "$NORMAL_ARCHIVE_SOURCE" "$OVERSIZED_CASE/$ARCHIVE_NAME" \
  || release_die "Oversized signed-feed case changed the normal archive bytes."
USHOT_FIXTURE_PADDING_BYTES="$OVERSIZED_FEED_PADDING_BYTES" \
  /usr/bin/perl -0777pi -e '
    my $padding_bytes = $ENV{"USHOT_FIXTURE_PADDING_BYTES"};
    die "invalid padding byte count\n" unless $padding_bytes =~ /\A[1-9][0-9]*\z/;
    my $replacement = "\n    " . (" " x $padding_bytes) . "\n  </channel>";
    my $count = s{</channel>}{$replacement}g;
    die "expected exactly one channel closing tag\n" unless $count == 1;
  ' "$OVERSIZED_CASE/appcast.xml" \
  || release_die "Could not add deterministic whitespace to the oversized signed-feed fixture."
/usr/bin/xmllint --noout "$OVERSIZED_CASE/appcast.xml"
sign_feed "$OVERSIZED_CASE/appcast.xml" \
  || release_die "Official Sparkle could not sign the oversized-feed fixture."
/usr/bin/xmllint --noout "$OVERSIZED_CASE/appcast.xml"
verify_oversized_feed_signature "$OVERSIZED_CASE/appcast.xml" \
  || release_die "Oversized-feed fixture failed the bounded cryptographic-only signed-feed verification."
assert_fixture_feed_identity "$OVERSIZED_CASE/appcast.xml"
verify_archive_signature "$OVERSIZED_CASE/$ARCHIVE_NAME" "$NORMAL_ARCHIVE_SIGNATURE" \
  || release_die "Oversized signed-feed case changed the normal archive signature boundary."
OVERSIZED_AUTHENTICATED_PREFIX_BYTES="$(
  /usr/bin/perl -0777 -e '
    my $data = <>;
    my $marker = "<!-- sparkle-signatures:\n";
    my $offset = rindex($data, $marker);
    die "signed-feed signature marker is absent\n" if $offset < 0;
    print $offset;
  ' "$OVERSIZED_CASE/appcast.xml"
)" || release_die "Could not measure the oversized authenticated XML prefix."
OVERSIZED_SIGNED_FEED_BYTES="$(release_file_size "$OVERSIZED_CASE/appcast.xml")"
[[ "$OVERSIZED_AUTHENTICATED_PREFIX_BYTES" =~ ^[1-9][0-9]*$ \
    && "$OVERSIZED_SIGNED_FEED_BYTES" =~ ^[1-9][0-9]*$ ]] \
  || release_die "Oversized signed-feed measurements are not canonical decimal integers."
OVERSIZED_SIGNATURE_TRAILER_BYTES=$((
  10#$OVERSIZED_SIGNED_FEED_BYTES - 10#$OVERSIZED_AUTHENTICATED_PREFIX_BYTES
))
(( 10#$OVERSIZED_AUTHENTICATED_PREFIX_BYTES > 10#$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES \
    && 10#$OVERSIZED_SIGNED_FEED_BYTES > 10#$SIGNED_FEED_WIRE_CEILING_BYTES \
    && 10#$OVERSIZED_SIGNED_FEED_BYTES <= 10#$LOOPBACK_MAX_FEED_FIXTURE_BYTES \
    && OVERSIZED_SIGNATURE_TRAILER_BYTES > 0 \
    && OVERSIZED_SIGNATURE_TRAILER_BYTES <= 512 )) \
  || release_die "Oversized fixture must exceed both the 1 MiB authenticated-prefix limit and complete 1,049,088-byte wire ceiling while remaining inside the 2 MiB loopback-server boundary with a bounded signature trailer."
OVERSIZED_VALIDATOR_STDOUT="$WORKSPACE/oversized-feed-validator.stdout"
OVERSIZED_VALIDATOR_STDERR="$WORKSPACE/oversized-feed-validator.stderr"
OVERSIZED_VALIDATOR_EXPECTED_STDERR="$WORKSPACE/oversized-feed-validator.expected.stderr"
printf 'error: verified signed appcast envelope violates Ushot policy: %s\n' \
  "$OVERSIZED_FEED_REJECTION_CATEGORY" > "$OVERSIZED_VALIDATOR_EXPECTED_STDERR"
set +e
"$AUTHENTICATED_APPCAST_VALIDATOR" \
  "$OVERSIZED_CASE/appcast.xml" \
  >"$OVERSIZED_VALIDATOR_STDOUT" \
  2>"$OVERSIZED_VALIDATOR_STDERR"
OVERSIZED_VALIDATOR_STATUS=$?
set -e
[[ "$OVERSIZED_VALIDATOR_STATUS" == "$VALIDATOR_POLICY_EXIT_STATUS" \
    && ! -s "$OVERSIZED_VALIDATOR_STDOUT" ]] \
  || release_die "App-identical authenticated XML validator did not return the exact policy-rejection status for the oversized signed feed."
/usr/bin/cmp "$OVERSIZED_VALIDATOR_STDERR" "$OVERSIZED_VALIDATOR_EXPECTED_STDERR" \
  || release_die "App-identical authenticated XML validator returned an unexpected oversized-feed diagnostic."
validate_final_archive_bundle \
  "$OVERSIZED_CASE/$ARCHIVE_NAME" \
  "$FIXTURE_VERSION" \
  "$FIXTURE_BUILD" \
  oversized-signed-feed
release_log "Prepared oversized-signed-feed with valid feed/archive EdDSA, authenticated prefix above 1 MiB, and exact policy rejection evidence."

for case_directory in \
  "$NORMAL_CASE" \
  "$TAMPERED_CASE" \
  "$FIXTURES_ROOT/short-version-mismatch" \
  "$FIXTURES_ROOT/build-number-mismatch" \
  "$FIXTURES_ROOT/short-and-build-mismatch" \
  "$RAW_XML_CASE" \
  "$OVERSIZED_CASE"; do
  [[ -d "$case_directory" && ! -L "$case_directory" \
      && -f "$case_directory/appcast.xml" \
      && ! -L "$case_directory/appcast.xml" \
      && -f "$case_directory/$ARCHIVE_NAME" \
      && ! -L "$case_directory/$ARCHIVE_NAME" ]] \
    || release_die "Fixture case is incomplete or symbolic: $case_directory"
done
[[ "$(/usr/bin/find "$FIXTURES_ROOT" -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
  || release_die "Fixture output must not contain symbolic links."

NORMAL_FEED_SHA256="$(release_sha256 "$NORMAL_CASE/appcast.xml")"
NORMAL_ARCHIVE_SHA256="$(release_sha256 "$NORMAL_CASE/$ARCHIVE_NAME")"
TAMPERED_FEED_SHA256="$(release_sha256 "$TAMPERED_CASE/appcast.xml")"
TAMPERED_ARCHIVE_SHA256="$(release_sha256 "$TAMPERED_CASE/$ARCHIVE_NAME")"
SHORT_FEED_SHA256="$(release_sha256 "$FIXTURES_ROOT/short-version-mismatch/appcast.xml")"
SHORT_ARCHIVE_SHA256="$(release_sha256 "$FIXTURES_ROOT/short-version-mismatch/$ARCHIVE_NAME")"
BUILD_FEED_SHA256="$(release_sha256 "$FIXTURES_ROOT/build-number-mismatch/appcast.xml")"
BUILD_ARCHIVE_SHA256="$(release_sha256 "$FIXTURES_ROOT/build-number-mismatch/$ARCHIVE_NAME")"
BOTH_FEED_SHA256="$(release_sha256 "$FIXTURES_ROOT/short-and-build-mismatch/appcast.xml")"
BOTH_ARCHIVE_SHA256="$(release_sha256 "$FIXTURES_ROOT/short-and-build-mismatch/$ARCHIVE_NAME")"
RAW_FEED_SHA256="$(release_sha256 "$RAW_XML_CASE/appcast.xml")"
RAW_ARCHIVE_SHA256="$(release_sha256 "$RAW_XML_CASE/$ARCHIVE_NAME")"
OVERSIZED_FEED_SHA256="$(release_sha256 "$OVERSIZED_CASE/appcast.xml")"
OVERSIZED_ARCHIVE_SHA256="$(release_sha256 "$OVERSIZED_CASE/$ARCHIVE_NAME")"

verify_signing_boundary
GENERATE_APPCAST_SHA256="$(binding_sha256 "$GENERATE_APPCAST_BINDING")"
GENERATE_KEYS_SHA256="$(binding_sha256 "$GENERATE_KEYS_BINDING")"
SIGN_UPDATE_SHA256="$(binding_sha256 "$SIGN_UPDATE_BINDING")"
FIXTURE_SCRIPT_SHA256="$EXPECTED_SCRIPT_SHA256"
RELEASE_COMMON_SOURCE_SHA256="$(
  /usr/bin/jq -er '.files["scripts/release-common.sh"].sha256' \
    "$FROZEN_BUNDLE_DIRECTORY/freeze-manifest.json"
)"
VALIDATE_APPCAST_SOURCE_SHA256="$(
  /usr/bin/jq -er '.files["scripts/validate-appcast.sh"].sha256' \
    "$FROZEN_BUNDLE_DIRECTORY/freeze-manifest.json"
)"
RELEASE_NOTES_SOURCE_SHA256="$(
  /usr/bin/jq -er '.files["updates/release-notes/0.1.4.md"].sha256' \
    "$FROZEN_BUNDLE_DIRECTORY/freeze-manifest.json"
)"
REVIEWED_SOURCE_MANIFEST_SHA256="$(
  /usr/bin/jq -er '.reviewedSourceManifestSHA256' \
    "$FROZEN_BUNDLE_DIRECTORY/metadata/request.json"
)"
SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256="$(
  /usr/bin/jq -er '.publicKeyFingerprintSHA256' \
    "$FROZEN_BUNDLE_DIRECTORY/freeze-manifest.json"
)"
DMG_ASSET_SHA256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[0]}")"
ZIP_ASSET_SHA256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[1]}")"
DSYM_ASSET_SHA256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[2]}")"
RELEASE_MANIFEST_ASSET_SHA256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[3]}")"
RELEASE_CHECKSUMS_ASSET_SHA256="$(binding_sha256 "${ASSET_SNAPSHOT_BINDINGS[4]}")"

/usr/bin/jq -n \
  --arg sourceVersion "$TRANSITION_SOURCE_VERSION" \
  --arg sourceBuild "$TRANSITION_SOURCE_BUILD" \
  --arg targetVersion "$FIXTURE_VERSION" \
  --arg targetBuild "$FIXTURE_BUILD" \
  --arg tag "$FIXTURE_TAG" \
  --arg appcastURL "$USHOT_APPCAST_URL" \
  --arg enclosureURL "$CANONICAL_ENCLOSURE_URL" \
  --arg archiveName "$ARCHIVE_NAME" \
  --arg sparkleVersion "$USHOT_SPARKLE_VERSION" \
  --arg sparkleArchiveSHA256 "$USHOT_SPARKLE_ARCHIVE_SHA256" \
  --arg validatorSHA256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
  --arg publicKeyDeriverSHA256 "$PUBLIC_KEY_DERIVER_SHA256" \
  --arg embeddedPublicKeyVerifierSHA256 "$EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256" \
  --arg generateAppcastSHA256 "$GENERATE_APPCAST_SHA256" \
  --arg generateKeysSHA256 "$GENERATE_KEYS_SHA256" \
  --arg signUpdateSHA256 "$SIGN_UPDATE_SHA256" \
  --arg keySource "$KEY_SOURCE" \
  --arg keyAccount "$USHOT_SPARKLE_KEY_ACCOUNT" \
  --arg publicKeyFingerprintSHA256 "$SPARKLE_PUBLIC_KEY_FINGERPRINT_SHA256" \
  --arg frozenBundleManifestSHA256 "$EXPECTED_FREEZE_MANIFEST_SHA256" \
  --arg reviewedSourceManifestSHA256 "$REVIEWED_SOURCE_MANIFEST_SHA256" \
  --arg fixtureScriptSHA256 "$FIXTURE_SCRIPT_SHA256" \
  --arg releaseCommonSourceSHA256 "$RELEASE_COMMON_SOURCE_SHA256" \
  --arg validateAppcastSourceSHA256 "$VALIDATE_APPCAST_SOURCE_SHA256" \
  --arg dmgAssetSHA256 "$DMG_ASSET_SHA256" \
  --arg zipAssetSHA256 "$ZIP_ASSET_SHA256" \
  --arg dsymAssetSHA256 "$DSYM_ASSET_SHA256" \
  --arg releaseManifestAssetSHA256 "$RELEASE_MANIFEST_ASSET_SHA256" \
  --arg releaseChecksumsAssetSHA256 "$RELEASE_CHECKSUMS_ASSET_SHA256" \
  --arg releaseNotesSHA256 "$RELEASE_NOTES_SOURCE_SHA256" \
  --arg normalFeedSHA256 "$NORMAL_FEED_SHA256" \
  --arg normalArchiveSHA256 "$NORMAL_ARCHIVE_SHA256" \
  --arg tamperedFeedSHA256 "$TAMPERED_FEED_SHA256" \
  --arg tamperedArchiveSHA256 "$TAMPERED_ARCHIVE_SHA256" \
  --arg shortFeedSHA256 "$SHORT_FEED_SHA256" \
  --arg shortArchiveSHA256 "$SHORT_ARCHIVE_SHA256" \
  --arg buildFeedSHA256 "$BUILD_FEED_SHA256" \
  --arg buildArchiveSHA256 "$BUILD_ARCHIVE_SHA256" \
  --arg bothFeedSHA256 "$BOTH_FEED_SHA256" \
  --arg bothArchiveSHA256 "$BOTH_ARCHIVE_SHA256" \
  --arg rawFeedSHA256 "$RAW_FEED_SHA256" \
  --arg rawArchiveSHA256 "$RAW_ARCHIVE_SHA256" \
  --arg rawPolicyRejectionCategory "$RAW_XML_REJECTION_CATEGORY" \
  --arg oversizedFeedSHA256 "$OVERSIZED_FEED_SHA256" \
  --arg oversizedArchiveSHA256 "$OVERSIZED_ARCHIVE_SHA256" \
  --arg oversizedPolicyRejectionCategory "$OVERSIZED_FEED_REJECTION_CATEGORY" \
  --arg oversizedAuthenticatedPrefixBytes "$OVERSIZED_AUTHENTICATED_PREFIX_BYTES" \
  --arg oversizedSignedFeedBytes "$OVERSIZED_SIGNED_FEED_BYTES" \
  --arg maximumAuthenticatedPrefixBytes "$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" \
  --arg maximumSignedFeedWireBytes "$SIGNED_FEED_WIRE_CEILING_BYTES" \
  --arg loopbackMaximumFeedBytes "$LOOPBACK_MAX_FEED_FIXTURE_BYTES" \
  --arg mismatchVersion "$SHORT_MISMATCH_VERSION" \
  --arg mismatchBuild "$BUILD_MISMATCH_BUILD" \
  '{
    schemaVersion: 2,
    purpose: "isolated Ushot 0.1.3 to 0.1.4 update-transition evidence",
    source: {version: $sourceVersion, build: $sourceBuild},
    advertisedTarget: {version: $targetVersion, build: $targetBuild, tag: $tag},
    requests: {appcastURL: $appcastURL, enclosureURL: $enclosureURL},
    tools: {
      sparkleVersion: $sparkleVersion,
      sparkleReleaseArchiveSHA256: $sparkleArchiveSHA256,
      sparkleGenerateAppcastSHA256: $generateAppcastSHA256,
      sparkleGenerateKeysSHA256: $generateKeysSHA256,
      sparkleSignUpdateSHA256: $signUpdateSHA256,
      authenticatedAppcastValidatorSHA256: $validatorSHA256,
      publicKeyDeriverSHA256: $publicKeyDeriverSHA256,
      embeddedPublicKeyVerifierSHA256: $embeddedPublicKeyVerifierSHA256,
      keySource: $keySource,
      signingPublicKeyIdentityVerified: true,
      keyAccount: $keyAccount,
      publicKeyFingerprintSHA256: $publicKeyFingerprintSHA256,
      archiveAndFeedVerification: "independent embedded-public-key verifier"
    },
    reviewedSources: {
      externalReviewedSourceManifestSHA256: $reviewedSourceManifestSHA256,
      frozenBundleManifestSHA256: $frozenBundleManifestSHA256,
      fixtureScriptSHA256: $fixtureScriptSHA256,
      releaseCommonSHA256: $releaseCommonSourceSHA256,
      validateAppcastSHA256: $validateAppcastSourceSHA256
    },
    candidateInputs: {
      exactAssetCount: 5,
      assets: [
        {name: "Ushot-0.1.4-arm64.dmg", sha256: $dmgAssetSHA256},
        {name: "Ushot-0.1.4-arm64.zip", sha256: $zipAssetSHA256},
        {name: "Ushot-0.1.4-arm64.dSYM.zip", sha256: $dsymAssetSHA256},
        {name: "Ushot-0.1.4-arm64.release-manifest.json", sha256: $releaseManifestAssetSHA256},
        {name: "SHA256SUMS.txt", sha256: $releaseChecksumsAssetSHA256}
      ],
      releaseNotesSHA256: $releaseNotesSHA256
    },
    invariants: {
      privateKeyWrittenByThisScript: false,
      deployedOrPublished: false,
      outputMode: "0700",
      archiveName: $archiveName
    },
    fixtures: [
      {
        name: "normal",
        feed: {path: "normal/appcast.xml", sha256: $normalFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "accepted"},
        archive: {path: ("normal/" + $archiveName), sha256: $normalArchiveSHA256, edDSA: "verified", bundleVersion: $targetVersion, bundleBuild: $targetBuild},
        expectedClientResult: "atomic replacement and relaunch"
      },
      {
        name: "tampered-archive",
        feed: {path: "tampered-archive/appcast.xml", sha256: $tamperedFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "accepted"},
        archive: {path: ("tampered-archive/" + $archiveName), sha256: $tamperedArchiveSHA256, edDSA: "rejection-proven", sameByteLengthAsNormal: true, bundleVersion: $targetVersion, bundleBuild: $targetBuild, bundleAdHocSignature: "verified-after-final-archive-extraction"},
        expectedClientResult: "archive EdDSA rejection before extraction"
      },
      {
        name: "short-version-mismatch",
        feed: {path: "short-version-mismatch/appcast.xml", sha256: $shortFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "accepted"},
        archive: {path: ("short-version-mismatch/" + $archiveName), sha256: $shortArchiveSHA256, edDSA: "verified", bundleVersion: $mismatchVersion, bundleBuild: $targetBuild},
        expectedClientResult: "post-extraction exact-version rejection"
      },
      {
        name: "build-number-mismatch",
        feed: {path: "build-number-mismatch/appcast.xml", sha256: $buildFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "accepted"},
        archive: {path: ("build-number-mismatch/" + $archiveName), sha256: $buildArchiveSHA256, edDSA: "verified", bundleVersion: $targetVersion, bundleBuild: $mismatchBuild},
        expectedClientResult: "post-extraction exact-build rejection"
      },
      {
        name: "short-and-build-mismatch",
        feed: {path: "short-and-build-mismatch/appcast.xml", sha256: $bothFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "accepted"},
        archive: {path: ("short-and-build-mismatch/" + $archiveName), sha256: $bothArchiveSHA256, edDSA: "verified", bundleBuild: $mismatchBuild, bundleVersion: $mismatchVersion},
        expectedClientResult: "post-extraction exact-version-and-build rejection"
      },
      {
        name: "duplicate-build-metadata",
        feed: {path: "duplicate-build-metadata/appcast.xml", sha256: $rawFeedSHA256, edDSA: "verified", authenticatedXMLPolicy: "rejection-proven", rejectionCategory: $rawPolicyRejectionCategory},
        archive: {path: ("duplicate-build-metadata/" + $archiveName), sha256: $rawArchiveSHA256, edDSA: "verified", bundleVersion: $targetVersion, bundleBuild: $targetBuild},
        expectedClientResult: "authenticated raw-XML rejection before item parsing"
      },
      {
        name: "oversized-signed-feed",
        feed: {
          path: "oversized-signed-feed/appcast.xml",
          sha256: $oversizedFeedSHA256,
          edDSA: "verified",
          verificationMode: "cryptographic-only-2MiB",
          authenticatedXMLPolicy: "rejection-proven",
          rejectionCategory: $oversizedPolicyRejectionCategory,
          authenticatedPrefixBytes: ($oversizedAuthenticatedPrefixBytes | tonumber),
          maximumAuthenticatedPrefixBytes: ($maximumAuthenticatedPrefixBytes | tonumber),
          signedFeedBytes: ($oversizedSignedFeedBytes | tonumber),
          maximumSignedFeedWireBytes: ($maximumSignedFeedWireBytes | tonumber),
          loopbackMaximumFeedBytes: ($loopbackMaximumFeedBytes | tonumber)
        },
        archive: {path: ("oversized-signed-feed/" + $archiveName), sha256: $oversizedArchiveSHA256, edDSA: "verified", bundleVersion: $targetVersion, bundleBuild: $targetBuild},
        expectedClientResults: {
          contentLength: "declared Content-Length rejection before body acceptance or XML parsing",
          chunked: "incremental wire-size rejection before signed-feed or XML parsing"
        }
      }
    ]
  }' > "$FIXTURES_ROOT/fixture-manifest.json"

FIXTURE_CHECKSUM_PATHS=(
  "normal/appcast.xml"
  "normal/$ARCHIVE_NAME"
  "tampered-archive/appcast.xml"
  "tampered-archive/$ARCHIVE_NAME"
  "short-version-mismatch/appcast.xml"
  "short-version-mismatch/$ARCHIVE_NAME"
  "build-number-mismatch/appcast.xml"
  "build-number-mismatch/$ARCHIVE_NAME"
  "short-and-build-mismatch/appcast.xml"
  "short-and-build-mismatch/$ARCHIVE_NAME"
  "duplicate-build-metadata/appcast.xml"
  "duplicate-build-metadata/$ARCHIVE_NAME"
  "oversized-signed-feed/appcast.xml"
  "oversized-signed-feed/$ARCHIVE_NAME"
  "fixture-manifest.json"
)

write_fixture_checksums() {
  local checksum_path
  local checksum_digest
  local temporary_sums="SHA256SUMS.txt.tmp"

  [[ ! -e "$temporary_sums" && ! -L "$temporary_sums" ]] \
    || release_die "Temporary fixture checksum path already exists."
  : > "$temporary_sums"
  /bin/chmod 600 "$temporary_sums"
  for checksum_path in "${FIXTURE_CHECKSUM_PATHS[@]}"; do
    [[ -f "$checksum_path" && ! -L "$checksum_path" ]] \
      || release_die "Fixture checksum input is missing or symbolic: $checksum_path"
    checksum_digest="$(release_sha256 "$checksum_path")"
    [[ "$checksum_digest" =~ ^[0-9a-f]{64}$ ]] \
      || release_die "Fixture checksum is malformed: $checksum_path"
    printf '%s  %s\n' "$checksum_digest" "$checksum_path" >> "$temporary_sums"
  done
  [[ ! -e SHA256SUMS.txt && ! -L SHA256SUMS.txt ]] \
    || release_die "Fixture checksum output already exists."
  /bin/mv "$temporary_sums" SHA256SUMS.txt
}

verify_fixture_checksums() {
  local checksum_line
  local expected_digest
  local checksum_path
  local actual_digest
  local checksum_index=0

  [[ -f SHA256SUMS.txt && ! -L SHA256SUMS.txt ]] \
    || release_die "Fixture checksum set is missing or symbolic."
  while IFS= read -r checksum_line; do
    [[ "$checksum_line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]](.+)$ ]] \
      || release_die "Fixture checksum line is malformed."
    expected_digest="${BASH_REMATCH[1]}"
    checksum_path="${BASH_REMATCH[2]}"
    ((checksum_index < ${#FIXTURE_CHECKSUM_PATHS[@]})) \
      || release_die "Fixture checksum set contains extra entries."
    [[ "$checksum_path" == "${FIXTURE_CHECKSUM_PATHS[$checksum_index]}" \
        && -f "$checksum_path" && ! -L "$checksum_path" ]] \
      || release_die "Fixture checksum path differs from the fixed allowlist: $checksum_path"
    actual_digest="$(release_sha256 "$checksum_path")"
    [[ "$actual_digest" == "$expected_digest" ]] \
      || release_die "Fixture checksum mismatch: $checksum_path"
    checksum_index=$((checksum_index + 1))
  done < SHA256SUMS.txt
  [[ "$checksum_index" == "${#FIXTURE_CHECKSUM_PATHS[@]}" ]] \
    || release_die "Fixture checksum set is incomplete."
}

(
  cd "$FIXTURES_ROOT"
  write_fixture_checksums
  verify_fixture_checksums
)

/usr/bin/find "$FIXTURES_ROOT" -type d -exec /bin/chmod 700 {} \;
/usr/bin/find "$FIXTURES_ROOT" -type f -exec /bin/chmod 600 {} \;
[[ "$(/usr/bin/stat -f '%Lp' "$FIXTURES_ROOT")" == "700" ]] \
  || release_die "Fixture staging root permissions are not exactly 0700."

OUTPUT_STAGING="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.ushot-update-transition-fixtures.XXXXXXXX")"
/bin/chmod 700 "$OUTPUT_STAGING"
[[ -d "$OUTPUT_STAGING" && ! -L "$OUTPUT_STAGING" \
    && "$(/usr/bin/dirname "$OUTPUT_STAGING")" == "$OUTPUT_PARENT" \
    && "$(/usr/bin/stat -f '%u' "$OUTPUT_STAGING")" == "$(/usr/bin/id -u)" \
    && "$(/usr/bin/stat -f '%Lp' "$OUTPUT_STAGING")" == "700" ]] \
  || release_die "Could not establish a mode-0700 output staging directory."
/usr/bin/ditto "$FIXTURES_ROOT" "$OUTPUT_STAGING"
(
  cd "$OUTPUT_STAGING"
  verify_fixture_checksums
)
[[ "$(/usr/bin/find "$OUTPUT_STAGING" -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
  || release_die "Copied fixture output unexpectedly contains symbolic links."
[[ ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] \
  || release_die "Fixture output path appeared during preparation; refusing to merge or overwrite it."
/bin/mv "$OUTPUT_STAGING" "$OUTPUT_DIRECTORY"
OUTPUT_STAGING=""
OUTPUT_CLEANUP_PATH="$OUTPUT_DIRECTORY"
[[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" \
    && "$(/usr/bin/stat -f '%u' "$OUTPUT_DIRECTORY")" == "$(/usr/bin/id -u)" \
    && "$(/usr/bin/stat -f '%Lp' "$OUTPUT_DIRECTORY")" == "700" ]] \
  || release_die "Final fixture output did not retain its mode-0700 identity."
[[ "$(/usr/bin/find "$OUTPUT_DIRECTORY" -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
  || release_die "Final fixture output acquired a symbolic link after placement."
(
  cd "$OUTPUT_DIRECTORY"
  verify_fixture_checksums
) || release_die "Final fixture output failed its complete checksum set after placement."

unset PRIVATE_KEY DERIVED_PUBLIC_KEY EARLY_PRIVATE_KEY
release_log "Prepared isolated update-transition fixtures without deployment or publication: $OUTPUT_DIRECTORY"
release_log "Use one case directory at a time with serve-update-transition-loopback.sh and preserve independent runtime evidence."
printf 'output=%s\nmanifest_sha256=%s\nresult=PASS\n' \
  "$OUTPUT_DIRECTORY" \
  "$(release_sha256 "$OUTPUT_DIRECTORY/fixture-manifest.json")"
OUTPUT_CLEANUP_PATH=""
