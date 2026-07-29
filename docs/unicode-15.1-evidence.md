# Pinned Unicode 15.1.0 correction-core evidence

**Status:** evidence spike; implementation is gated on the checked-in official
conformance tests in `Unicode15_1Tests`. This is not host ICU/Foundation
behavior and does not alter the approved Vocabulary UI.

## Contract and architecture

`Unicode15_1` is a pure-Swift leaf module for the correction core. It has no
Foundation, ICU, locale, clock, file-system, network, diagnostics, audio,
Accessibility, or clipboard dependency. It provides only:

1. Unicode 15.1.0 NFKC, including algorithmic Hangul decomposition/composition;
2. Unicode default full case folding (C/F mappings; Turkic T mappings excluded);
3. UAX #29 Unicode 15.1 word-boundary classification and boundary decisions.

`TranscriptCorrectionPipeline` must use these operations for the one
`matchKey(_:)` implementation; it must retain original-scalar provenance outside
this module. It must never index the original string using normalized offsets.
The U-23 tests exercise compatibility expansion and prove the caller must treat
each source scalar expansion atomically.

The table generator has no dependencies and consumes vendored Unicode Character
Database files. It emits sorted flat arrays and binary-search indexes rather
than dictionaries or per-scalar objects. The generated data is **294,454 bytes**
at the current spike revision: 5,857 decomposition mappings, 922 non-zero
canonical combining classes, 945 canonical composition pairs, 1,530 default
full-case-fold mappings, and 1,870 word-break/property ranges. The data source
inputs and full official conformance fixtures total **5,152,566 bytes**. This is
small enough for a local macOS application and avoids OS-version drift.

## Authoritative sources and integrity

All inputs are unmodified official Unicode 15.1.0 data:

| File | Official URL | SHA-256 |
| --- | --- | --- |
| UnicodeData.txt | https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| CompositionExclusions.txt | https://www.unicode.org/Public/15.1.0/ucd/CompositionExclusions.txt | `59d2d9e3dfdf0a999cf9dae11d594f053631222679a2f5710315ea07f7fe82af` |
| CaseFolding.txt | https://www.unicode.org/Public/15.1.0/ucd/CaseFolding.txt | `4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf` |
| WordBreakProperty.txt | https://www.unicode.org/Public/15.1.0/ucd/auxiliary/WordBreakProperty.txt | `0f5f68bdab1bac4a2bf6576530dca10a322eadbc980b386a7627c89929053dc5` |
| emoji-data.txt | https://www.unicode.org/Public/15.1.0/ucd/emoji/emoji-data.txt | `d7aef489c8fe4c14f09ea5695200277c6b93ac82ac60845cdd2161b0d6835cc1` |
| NormalizationTest.txt | https://www.unicode.org/Public/15.1.0/ucd/NormalizationTest.txt | `871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e` |
| WordBreakTest.txt | https://www.unicode.org/Public/15.1.0/ucd/auxiliary/WordBreakTest.txt | `69506b2253b8defb1f15b1476397376285cfda3bafd9304ee50d48bbfa0a2ab4` |

Unicode data is licensed under Unicode License v3, reproduced in
`ThirdPartyLicenses/unicode-15.1.0-LICENSE.txt`.

## Conformance and performance gates

The CI-blocking tests intentionally parse official fixtures rather than a
hand-picked sample:

- every applicable NFKC form in `NormalizationTest.txt` (95,370 assertions);
- every C/F mapping in `CaseFolding.txt` (more than 1,500 mappings, with full
  mappings overriding common mappings); and
- every line in `WordBreakTest.txt` (more than 1,800 full boundary sequences).

They also include U-23 adversarial cases for `ﬁ`, `ß`, `㍿`, `㈱`, and NFC/NFD
accent equivalence. The micro-benchmark is a guard, not a release result: it
requires NFKC + folding + boundaries for a 7,680-scalar mixed input to stay
below 10 ms per iteration, leaving the correction pipeline's 10 ms p95 draft
budget intact. The spike measured **2.657 ms/iteration** across 500 optimized
iterations on the current Apple-silicon host; the resulting standalone executable
was **226 KB**. A release evidence run must record median/p95/max on the
supported macOS 15 and macOS 26 hardware matrix.

## Spike measurements (2026-07-26)

| Check | Result | Method |
| --- | --- | --- |
| Deterministic generation | Pass; generated SHA-256 `f10fd0d1cc8919276171efa13248ac6825c81efb245c1dfb11350e662d5502b4` unchanged after regeneration | `node Scripts/generate-unicode-15.1.mjs` followed by a clean diff |
| Core source / module size | 294,454 bytes / 35 KB | generated source and optimized standalone module |
| Optimized core compile | 2.57 s real, 163 MiB peak RSS | `swiftc -O -parse-as-library` on the two pure-Swift core files |
| Official NFKC | Pass, 95,370 assertions | all 19,074 `NormalizationTest.txt` rows and five required input forms |
| Official case folding | Pass, 1,530 mappings | all C/F mappings, full mappings taking precedence |
| Official UAX #29 word breaking | Pass, 1,826 sequences | every `WordBreakTest.txt` sequence |
| Mixed-input runtime | 2.657 ms/iteration | 500 optimized NFKC + full-fold + word-boundary iterations over 7,680 scalars |

The package test target currently cannot run on this machine because its existing
XCTest imports are unavailable in the CommandLineTools-only toolchain. The
equivalent standalone harness passed the official fixtures above; Xcode's XCTest
environment remains the CI/release venue for `Unicode15_1Tests`.

## Reproducible update procedure

1. Create `UnicodeData/<new-version>/` and download the seven files above from
   the matching `https://www.unicode.org/Public/<new-version>/ucd/` paths.
2. Record `shasum -a 256` values in this document; reject a download that does
   not exactly match the reviewed values.
3. Update the version/path constants in `Scripts/generate-unicode-15.1.mjs`,
   run `node Scripts/generate-unicode-15.1.mjs`, and review only deterministic
   table changes.
4. Run the entire `Unicode15_1Tests` conformance suite plus the macOS 15/26
   reference-machine matrix. Do not change a vocabulary document's pinned
   `unicodeVersion` in place: an unsupported version opens read-only.
5. Update this evidence, the SDD, third-party attribution, corpus manifests,
   and release evidence in the same reviewed change.

## Product decision if this gate fails

Do not fall back to Foundation/ICU, ASCII-only matching, or a newer host Unicode
version. Disable Vocabulary edits and correction matching for that build, keep
raw dictation working, and either repair the pinned implementation or explicitly
approve a new pinned Unicode release with the procedure above.
