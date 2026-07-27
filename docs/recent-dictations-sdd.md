# Recent Dictations and insertion recovery — SDD and TDD

**Status:** design and test contract; implementation is intentionally blocked on
the UI decisions in [Approval required](#approval-required).  This document
implements the Slice 3 direction in [the product roadmap](product-roadmap.md)
without changing Saymark's local-first or no-audio-by-default contract.

## 1. Outcome and non-goals

Recent Dictations lets a person recover the *final text* of recent dictations
when a normal, live, or final insertion did not reach the intended field.  It
also provides a deliberately small, searchable local list from which a person
can copy or explicitly reinsert text.  It is a recovery aid, not a recording
archive, clipboard manager, activity monitor, or automatic retry mechanism.

This slice must provide:

- local, text-only records of final non-empty transcripts when history has been
  explicitly enabled;
- a newest-first list and search returning at most 25 records; the initial
  surface shows 20 records;
- Copy and explicit Reinsert actions;
- recovery of final text after eligible delivery failures and Accessibility
  fallbacks (never secure-input/credential text); and
- retention, deletion, and clear-history controls that are understandable
  before sensitive text is persisted.

It must not provide:

- microphone audio, waveform, provisional hypothesis, selected text, active
  application, field contents, cursor position, clipboard snapshot, or screen
  capture retention;
- network sync, cloud backup, remote search, account identity, analytics of
  text/query values, or automatic re-insertion/replay;
- a history record while history is Off; or
- a history record for a dictation that started while history was Off, a
  dictation finalized while it is Off, or a finalization sampled while secure
  input is active;
- a claim of forensic secure erasure from an SSD, APFS snapshot, or a user's
  backups.

The existing final-insertion path remains authoritative: it pastes one final
transcript and restores the previous clipboard only when doing so cannot
overwrite a newer user copy.  A history record is recovery state; it is never a
signal to send another paste.  Planned live insertion may update a record's
*delivery outcome*, but may not save provisional text or become a second text
ownership mechanism.

## 2. Product policy

### 2.1 Retention and result scope

The strict default is **History: Off**.  On a new install, upgrade, reset, or
unreadable setting, Saymark stores no transcript and does not create a history
database.  Enabling history requires an explicit, informed retention selection;
there is no implicit first-run default that begins collecting text.  The
recommended initial explicit choice is **30 days** (pending approval), with:

| Choice | Stored records | Required behavior |
| --- | --- | --- |
| Off (default) | none | Delete the active store and disable all writes. |
| This session | final text durably during the current app session | Delete on orderly quit; on relaunch remove any prior session store before accepting a new record. A crash can leave data until that next launch, so it is durable-within-session and best-effort removal, not no-disk persistence. |
| 7 / 30 / 90 days | final text until its individual expiry | Purge before reads and at launch/idle maintenance. On a shorter-policy change, recompute existing expiry and purge immediately; increasing retention affects new records only. |
| Until I delete | final text | Show the chosen indefinite retention plainly; clear/delete remains available. |

The recent-list query is newest first, has a default limit of **20**, and has a
hard cap of **25** regardless of caller. Search is local token/prefix search;
it never sends text to an embedding or ranking service. It uses FTS5's
`unicode61 remove_diacritics 2` tokenizer: composed/decomposed Latin diacritics
match (for example `café`/`cafe`), Unicode case comparison follows that
tokenizer, and it deliberately does **not** promise equivalence for `ß`/`ss`
or Turkish `I`/dotless `ı`. RTL tokens remain literal tokenizer tokens. The
query is tokenized using that same tokenizer; empty tokens are dropped; each
token is double-quoted with internal `"` doubled and a prefix `*` is appended
outside the closing quote. Thus FTS punctuation and `AND`, `OR`, `NOT`, and
`NEAR` are user text, not query grammar. It returns the same maximum. The list
does not promise a complete archive browser.

Record creation has a size limit of 100,000 UTF-8 bytes after finalization. A
larger final text is not retained; the delivery flow still uses the complete
text and emits only the content-free category `record_too_large`.
This bound prevents one paste from consuming unbounded disk. The typed,
content-free local diagnostic outcome `record_too_large` is the sole telemetry
effect; it has no row or remote event. The approved UI must decide whether and
how to tell the person that this recovery copy was not saved.

### 2.2 When a record is written

1. At dictation **start**, the main actor snapshots whether history is enabled.
   A dictation that starts with Off is permanently ineligible even if a person
   enables history before releasing the shortcut.
2. A dictation obtains a non-empty, authoritative final transcript. At the
   finalization snapshot, the main actor samples `TextInjector.secureInputActive`
   and the current history policy before any final text reaches history code.
   If secure input is active, history is Off at either snapshot, HUD-only
   retention is disallowed, or the text exceeds the cap, no row/FTS row/write
   occurs. Secure-input delivery remains the existing clipboard fallback only.
3. For an eligible final, `HistoryStore` makes one **bounded pre-delivery
   attempt** to insert the final text transactionally with `delivery_state =
   pending`. It has a 75 ms p95 budget and a 100 ms hard deadline; timeout,
   `SQLITE_BUSY`, cancellation, full disk, or any store error rolls back/abandons
   the attempt and immediately fails open to delivery. It may not retry in the
   background or delay/prevent final delivery. Retention purge is never on this
   path; it runs at launch and idle maintenance.
4. The existing live/final delivery code runs exactly once. When a row exists,
   it maps its only canonical outcomes to `inserted`, `copied_accessibility`,
   `insertion_failed`, or `hud_only`. If the process ends or state update fails
   after the committed insert, the durable state remains `pending` and is shown
   as **delivery status unknown**. Secure input intentionally has no row.
5. A delivery-state update failure never causes a second insert, second
   transcript write, or delivery retry. Store errors emit only a closed,
   content-free diagnostics category.

No-speech, cancellation before final text, model failure without final text,
history Off at dictation start or finalization, secure input, HUD-only when it
is disallowed, and a too-large final do not create a record. Text is stored
exactly as supplied by the authoritative final model, without the
presentation-only trailing space used by `TextInjector.paste`.

The bounded ordering makes failed synthetic paste or unavailable Accessibility
recoverable when the deadline permits, without turning storage into a delivery
dependency. A successful insertion can have a `pending` record after a crash;
the UI describes it as delivery status unknown, never as proof text was not
inserted. Secure input is a credential signal, so it is deliberately not a
history-recovery case.

### 2.3 Recovery behavior

For a normal final insertion failure or missing Accessibility permission, the
HUD retains existing immediate feedback and clipboard fallback. When an
eligible saved row exists, feedback can additionally route to it (wording and
placement need approval). Secure-input feedback never offers history because
no credential text was retained. If history was Off or the bounded write did
not commit, the existing clipboard fallback is the only recovery route and
must not turn history on.

Planned live insertion is outside schema version 1. Focus loss, selection/cursor
changes, or a user-owned edit stop revision as required by
[performance acceptance](performance-acceptance.md#human-perceived-live-insertion-gates),
but this feature neither reserves a delivery-state value nor assumes live
revision exists. A later design needs a migration and separate approval. It
must never discover, replace, or reconstruct text in the target field.

Copy writes the exact saved text to the general pasteboard and reports success
or failure. When the history window opens, `HistoryController` transiently
captures the previously frontmost `NSRunningApplication` identity; it is never
stored in a row, preferences, diagnostics, or telemetry. Reinsert requires an
explicit activation/confirmation, resigns the history window, activates that
still-running captured app, waits for it to be frontmost, and only then calls
`TextInjector.paste(text)` once. If the app quit, identity cannot be verified,
or another app becomes frontmost, it performs no paste and offers Copy. Reinsert
is exact-text (no trailing-space suffix), unlike a new final insertion; the
approved copy must say so if needed. It has the same Accessibility, secure-input,
clipboard-restoration, and result reporting rules as a new dictation, cannot be
invoked by keyboard focus alone, and never runs automatically.

## 3. Architecture and data model

### 3.1 Ownership and interfaces

`SaymarkKit` gains a UI-independent `HistoryStore` protocol and a single
serialized SQLite implementation.  It owns persistence, migration, retention
purging, capped queries, and deletion.  It accepts final text only through a
small value type and exposes records only to the app's history presentation.
It must not depend on SwiftUI, AppKit, HUD state, PostHog, or speech models.

`Sources/Saymark` owns the `HistoryController`/observable presentation state,
the settings choice, the non-restorable history window, transient previous-app
identity, user intent for Copy/Reinsert, and mapping current delivery results
to the store. `DictationController` makes the bounded record attempt only after
the start/finalization eligibility checks. `TextInjector` remains the sole
pasteboard/event-delivery primitive. A dependency-injected clock, store URL,
delivery adapter, secure-input seam, and frontmost-app adapter make policy and
crash/failure paths deterministic in tests.

The store is an actor (or an equivalent private serial executor) with no
long-lived read transaction across UI rendering. UI operations receive value
snapshots. An in-memory, store-global `generation` increments after each
committed mutation and lets the controller ignore out-of-order refreshes; it is
not a record column or diagnostic field. All app-facing APIs are
cancellation-aware: cancellation abandons the caller's result, never
half-applies a transaction. A pre-delivery cancellation must finish/rollback
within the 100 ms deadline and then deliver normally.

### 3.2 Storage location and format

For bundle id `B`, the preferred path is:

```text
~/Library/Application Support/B/RecentDictations/history.sqlite3
~/Library/Application Support/B/RecentDictations/history.sqlite3-wal
~/Library/Application Support/B/RecentDictations/history.sqlite3-shm
```

The directory is created with owner-only permissions (`0700`); database, WAL,
SHM, migration, and advisory-lock files are owner-read/write (`0600`). At
creation, write `.metadata_never_index` and set the directory's
`URLResourceValues.isExcludedFromBackup` flag, preventing future Spotlight and
Time Machine inclusion. Use Application Support discovered through
`FileManager`, not a hard-coded home path, Documents, Logs, defaults, the
pasteboard, or a cache. The directory is excluded from diagnostic-log paths and
all “Reveal diagnostic log” actions. These permissions defend against other
normal local users; Saymark is not sandboxed, so another application running as
the unlocked same user can read the files.

SQLite is selected for atomic transactions, bounded indexed reads, crash
recovery, and schema migration. Use `journal_mode=WAL`, `synchronous=FULL`, a
short pre-delivery `busy_timeout` bounded by §2.2, `secure_delete=ON`,
`journal_size_limit=0`, and a transaction for every mutation. After every
delete, clear, Off transition, expiry purge, or migration, finish the mutation
with `wal_checkpoint(TRUNCATE)` before reporting deletion complete. A busy
checkpoint is retried only by idle maintenance; deletion UI must say it is
still completing, never claim completion early.

Version 1 does not run `VACUUM`: it can copy text outside the protected
directory. Every history connection uses `temp_store=MEMORY`; before migration,
purge, or large search it also establishes a process-serialized SQLite temp
directory inside the protected store directory (and restores it afterward). If
that containment cannot be established, maintenance fails closed and delivery
fails open. The implementation must prove no temp/spill artifact contains text
outside the store directory. A network filesystem that cannot support WAL/SHM
is unsupported and disables history with a typed `unsupported_filesystem`
error; it must not silently fall back to unsafe behavior.

Minimal schema (schema version 1):

| Column | Type / constraint | Purpose |
| --- | --- | --- |
| `id` | UUID text, primary key | Opaque record identity; never sent remotely. |
| `created_at_ms` | integer, indexed | Local creation time for order and expiry. |
| `expires_at_ms` | integer nullable, indexed | Retention boundary; null only for Until I delete. |
| `text` | text, non-empty | Exact final transcript. |
| `delivery_state` | constrained text | One canonical value from the table below. |
| `delivery_updated_at_ms` | integer nullable | Audits a state transition locally. |

`PRAGMA user_version` is the sole schema migration guard; no per-row version is
permitted. A small store-metadata table holds the current retention policy and
`last_observed_now_ms` high-water mark. Every store access advances that mark
transactionally to `max(wall_clock_now, last_observed_now_ms)`. Creation time
uses the same value, expiry compares against it, and ordering breaks equal times
by opaque id. Therefore wall-clock rollback cannot extend retention or reorder
new records.

The sole v1 delivery-state enum and `CHECK` constraint are:

| Value | Meaning / valid transition |
| --- | --- |
| `pending` | committed pre-delivery row; may become a terminal state, or remains unknown after crash/update failure. |
| `inserted` | one final paste was posted. |
| `copied_accessibility` | Accessibility unavailable; clipboard fallback was used. |
| `insertion_failed` | synthetic final paste failed; clipboard fallback was used. |
| `hud_only` | approved HUD-only retention path completed without external paste. |

Only `pending → terminal` is valid and terminal values never change. Secure
input and planned live-ownership loss are no-row cases in v1.

Search uses external-content SQLite FTS5 only, configured with the tokenizer
and escaping contract in §2.1. The implementation must keep its triggers
transactionally consistent with `records`, ensure delete/clear removes every
shadow row, and apply the same byte-level deletion test to all FTS files.
Search text is local sensitive data.

No app-specific encryption is introduced in this slice without an approved
cryptographic design.  File permissions protect against other normal local
users; macOS volume encryption (FileVault) protects data at rest when enabled.
Neither protects an already-unlocked account or makes deletion from SSD
snapshots/backups forensically guaranteed.  An optional future per-store
encryption design must keep a randomly generated key in the Keychain, define
lost-key behavior, migrate atomically, and receive separate security review.
Never invent a custom cipher or store a key in `UserDefaults`.

### 3.3 Preferences, migration, and deletion

Preferences contain only policy, not text: `history.retentionPolicy`, a
versioned policy value, and an optional one-time education marker. Store
metadata is the transactional source of truth for active policy; UserDefaults
is mirrored only after the store transaction succeeds. Invalid, unknown, or
future policy values resolve to Off and schedule safe cleanup; they must never
resolve to indefinite retention.

Database startup follows this sequence:

1. create/open the directory and database with no-follow APIs
   (`SQLITE_OPEN_NOFOLLOW` where supported), then `fstat` the opened descriptors
   for expected owner/mode; do not rely on a pre-flight `lstat` check. This is
   defense in depth against a same-user attacker, not a sandbox boundary;
2. acquire one advisory `flock`/`F_SETLK` on an open descriptor. The kernel
   releases it on crash; a second live app instance waits only to the bounded
   timeout then exposes typed `busy`, without a persistent lockfile;
3. verify application id, `user_version`, schema, constraints, filesystem
   support, and temp-directory containment;
4. run each migration in one transaction. Do not make automatic plaintext
   backups; preserve the original on failure and remove all migration artifacts
   after success; and
5. advance the time high-water mark, purge expired/search rows transactionally,
   run secure deletion/checkpoint, then make the store available.

An unsupported newer schema, corrupted database, failed permission check, or
failed migration closes the store and disables history for the run without
deleting original data.  The UI surfaces a content-free recovery/error state.
It must never silently reset the store.  The repair/export choice requires
approval before implementation because an export itself contains sensitive
text.

On a policy change, a serialized store transaction updates metadata, then uses
`expires_at_ms = MIN(COALESCE(expires_at_ms, far_future), created_at_ms +
new_duration_ms)` for every bounded downward transition and purges immediately.
Changing to This session or Off clears records immediately. Increasing duration
does not extend existing rows; it applies only to future rows. Only after that
transaction/checkpoint succeeds is the UserDefaults mirror changed. A crash
between these writes can shorten retention, never extend it.

Single-delete is transactional: delete the record and all search-index entries,
perform secure deletion/checkpoint, then refresh UI. Clear History and Off use
explicit confirmation, one delete transaction, secure deletion, and
`wal_checkpoint(TRUNCATE)` before saying local store files no longer contain the
text. A concurrent stale writer must re-check metadata in its transaction and
cannot recreate a row after Off. There is no v1 VACUUM action. These controls
remove plaintext from the app's current database/WAL/SHM/FTS/temp artifacts,
but cannot erase prior snapshots or backups already made; future backup and
Spotlight inclusion are prevented at directory creation.

## 4. Privacy, security, accessibility, and telemetry model

### 4.1 Data-flow rules

| Data | Allowed location/use | Forbidden |
| --- | --- | --- |
| Final transcript | in-memory delivery; opted-in local history database; user-initiated copy/reinsert | diagnostics, unified log, PostHog, crash payload, URL, filename, preferences, model benchmark output |
| Provisional/live text | transient HUD/field ownership state only | history, database, telemetry, log |
| Audio | active capture/inference buffers only | history, database, export, logs, telemetry |
| Search query | transient local UI/store query only | persistence, `NSSearchField` recents, search suggestions, window restoration, logs, telemetry, remote requests |
| Previous-frontmost app identity | transient `HistoryController` handoff while a history window is open | history rows, delivery metadata, preferences, diagnostics, telemetry |
| App/focus/field/selection/clipboard data | current delivery primitive only where already required | history rows, delivery metadata, telemetry |
| Record id/timestamp/outcome | local database; aggregate content-free diagnostics | remote identity correlation or text-derived identifiers |

All errors crossing the history boundary are typed categories (`unavailable`,
`corrupt`, `migration_failed`, `permission_denied`, `busy`, `io_failed`,
`unsupported_filesystem`, `deadline_exceeded`) rather than raw SQLite
descriptions or SQL. SQL uses bound parameters and the FTS escaping contract in
§2.1. The database is never exposed to plugins, scripts, model adapters, or
arbitrary file paths. Do not support clickable links, rich text, or automatic
execution of transcript content in the list; render as plain, selectable text.

### 4.2 Privacy-safe telemetry and diagnostics

Remote PostHog telemetry is opt-in and Off by default, but is live in builds
that inject a `PostHogAPIKey`; it is not universally disabled. History produces
**no PostHog event or property**. Before shipping this feature, existing
`dictation_completed` exact `character_count` and `word_count` properties must
be removed or converted to approved coarse bands so they cannot fingerprint a
short transcript; this is a release precondition, not evidence that history
itself sent data.

History diagnostics use a dedicated typed `HistoryDiagnosticEvent` API, not
the general free-form `SaymarkDiagnostics.log(fields:)` API until that API has
per-key value validation. Its closed vocabulary is: operation
`insert|query|delete|clear|purge|policy_change`; outcome
`success|unavailable|corrupt|migration_failed|permission_denied|busy|io_failed|unsupported_filesystem|deadline_exceeded|record_too_large`;
retention `off|session|days_7|days_30|days_90|until_deleted`; result count
integer 0...25; and duration a non-negative bounded integer. Do not log record
ids, timestamps, raw errors/paths, query tokens/count, precise text length,
delivery target, or arbitrary string under an allowlisted key. The general
logger's existing name-only allowlist is not sufficient; production code must
add per-key closed-value validators and negative tests before it can receive
any history event.

Test fixtures must use synthetic, non-personal text.  Test databases,
WAL/SHM, exports, and crash artifacts belong under temporary test directories
and are removed in teardown.  No real user history database may enter a bug
report, repository, CI artifact, video, or PR screenshot.

### 4.3 Accessibility and interaction requirements

- The history window has a labelled navigation hierarchy: retention summary,
  search field, result count, result list, selected-record content, delivery
  status, Copy, Reinsert, Delete, Clear History, and close controls.
- The list uses stable accessibility identifiers and announces results/empty
  state without reading every transcript on each refresh. It uses debounced
  `NSAccessibility.post(element:notification:.announcementRequested)` for the
  count/empty change. Screen-reader focus remains on the nearest surviving row
  after delete; after clear it moves to the empty-state heading.
- All actions are keyboard reachable with standard focus order.  Destructive
  actions require confirmation whose default button is non-destructive.  Copy
  and Reinsert expose their destination and fallback outcomes in accessible
  text, not color alone.
- Use Dynamic Type/system text sizing, high contrast, VoiceOver labels,
  reduced motion, localization-friendly strings, and no time-only error
  message.  Transcript text must be selectable and must not be truncated
  without an accessible way to read the full value.
- The history `NSWindow` sets `isRestorable = false`, never enables
  `NSSearchField.recentsAutosaveName`, provides no search suggestions, and uses
  `sharingType = .none` unless the approved mockup explicitly accepts a
  support/demo exception. This prevents ordinary state restoration, search
  recents, and window sharing from exposing queries/transcripts.
- Opening history, search, deletion, and retention changes must not steal focus
  from the target app until a person explicitly opens history. Reinsert names
  the previously-frontmost app and changes only that verified target, never the
  history window or an unknown current app.

## 5. UI information architecture and approval required

Proposed surfaces (not approved and not implemented):

1. **Settings → Privacy → Recent Dictations.**  Shows Off/This session/7/30/90
   days/Until I delete, a concise local-text/no-audio disclosure, and an
   immediate Clear History action.  Selecting any enabled policy presents the
   informed-choice confirmation.
2. **Menu bar → Recent Dictations….**  Opens a standard resizable history
   window only when history is enabled.  It contains search, a newest-first
   20-item list, and a detail/action pane.  More results, if any, are fetched
   only in capped pages up to 25.
3. **Failure recovery in the HUD.**  Existing copy/fallback language remains
   primary.  When a saved record exists, an additional “Open Recent
   Dictations” route is available; it must not reveal the transcript in a
   notification or menu label.
4. **Destructive confirmation.** Delete shows what will be removed without
   restating text. Clear/Off says local database artifacts will be cleared only
   after secure deletion and a truncating checkpoint complete; it explains that
   prior backups/snapshots cannot be erased.

### Approval required

Implementation must pause for a user-approved mockup covering these decisions:

| Decision | Proposed default | Why approval is needed |
| --- | --- | --- |
| Enablement and retention selector | Off until an explicit choice; recommended 30 days | This changes how long sensitive user text persists. |
| Retention choices | This session, 7, 30, 90 days, Until I delete | The product must balance recovery with privacy. |
| History access and layout | Menu item opens a standard window with list/detail | Determines discoverability, information density, and accidental disclosure risk. |
| Result presentation | 20 initially, 25 maximum; full text selected in detail pane | Determines whether text is exposed in the menu or only on explicit open. |
| Failure affordance | HUD link to history only when an eligible row committed | Affects recovery and must not imply secure-input credentials were retained. |
| Secure-input retention | Never retain when secure input is sampled at finalization (recommended) | This avoids a password/secure-terminal credential archive. |
| HUD-only retention | Disallowed by default pending explicit approval | Presentation/demo mode has a different expectation of persistence. |
| Reinsert confirmation | Required; names the transient previously-frontmost app and falls back to Copy if gone/unknown | Prevents pasting into Saymark's own history window or another app. |
| Oversize dictation feedback | Decide whether to say a >100 KB final was not saved | Recovery otherwise disappears for the longest content. |
| Retention-shortening copy | States “Changing to 7 days deletes items older than 7 days now” | This privacy operation is immediate and irreversible. |
| Delete/Clear/Off confirmation and backup wording | Explicit confirmation, no secure-wipe claim | This is privacy-critical language. |
| Session-only crash behavior | Best-effort removal at next launch, not a durability claim | Users need a truthful expectation. |
| Window sharing | `sharingType = .none` (recommended) | Balances transcript privacy against support/demo workflows. |

**Minimum mockup package:** (a) Privacy settings before and after choosing an
enabled retention policy, including confirmation; (b) populated and empty
history window at normal and large text size; (c) secure-input HUD state that
clearly has no history route and insertion-failed state that does; (d) Reinsert
confirmation naming a prior app and its quit/unknown fallback; (e) Delete,
Clear History, and turning-Off confirmations; and (f) a 90-to-7-day shortening
confirmation. Provide light and dark macOS appearances plus VoiceOver labels or
an accessibility annotation sheet. Do not proceed to production UI until these
are approved.

## 6. Test-driven implementation plan

Every slice starts with a failing test.  Tests use an injected temporary store,
fixed clock, and fake delivery/insertion boundaries; no test records real audio
or production history text.

### Slice A — policy and store foundation

Implement `HistoryRetentionPolicy`, record value types, store URL/descriptor
validation, advisory lock, schema/metadata/time high-water mark, transaction
wrapper, typed diagnostics, and disabled no-op store. Unit tests prove Off
never creates a directory or accepts text, invalid policy resolves to Off,
expiry uses epoch milliseconds, rollback cannot resurrect/reorder rows, and
public queries clamp to 25.

### Slice B — durable finalization and recovery state

Add the start/final secure-input/policy eligibility gate, bounded pre-delivery
write, and canonical delivery-state transition. Use a fake `TextInjector` to
test inserted, unavailable Accessibility, secure-input no-row,
synthetic-paste failure, approved HUD-only, unknown-after-crash, and the DEBUG
harness exclusion. Prove delivery happens once even when store/state update
fails, times out, is busy, or is cancelled; history never retries automatically.

### Slice C — retention, search, migration, and deletion

Add FTS escaping/folding, expiry purge/shortening, single delete, clear/Off,
schema migrations, corruption/filesystem handling, concurrent policy/write
interleavings, secure deletion/checkpoint, temp containment, and no-index/no-
backup setup. Add the 10,000-record cold/warm performance fixture and verify
no content escapes logger or PostHog boundaries.

### Slice D — approved native UI and accessibility

After mockup approval, add settings, history window, recovery route, copy,
reinsert confirmation, destructive confirmations, localization, and
accessibility identifiers.  XCUITest covers the visible approved flows and
test-only adapters isolate Accessibility/pasteboard/model boundaries.

### Slice E — acceptance and release evidence

Run unit, app, UI, security, privacy, and performance suites; inspect test
diagnostics/artifacts for text leakage; make a consented demo using synthetic
text only. Record retention choice, test environment, migration version,
FTS escaping decision, 10,000-row cold/warm query and insert latency delta,
byte-level deletion report, PostHog negative scan, and unresolved risks in the
PR. Performance evidence records Mac model, memory, macOS, app/dependency
revision, and fixture revision as required by `performance-acceptance.md`.

## 7. Exhaustive acceptance cases

### 7.1 Unit and component tests

| ID | Requirement and exact assertion |
| --- | --- |
| RD-U01 | Fresh/default/invalid/future preferences resolve to Off; no history directory, DB, WAL, SHM, or text-bearing log is created. |
| RD-U02 | Each enabled policy produces the correct nullable expiry; bounded durations use elapsed epoch duration, and the monotonic high-water mark prevents clock rollback from extending/reordering rows. |
| RD-U03 | An eligible non-empty final commits at most one exact-text row before fake delivery within the deadline; text has no synthetic trailing insertion space. |
| RD-U04 | Empty final, cancellation, pre-final failure, too-large final, Off at start/finalization, disallowed HUD-only, and secure input store no row; delivery semantics remain unchanged. |
| RD-U05 | The canonical `pending|inserted|copied_accessibility|insertion_failed|hud_only` enum is the sole accepted constraint; only `pending → terminal` is valid, idempotent, and cannot create a missing row. |
| RD-U06 | Final insertion, approved HUD-only, missing Accessibility, injection failure, update failure, and DEBUG daily-driver harness exclusion produce required states/no-row behavior; secure input has no state because it has no row. |
| RD-U07 | If outcome update fails or process restarts between write/update, one recoverable canonical `pending` row exists (shown as delivery status unknown) and delivery is not invoked again. |
| RD-U08 | List/search are newest first, deterministic for equal timestamps via opaque id ordering, default 20, and caller values 0/negative/26/huge clamp safely to 1…25. |
| RD-U09 | FTS5 search uses the specified `unicode61 remove_diacritics 2` folding/escaping contract, literal token prefixes, 25 cap, and named café/combining/ß/Turkish/RTL cases; it never persists query values. |
| RD-U10 | Insert/search fuzz includes quotes, every FTS5 operator/metacharacter, bare boolean keywords, SQL metacharacters, emoji, combining marks, RTL, newlines, 100k boundary, and malformed UTF-8; it produces literal results/no crash, not merely parameter safety. |
| RD-U11 | Expiry purge runs before read and at launch/idle; exact-boundary behavior is deterministic; high-water time prevents rollback/advance resurrection. |
| RD-U12 | Single delete/clear remove primary/search rows atomically, run secure deletion plus truncating checkpoint, and leave old rows intact on a failed transaction. |
| RD-U13 | Switching to Off deletes store data before the preference mirror changes; a concurrent stale writer re-checks metadata and cannot recreate a row. |
| RD-U14 | Session policy removes an orderly-quit store and clears prior-session remnants on next launch; crash behavior is labelled best-effort. |
| RD-U15 | Schema vN→vN+1 migration preserves valid rows/state, is repeat-safe, rolls back fully on injected failure, uses `user_version` only, and creates no plaintext backup. |
| RD-U16 | Corrupt DB, foreign app id, future schema, no-follow/symlink attack, wrong descriptor permissions, advisory-lock contention, unsupported network filesystem, and I/O error fail closed with typed errors/no destructive reset. |
| RD-U17 | Store creates owner-only parent/database/WAL/SHM/temp/lock artifacts; path/raw error text never enters diagnostics. |
| RD-U18 | Copy writes exact saved text only on user action; Reinsert posts exact saved text (no suffix) once to a verified prior app and propagates fallback results. |
| RD-U19 | Reinsert never consults saved original application/field/clipboard/selection metadata because none exists. |
| RD-U20 | Typed history diagnostics and general logger validation reject transcript, search term, clipboard, field text, id, raw SQLite error/path, URL, and payload values carried under otherwise allowlisted names such as `reason`, `state`, or `destination`. |
| RD-U21 | Every downward transition, including Until-I-delete→bounded, atomically shortens `expires_at_ms` and immediately purges rows excluded by the new policy; increases never extend existing rows. |
| RD-U22 | Simulated abnormal termination while holding advisory lock permits next launch to open the store; no stale lockfile permanently disables history. |
| RD-U23 | Secure input sampled at finalization produces no row/FTS row and no sentinel byte in store files, regardless of retention policy. |
| RD-U24 | A history row requires enabled policy at both dictation start and finalization; enabling only mid-dictation never retains earlier speech. |

### 7.2 Integration, crash, concurrency, performance, and security tests

| ID | Requirement and exact assertion |
| --- | --- |
| RD-I01 | A real temporary SQLite store survives close/reopen after final write, including WAL recovery; it returns exact record and `pending` state. |
| RD-I02 | Injected termination after committed insert/before delivery update and after outcome update reopens without corruption or duplicate delivery. |
| RD-I03 | Many simultaneous finalizations, reads, deletes, retention changes, and UI refreshes serialize without lost rows, deadlock, SQLite `BUSY` leak, stale resurrection, or main-thread blocking. |
| RD-I04 | A reader held during clear/delete sees either a consistent old snapshot or consistent empty snapshot, never half-indexed text; subsequent read is empty. |
| RD-I05 | Migration failure/corrupt input leaves source bytes available for user-directed repair and creates no automatic plaintext export/backup artifact. |
| RD-I06 | Fuzz 10,000 generated Unicode transcripts/query strings including FTS5 expression syntax/keywords; no crash, grammar reinterpretation, SQL injection, invalid UTF-8, unbounded allocation, or log leak occurs. |
| RD-I07 | On declared reference Mac, cold-open and warm 10,000-record list/search p95 <= 100 ms; record Mac model/memory/macOS/app/dependency/fixture revisions and ensure 20 refreshes do not stall main thread >100 ms. |
| RD-I08 | Idle retention purge/clear on 10,000 records has a documented budget, never runs pre-delivery, and leaves no logical orphan FTS/WAL rows. |
| RD-I09 | Static/dynamic privacy scan of JSONL, unified log, crash/error sink, URL/file names, UserDefaults, saved-state artifacts, and CI artifacts finds no final/provisional/query/app/clipboard sentinel. |
| RD-I10 | Security audit verifies bound SQL plus FTS escaping, no-follow descriptor checks, permissions, enum constraint, size cap, no UserDefaults text/key material, Spotlight/backup exclusion, and unsupported-filesystem failure. |
| RD-I11 | Store insert failure, `BUSY`, deadline timeout, and cancellation still deliver exactly once; on a 10,000-row store the added stop-to-final delta remains within the existing 300/500/750 ms p50/p95/hard gates. |
| RD-I12 | After delete/clear/Off/purge/migration, close store and byte-scan database, WAL, SHM, FTS shadow, lock, migration, and controlled-temp artifacts: no sentinel exists; 10k maintenance never writes sentinel outside store directory. |
| RD-I13 | A PostHog fake receives zero `history_*` events/properties across full flow, and existing transcript-size values are absent or approved coarse bands only. |
| RD-I14 | The store directory has backup exclusion and `.metadata_never_index`; an integration check verifies a sentinel is not returned by Spotlight/`mdfind`. |

### 7.3 Native UI and accessibility tests (after approval)

| ID | Requirement and exact assertion |
| --- | --- |
| RD-UI01 | Fresh install shows History Off in Privacy settings, with no history menu/window entry that exposes transcript text. |
| RD-UI02 | Choosing an enabled policy displays the approved disclosure/confirmation; cancel leaves Off/no files, confirm exposes exactly approved controls. |
| RD-UI03 | A populated window opens on explicit action, debounced-announces result count, displays 20 newest records, and never binds a transcript to menu-bar label, status line, accessibility label, or notification. |
| RD-UI04 | Search by keyboard changes only local results, supports clear/empty/no-result states, caps at 25, retains accessibility focus, and has no recents/autosave/suggestions. |
| RD-UI05 | Copy produces the expected pasteboard value and accessible confirmation without auto-closing the window. |
| RD-UI06 | Reinsert requires approved confirmation, exercises successful paste/missing-Accessibility/secure-input/failed-paste feedback without duplicates, and tells user exact-text versus normal insertion suffix behavior. |
| RD-UI07 | Eligible failed final delivery offers approved history route; history Off, deadline failure, and secure input show only ordinary clipboard fallback and never prompt to retain. |
| RD-UI08 | Delete/clear/Off confirmations are keyboard operable, default to cancel, remove rows on confirmation, show the approved empty state, and do not repeat sensitive transcript text in a confirmation. |
| RD-UI09 | VoiceOver labels/values/hints, keyboard traversal, large text, high contrast, dark/light appearance, reduced motion, localization expansion, and selected-text copy all meet the approved mockup contract. |
| RD-UI10 | Opening/closing/history refresh does not steal focus from the former target app except after explicit Reinsert confirmation, and the app releases observers/windows after close. |
| RD-UI11 | With history window key, Reinsert deactivates it and delivers only to the previously-frontmost verified app; if that app quit/changed, it never pastes into Saymark and offers Copy. |
| RD-UI12 | Search a sentinel, quit/relaunch, and assert no sentinel in UserDefaults or saved-application-state artifact; window is non-restorable and sharing policy matches approved mockup. |

## 8. Requirements-to-tests traceability

| Requirement | Primary tests | Release evidence |
| --- | --- | --- |
| Local text-only history, no audio/provisional/secure-input text | RD-U01, U03–U04, U20, U23–U24, I09–I10 | Privacy scan and fixture review |
| Explicit default-Off / retroactive retention controls | RD-U01–U02, U13–U14, U21, UI01–UI02, UI08 | Approved settings/shortening mockup and UI run |
| 20 initial / 25 max literal local search | RD-U08–U10, I06–I07, UI03–UI04 | FTS escaping decision and cold/warm 10k p95 report |
| Copy and explicit Reinsert target safety | RD-U18–U19, UI05–UI06, UI11 | Target/fallback matrix |
| Bounded final recovery / no delivery dependency | RD-U03–U07, U24, I01–I03, I11, UI07 | Failure injection and stop-to-final delta report |
| Crash consistency / migration / concurrency | RD-U07, U11–U17, U22, I01–I05 | Migration/crash/temp containment fixtures |
| Delete/clear/Off byte removal | RD-U12–U14, U21, I04, I08, I12, UI08 | Byte-level DB/WAL/SHM/FTS/temp report |
| Data protection and injection resistance | RD-U10, U16–U17, I06, I10, I14 | Security review/check output |
| Accessibility and disclosure-safe UI | RD-UI01–UI12 | Approved mockups and XCUITest artifacts |
| Privacy-safe diagnostics/telemetry | RD-U20, I09, I13 | Closed-value logger diff and PostHog negative scan |

## 9. Open questions and risks

1. **Approval gate:** the retention choices, indefinite option, window layout,
   failure affordance, and Reinsert confirmation materially affect privacy and
   require the mockups above.
2. **macOS backup semantics:** the implementation prevents future Spotlight and
   Time Machine inclusion, but cannot ensure removal from backup/APFS snapshots
   already created. Product/legal wording needs review.
3. **App-level encryption:** FileVault is optional and ordinary permissions do
   not protect an unlocked account.  Decide whether a future Keychain-backed
   encrypted store is needed before representing history as “encrypted.”
4. **Session-only guarantee:** a process crash can leave bytes until next launch
   or OS-level recovery.  The wording must say best effort, or omit this option.
5. **FTS footprint:** FTS shadow tables duplicate sensitive text. The selected
   FTS5 design, byte-removal proof, and controlled temporary storage are release
   gates, not optional implementation details.
6. **Export:** recent-dictation recovery does not claim Slice 3 completion;
   file transcription and export remain separately designed work in the roadmap.
7. **Live-insertion dependency:** this feature has no reserved live state and
   must not imply live revision behavior exists before independent approval.
8. **PostHog privacy:** existing exact transcript-size properties require a
   separate approved removal/banding change before this feature can claim its
   no-fingerprinting contract.
9. **Video evidence:** the final demo must use synthetic transcript text and a
   test profile, never a real person's retained history.

## 10. Claude Opus independent-review package

The initial independent review is retained in
[`reviews/recent-dictations-claude-opus-5.md`](reviews/recent-dictations-claude-opus-5.md).
Re-submit this revision plus that review/disposition before implementation:

- `docs/recent-dictations-sdd.md` (this contract)
- `docs/product-roadmap.md`, `docs/privacy-and-security.md`,
  `docs/diagnostic-logging.md`, `docs/performance-acceptance.md`, and
  `docs/integration-testing.md`
- `Sources/Saymark/DictationController.swift`, `Sources/Saymark/Theme.swift`,
  `Sources/Saymark/SettingsView.swift`, and `Sources/Saymark/MenuPopover.swift`
- `SaymarkKit/Sources/SaymarkKit/TextInjector.swift` and
  `SaymarkKit/Sources/SaymarkKit/DiagnosticLogging.swift`

Suggested review prompt:

> You are the independent security, architecture, SDD, and TDD reviewer for
> Saymark, a native local-first macOS dictation app. Review the attached Recent
> Dictations and insertion-recovery design against the attached existing
> product/privacy/insertion code. Do not edit files or implement code. Identify
> concrete correctness, privacy, security, crash-consistency, SQLite/WAL/FTS,
> concurrency, migration, accessibility, macOS data-protection, and test-gap
> findings. Verify that no audio, provisional transcript, focused-app text,
> selected text, clipboard content, search query, record id, or raw error can
> reach persistence outside the local history store, diagnostics, telemetry,
> or UI. Challenge any unjustified encryption/deletion claim. Classify every
> finding as blocker, high, medium, or note; cite document section and relevant
> source file; and end with a concise must-fix list before implementation.
