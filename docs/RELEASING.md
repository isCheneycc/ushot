# Releasing Ushot

Ushot currently has no Developer ID certificate. Public builds are distributed from GitHub as intentionally ad-hoc signed, unnotarized artifacts; the current release and updater rollout does not require paid Apple Developer Program membership. Local development and the installed `/Applications/Ushot.app` use a separate, stable Apple Development signature so routine development does not continuously invalidate Screen Recording authorization.

The fixed hardened update feed is active and currently serves Ushot 0.1.10 (build 11):

```text
https://ischeneycc.github.io/ushot/updates/v1/appcast.xml
```

Ushot 0.1.10 (build 11) is the current published release. Protected run [`32922355161`](https://github.com/isCheneycc/ushot/actions/runs/32922355161) completed all 11 jobs with `publish_update_feed=true`, published and anonymously verified exactly five immutable assets, independently signed its archive, and extended the authenticated production feed while retaining 0.1.9 and the earlier signed history.

Ushot 0.1.10 repairs Screen Recording and LaunchServices attribution by isolating Debug identity and storage, explicitly declaring the public display identity, keeping disposable and recoverable bundles out of app discovery, and verifying exact registration of the installed Release app. Its feed-enabled publication makes that repair available to supported 0.1.9 installations through a manual **Check for Updates…** request; permission may still need to be granted again after replacement because ad-hoc TCC continuity is not guaranteed.

Ushot 0.1.11 (build 12) is the prepared next candidate. It keeps every pinned screenshot under a stable identity so new captures no longer replace existing pins, while preserving independent movement, resize, editing, output and close lifecycles. It is intended for a reviewed `publish_update_feed=true` run that publishes the immutable five-asset GitHub Release and extends the authenticated production feed; neither publication is complete until the protected workflow and independent live verification succeed.

The first public installation requires the user to remove quarantine explicitly. Direct-download GitHub Releases and production Sparkle updates have separate readiness gates. Ushot 0.1.1 is the first direct-download preview and remains on the legacy `/updates/appcast.xml`, which must stay permanently absent. Ushot 0.1.2 (build 3) is the published first manual-install hardened transition; its immutable five-asset Release used `publish_update_feed=false`, and the v1 endpoint remained absent. Parsed `SUAppcastItem` values cannot prove that authenticated XML contained no duplicate or wrong-namespace metadata, so published Ushot 0.1.3 (build 4) is the second manual GitHub-only transition and adds pre-parse validation. Its protected run also used `publish_update_feed=false`; both appcast URLs remained HTTP 404. The complete 0.1.3 → 0.1.4 matrix passed before protected run [`31141110871`](https://github.com/isCheneycc/ushot/actions/runs/31141110871) published 0.1.4 (build 5) as the first v1 feed item. Runs [`31552493658`](https://github.com/isCheneycc/ushot/actions/runs/31552493658) and [`31864175412`](https://github.com/isCheneycc/ushot/actions/runs/31864175412) subsequently extended that authenticated history with 0.1.5 (build 6) and 0.1.6 (build 7). Protected runs [`32689508333`](https://github.com/isCheneycc/ushot/actions/runs/32689508333) and [`32817346826`](https://github.com/isCheneycc/ushot/actions/runs/32817346826) then published 0.1.7 (build 8) and 0.1.8 (build 9) as immutable direct-download Releases with `publish_update_feed=false`; each anonymously verified all five assets, skipped signing/feed/Pages, and left the production v1 feed byte-identical at 0.1.6 (build 7) while the legacy endpoint remained HTTP 404. Protected run [`32824113225`](https://github.com/isCheneycc/ushot/actions/runs/32824113225) subsequently published 0.1.9 (build 10) with `publish_update_feed=true`, completed all 11 jobs and deployed the signed feed retaining 0.1.6, 0.1.5 and 0.1.4. Protected run [`32922355161`](https://github.com/isCheneycc/ushot/actions/runs/32922355161) then published 0.1.10 (build 11) with `publish_update_feed=true`, completed all 11 jobs and extended that authenticated history while retaining 0.1.9; direct-download-only 0.1.7 and 0.1.8 were not inserted retroactively.

## Security invariants

Every release command enforces the applicable invariants below. The appcast, production-version monotonicity and EdDSA-signing bullets apply only to an explicit `publish_update_feed=true` run; `publish_update_feed=false` deliberately creates no appcast.

- Product: `Ushot.app`
- Bundle identifier: `io.github.ischeneycc.ushot`
- Architecture: `arm64`
- App-compiling CI and release jobs run on the `macos-15` arm64 image with the installed Xcode 26.3 toolchain selected explicitly, so the compiler sees the macOS 26 ScreenCaptureKit screenshot API while tests execute on a supported older OS; control, approval, signing, validation and publication jobs retain their narrower existing toolchain boundaries
- The deployment target remains macOS 14. ScreenCaptureKit is weak-linked, 0.1.7-or-later asset validation requires `SCScreenshotConfiguration` and `SCScreenshotOutput` to remain weak imports, and CI launches the exact public-build app artifact to prove macOS 14 launch compatibility; runtime availability routing keeps macOS 14/15 on the separately validated legacy capture path
- Stable tag: `v<MARKETING_VERSION>`
- Build: positive integer matching `CURRENT_PROJECT_VERSION`
- Workflow run ref, requested tag, local tag, remote tag and `GITHUB_SHA` all resolve to the same commit, and the local/remote tag object SHA also matches for annotated tags
- The tagged commit is an ancestor of protected `main` and has a successful `CI` push run on `main`
- Sparkle account: `io.github.ischeneycc.ushot.20260806`
- Hardened feed: `https://ischeneycc.github.io/ushot/updates/v1/appcast.xml`; legacy `https://ischeneycc.github.io/ushot/updates/appcast.xml` remains permanently absent
- No executable contains `com.apple.security.get-task-allow=true`
- Public app is ad-hoc signed, has no Team ID or Apple Development authority, and has Hardened Runtime disabled
- Local installed app has a stable Apple Development authority and Team ID
- The complete appcast passes Sparkle signed-feed verification; from 0.1.3 onward, the exact authenticated XML bytes are delivered to the host after EdDSA verification and before parsing, and every full enclosure independently contains a valid EdDSA signature
- The 0.1.3-or-later runtime host requires `SURequireExactUpdateVersionIdentity=true`, `SURequireEdDSAUpdateArchiveSignature=true`, `SURequireHostSignedAppcastValidation=true` and `SUMaximumSignedAppcastContentLength=1048576`; the embedded framework exposes `SUUpdateVersionIdentityHardeningVersion=1`, `SUHostSignedAppcastValidationVersion=1` and `SUFeedDownloadSizeLimitVersion=1`. A missing/false host policy, missing/invalid size limit, missing/wrong marker, absent hook owner or hook rejection fails before a request or before XML parsing. Appcast transport admits at most a 1,048,576-byte authenticated prefix plus the fixed 512-byte signed-feed trailer (1,049,088 wire bytes total), rejecting an oversized declared `Content-Length` before body buffering and enforcing the same ceiling incrementally for chunked or otherwise undeclared responses. This cap applies only to temporary appcast downloads; persistent update-archive/ZIP downloads remain eligible and must pass their separate Sparkle EdDSA verification. The published 0.1.2 artifact is retained as a historical exception that predates the raw-XML and bounded-feed keys, markers and hooks
- The reviewed runtime fork rejects an extracted `CFBundleShortVersionString` or `CFBundleVersion` mismatch and rejects archive EdDSA failure without accepting matching application code signing as a substitute
- Pipeline and runtime validate the raw RSS/channel/item hierarchy, namespaces, element/attribute uniqueness and absence of DTD/entity declarations before parsed item policy can collapse metadata
- Every non-seed item has exactly one nonempty restricted-Markdown `description` with `sparkle:format="markdown"`; links, images, raw HTML, autolinks, entities, URL/domain/network-address-like destinations, item-level `releaseNotesLink`, `link`, `fullReleaseNotesLink` and delta enclosures are absent
- Appcast short/build versions, tag, filenames and the `CFBundleShortVersionString`/`CFBundleVersion` extracted from the final ZIP agree exactly
- The new stable semantic version and positive decimal build number are each strictly greater than every retained item in the authenticated production appcast
- An existing production feed passes Sparkle's cryptographic verification and the embedded-notes structural policy before it is extended or redeployed; a detached-notes feed is rejected rather than migrated automatically
- The feed-only signing job has only read access to repository contents and actions; the publishing job has repository write access but never receives the Sparkle private key, while the final Pages/OIDC job checks out no source and executes only the pinned deploy action
- Every release-workflow checkout disables persisted GitHub credentials, and every action used by that workflow is pinned to a full commit SHA
- The default `publish_update_feed=false` path still builds, validates, publishes and anonymously download-verifies exactly the five Release assets, but does not fetch Sparkle tools or the current feed, read the EdDSA private key, create a Pages artifact or run `deploy-appcast`
- Only `publish_update_feed=true` may sign and deploy the production feed. The first feed item was admitted only after the 0.1.3 hardened-runtime build evidence, operator-run key-recovery drill and clean-account 0.1.3 → 0.1.4 raw-XML/mismatch/tamper/update matrix passed; every later feed-enabled release must preserve those gates and extend the authenticated history

Disabling Hardened Runtime is deliberate **only** for `public-adhoc`: Sparkle documents that an ad-hoc host can fail to load Sparkle when Library Validation is enabled. `local-signed` and the future `developer-id` mode keep Hardened Runtime enabled. The scripts never recursively re-sign Sparkle with `codesign --deep`.

The archive-version check above is a protected publication gate, while the reviewed runtime fork adds the separate post-extraction check and strict archive-EdDSA policy. The published 0.1.2 dependency remains historically pinned to `https://github.com/isCheneycc/Sparkle`, exact immutable tag `2.9.5-ushot.2`, revision `f4d8362bf9b6231596db3a0cc8812fdca8100961`; it predates the raw authenticated-XML hook. Fork tag `2.9.5-ushot.3` is retained only as the historical authenticated-XML-hook predecessor. Published Ushot 0.1.3 pins the [bounded-feed successor Release](https://github.com/isCheneycc/Sparkle/releases/tag/2.9.5-ushot.4), exact tag `2.9.5-ushot.4`, revision `3d81360ff115ffb80222c2723d72cb4cfa802774`, whose SwiftPM ZIP SHA-256 is `d8d36e5b5ee9e97b17babc1beeb26795b96558cafe5450130aafa5b169d5c829`; Release/CI builds must continue to refuse automatic package resolution. The runtime fork does not replace the publisher: appcasts and archives continue to be generated and signed with the official upstream Sparkle 2.9.5 tools. The fork Release was verified dependency evidence, not Ushot publication or runtime-transition evidence. The complete 0.1.3 → 0.1.4 runtime matrix passed before the first feed publication; source review, CI or a downloadable Release still cannot substitute for the runtime and pipeline gates on later releases.

## One-time GitHub setup

1. Create the public repository `isCheneycc/ushot`.
2. Protect `main`, require the `CI` workflow, require pull requests, and do not permit release operators to bypass those rules.
3. Create a tag ruleset for `v*` that blocks updates and deletion. Tag protection is mandatory: a published tag is immutable.
4. Create a protected GitHub Environment named `release`, add required reviewers, and use exact tag deployment rules. Admit only the exact currently reviewed release tag and never use a `v*` wildcard. After the completed 0.1.10 publication, `release`, `update-feed-signing` and `github-pages` each admit only exact tag `v0.1.10`; before the prepared 0.1.11 feed-enabled dispatch, replace each participating rule with exact tag `v0.1.11`. This general approval environment must contain no `SPARKLE_ED25519_PRIVATE_KEY` secret; repository, `release` and `github-pages` currently contain zero secrets, while `update-feed-signing` alone contains the signing secret. A failed or superseded tag stays permanently absent from every allowlist because its immutable workflow source cannot be revoked from `main`.

Those four steps are sufficient for `publish_update_feed=false`. Before any `publish_update_feed=true` run:

5. Create a separate protected GitHub Environment named `update-feed-signing`, add required reviewers, and allow only the exact feed-enabled tag currently approved. A missing environment may be created by GitHub without the intended protections, so configure and inspect it before the first true run.
6. In Settings → Pages, select **GitHub Actions** as the source. Configure the generated `github-pages` environment with the same exact approved-tag policy; never allow a failed, superseded or wildcard tag.
7. Add `SPARKLE_ED25519_PRIVATE_KEY` only to `update-feed-signing`. Its value is the private key exported from the Sparkle keychain account below—not the public key from `Base.xcconfig`. Confirm the secret is absent from `release` before any no-feed run, because GitHub makes an environment's secrets available when a job using that environment starts even if no step references the secret.

The Ushot-specific Sparkle account already used locally is:

```text
io.github.ischeneycc.ushot.20260806
```

All Sparkle tool invocations must pass that account explicitly. A login-Keychain item is permitted only as short-lived production-key rotation staging. Removable offline media or a second provider is preferred, but the owner explicitly declined iCloud and accepted the single-provider risk. Create the encrypted file in the restricted local staging directory, then commit it to the owner-approved private repository `isCheneycc/ushot-signing-key-backup`:

```bash
scripts/backup-sparkle-key.sh \
  --output "/Users/cheney/Documents/Ushot-Signing-Key-Staging/Ushot-Sparkle-Ed25519-20260806.enc"
```

The current helper reads the Keychain value into process memory, proves that it derives Ushot's committed public key, passes plaintext only through process memory/standard input, and writes only an AES-256-CBC/PBKDF2 encrypted temporary file in the canonical output directory. It asks for the password again through OpenSSL's hidden controlling-terminal prompt, decrypts into process memory for byte comparison, atomically installs the mode-0600 ciphertext without overwriting, clears variables on exit/signals and removes its private workspace. No plaintext key file is created by the current implementation. Use a new high-entropy password and keep it in a password manager or physical record outside GitHub. Keep the printed encrypted-file SHA-256 with the recovery record. Never commit, log, paste into an issue, put in an environment/command-line argument, or provide the key or backup password to an agent. The private repository stores ciphertext and nonsecret recovery metadata only; it must contain no plaintext key, password, GitHub Secret, workflow or executable recovery helper. This single repository is off-device but not independent because the same GitHub account also controls the signing Secret; the owner explicitly accepts that account loss or repository deletion can strand the update chain. CI similarly removes the inherited secret name, keeps tracing/core dumps disabled and feeds the in-memory value to derivation/signing through standard input; it never writes the key into the source repository or an artifact.

The 2026-08-06 ciphertext at `~/Documents/Ushot-Sparkle-Ed25519-Backup.enc` is OpenSSL salted format, mode `0600`, 64 bytes, SHA-256 `da3f8fdd48a2906e48a7847ce252af472c11d865950673f7fb05375736d3f379`, and its decrypt/byte-compare check passed. It is on the same internal disk as the login Keychain and therefore is only encrypted staging evidence. The helper used for that run also created and deleted temporary plaintext files; APFS snapshots or residual blocks cannot be ruled out. Preserve this record as old-key evidence, but do not claim it is an independent backup or use it for the rotated production key's recovery gate.

The repository owner approved rotation on 2026-08-06 because no production appcast had yet been signed and the manual 0.1.3 installation provided the clean trust-root migration. The new key was generated with the checksum-pinned official Sparkle 2.9.5 tool under account `io.github.ischeneycc.ushot.20260806`; its derived public key exactly matches `+zRL11/2yYePt5O+OetThnLGwyvAvFtPPXxiBBOTTjE=` in source. The encrypted GitHub recovery record passed at archived private root commit `9fe3d07a31bad91c6b75142955f31d1c30816ec1`, ciphertext SHA-256 `f308c694d6597a52a700ab4f9b97386ee17bd5332ad7725655fd13ab666155d0`; a mode-0700 fresh clone matched the locally recovery-checked bytes and passed Git-object, five-file, mode, header and digest checks. The old `update-feed-signing` Secret was then replaced through stdin and its metadata advanced to `2026-08-06T06:02:05Z`. Published 0.1.1/0.1.2 artifacts and their old public key remain unchanged; published 0.1.3 embeds the rotated public key. A temporary local Keychain copy or staging ciphertext may be deleted only after the exact published-asset recovery drill passes and the owner explicitly approves deletion.

Before the first feed publication, the key custodian personally ran the drill against the exact five published 0.1.3 assets from an interactive Terminal. Repeat the same procedure against the applicable published assets whenever a later release policy requires a new recovery drill:

```bash
scripts/run-sparkle-key-recovery-drill.sh \
  --backup "/absolute/path/to/fresh-clone/Ushot-Sparkle-Ed25519-20260806.enc" \
  --expected-backup-sha256 "NEW_BACKUP_SHA256" \
  --assets-directory "/absolute/path/to/ushot/build/release/public-adhoc/artifacts"
```

The user enters the password only at OpenSSL's hidden `/dev/tty` prompt. Do not ask the user to send or paste it into chat, a command, an environment variable or a log. Record only the nonsecret `version`, `build`, backup/archive/appcast hashes and `result=PASS` lines. The helper verifies the selected exact assets, recovered public-key identity, disposable appcast/archive signatures and tamper rejection without a plaintext key file; this is not client-update evidence, and the separate protected run remains the source of publication evidence.

## Local stable build and installation

Create an Apple Development certificate in Xcode → Settings → Accounts → Manage Certificates. Copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and set the correct Team ID.

```bash
scripts/build-release.sh --mode local-signed
scripts/package-dmg.sh --mode local-signed
scripts/install-local.sh
```

The ordinary Debug host uses `io.github.ischeneycc.ushot.debug` and isolated preferences/Application Support storage; it must never request or inherit the production app's Screen Recording identity. Xcode must not register disposable Ushot host apps with LaunchServices, and after validation the release builder explicitly unregisters each host app in DerivedData or the copied artifact only when that exact path is present, then verifies its absence. The stable local Release keeps `io.github.ischeneycc.ushot`. After the transactional installer validates and atomically moves the final bundle to `/Applications/Ushot.app`, it force-registers and verifies that exact path before launch. Recoverable bundles use a non-`.app` backup suffix and are explicitly removed from LaunchServices attribution after each move. Registration failure triggers rollback; a registered replacement that fails to launch is unregistered and verified absent before it can be moved aside, and a restored app is registered again before any relaunch.

The build and installer reject ad-hoc signatures, missing Team IDs, non-Apple-Development identities, missing designated requirements, mismatched dSYMs and incompatible replacement identities. The secure installer rewrite does not implement a signing-identity migration override: `ALLOW_SIGNING_IDENTITY_MIGRATION` has no supported effect and must not be recommended. If an intentional identity migration is required, stop at the visible rejection and implement a separately reviewed transactional migration path before changing the installed app; there is no documented bypass.

Never install a `public-adhoc` build over the local signed `/Applications/Ushot.app` used for development.

## Preparing a public release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`. Both values must match the release tag and final bundle. A feed-enabled release additionally requires both the stable semantic version and positive decimal build to be strictly greater than every retained item in the signed production appcast.
2. Add nonempty restricted-Markdown source notes at `updates/release-notes/<version>.md`. Links, images, raw HTML, autolinks, entities and URL/domain/network-address-like destinations are forbidden. Do not add Sparkle signing comments or appcast elements yourself.
3. Run the relevant tests and direct-install manual checks. Preserve the historical 0.1.2/0.1.3 transition evidence. For a feed-enabled release, authenticate and validate the existing production feed before extension, prove that both the new stable version and build are strictly monotonic, and rerun the relevant runtime, raw-XML, archive-signature, exact-version and active-work regressions. A `publish_update_feed=false` release is direct-download-only and must never be presented as an in-app update.
4. Commit the exact release source.
5. Merge the release commit into protected `main`, wait for the `CI` push run on that exact commit to succeed, then create and push an immutable tag matching the version exactly, for example `v0.1.11` for version 0.1.11.
6. Add that exact tag to the protected `release` environment's deployment rules and confirm failed or superseded tags remain excluded. For a feed-enabled release, configure `update-feed-signing` and `github-pages` to admit the same exact tag before dispatch as well. Then dispatch **Protected release** at the tag ref, not at `main`. The ref and the `tag` input must be identical. The prepared 0.1.11 candidate uses:

   ```bash
   TAG=v0.1.11
   BUILD_NUMBER=12
   PUBLISH_UPDATE_FEED=true
   gh workflow run release.yml \
     --ref "$TAG" \
     -f tag="$TAG" \
     -f build_number="$BUILD_NUMBER" \
     -f publish_update_feed="$PUBLISH_UPDATE_FEED"
   ```

7. Approve the protected `release` environment only after comparing the run ref, requested tag, bound commit SHA and successful CI run.

The completed 0.1.2, 0.1.3, 0.1.7 and 0.1.8 runs used `publish_update_feed=false`. Each published five immutable direct-download assets, verified every remote byte and downloaded all five again through the anonymous public boundary. The 0.1.3, 0.1.7 and 0.1.8 runs skipped every signing, feed-validation and Pages job. Preserve those records exactly. Users had to install 0.1.2/0.1.3 manually as applicable while the v1 endpoint was absent; 0.1.7 and 0.1.8 were direct-download-only at publication because the production feed then remained at 0.1.6. The later 0.1.9 and 0.1.10 feeds supersede those versions without inserting them into signed history retroactively.

The operator-run encrypted-key recovery drill and complete clean-account 0.1.3 → 0.1.4 authenticated-XML/helper/replacement/tamper/exact-version/active-work matrix passed before 0.1.4 became the first feed item. The latest completed feed extension used:

```bash
TAG=v0.1.10
BUILD_NUMBER=11
gh workflow run release.yml \
  --ref "$TAG" \
  -f tag="$TAG" \
  -f build_number="$BUILD_NUMBER" \
  -f publish_update_feed=true
```

Run [`32922355161`](https://github.com/isCheneycc/ushot/actions/runs/32922355161) completed that command and the live post-deployment checks. For every future release, replace the tag/build with the new monotonic identity, review all three exact-tag environment rules, and treat publication and feed deployment as unproven until their own protected and independent verification completes.

The workflow has eleven explicit capability boundaries. Read-only `preflight` binds the run ref, input, tag, commit, protected-main ancestry and successful CI run. Credential-free `build-artifacts` builds `public-adhoc`, packages the exact assets, extracts the final ZIP and dSYM, mounts the final DMG read-only, and revalidates app identity/signature, dSYM UUIDs, exact DMG root and `/Applications` link; every executable must resolve the embedded Sparkle framework through `@executable_path/../Frameworks`. Credential-free `prepare-signing-inputs` always produces an exact allow-listed artifact: for a feed run it downloads at most 1,048,576 bytes of authenticated XML plus the fixed 512-byte signed-feed trailer allowance (1,049,088 wire bytes total) as opaque bytes, together with the separately bounded checksum-pinned official Sparkle archive; a no-feed run emits only a canonical sentinel. This publishing-input bound is distinct from the runtime `SUMaximumSignedAppcastContentLength=1048576` policy, and neither bound applies to update-archive/ZIP transport. Secret-free `approve-release` uses the protected but empty `release` environment for both modes. Feed-only `build-authenticated-appcast-validator` runs on its own credential-free macOS runner, verifies fixed source hashes, directly compiles and ad-hoc signs both the app-identical authenticated-XML validator and canonical Ed25519 public-key deriver, and preserves their exact two-file payload with one immutable Artifact ID/digest plus an independent SHA-256 for each binary. Only a job-level true `sign-update-feed` enters the separate `update-feed-signing` environment, and it never invokes Swift, `swiftc`, `xcrun` or any other compiler. It permits only pinned checkout/download actions and fixed workflow shell before its sole secret-bearing step. Every Artifact download uses pinned official `actions/download-artifact` v8 with explicit `digest-mismatch: error`; the signer then binds producer Artifact IDs/names/REST digests, the exact two-file/no-symlink layout, both binaries' independent SHA-256 values and strict code signatures, release checksums and reviewed hashes for `release-common.sh` plus `generate-appcast.sh`. It freshly extracts checksum-pinned official tools, validates each required tool's strict code signature, proves private/public-key identity only through the prebuilt deriver and signs. Signing-boundary `generate-appcast.sh` requires that exact deriver path and hash and cannot fall back to source interpretation. After official EdDSA verification and before `xmllint` or `generate_appcast` can parse or normalize retained bytes, the fixed signing path runs the prebuilt app-identical XML validator. It repeats that policy on the generated cryptographically verified feed, then uploads the exact accepted bytes with bound size/SHA-256 before any mutable repository validation executes. `validate-signed-appcast` downloads both that immutable feed artifact and the original reviewed two-file helper artifact, rebinds their REST identities, independent hashes, layout and code signatures, and validates only a disposable no-key copy; it has no implicit Swift or SwiftPM build fallback. A fresh no-checkout `stage-pages-artifact` runner re-downloads the original signing artifact, rebinds its REST identity/size/SHA-256 and uploads an attempt-qualified Pages artifact. Secret-free `publish-release` resumes or creates the draft Release, verifies every remote byte, publishes and anonymously verifies all five exact-ID-bound assets. Read-only `admit-appcast-deployment` rechecks the immutable tag, CI, Release bytes and Pages artifact ID/name/digest without Pages/OIDC authority. Finally, `deploy-appcast` receives Pages/OIDC write permission but performs no checkout or shell execution; its sole step is the pinned `deploy-pages` action selecting the admitted attempt-qualified artifact. A false run stops after Release publication: it never builds or downloads the signing validators, downloads signing inputs, starts `update-feed-signing`, reads the key, creates Pages bytes or reaches deployment.

Before extending update history, the current production feed stays opaque and within the 1,048,576-byte authenticated-prefix plus 512-byte trailer wire bound until the official upstream Sparkle 2.9.5 `sign_update --verify` tool authenticates the complete bytes; only then is the exact signed prefix passed to the shared XML policy. The matching runtime framework advertises `SUFeedDownloadSizeLimitVersion=1`, rejects a declared `Content-Length` above the 1,049,088-byte total before buffering, and enforces that same total incrementally for chunked or otherwise undeclared appcast responses. Those feed-only limits do not cap persistent update-archive/ZIP downloads. The repository's unsigned `updates/v1/appcast.xml` seed admission is fail-closed and bound only to exact 0.1.4 (build 5). It never admits 0.1.2, 0.1.3, an arbitrary newer identity or a release merely because production returned HTTP 404. The admitted seed requires the v1 production URL to return HTTP 404, exactly one fixed Ushot channel with zero update items, and byte-for-byte equality with the committed seed. Every later 404 is fatal, while the legacy `/updates/appcast.xml` remains intentionally and permanently 404. Any authenticated existing v1 feed with duplicate/misplaced metadata, a noncanonical RSS/Sparkle namespace or hierarchy, DTD/entity declarations, unrestricted description content, `releaseNotesLink`, item-level `link`, `fullReleaseNotesLink`, deltas, or anything other than exactly one nonempty restricted-Markdown `description` per item fails closed and is never normalized, rewritten or re-signed automatically. The new version and build must each compare strictly greater than every retained item using overflow-safe component/decimal comparison. GitHub's asset digest is checked when present. If GitHub omits that field, the verifier downloads the asset and recomputes SHA-256 instead of treating size or HTTPS as sufficient proof.

For a local packaging dry run that does not publish anything:

```bash
scripts/build-release.sh \
  --mode public-adhoc \
  --version 0.1.11 \
  --build-number 12

scripts/package-release.sh \
  --mode public-adhoc \
  --version 0.1.11 \
  --build-number 12 \
  --tag v0.1.11
```

## Exact release assets

The immutable published [`v0.1.10`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.10) GitHub Release (id `376843513`, published `2026-08-26T02:29:07Z`) contains exactly the following:

```text
Ushot-0.1.10-arm64.dmg
Ushot-0.1.10-arm64.zip
Ushot-0.1.10-arm64.dSYM.zip
Ushot-0.1.10-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`32922355161`](https://github.com/isCheneycc/ushot/actions/runs/32922355161) attempt 1 completed all 11 jobs on 2026-08-26 with `publish_update_feed=true`. Release PR [`#22`](https://github.com/isCheneycc/ushot/pull/22) and exact protected-main CI push run [`32921770545`](https://github.com/isCheneycc/ushot/actions/runs/32921770545) preceded the immutable tag; annotated tag object `582e396864eb69df7ee459797a8196b54e182a81` peels to commit `9fbe22c00d4fe17fb1a841b9c04e9dc7814ad1b9`. The exact public files are:

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `Ushot-0.1.10-arm64.dmg` | 4,668,916 | `bb3c62d29637d369084815e279a715eac121a6fdbb3fe5bb206ac5b261ebadfa` |
| `Ushot-0.1.10-arm64.zip` | 4,228,271 | `97ed75f771ac99e10bd929c864bffadc4b9b51f001f0cf2c265151d5cf3646d9` |
| `Ushot-0.1.10-arm64.dSYM.zip` | 5,969,086 | `67808964da11500acd99c17aa5f2ea2e8b5366c90c86a93dadcf1cc8d7d567e1` |
| `Ushot-0.1.10-arm64.release-manifest.json` | 896 | `2e1c0b488130e2d130e91bf3ade314affd63b51e71077ecec64a0eef8b87a485` |
| `SHA256SUMS.txt` | 379 | `8677fabcab9ab4543d37165db1793e82a8a90c805db11f9a81a07ae85d2f698b` |

The workflow and a separate anonymous post-publication download both validated that exact five-asset set, including the complete ZIP/dSYM/DMG/manifest validator. Authenticated-appcast artifact `9590375415` has REST digest `sha256:00f3da9d2ea7292b7b90e604327240ee299ec80b8529bb78e233ccc832425cc4`; Pages artifact `9590394247` has REST digest `sha256:dc70b8e6162f0e42736879e70b403e8683d54cdc8990bfd359f693d07b6a596e`. Their appcast XML and the live 7,453-byte feed match byte-for-byte at SHA-256 `eb0b9073ea557f52f6ef983a204a98734a1563e7211c81aaf9778e30ad1ffd9e`; its identities are exactly 0.1.10/11, 0.1.9/10, 0.1.6/7, 0.1.5/6 and 0.1.4/5, while direct-download-only 0.1.7/0.1.8 remain absent. Independent Ed25519 verification and tamper rejection passed. Pages deployment `6095886078` reached success status `17338052537` at `2026-08-26T02:30:41Z`, and the legacy endpoint remains HTTP 404. The `release`, `update-feed-signing` and `github-pages` environment allowlists each admit only exact tag `v0.1.10`; repository, `release` and `github-pages` have zero secrets, and only `update-feed-signing` contains the unchanged `SPARKLE_ED25519_PRIVATE_KEY` secret.

The immutable published [`v0.1.9`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.9) GitHub Release (id `376238822`, published `2026-08-25T08:04:57Z`) contains exactly the following:

```text
Ushot-0.1.9-arm64.dmg
Ushot-0.1.9-arm64.zip
Ushot-0.1.9-arm64.dSYM.zip
Ushot-0.1.9-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`32824113225`](https://github.com/isCheneycc/ushot/actions/runs/32824113225) attempt 1 completed all 11 jobs on 2026-08-25 with `publish_update_feed=true`. Release PR [`#20`](https://github.com/isCheneycc/ushot/pull/20) and exact protected-main CI push run [`32823428509`](https://github.com/isCheneycc/ushot/actions/runs/32823428509) preceded the immutable tag; annotated tag object `a5b78f45a39744d418c689b729805a58d7d07383` peels to commit `14d590d4f226c84d4c849938d0dcb1bbfa557f11`. The exact public files are:

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `Ushot-0.1.9-arm64.dmg` | 4,665,899 | `772035ed7b3bfa3f4fa4437268f5679f0536f83ef9737d40a2e799b284583778` |
| `Ushot-0.1.9-arm64.zip` | 4,225,135 | `ec7449e1b565187eadfde915dea3931024f872172320cb95261bb33e6312df38` |
| `Ushot-0.1.9-arm64.dSYM.zip` | 5,958,953 | `0acf83bfcdeb2604bf4311d01bea43d7517828bd6f68c0c8461da7ea37cc7786` |
| `Ushot-0.1.9-arm64.release-manifest.json` | 891 | `2c6a1c50519b2287ca7fd4772fbd8a7874cf78711e25557fdc32529b97f3a2a8` |
| `SHA256SUMS.txt` | 375 | `09e0a4989e52cf540c7a6f916eef3670e90c126b4789f7b282ffaace3a2a5188` |

The workflow and a separate anonymous post-publication download both validated that exact five-asset set. The preserved authenticated appcast artifact and the live 6,188-byte feed match byte-for-byte at SHA-256 `7094c65e1fe5103b3c428ab2448f7c54831767a1db02c9ed99eae1a30db5cbad`; its identities are exactly 0.1.9/10, 0.1.6/7, 0.1.5/6 and 0.1.4/5. Local post-deploy runtime-policy validation passed, Pages deployment `6079064353` completed successfully, and the legacy endpoint remains HTTP 404. The `release`, `update-feed-signing` and `github-pages` environment allowlists each admit only exact tag `v0.1.9`; repository, `release` and `github-pages` have zero secrets, and only `update-feed-signing` contains the unchanged `SPARKLE_ED25519_PRIVATE_KEY` secret.

The immutable published [`v0.1.8`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.8) GitHub Release contains exactly the following:

```text
Ushot-0.1.8-arm64.dmg
Ushot-0.1.8-arm64.zip
Ushot-0.1.8-arm64.dSYM.zip
Ushot-0.1.8-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`32817346826`](https://github.com/isCheneycc/ushot/actions/runs/32817346826) attempt 1 completed on 2026-08-25 with `publish_update_feed=false`, published this exact set, verified all five assets through the anonymous public boundary and completed with exactly five successful jobs while all six signing, feed-validation and Pages jobs were skipped. The SHA-256 values are DMG `c4cc8aac2f169ef0ecf0817fafb874e402c4aae1794b854bd0204ac23e56a402`, app ZIP `c47e86713c977054fddcdb3f882f4c891e2152f2538885a4f81bdfd9b74ffccc`, dSYM ZIP `9f881a41d17b203d09dee3c8d52c42cf0b919553bafa163c0a274ce9ec14635f`, manifest `036e6f9cb562214cd89819351f00af0d14f846c050175b4c09983c99986f4a67`, and checksums `ce2bab98d9cd1a56d88667dc80a1cce5521f1e6f5d5a245e504cfb9b4b2a67b3`. Independent post-publication verification anonymously downloaded the five public assets again and passed the complete ZIP/dSYM/DMG/manifest validator. The annotated tag object `1fdd026ca4be507f7264d16d5d60b0bf1ecb59fb` peels to protected-main commit `5178c91472b835a8e885591d72b1a2095f9fd6d9`. The production v1 appcast remained byte-identical at SHA-256 `1b1f504c0e746d6509e6d6f4735c3b7d55914c79daf8535cdabb6912aa088225`, still serving 0.1.6 (build 7) over HTTP 200, and the legacy appcast remained HTTP 404.

The immutable published [`v0.1.7`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.7) GitHub Release contains exactly the following:

```text
Ushot-0.1.7-arm64.dmg
Ushot-0.1.7-arm64.zip
Ushot-0.1.7-arm64.dSYM.zip
Ushot-0.1.7-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`32689508333`](https://github.com/isCheneycc/ushot/actions/runs/32689508333) published this exact set on 2026-08-24 with `publish_update_feed=false`, verified all five assets through the anonymous public boundary and skipped every signing, feed-validation and Pages job. The SHA-256 values are DMG `d58ca182211ee3ba77f0f01a329e490a57fb043135c228d2817bae4a9e104b14`, app ZIP `f7cd1d87d9d72378613f7a55dfeaddec7decead0ae4269c57a2a67eaf6c93e69`, dSYM ZIP `c9abe2779b89b79a329284d5b562f8266dd5060481d512f7a1fdea4973cc9b42`, manifest `b8d80974a1f4ef4b92df01ae3d9a5cb181e1b8a4352c0999c7830007f77e3df8`, and checksums `3ceb84a3bb060e77318d9d0486ac5158fff3161740df6ad07f1dfb727c64c35b`. Independent post-publication verification downloaded the five public assets again and revalidated the complete set. The production v1 appcast remained byte-identical at SHA-256 `1b1f504c0e746d6509e6d6f4735c3b7d55914c79daf8535cdabb6912aa088225`, still serving 0.1.6 (build 7), and the legacy appcast remained HTTP 404.

The immutable published [`v0.1.6`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.6) GitHub Release contains exactly the following:

```text
Ushot-0.1.6-arm64.dmg
Ushot-0.1.6-arm64.zip
Ushot-0.1.6-arm64.dSYM.zip
Ushot-0.1.6-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`31864175412`](https://github.com/isCheneycc/ushot/actions/runs/31864175412) published this exact set on 2026-08-15 with `publish_update_feed=true`, verified all five assets through the anonymous public boundary and extended the authenticated v1 feed. The SHA-256 values are DMG `bce6a4ee94d3e5199adc2d495722af8920698907937b18ee9f40a1399d2016cc`, app ZIP `eeed6d5001499ccff32bbfe46d16bdfb1d6469797221f4a68af82702a8c8268d`, dSYM ZIP `a10ad3dff16b7e1de0036a01f1c63294a272fb53c78fe248471055ba11685282`, manifest `7ea03f1f6a63059120e03a5b0671f25672592b1f59ece73847f6d6e6c65be166`, and checksums `06a8d3b210c92cb5f3bbdf02721936acd0dc5edaf47f34781b707d6490662a8f`. Independent post-deployment verification authenticated the live appcast with the embedded Ed25519 public key and the app-identical raw-XML validator; its SHA-256 was `1b1f504c0e746d6509e6d6f4735c3b7d55914c79daf8535cdabb6912aa088225`. The legacy appcast remained HTTP 404.

The immutable published `v0.1.2` GitHub Release contains exactly the following:

```text
Ushot-0.1.2-arm64.dmg
Ushot-0.1.2-arm64.zip
Ushot-0.1.2-arm64.dSYM.zip
Ushot-0.1.2-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`31019244714`](https://github.com/isCheneycc/ushot/actions/runs/31019244714) published this exact set on 2026-08-06 and verified all five assets through the anonymous public boundary. A separate no-credential download matched the GitHub digests and passed the complete local asset validator. The SHA-256 values are DMG `19972a5b7b27f5f0a10bad5ff0839807cf1f339a6537fac4b3fffb1207444fdd`, app ZIP `c9dd0d376362d5a0f38a540553c134d5f6ddddaf1b341bc9084cd7325e6c411d`, dSYM ZIP `29e008d2c2f27023b4574ee59db057e46b18897efc01d157043d458ddfa39776`, manifest `f47f180e566a6bd69fd026c17b4fd7675f4786ad9c349f10604b2901104cff20`, and checksums `7e51853ef899118bfe4e0fbc8d1b855925eafa4f7d0ddfeb8179958f5cab116a`. Both feed endpoints still returned HTTP 404 after publication, so this evidence does not claim updater readiness.

The immutable published [`v0.1.3`](https://github.com/isCheneycc/ushot/releases/tag/v0.1.3) GitHub Release contains exactly the following:

```text
Ushot-0.1.3-arm64.dmg
Ushot-0.1.3-arm64.zip
Ushot-0.1.3-arm64.dSYM.zip
Ushot-0.1.3-arm64.release-manifest.json
SHA256SUMS.txt
```

Protected workflow run [`31078896953`](https://github.com/isCheneycc/ushot/actions/runs/31078896953) published this exact set on 2026-08-06 with `publish_update_feed=false` and verified all five assets through the anonymous public boundary. The SHA-256 values are DMG `223041e8b60321572a5952183331de4e13101ad119cd39b36244ddb7aef58349`, app ZIP `91b4fbe2c40826aec909cb38f3fea5e2056e40b5dfc2fbe54b3efeb1d687efc8`, dSYM ZIP `d540d593a7b745b3068792cd0dd296c8aea74e7792031ffdb29b4cfc18c9854f`, manifest `78410b923978e825083c164db9c308f37b3c7062d81899d9e173911a951529c0`, and checksums `19ba42accdad1c288966bc947f9905a9bc70b79e172a3a09b11f47cba30a99cf`. Both the legacy and v1 appcast URLs remained HTTP 404, and the signing, feed-validation and Pages jobs were skipped. This makes 0.1.3 available for direct download and manual installation; it is not evidence that in-app update is active.

- DMG: first installation only; it contains `Ushot.app` and an `/Applications` link.
- ZIP: contains the app bundle and becomes the only full Sparkle enclosure only when a feed-enabled run signs it into the appcast. In a direct-download-only run it is simply a validated Release asset and is not evidence of updater readiness.
- dSYM ZIP: archived symbols whose UUIDs must match the shipped executable.
- Manifest: product, bundle, version, build, tag, architecture, signature mode and per-asset hashes.
- Checksums: SHA-256 for the DMG, update ZIP, dSYM ZIP and manifest.

When `publish_update_feed=true`, the generated Pages payload contains only the signed `updates/v1/appcast.xml`. Each item carries exactly one nonempty restricted-Markdown `description`; there are no separately deployed or preserved release-note files. Before propagation, every retained raw item must have exact RSS/Sparkle namespaces and hierarchy, unique canonical metadata, no DTD/entity declarations, exactly one full enclosure whose URL is byte-identical to the canonical versioned official GitHub Release URL, and no link-like description content, item-level `releaseNotesLink`, `link`, `fullReleaseNotesLink` or delta enclosure. The false path creates no Pages payload, and no workflow may publish the legacy `updates/appcast.xml` path.

## First-install instructions

Only direct users to assets on the official GitHub Release. After dragging Ushot into Applications, use the narrow quarantine removal command:

```bash
xattr -d com.apple.quarantine /Applications/Ushot.app
open /Applications/Ushot.app
```

Do not recommend `xattr -cr`: it removes all extended attributes, not just quarantine. The public DMG and enclosed app are not notarized, so macOS trust prompts are expected.

## Mandatory release verification

Automation proves artifact identity, versions, hashes and publication ordering. Before announcing a direct-download preview, use a clean macOS 14+ account and verify:

- initial DMG install and the documented quarantine command;
- Screen Recording grant and denial behavior;
- relaunch, capture modes, annotation, copy/save/pin, history and login item behavior on the supported hardware selected for the preview.

Those checks admit only the direct-download Release. They preserve 0.1.2 as the published first manual transition and admitted 0.1.3 only as the published second manual transition, never as a feed. The completed 0.1.3 prepublication gate additionally required the three host booleans, exact `SUMaximumSignedAppcastContentLength=1048576`, all three framework markers, live hook ownership, pipeline duplicate/wrong-namespace/DTD/entity rejection, declared and streamed/chunked appcast oversize rejection, feed-cap exemption for persistent archives, and fail-closed missing/wrong configuration fixtures. Before the first `publish_update_feed=true` run for 0.1.4 (build 5), the separate 0.1.3 → 0.1.4 updater matrix passed the following checks; keep them as the regression basis for later feed extensions:

- the built 0.1.3 three required host booleans, exact `SUMaximumSignedAppcastContentLength=1048576`, all three embedded framework capability markers and authenticated-XML hook, including fail-closed missing/wrong-policy and owner-loss fixtures;
- an isolated-loopback HTTPS run that keeps the exact production feed URL and canonical signed enclosure URL without deploying Pages or modifying `SUFeedURL`;
- a real 0.1.3 → 0.1.4 Sparkle update;
- Sparkle Helper launch and atomic replacement of `/Applications/Ushot.app`;
- validly signed duplicate/misplaced/wrong-namespace/DTD/entity raw-feed rejection before item parsing; declared-`Content-Length` and streamed/chunked rejection above the 1,049,088-byte appcast wire ceiling; confirmation that a larger persistent ZIP remains eligible; plus signed-feed, tampered-ZIP, failed/missing archive EdDSA and exact extracted short/build mismatch rejection;
- offline, interrupted download, insufficient disk and GitHub outage behavior;
- permission reauthorization and multiple-display behavior after replacement;
- recovery of the EdDSA key from the independent encrypted backup without exposing it.

That two-version matrix passed before 0.1.4 became the first production feed item. Screen Recording permission may need to be granted again after public updates because ad-hoc identity continuity is not guaranteed.

## Failure recovery

- Do not delete a partial draft and do not move or recreate its tag. From the same workflow run, choose **Re-run failed jobs**. The preserved artifacts are retained for 30 days; publication validates the draft metadata and every existing expected asset, rejects unexpected or mismatched bytes, uploads only missing assets, verifies the complete set, and then publishes.
- If a run fails before draft creation because the immutable tag contains defective source or tooling, preserve the tag and failed run as evidence. Fix the root cause through protected `main`, increment both the marketing version and build number, pass CI, and create a new tag. Do not rerun the old tag expecting its source to change, move or recreate it, or describe that candidate as published. Keep the failed tag out of every protected environment's exact-tag allowlist.
- If a retry finds a published Release with the exact expected assets, it performs no Release mutation and continues safely. A published Release that is incomplete or mismatched fails closed and requires investigation; the workflow never overwrites it.
- In a `publish_update_feed=true` run, if `admit-appcast-deployment` succeeded but the final Pages action failed, rerun only the failed `deploy-appcast` job from the same workflow run. It selects the already admitted attempt-qualified Pages artifact by its preserved name and does not checkout source, rebuild, re-sign, overwrite published assets or recreate the tag. If admission itself failed, rerun failed jobs so the read-only admission checks execute again before deployment. A false run has no Pages job to recover.
- If the workflow artifacts have expired, stop and investigate instead of attempting to reconstruct supposedly identical bytes in a new run. DMG and ZIP creation are not assumed to be reproducible.
- Never hand-edit the generated signed appcast or extract and republish its embedded descriptions. Any byte change invalidates signed-feed authenticity; regenerate it through the protected workflow.
- Only exact 0.1.4 (build 5) may interpret a v1 appcast HTTP 404 as seed bootstrap. Every later v1 404 fails instead of silently resetting update history; the legacy endpoint remains intentionally absent and is never a seed input.
- If the production appcast fails EdDSA verification or the raw-XML/embedded-notes structural policy, stop publishing and investigate possible Pages, pipeline or key compromise; the workflow must never normalize or re-sign that input.

## Future Developer ID path

This path is deferred and is not required for the current ad-hoc rollout. The reviewed runtime fork requires archive EdDSA independently of application code signing, but Developer ID distribution remains disabled until that behavior has Developer-ID-specific built/runtime evidence. Before enabling `developer-id`, add a regression that corrupts only the archive EdDSA signature while preserving a valid Developer ID identity, and repeat the complete transition matrix; notarization cannot replace that result.

If that evidence is completed and the Apple Developer Program is joined, preserve the Bundle ID, Sparkle public key and key account. Then configure `DEVELOPER_ID_APPLICATION` and `DEVELOPMENT_TEAM` and test the explicit future path:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)'
export DEVELOPMENT_TEAM='TEAMID'
xcrun notarytool store-credentials 'ushot-notary' \
  --apple-id 'developer@example.com' \
  --team-id "$DEVELOPMENT_TEAM"
export NOTARYTOOL_KEYCHAIN_PROFILE='ushot-notary'
scripts/build-release.sh --mode developer-id
scripts/package-dmg.sh --mode developer-id
scripts/notarize.sh build/release/developer-id/artifacts/Ushot-X.Y.Z-arm64.dmg
```

`scripts/notarize.sh` accepts only the named keychain profile; it does not accept raw Apple ID, app-specific-password or team variables. Do not enable this path in the public workflow until strict archive EdDSA, Developer ID signing, notarization, stapling, Gatekeeper assessment and an update transition from the ad-hoc release have all passed end-to-end testing.
