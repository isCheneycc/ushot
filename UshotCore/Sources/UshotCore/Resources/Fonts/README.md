# Bundled handwritten fonts

These font files are distributed under SIL Open Font License 1.1, separately
from Ushot's source-code license. Keep the accompanying copyright and complete
license notices with every redistribution. The app loads the fonts locally;
no font download or system-wide font installation is required.

## Excalifont

- Runtime file: `Excalifont-Regular.ttf`
- PostScript name: `Excalifont-Regular`
- Version: `1.000;Glyphs 3.2 (3227)`
- Copyright: Copyright (c) 2024 by Excalidraw. All rights reserved.
- License: `Excalifont-OFL.txt`, extracted without rewriting its terms from the
  upstream font's copyright and license name records. No Reserved Font Name is
  declared in those records; the upstream Excalifont trademark notice remains
  in the font.
- Official source page: <https://plus.excalidraw.com/excalifont>
- Official full-font download:
  <https://excalidraw.nyc3.cdn.digitaloceanspaces.com/fonts/Excalifont-Regular.woff2>
- Retrieved on 2026-09-16. The download URL is mutable; it is **not** an
  immutable Git release. Its exact 52,296-byte source is retained as
  `Upstream/Excalifont-Regular.woff2` and pinned by SHA-256 below.
- The matching font identity and license are also recorded in Excalidraw's
  [font definition at commit a9186480121afc16ccdec789fc533e6a9ee68c10](https://github.com/excalidraw/excalidraw/blob/a9186480121afc16ccdec789fc533e6a9ee68c10/packages/excalidraw/fonts/Excalifont/index.ts).

The TTF is a documented WOFF2 container conversion, not a claimed upstream TTF.
It contains the complete font, with no subsetting, renaming or design edits.
Conversion used FontTools 4.60.1 with Brotli 1.2.0. From this directory, the
reproducible Python operation is:

```python
from fontTools.ttLib import TTFont

font = TTFont(
    "Upstream/Excalifont-Regular.woff2",
    recalcTimestamp=False,
    recalcBBoxes=False,
)
font.flavor = None
font.save("Excalifont-Regular.ttf")
```

Do not decode or modify tables before saving. The conversion was checked to
preserve all 585 glyph outlines and horizontal metrics, plus the exact `name`,
`cmap`, `GDEF`, `GPOS` and `GSUB` table bytes. The Unicode map has 561 entries,
including Latin, Greek and Cyrillic; it contains no CJK Unified Ideographs.
Chinese text uses the separately bundled Xiaolai fallback.

## Xiaolai

- Runtime file: `Xiaolai-Regular.ttf`
- Exact PostScript name: `XiaolaiSC` (the filename is not the PostScript name).
- Family: `Xiaolai SC`; version: `3.11`, dated December 4, 2020.
- Original font project: <https://github.com/lxgw/kose-font>
- This file is copied byte-for-byte from the CJK fallback used by Excalidraw:
  [scripts/woff2/assets/Xiaolai-Regular.ttf at commit a9186480121afc16ccdec789fc533e6a9ee68c10](https://github.com/excalidraw/excalidraw/blob/a9186480121afc16ccdec789fc533e6a9ee68c10/scripts/woff2/assets/Xiaolai-Regular.ttf).
- Its Git blob identity was independently checked as
  `c8673de7c35f1d67a12ea85e878aef3993837f2d`. Ushot has not converted,
  subsetted, renamed or otherwise edited this TTF.
- Complete upstream license: `Xiaolai-OFL.txt`, copied from
  [lxgw/kose-font commit 5359953d118976c7797ad3257d7cf4036ad09f3c](https://github.com/lxgw/kose-font/blob/5359953d118976c7797ad3257d7cf4036ad09f3c/OFL.txt),
  Git blob `2fea47d54ff4649dd34cb528d28b974c3aceb966`. It retains the LXGW
  and Nozomi Seto copyright notices.

This specific Excalidraw asset has 41,601 glyphs and 41,577 Unicode mappings,
including 20,949 CJK Unified Ideographs, 6,582 Extension A characters, kana
and Hangul. It does not contain ASCII, so it must be used as the explicit
CJK fallback after Excalifont. It is not a claim of complete coverage of
every modern Chinese character or of using the latest Xiaolai release.

Both TTF files were parsed directly by CoreText without installation, and
their PostScript names, source-file URLs, glyph counts and representative
Latin / Simplified Chinese / Traditional Chinese glyph mappings were checked.
These are font-data checks, not visual or UI acceptance tests.

## Checksums

SHA-256 values bind the complete file bytes:

```text
1255348616f44589c924a8e4dc6798723dea3f8b373efa388de7e8f6296b6562  Excalifont-Regular.ttf
ee41ec4c06bfa0728665499de6f4b4019e7953119ab20b5aeb5917f1609c3b2a  Upstream/Excalifont-Regular.woff2
29e737f5542aff88dbd3dfe80cae8d108fc82afd1c0953046435b6fdeb19f973  Excalifont-OFL.txt
17e58fb25e7a421b64ebea1c50104fadf752d9045fb102501434bce577e22b3f  Xiaolai-Regular.ttf
0df7e09be4c2c850a48bd8beb9cd64b343aad49cd5d3f6cfb2ad2e3d28a56ca4  Xiaolai-OFL.txt
```
