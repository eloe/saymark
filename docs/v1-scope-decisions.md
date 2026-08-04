# Saymark 1.0 scope decisions

Status: approved product scope for the `saymark-v1.0.0` release line
Decision date: 2026-08-03

Saymark 1.0 is a local-first macOS dictation utility. Its release priority is
the dependable shortcut → feedback → microphone → final transcript →
single-shot focused-input delivery loop. Version 1.0 does not attempt broad
Superwhisper parity, and it does not weaken privacy or text-ownership rules to
claim more features.

This document is the durable product decision for roadmap issues that are
closed as **not planned for 1.0**. Closing one of these issues does not mean its
acceptance criteria were implemented. It means the described feature is
deliberately excluded from the 1.0 product, is not advertised as shipped, and
must return through a new or reopened proposal before production work begins.
No decision here requires paid Apple Developer services.

## Required 1.0 evidence remains active

The following work covers behavior that already ships and therefore cannot be
waived by a scope decision:

| Issue | Required outcome |
| --- | --- |
| [#24](https://github.com/eloe/saymark/issues/24) | Certify the single-shot final insertion safeguards against real supported targets. |
| [#28](https://github.com/eloe/saymark/issues/28) | Publish real-hardware core-loop latency, long-dictation, and resource evidence. |
| [#29](https://github.com/eloe/saymark/issues/29) | Capture unlocked local end-to-end UI evidence without private content. |
| [#30](https://github.com/eloe/saymark/issues/30) | Prove held-out Vocabulary correction quality and latency. |
| [#31](https://github.com/eloe/saymark/issues/31) | Complete Vocabulary accessibility and schema-v2 interchange launch acceptance. |
| [#36](https://github.com/eloe/saymark/issues/36) | Define and enforce a supported total-record cap, then prove retention/search/deletion at that cap. `Until I delete` is currently unbounded, so release remains blocked until the product has an equivalent bounded policy. |
| [#38](https://github.com/eloe/saymark/issues/38) | Certify shipped onboarding accessibility and lifecycle behavior on real macOS. |

Issue [#45](https://github.com/eloe/saymark/issues/45) remains the administrative
tracker until every child has implementation evidence or an explicit disposition.

## Explicitly not planned for 1.0

| Issues | Decision | Product and safety rationale | Re-entry gate |
| --- | --- | --- | --- |
| [#25](https://github.com/eloe/saymark/issues/25), [#26](https://github.com/eloe/saymark/issues/26), [#27](https://github.com/eloe/saymark/issues/27) | Do not ship provisional cross-application field mutation or a live-target certification program in 1.0. Preserve the pure policy as an inert, fail-closed research boundary. | Revising another application's text introduces substantially more focus, selection, user-edit, secure-input, undo, and synthetic-event risk than single-shot final delivery. It is not required for a dependable core loop. | Reopen all B-01…B-05 evidence gates, obtain independent security review, and prove target-specific ownership before any production mutation is enabled. |
| [#32](https://github.com/eloe/saymark/issues/32) | Do not add model-native Vocabulary prompting or biasing in 1.0. | The shipped deterministic correction layer is local, inspectable, reversible, and model-independent. A second model-specific path would add sensitive inference behavior and quality uncertainty without a demonstrated core-loop need. | A capability adapter must prove support in the pinned models plus held-out accuracy, latency, privacy, and fallback behavior. |
| [#33](https://github.com/eloe/saymark/issues/33) | Do not add transcript-file export—single, selected, filtered, or bulk—in 1.0. | File export creates durable plaintext outside Saymark's retention controls. Explicit per-row Copy remains the supported recovery action without silently multiplying sensitive data. | Approve a threat model, destination UX, overwrite policy, metadata contract, cleanup guidance, and privacy tests. |
| [#34](https://github.com/eloe/saymark/issues/34) | Do not add file transcription in 1.0. | Import, decoding, progress, cancellation, and retry form a separate job product and do not strengthen live microphone dictation. | Define supported formats, resource limits, cancellation/recovery semantics, and local-only acceptance evidence. |
| [#35](https://github.com/eloe/saymark/issues/35) | Do not retain dictation audio in 1.0. | Text-only history is the stronger privacy contract. Audio retention would add consent, encryption, backup, deletion, storage, and forensic obligations. | Requires a separately approved privacy design and must remain opt-in; no implementation may weaken the default no-audio invariant. |
| [#37](https://github.com/eloe/saymark/issues/37) | Do not gate 1.0 on a screen-by-screen Superwhisper onboarding comparison. | Saymark should be certified directly against native accessibility and lifecycle acceptance, not competitor visual parity. Issue #38 owns that proof. | Reopen only for a bounded research question that cannot be answered through Saymark's own acceptance tests. |
| [#39](https://github.com/eloe/saymark/issues/39) | Do not run an open-ended Murmur-era visual-inheritance program for 1.0. | Broad aesthetic inventory can displace core reliability. Concrete wrong-brand, privacy, credential, or misleading-state defects remain release bugs and must be fixed on evidence. | File a narrowly evidenced defect with an affected surface and acceptance screenshot or behavior. |
| [#40](https://github.com/eloe/saymark/issues/40) | Do not ship formatting transforms in 1.0. | Voice/Message/Email/Note transforms introduce semantic alteration, provider, provenance, latency, and fallback risks after transcription. | Specify deterministic or provider-neutral behavior, preview/undo, privacy, failure fallback, and quality acceptance. |
| [#41](https://github.com/eloe/saymark/issues/41) | Do not collect selected text, clipboard context, or per-app content modes in 1.0. | These workflows materially expand access to user-owned application data and complicate the focused-input ownership boundary. | Requires explicit per-use consent, minimization, no-retention proof, protected-app policy, and security review. |
| [#42](https://github.com/eloe/saymark/issues/42) | Ship an honest English-only 1.0; do not add language selection, detection, or translation. | Language claims require model capability and per-locale corpus evidence. Translation is a separate semantic transformation. | Add only a language with pinned-model support and locale-specific accuracy, latency, UI, and fallback evidence. |
| [#43](https://github.com/eloe/saymark/issues/43) | Do not ship meetings, diarization, or long-running recording in 1.0. | Meetings are a distinct recording and retention product with timestamp, recovery, consent, storage, and diarization obligations. | Requires a separate privacy/product design and long-running capture/recovery evidence. |
| [#44](https://github.com/eloe/saymark/issues/44) | Do not ship sync, accounts, cloud storage, or additional platforms in 1.0. Keep versioned local Vocabulary interchange. | Cloud identity, E2EE, key recovery, remote deletion, and cross-platform support conflict with proving the offline macOS core first. | Requires an approved trust model, portable schema, key lifecycle, revocation/deletion behavior, and platform-specific acceptance. |

## Release consequence

The excluded capabilities must remain absent from product claims, settings, and
release notes. Their dormant policy documents or test foundations do not make
them shipped features. The 1.0 release remains blocked on the active evidence
issues above, repository gates, and a zero-open-issue check after all recorded
dispositions are applied.

Before applying the not-planned closures, GitHub's active issue contracts must
be reconciled with this dependency decision: #24 must own the shipped
single-shot target matrix rather than depend on #27; #31 must name schema-v2
export with legacy-v1 migration rather than an undecided schema v1; #36 must
require a supported total-record cap, user-visible cap-reached behavior, and
verification at that cap; and #45 must remove #37 as a blocker for direct
onboarding acceptance in #38. Closing an issue while an active issue still
depends on it—or while #36 can close with unbounded retention—would be
contradictory and does not count as reconciliation.
