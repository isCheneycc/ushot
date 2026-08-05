# Releasing Ushot

Ushot currently has no Developer ID certificate. Public builds are distributed from GitHub as intentionally ad-hoc signed, unnotarized artifacts. Local development and the installed `/Applications/Ushot.app` use a separate, stable Apple Development signature so routine development does not continuously invalidate Screen Recording authorization.

The stable update feed is:

```text
https://ischeneycc.github.io/ushot/updates/appcast.xml
```

The first public installation requires the user to remove quarantine explicitly. Direct-download GitHub Releases and production Sparkle updates have separate readiness gates. Ushot 0.1.1 is the first direct-download preview while its production appcast remains absent; in that state **Check for Updates…** stays visible and reports a feed failure. Once the updater gate is separately approved, subsequent updates are delivered by Sparkle 2.9.5 and the complete appcast plus each update archive are authenticated with Ushot's EdDSA key.

## Security invariants

Every release command enforces the applicable invariants below. The appcast, production-version monotonicity and EdDSA-signing bullets apply only to an explicit `publish_update_feed=true` run; `publish_update_feed=false` deliberately creates no appcast.

- Product: `Ushot.app`
- Bundle identifier: `io.github.ischeneycc.ushot`
- Architecture: `arm64`
- Stable tag: `v<MARKETING_VERSION>`
- Build: positive integer matching `CURRENT_PROJECT_VERSION`
- Workflow run ref, requested tag, local tag, remote tag and `GITHUB_SHA` all resolve to the same commit, and the local/remote tag object SHA also matches for annotated tags
- The tagged commit is an ancestor of protected `main` and has a successful `CI` push run on `main`
- Sparkle account: `io.github.ischeneycc.ushot`
- Feed: `https://ischeneycc.github.io/ushot/updates/appcast.xml`
- No executable contains `com.apple.security.get-task-allow=true`
- Public app is ad-hoc signed, has no Team ID or Apple Development authority, and has Hardened Runtime disabled
- Local installed app has a stable Apple Development authority and Team ID
- The complete appcast passes Sparkle signed-feed verification, and every full enclosure independently contains a valid EdDSA signature
- Every non-seed item has exactly one nonempty restricted-Markdown `description` with `sparkle:format="markdown"`; links, images, raw HTML, autolinks, entities, URL/domain/network-address-like destinations, item-level `releaseNotesLink`, `link`, `fullReleaseNotesLink` and delta enclosures are absent
- Appcast short/build versions, tag, filenames and the `CFBundleShortVersionString`/`CFBundleVersion` extracted from the final ZIP agree exactly
- The new stable semantic version and positive decimal build number are each strictly greater than every retained item in the authenticated production appcast
- An existing production feed passes Sparkle's cryptographic verification and the embedded-notes structural policy before it is extended or redeployed; a detached-notes feed is rejected rather than migrated automatically
- The signing job has only read access to repository contents; the publishing job has repository write access but never receives the Sparkle private key
- Every release-workflow checkout disables persisted GitHub credentials, and every action used by that workflow is pinned to a full commit SHA
- The default `publish_update_feed=false` path still builds, validates, publishes and anonymously download-verifies exactly the five Release assets, but does not fetch Sparkle tools or the current feed, read the EdDSA private key, create a Pages artifact or run `deploy-appcast`
- Only `publish_update_feed=true` may sign and deploy the production feed, and that opt-in does not waive the key-recovery drill, client-side enclosed-version fix or clean-account update matrix

Disabling Hardened Runtime is deliberate **only** for `public-adhoc`: Sparkle documents that an ad-hoc host can fail to load Sparkle when Library Validation is enabled. `local-signed` and the future `developer-id` mode keep Hardened Runtime enabled. The scripts never recursively re-sign Sparkle with `codesign --deep`.

The archive-version check above is a protected publication gate, not a client-side equivalent. Sparkle 2.9.5 does not expose the extracted application URL through a public pre-install delegate and does not compare both enclosed bundle versions with the appcast before installation. Keep production self-update blocked until an upstream version or a reviewed hardening closes that gap; a successful CI run alone cannot waive it.

## One-time GitHub setup

1. Create the public repository `isCheneycc/ushot`.
2. Protect `main`, require the `CI` workflow, require pull requests, and do not permit release operators to bypass those rules.
3. Create a tag ruleset for `v*` that blocks updates and deletion. Tag protection is mandatory: a published tag is immutable.
4. Create a protected GitHub Environment named `release`, add required reviewers, and use exact tag deployment rules. Add only the tag currently approved for publication, such as `v0.1.1`; never use a `v*` wildcard. A failed or superseded tag stays permanently absent from this allowlist because its immutable workflow source cannot be revoked from `main`.

Those four steps are sufficient for `publish_update_feed=false`. Before any `publish_update_feed=true` run:

5. In Settings → Pages, select **GitHub Actions** as the source. Configure the generated `github-pages` environment with the same exact approved-tag policy; never allow a failed, superseded or wildcard tag.
6. Add `SPARKLE_ED25519_PRIVATE_KEY` to the `release` environment's secrets. Its value is the private key exported from the Sparkle keychain account below—not the public key from `Base.xcconfig`.

The Ushot-specific Sparkle account already used locally is:

```text
io.github.ischeneycc.ushot
```

All Sparkle tool invocations must pass that account explicitly. To export the private key for the protected secret, download the checksum-pinned tools and write the export directly to a secure location:

```bash
SPARKLE_BIN="$(scripts/download-sparkle-tools.sh | tail -n 1)"
"$SPARKLE_BIN/generate_keys" \
  --account io.github.ischeneycc.ushot \
  -x /path/to/encrypted/ushot-sparkle-private-key
```

Keep at least one separate encrypted offline backup. Never commit, log, paste into an issue, or pass the key as a command-line argument. CI injects the GitHub secret through standard input using `--ed-key-file -`; it never writes the key into the repository or an artifact. Losing this key while Ushot has no Developer ID fallback can strand every existing installation on its current update trust chain.

## Local stable build and installation

Create an Apple Development certificate in Xcode → Settings → Accounts → Manage Certificates. Copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and set the correct Team ID.

```bash
scripts/build-release.sh --mode local-signed
scripts/package-dmg.sh --mode local-signed
scripts/install-local.sh
```

The build and installer reject ad-hoc signatures, missing Team IDs, non-Apple-Development identities, missing designated requirements, mismatched dSYMs and incompatible replacement identities. Use this override only for one intentional identity migration:

```bash
ALLOW_SIGNING_IDENTITY_MIGRATION=YES scripts/install-local.sh
```

Never install a `public-adhoc` build over the local signed `/Applications/Ushot.app` used for development.

## Preparing a public release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`. Both values must match the release tag and final bundle. A feed-enabled release additionally requires both the stable semantic version and positive decimal build to be strictly greater than every retained item in the signed production appcast.
2. Add nonempty restricted-Markdown source notes at `updates/release-notes/<version>.md`. Links, images, raw HTML, autolinks, entities and URL/domain/network-address-like destinations are forbidden. Do not add Sparkle signing comments or appcast elements yourself.
3. Run the relevant tests and the direct-install manual checks. The complete old-version → new-version updater matrix is additionally mandatory before `publish_update_feed=true`.
4. Commit the exact release source.
5. Merge the release commit into protected `main`, wait for the `CI` push run on that exact commit to succeed, then create and push an immutable tag matching the version exactly, for example `v0.1.1`.
6. Add that exact tag to the protected `release` environment's deployment rules and confirm failed or superseded tags remain excluded. Then dispatch **Protected release** at the tag ref, not at `main`. The ref and the `tag` input must be identical:

   ```bash
   TAG=v0.1.1
   BUILD_NUMBER=2
   gh workflow run release.yml \
     --ref "$TAG" \
     -f tag="$TAG" \
     -f build_number="$BUILD_NUMBER" \
     -f publish_update_feed=false
   ```

7. Approve the protected `release` environment only after comparing the run ref, requested tag, bound commit SHA and successful CI run.

For 0.1.1, keep `publish_update_feed=false`. This publishes the five immutable direct-download assets, verifies every remote byte, and downloads all five again through the anonymous public boundary. It skips Sparkle tool download, current-feed access, private-key signing, Pages artifact creation and `deploy-appcast`. **Check for Updates…** remains visible in the app and reports a feed failure until the production feed is activated.

Only after the independent encrypted key recovery drill, client-side enclosed-version gap and complete clean-account updater matrix are closed may an operator dispatch the feed path:

```bash
TAG=vX.Y.Z
BUILD_NUMBER=N
gh workflow run release.yml \
  --ref "$TAG" \
  -f tag="$TAG" \
  -f build_number="$BUILD_NUMBER" \
  -f publish_update_feed=true
```

The workflow has four capability boundaries. Read-only preflight binds the run ref, input, tag, commit, protected-main ancestry and successful CI run. The protected `release` job always builds `public-adhoc`, packages the exact assets, extracts the final ZIP and dSYM, mounts the final DMG read-only, and revalidates the contained app identity/signature, dSYM UUIDs, exact DMG root and `/Applications` link; every app executable must resolve the embedded Sparkle framework through `@executable_path/../Frameworks`. Validating the pre-archive build directory alone is insufficient. With `publish_update_feed=true`, the same read-only job also runs Sparkle `generate_appcast --embed-release-notes` to create the enclosure EdDSA signature and sign the complete appcast. It uploads immutable release results to a workflow artifact; no repository write token exists in that job. A separate job, which has no signing secret, recovers the artifact, rechecks remote tag and CI admission, resumes or creates a draft GitHub Release, verifies every remote byte, publishes, and anonymously verifies all five assets. The final `github-pages` job exists only for the true path and exposes the already-signed appcast after the stable Release is verified.

Before extending update history, Sparkle's official `sign_update --verify` validates the complete current production feed. The repository's existing unsigned-seed admission is fail-closed and restricted to the historical `0.1.0` build `1` candidate. That candidate never published an appcast and is permanently tombstoned by keeping `v0.1.0` out of the protected `release` environment's exact-tag allowlist; reviewers must never approve it. This environment rule is authoritative because changing `main` cannot revoke workflow source already attached to an immutable old tag. Before the first future `publish_update_feed=true` release, a separate reviewed change must bind seed admission to that exact newer version and build; it must never accept an arbitrary release merely because production returned HTTP 404. The admitted seed still requires an explicit production HTTP 404, exactly one fixed Ushot channel with zero update items, and a byte-for-byte comparison with the committed seed. Every later 404 is fatal. Any existing feed with a noncanonical RSS/Sparkle namespace or hierarchy, unrestricted description content, `releaseNotesLink`, item-level `link`, `fullReleaseNotesLink`, deltas, or anything other than exactly one nonempty restricted-Markdown `description` per item fails closed and is never rewritten or re-signed automatically. The new version and build must each compare strictly greater than every retained item using overflow-safe component/decimal comparison. GitHub's asset digest is checked when present. If GitHub omits that field, the verifier downloads the asset and recomputes SHA-256 instead of treating size or HTTPS as sufficient proof.

For a local packaging dry run that does not publish anything:

```bash
scripts/build-release.sh \
  --mode public-adhoc \
  --version 0.1.1 \
  --build-number 2

scripts/package-release.sh \
  --mode public-adhoc \
  --version 0.1.1 \
  --build-number 2 \
  --tag v0.1.1
```

## Exact release assets

For version `0.1.1`, the GitHub Release contains exactly:

```text
Ushot-0.1.1-arm64.dmg
Ushot-0.1.1-arm64.zip
Ushot-0.1.1-arm64.dSYM.zip
Ushot-0.1.1-arm64.release-manifest.json
SHA256SUMS.txt
```

- DMG: first installation only; it contains `Ushot.app` and an `/Applications` link.
- ZIP: contains the app bundle and becomes the only full Sparkle enclosure only when a feed-enabled run signs it into the appcast. In the direct-download preview it is simply a validated Release asset and is not evidence of updater readiness.
- dSYM ZIP: archived symbols whose UUIDs must match the shipped executable.
- Manifest: product, bundle, version, build, tag, architecture, signature mode and per-asset hashes.
- Checksums: SHA-256 for the DMG, update ZIP, dSYM ZIP and manifest.

When `publish_update_feed=true`, the generated Pages payload contains only the signed `updates/appcast.xml`. Each item carries exactly one nonempty restricted-Markdown `description`; there are no separately deployed or preserved release-note files. Before propagation, every retained item must have exact RSS/Sparkle namespaces and hierarchy, exactly one full enclosure whose URL is byte-identical to the canonical versioned official GitHub Release URL, and no link-like description content, item-level `releaseNotesLink`, `link`, `fullReleaseNotesLink` or delta enclosure. The false path creates no Pages payload.

## First-install instructions

Only direct users to assets on the official GitHub Release. After dragging Ushot into Applications, use the narrow quarantine removal command:

```bash
xattr -dr com.apple.quarantine /Applications/Ushot.app
open /Applications/Ushot.app
```

Do not recommend `xattr -cr`: it removes all extended attributes, not just quarantine. The public DMG and enclosed app are not notarized, so macOS trust prompts are expected.

## Mandatory release verification

Automation proves artifact identity, versions, hashes and publication ordering. Before announcing a direct-download preview, use a clean macOS 14+ account and verify:

- initial DMG install and the documented quarantine command;
- Screen Recording grant and denial behavior;
- relaunch, capture modes, annotation, copy/save/pin, history and login item behavior on the supported hardware selected for the preview.

Those checks admit only the direct-download Release. Before `publish_update_feed=true`, the separate updater matrix must also verify:

- a real previous-version → new-version Sparkle update;
- Sparkle Helper launch and atomic replacement of `/Applications/Ushot.app`;
- signed-feed and tampered-ZIP rejection;
- offline, interrupted download, insufficient disk and GitHub outage behavior;
- permission reauthorization and multiple-display behavior after replacement.

Until that two-version matrix succeeds, the ad-hoc Sparkle updater remains blocked even when the GitHub Release is downloadable. Screen Recording permission may need to be granted again after public updates because ad-hoc identity continuity is not guaranteed.

## Failure recovery

- Do not delete a partial draft and do not move or recreate its tag. From the same workflow run, choose **Re-run failed jobs**. The preserved artifacts are retained for 30 days; publication validates the draft metadata and every existing expected asset, rejects unexpected or mismatched bytes, uploads only missing assets, verifies the complete set, and then publishes.
- If a run fails before draft creation because the immutable tag contains defective source or tooling, preserve the tag and failed run as evidence. Fix the root cause through protected `main`, increment both the marketing version and build number, pass CI, and create a new tag. Do not rerun the old tag expecting its source to change, move or recreate it, or describe that candidate as published. Keep the failed tag out of every protected environment's exact-tag allowlist.
- If a retry finds a published Release with the exact expected assets, it performs no Release mutation and continues safely. A published Release that is incomplete or mismatched fails closed and requires investigation; the workflow never overwrites it.
- In a `publish_update_feed=true` run, if the GitHub Release published successfully but Pages deployment failed, rerun only the failed `deploy-appcast` job from the same workflow run. It reuses the preserved `github-pages` artifact, rechecks the immutable tag and published asset bytes, and does not rebuild, re-sign, overwrite published assets or recreate the tag. A false run has no Pages job to recover.
- If the workflow artifacts have expired, stop and investigate instead of attempting to reconstruct supposedly identical bytes in a new run. DMG and ZIP creation are not assumed to be reproducible.
- Never hand-edit the generated signed appcast or extract and republish its embedded descriptions. Any byte change invalidates signed-feed authenticity; regenerate it through the protected workflow.
- If the appcast is unavailable with anything other than an explicit first-release 404, publishing fails instead of silently resetting update history.
- If the production appcast fails EdDSA verification or the embedded-notes structural policy, stop publishing and investigate possible Pages or key compromise; the workflow must never normalize or re-sign that input.

## Future Developer ID path

This path is currently blocked independently of Apple Developer membership. Sparkle 2.9.5 can accept a matching Developer ID code signature when EdDSA validation of an ordinary ZIP enclosure fails. That fallback conflicts with Ushot's rule that every update archive must pass EdDSA verification. Before enabling `developer-id`, upgrade or harden the updater so archive EdDSA is independently mandatory, add a regression test that corrupts only the enclosure signature while preserving a valid Developer ID identity, and repeat the complete transition matrix.

After that blocker is resolved and the Apple Developer Program is joined, preserve the Bundle ID, Sparkle public key and key account. Then configure `DEVELOPER_ID_APPLICATION` and `DEVELOPMENT_TEAM` and test the explicit future path:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)'
export DEVELOPMENT_TEAM='TEAMID'
xcrun notarytool store-credentials 'ushot-notary' \
  --apple-id 'developer@example.com' \
  --team-id "$DEVELOPMENT_TEAM"
export NOTARYTOOL_KEYCHAIN_PROFILE='ushot-notary'
scripts/build-release.sh --mode developer-id
scripts/package-dmg.sh --mode developer-id
scripts/notarize.sh build/release/developer-id/artifacts/Ushot-0.1.1-arm64.dmg
```

`scripts/notarize.sh` accepts only the named keychain profile; it does not accept raw Apple ID, app-specific-password or team variables. Do not enable this path in the public workflow until strict archive EdDSA, Developer ID signing, notarization, stapling, Gatekeeper assessment and an update transition from the ad-hoc release have all passed end-to-end testing.
