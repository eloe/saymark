# Claude Opus 5 independent review — Recent Dictations

**Review date:** 2026-07-26
**Reviewer:** Claude Opus 5 High (`claude-opus-5`)
**Mode:** read-only architecture, security, SDD, and TDD review
**Reviewed revision:** `a7c7e5c` (`docs: specify recent dictation recovery`)
**Original verdict:** **REJECT for implementation as written**
**Review artifact:** retained from the desktop Claude review; this document is
the durable repository record and remediation index. It records review claims
and planned specification changes, not implementation evidence.

## Outcome

The reviewer accepted the original default-Off, no-audio/no-provisional-text,
no-forensic-erasure claim, deferred encryption design, no-automatic-retry rule,
and structural prohibition on retaining original target-app metadata. It rejected
the revision because secure-input credentials could be retained, a synchronous
history write could block final delivery, retention-shortening was ineffective,
and deletion did not remove plaintext from active SQLite artifacts.

The remediation revision updates
[`../recent-dictations-sdd.md`](../recent-dictations-sdd.md) before code begins.
“Addressed in SDD” never means verified in code; the follow-up review disposition
and Slice C/E code-evidence re-review requirements appear below.

## Blockers

| ID | Independent finding | SDD remediation / future evidence |
| --- | --- | --- |
| B1 | Sampling secure input after retaining a final can turn password/secure-terminal dictation into a long-lived credential archive. | §2.2 samples secure input before text reaches history and mandates no row/FTS write; approval table records the decision. `RD-U23`, `RD-UI07`. |
| B2 | A `synchronous=FULL` write and purge before paste made history an unbounded delivery dependency with no latency budget. | §2.2 defines 75 ms p95 / 100 ms hard bounded attempt, rollback/fail-open, no background retry, and idle-only purge. `RD-I11`. |
| B3 | Materialized expiry meant 90→7 days or indefinite→bounded did not shorten existing records. | §3.3 makes store metadata transactional source of truth, applies a downward expiry minimum/purge before preference mirror. `RD-U21`. |
| B4 | SQLite DELETE and passive WAL handling leave transcript bytes in database/WAL after Clear. | §3.2–3.3 require `secure_delete=ON`, `journal_size_limit=0`, `wal_checkpoint(TRUNCATE)`, honest completion copy, and byte scan. `RD-I12`. |

## High findings

| ID | Independent finding | SDD remediation / future evidence |
| --- | --- | --- |
| H1 | Bound FTS5 `MATCH` values still parse as query grammar; literal-prefix search was undefined. | §2.1 selects `unicode61 remove_diacritics 2`, defines quoted-token escaping and folding edge cases. `RD-U09`, `RD-U10`, `RD-I06`. |
| H2 | Reinsert after opening Saymark history would paste into Saymark's own key window. | §2.3 holds prior-frontmost app identity only in controller memory, verifies/reactivates it, otherwise offers Copy. `RD-UI11`. |
| H3 | Search query can persist through search recents, suggestions, and macOS state restoration. | §4.1/4.3 forbid recents/suggestions, require non-restorable window. `RD-UI12`, `RD-I09`. |
| H4 | Existing diagnostic allowlist checks keys but permits arbitrary strings under allowed keys. | §4.2 requires typed closed-value history diagnostics and per-key general logger validation. `RD-U20`. |
| H5 | PostHog is live for opted-in keyed builds and has no property allowlist; exact transcript counts already conflict with no-fingerprinting language. | §4.2 correctly states opt-in reality, forbids all history PostHog data, and makes removal/coarse-banding of exact counts a release precondition. `RD-I13`. |
| H6 | VACUUM and spill files can copy plaintext outside the protected directory. | §3.2 bans v1 VACUUM, uses memory temp store and protected controlled temp directory; byte scan covers maintenance. `RD-I12`. |
| H7 | Wall-clock rollback can resurrect expired rows/reorder records. | §3.2 uses durable high-water time at open/mutation/idle plus read-only in-memory filtering for creation/expiry/order. `RD-U02`, `RD-U11`. |
| H8 | An unspecified persistent lock could permanently disable history after crash. | §3.3 requires kernel-released advisory lock only. `RD-U22`. |
| H9 | Parent symlink precheck is TOCTOU and incomplete. | §3.3 uses no-follow opens and descriptor verification; explicitly states defense-in-depth limit. `RD-U16`, `RD-I10`. |
| H10 | Future Spotlight/Time Machine inclusion is preventable, not merely an uncontrollable deletion caveat. | §3.2 creates `.metadata_never_index` and backup exclusion. `RD-I14`. |
| H11 | Original scope dropped export while still implying Slice 3 acceptance completion. | `product-roadmap.md` now says recovery copy/delete may ship first and keeps export as a separate gate. |

## Medium findings

| ID | Independent finding | SDD remediation / future evidence |
| --- | --- | --- |
| M1 | Delivery state had no single canonical enum. | §3.2 defines one five-value state table/check constraint. `RD-U05`. |
| M2 | Oversize `history_record_too_large` had no enum/diagnostic home or user decision. | §2.1 gives `record_too_large` a typed diagnostic vocabulary and approval decision. `RD-U04`, §5. |
| M3 | Per-row schema version conflicted with `user_version`. | §3.2 removes per-row version; `user_version` is sole guard. `RD-U15`. |
| M4 | Enabling history mid-dictation could retain earlier speech. | §2.2 requires policy enabled at start and finalization. `RD-U24`. |
| M5 | HUD-only retention was a user expectation decision, not a decided behavior. | §2.2/§5 disallow it by default pending approval. `RD-U04`, `RD-UI07`. |
| M6 | File permissions were overstated against apps running as the unlocked same user. | §3.2 now says exactly that; encryption remains deferred. |
| M7 | `foreign_keys=ON` had no schema use and `revision` had no defined scope. | §3.1 replaces it with in-memory store-global generation; §3.2 removes unused pragma. |
| M8 | DEBUG daily-driver harness bypasses delivery and would leave pre-delivery history pending. | §6/`RD-U06` require history-path exclusion in the harness. |
| M9 | Controller state/status could retain/expose final text indefinitely. | §6/`RD-UI03` require no transcript binding to menu/status/accessibility and release-time clearing review. |
| M10 | “This session” did not explain durable-until-next-launch crash behavior. | §2.1 names it durable-within-session and best-effort removal. |
| M11 | 10k performance test lacked cold-open and required machine metadata. | §6/`RD-I07` add cold/warm runs and performance-acceptance recording. |
| M12 | Case/diacritic behavior was not specific enough to test. | §2.1 defines tokenizer and named Unicode edge cases. |

## Low findings

| ID | Independent finding | SDD remediation / future evidence |
| --- | --- | --- |
| L1 | Copy was exact but Reinsert added a surprising trailing space. | §2.3 makes Reinsert exact-text; `RD-U18`, `RD-UI06`. |
| L2 | WAL/SHM can fail on SMB/NFS home directories. | §3.2/`RD-U16` define typed unsupported-filesystem failure. |
| L3 | Reserved live-ownership state would freeze an unimplemented feature into v1 schema. | §2.2/3.2 omit it; later live feature needs migration. |
| L4 | macOS file-protection APIs do not justify encryption claims. | §3.2 preserves deferred Keychain-backed encryption only; no false encryption claim. |
| L5 | Accessibility result-count announcement lacked a macOS mechanism. | §4.3 specifies debounced `NSAccessibility` announcement. |
| L6 | History window sharing could expose transcript wall during recording/share. | §4.3 uses `sharingType = .none` pending approved exception. |

## Follow-up review and final documentation corrections

**Follow-up verdict:** **APPROVE-WITH-CHANGES** on `60e0e7d`. No further
full-document review is required once the following documentation corrections
are committed. Code must receive independent re-review at Slice C/E evidence
stage; this is not an implementation approval.

| ID | Follow-up finding | Final SDD remediation / future evidence |
| --- | --- | --- |
| D1 | A typed event's properties were closed but its event name could still bypass logger controls. | §4.2 permits only literal `history.operation`, requires event-name validation, and extends `RD-U20` to reject dynamic/unknown names. |
| D2 | Search/transcript controls can leak tokens into spellcheck/autocorrect/replacement/completion services. | §4.3 disables those services on both native controls; `RD-I16` scans `~/Library/Spelling` under a dedicated test account. |
| D2b | Search needed explicit multi-token literal semantics. | §2.1/`RD-U09` define deduplicated all-token AND/prefix matching in any order; empty tokens return recents. |
| D3 | Reinsert activation could wait indefinitely or paste after a target changed. | §2.3 caps wait at 500 ms and pins/rechecks PID immediately before paste; `RD-UI13`. |
| D4 | Persisting high-water time on every read creates write/WAL churn. | §3.2 makes reads in-memory/filter-only and persists at open/mutation/idle; `RD-U11` states the precise durable guarantee. |
| D5 | `secure_delete` must apply to every SQLite connection, not just the main writer. | §3.2/`RD-I12` require verification on every read/migration/test/recovery connection. |
| D6 | `hud_only` remained in v1 schema despite being unapproved. | §2.2/§3.2 remove it; HUD-only is no-row until a later reviewed migration. `RD-U05–U06`. |
| D7 | The same-user unsandboxed caveat and safe directory creation needed stronger wording. | §3.2 states atomic verified 0700 creation and that it is not a confidentiality boundary for the unlocked same user. `RD-U17`. |
| D8 | Privacy scan omitted window title. | §4.3 makes title static; `RD-I09` scans it for sentinels. |
| D9 | Approval/mocks omitted deadline-miss and delivery-unknown copy. | §5 adds both decisions and minimum mockup states. |
| D10 | Approval/mocks omitted immediate deletion when switching to This session. | §5 adds the destructive transition/copy and mockup. |
| D11 | All review findings must remain durable. | This section preserves the follow-up verdict/disposition; §10 points to this record. |

## Required code re-review questions (Slice C/E)

1. Is the bounded pre-delivery transaction/cancellation mechanism technically
   capable of a true 100 ms deadline without a late commit or main-thread wait?
2. Is controlled SQLite temporary storage feasible and safe with Saymark's
   process-wide SQLite use, or must the feature adopt a different store design?
3. Do `secure_delete`, full checkpoint/truncate, FTS behavior, and macOS
   filesystem semantics satisfy the promised byte-level test on the supported
   platform?
4. Does the planned diagnostic/PostHog remediation actually close existing
   free-form-property paths, rather than merely adding a history convention?
5. Do implementation evidence and UI tests cover secure input, deadline miss,
   delivery unknown, HUD-only no-row, prior-app PID reinsert, oversize finals,
   shortening/This-session deletion, spelling artifacts, and window sharing?

## Re-review context

Use the current SDD, this review record, `docs/product-roadmap.md`, privacy /
diagnostic / performance docs, and the current `DictationController`,
`TextInjector`, diagnostics, settings, and PostHog call sites. Review remains
read-only. Classify any remaining gap as blocker/high/medium/note and distinguish
design intent from tested implementation evidence.
