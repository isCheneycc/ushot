# Release notes

Add one unsigned Markdown file named `<version>.md` for every stable release, for example `0.1.1.md`.

For a feed-enabled release, the protected workflow passes these source notes to Sparkle 2.9.5 `generate_appcast --embed-release-notes`. Each retained release becomes exactly one nonempty appcast `description` with `sparkle:format="markdown"`; no separate note file is published to Pages. This is deliberately restricted Markdown: do not add links, images, raw HTML, autolinks, entities, URL/domain/network-address-like destinations, item links, detached release-note URLs or delta-download instructions. The release scripts apply this rule to the new source and every retained embedded description before signing. A manual-only `publish_update_feed=false` release may still keep its note here as release source without creating or deploying an appcast.

These files are unsigned source inputs. For an online update, authenticity comes from signed-feed verification of the complete generated appcast, including the embedded description, followed by host validation of the exact authenticated XML before Sparkle parses items. The zero-item seed is reserved for the first online update, 0.1.4 (build 5). Never copy generated appcast content back here or hand-edit the signed Pages payload.
