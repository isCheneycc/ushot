# Release notes

Add one unsigned Markdown file named `<version>.md` for every stable release, for example `0.1.1.md`.

The protected release workflow passes these source notes to Sparkle 2.9.5 `generate_appcast --embed-release-notes`. Each release becomes exactly one nonempty appcast `description` with `sparkle:format="markdown"`; no separate note file is published. This is deliberately restricted Markdown: do not add links, images, raw HTML, autolinks, entities, URL/domain/network-address-like destinations, item links, detached release-note URLs or delta-download instructions. The release scripts apply this rule to the new source and every retained embedded description before signing.

These files are unsigned source inputs. Authenticity comes from signed-feed verification of the complete generated appcast, including the embedded description. Never copy generated appcast content back here or hand-edit the signed Pages payload.
