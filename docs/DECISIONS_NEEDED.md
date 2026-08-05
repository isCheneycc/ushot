# Decisions Needed

The implementation uses safe temporary values so these decisions do not block development:

- Final product name and bundle identifier (temporary: `UshotApp`, `com.example.UshotApp`).
- Final open-source license. License pending; no `LICENSE` file is created yet.
- Final app icon and brand assets.
- Developer ID team, signing identity and notarization keychain profile. These stay outside source control.
- Website/update-feed provider for a future `UpdateChecking` implementation.
- Which post-1.0 capabilities, if any, use a purchase or subscription entitlement.
