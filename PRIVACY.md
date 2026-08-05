# Privacy

UshotApp is designed as a local-only utility.

## Screen access

macOS Screen Recording permission is required for screenshots and pixel sampling. UshotApp requests no Accessibility permission and uses no private API. Screen pixels are read only in response to an explicit capture or color-picker action.

## Data processing

- Captures, annotations, clipboard exports and color samples are processed on the Mac.
- The application contains no telemetry, analytics, advertising SDK, account system or network client.
- OSLog entries contain operational categories, identifiers and error descriptions; they must never contain screenshot pixels, OCR/annotation text, clipboard values or file contents.

## Persistence

Screenshot history is off by default. When enabled, each editable record is stored under the app's Application Support directory as two PNG files and two versioned JSON files. Turning history off stops new records; it does not silently delete existing records. Users can inspect the directory, delete individual items or clear all history after confirmation.

Settings are stored locally in UserDefaults as one versioned Codable document. Launch at Login is managed through Apple's ServiceManagement API.

## Distribution and networking

The first website-distributed build uses Hardened Runtime and is not sandboxed, so users can choose arbitrary save destinations and drag files to other apps. That choice does not add networking. A future updater or optional network feature must update this document before release and must not be silently introduced.
