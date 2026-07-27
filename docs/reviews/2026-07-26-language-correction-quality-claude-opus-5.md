# Independent review record: language correction quality

**Reviewer:** Claude Opus 5 High

**Review target:** `aa4fbce` (`docs: specify language correction quality`)

**Review method:** read-only architecture, SDD/TDD, privacy, security, and
language/correction-quality review.

**Original verdict:** APPROVE-WITH-CHANGES. No production code was reviewed or
shipped. The reviewer required all blocker and high findings to be resolved in
the SDD before Slice A.

**Original full report:** retained locally at
`/Users/eloe/.claude/plans/you-are-an-independent-mighty-snowflake.md` during
this design phase. This repository record captures the actionable findings and
their disposition without copying environment-specific paths into product docs.

## Required findings and disposition

| ID | Finding | Disposition in remediation commit |
| --- | --- | --- |
| B1 | A 100 ms draft-correction budget consumes the live update budget and risks queueing. | Split into draft p95 <= 10 ms/max <= 25 ms, final-only p95 <= 100 ms; latest-wins, zero-backlog contract and I-12/P-04 added. |
| B2 | Empty Parakeet result uses the raw Nemotron draft; correcting rendered text would cascade. | Raw-only, exactly-once `nemotron_fallback` rule and I-11 added. |
| B3 | Host ICU makes cross-macOS reproducibility false. | Pinned/vendored Unicode 15.1.0 contract, document `unicodeVersion`, and macOS golden-test requirement added. |
| B4 | Length-changing normalization lacks a map back to original spans. | Per-match-scalar source-range provenance and U-23 added. |
| H1 | Validator and matcher could use different normalization. | One canonical `matchKey(_:)` and U-24 added. |
| H2 | Count-only imports can conceal malicious replacement values. | Per-entry diff, URL flag, acknowledgement, U-18/UI-07 expansion added. |
| H3 | Unsafe control/bidi/invisible scalar values can change insertion meaning. | Explicit scalar rejection and U-25/S-03 coverage added. |
| H4 | Name-only diagnostics allowlist cannot prove values are private. | Numeric-only correction fields, opt-in/bucketed data, generic-name prohibition, and S-07 value scan added. |
| H5 | Normalized WER cannot measure case/punctuation benefit. | Exact target-term surface metric defined; rendered WER is regression-only. |
| H6 | Rule-transforming the reference hides false replacements. | Human-authored reference is never rule-transformed. |
| H7 | Vocabulary benefit can be made circular with post-hoc aliases. | Frozen development/evaluation split and confidence interval required. |
| H8 | Five clips cannot justify language promotion. | Multi-speaker/scenario/duration/word-count evidence and CI required; five clips are smoke-only. |
| H9 | A bare `AUTO` HUD badge implies language detection. | SDD now requires removal or approved `EN` replacement and a UI assertion. |

## Additional incorporated findings

All medium and low findings were incorporated: durable 0600 storage and import
hardening, corpus-schema/BCP-47 requirements, model-selection fail-closed
requirements, raw-versus-corrected metric names, streaming-harness prerequisite,
CI versus release-gate venues, explicit token-boundary examples, traceability,
and a link from `docs/README.md`. Added requirements are U-23 through U-27,
I-11 through I-13, P-04, S-07 through S-09, and A-01.

## Follow-up condition

The amended design remains documentation only. Slice A may begin only after the
user approves the UI mockups identified in the SDD and implementation starts
with the corresponding failing tests.
