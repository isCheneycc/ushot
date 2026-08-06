# Privacy

Ushot is a local-first utility. Screenshot pixels and user-created content stay on the Mac.

## Screen and accessibility access

macOS Screen Recording permission is required for screenshots, the color picker and other pixel sampling. Screen pixels are read only in response to an explicit capture or color-picker action and are processed locally.

Window-level smart region snapping works without Accessibility permission. The optional Accessibility permission is used only to refine a hovered application window to a useful interface control. Denying or revoking it leaves ordinary capture and window snapping available. Ushot uses public macOS APIs and never queries its own capture overlay as the target element.

The GitHub distribution has no Developer ID signature or Apple notarization. Installing the published manual-only 0.1.2 or 0.1.3 transition, or a later online update, can cause macOS to request Screen Recording or Accessibility permission again. Apple Developer Program membership is not required for this ad-hoc distribution.

## Local data processing

- Captures, annotations, clipboard exports, color samples and image encoding are processed on the Mac.
- Ushot has no account system, telemetry, analytics, advertising SDK or crash-report upload.
- Ushot does not collect or submit a system profile. It does not send the Mac model, serial number, display layout, installed applications, locale or capture-permission state.
- OSLog entries may contain application versions, lifecycle states, durations, non-content geometry and error categories. They must never contain screenshot pixels, OCR/annotation text, clipboard values, filenames, file contents, update private keys or other user content.

## Local persistence

Screenshot history is off by default. When enabled, each editable record is stored under the app's Application Support directory as two PNG files and two versioned JSON files. Turning history off stops new records; it does not silently delete existing records. Users can inspect the directory, delete individual items or clear all history after confirmation.

Settings are stored locally in UserDefaults as one versioned Codable document. Launch at Login is managed through Apple's ServiceManagement API.

## Update network access

Ushot makes no update request at launch or on a schedule. Sparkle automatic checks, automatic downloads and system-profile submission are explicitly disabled.

Only when the user chooses **Check for Updates…** does Ushot make an update request. The published 0.1.1 client requests the legacy `https://ischeneycc.github.io/ushot/updates/appcast.xml`, which remains permanently unavailable and therefore cannot lead to an archive download. The published 0.1.2 and 0.1.3 manual transitions instead use the v1 boundary:

1. Requests the signed update feed from `https://ischeneycc.github.io/ushot/updates/v1/appcast.xml`. Restricted-Markdown release notes are embedded in this same signed response; Ushot does not make a detached release-notes request, and the release pipeline forbids links, images, raw HTML and URL-like destinations. This endpoint remains unavailable throughout both manual transitions. Its first permitted item is the separately gated 0.1.4 (build 5) update.
2. If the user accepts the update, downloads its archive from the official `https://github.com/isCheneycc/ushot/releases` release. GitHub may serve that asset through its normal GitHub-controlled download redirects.

These requests contain normal HTTPS connection metadata visible to the hosting providers, such as the client's IP address and standard HTTP headers. Ushot adds no screenshot, annotation, clipboard, history, system-profile or advertising identifier. There is no Ushot-operated server receiving update analytics.

The update archive is authenticated locally with the Sparkle EdDSA public key embedded in Ushot. The hardened runtime also requires its extracted display/build versions to match the signed appcast exactly and does not accept matching application code signing in place of archive EdDSA. Starting with 0.1.3, Ushot validates the exact authenticated XML before Sparkle parses item metadata; this local check adds no request and prevents duplicate or wrong-namespace fields, DTDs and entities from being hidden by parsed objects. HTTPS transport does not replace those checks. The 0.1.3 direct-download Release is published, and the recovered-key drill against its exact published assets is recorded. The 0.1.3 → 0.1.4 clean-account, raw-XML, tamper and mismatch client matrix still blocks production self-update.

## Distribution

The first public build is not sandboxed so users can choose arbitrary save destinations and drag files to other applications. Public release archives are intentionally ad-hoc signed, are not notarized and do not use Developer ID. This distribution choice does not grant Ushot any additional network access.

Any future network-backed feature, telemetry or account functionality requires an explicit product decision and an update to this document before release. It must not be introduced silently.
