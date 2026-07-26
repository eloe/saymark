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
- recovery of final text after delivery fails, including secure-input and
  Accessibility fallbacks; and
- retention, deletion, and clear-history controls that are understandable
  before sensitive text is persisted.

It must not provide:

- microphone audio, waveform, provisional hypothesis, selected text, active
  application, field contents, cursor position, clipboard snapshot, or screen
  capture retention;
- network sync, cloud backup, remote search, account identity, analytics of
  text/query values, or automatic re-insertion/replay;
- a history record while history is Off; or
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
| This session | final text until app termination | Delete on orderly quit; on relaunch remove any prior session store before accepting a new record. It is crash-recovery-best-effort, not a durability promise. |
| 7 / 30 / 90 days | final text until its individual expiry | Purge expired records at launch, before reads, after writes, and when the policy changes. |
| Until I delete | final text | Show the chosen indefinite retention plainly; clear/delete remains available. |

The recent-list query is newest first, has a default limit of **20**, and has a
hard cap of **25** regardless of caller.  Search is local, case- and
diacritic-insensitive literal token/prefix search over transcript text; it does
not use a remote embedding or an opaque ranking service.  It returns the same
maximum.  The list deliberately does not promise a complete archive browser.

Record creation has a size limit of 100,000 UTF-8 bytes after finalization.  A
larger final text is not retained; the delivery flow still uses the complete
text and emits only the content-free category `history_record_too_large`.
This bound prevents one paste from consuming unbounded disk and must be shown
in the retention explanation only if product chooses to expose it.

### 2.2 When a record is written

1. A dictation obtains a non-empty, authoritative final transcript.
2. The main actor snapshots the history policy for that dictation.  If it is
   Off, no text is handed to history code.
3. If enabled and within the size bound, `HistoryStore` durably inserts the
   final transcript in one database transaction **before** final delivery is
   attempted.  It sets `delivery_state = pending` and no destination metadata.
4. The existing live/final delivery code runs exactly once.  It maps only the
   outcome category to the same record: `inserted`, `copied_accessibility`,
   `copied_secure_input`, `insertion_failed`, `hud_only`, or
   `revision_stopped_ownership_lost` (the last is reserved for live insertion).
5. A delivery-state update failure never causes a second insert, a second
   transcript write, or a delivery retry.  The record remains recoverable with
   state `pending_or_unknown`.

No-speech, cancellation before final text, model failure without final text,
and a user disabling history before the finalization snapshot do not create a
record.  Text is stored as the final transcript exactly as supplied by the
authoritative final model, without the presentation-only trailing space used by
`TextInjector.paste`.

This ordering is intentional: if Saymark crashes after a failed paste, after
secure input blocks synthetic paste, or while Accessibility is unavailable, the
person has a durable recovery copy.  It does mean a successful insertion can
briefly have a `pending_or_unknown` record after a crash; the UI must describe
that as delivery status unknown, never as proof the text was not inserted.

### 2.3 Recovery behavior

For a normal final insertion failure, secure-input fallback, or missing
Accessibility permission, the HUD retains the existing immediate feedback and
clipboard fallback.  When history was enabled at finalization, that feedback
also offers a non-destructive route to the saved item (exact wording and
placement need approval).  If history was Off, the existing clipboard fallback
is the only recovery route and must not turn history on.

For planned live insertion, focus loss, selection/cursor changes, or a
user-owned edit stop Saymark's revisions as required by
[performance acceptance](performance-acceptance.md#human-perceived-live-insertion-gates).
At finalization Saymark saves only the final transcript, marks the associated
delivery result as `revision_stopped_ownership_lost`, and requires the user to
choose Copy or Reinsert.  It never tries to discover, replace, or reconstruct
text in the target field.  If safe atomic final insertion remains available,
that fallback is a separate, explicitly approved delivery decision; history
does not make it safe.

Copy writes the exact saved text to the general pasteboard and reports success
or failure.  Reinsert performs one fresh `TextInjector.paste(text + " ")` into
the *current* focused field after the user invokes it; it has the same
Accessibility, secure-input, clipboard-restoration, and result reporting rules
as a new dictation.  Reinsert must visibly identify that it will affect the
currently focused app, cannot be invoked by keyboard focus alone without an
activation action, and never runs automatically when a history window opens.

## 3. Architecture and data model

### 3.1 Ownership and interfaces

`SaymarkKit` gains a UI-independent `HistoryStore` protocol and a single
serialized SQLite implementation.  It owns persistence, migration, retention
purging, capped queries, and deletion.  It accepts final text only through a
small value type and exposes records only to the app's history presentation.
It must not depend on SwiftUI, AppKit, HUD state, PostHog, or speech models.

`Sources/Saymark` owns the `HistoryController`/observable presentation state,
the settings choice, the history window, user intent for Copy/Reinsert, and
mapping current delivery results to the store.  `DictationController` creates
the record once after finalization and before final delivery.  `TextInjector`
remains the sole pasteboard/event-delivery primitive.  A dependency-injected
clock, store URL, and delivery adapter make policy and crash/failure paths
deterministic in tests.

The store is an actor (or an equivalent private serial executor) with no
long-lived read transaction across UI rendering.  UI operations receive value
snapshots.  A monotonically increasing `revision` lets the controller ignore
out-of-order refreshes after a delete, retention change, or concurrent write.
All app-facing APIs are cancellation-aware: cancellation abandons the caller's
result, never half-applies a transaction.

### 3.2 Storage location and format

For bundle id `B`, the preferred path is:

```text
~/Library/Application Support/B/RecentDictations/history.sqlite3
~/Library/Application Support/B/RecentDictations/history.sqlite3-wal
~/Library/Application Support/B/RecentDictations/history.sqlite3-shm
```

The directory is created with owner-only permissions (`0700`); database,
WAL, SHM, temporary migration, and lock files are owner-read/write (`0600`).
Use the Application Support directory discovered through `FileManager`, not a
hard-coded home path, Documents, Logs, defaults, the pasteboard, or a cache.
The directory is excluded from diagnostic-log paths and from all “Reveal
diagnostic log” actions.

SQLite is selected for atomic transactions, bounded indexed reads, crash
recovery, and schema migration.  Use `journal_mode=WAL`, `foreign_keys=ON`,
`busy_timeout`, `synchronous=FULL`, and a transaction for every mutation.
Checkpoint the WAL after destructive retention/deletion work when it does not
block an active reader.  An implementation may instead use a private rollback
journal only if it preserves the same atomicity and recovery tests.

Minimal schema (schema version 1):

| Column | Type / constraint | Purpose |
| --- | --- | --- |
| `id` | UUID text, primary key | Opaque record identity; never sent remotely. |
| `created_at_ms` | integer, indexed | Local creation time for order and expiry. |
| `expires_at_ms` | integer nullable, indexed | Retention boundary; null only for Until I delete. |
| `text` | text, non-empty | Exact final transcript. |
| `delivery_state` | constrained text | Content-free recovery status from §2.2. |
| `delivery_updated_at_ms` | integer nullable | Audits a state transition locally. |
| `schema_version` | integer | Store migration guard. |

Search uses SQLite FTS5 with an external-content table or a reviewed indexed
normalized column.  The implementation must document the selected option,
keep it transactionally consistent with `records`, and ensure delete/clear
removes its rows too.  Search text is still local sensitive data; FTS shadow
tables receive the same permissions and deletion requirements.

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
versioned policy value, and an optional one-time education marker.  Invalid,
unknown, or future policy values resolve to Off and schedule a safe cleanup;
they must never resolve to indefinite retention.

Database startup follows this sequence:

1. verify the parent is not a symlink and has expected owner-only permissions;
2. take the single-process/store lock and open SQLite without logging its path
   if an error contains user-controlled components;
3. verify application id, `user_version`, schema, and constraints;
4. run each migration in one transaction, with an atomic pre-migration backup
   only when required for rollback and with the backup removed after success;
5. purge expired rows and orphaned search rows transactionally; then make the
   store available.

An unsupported newer schema, corrupted database, failed permission check, or
failed migration closes the store and disables history for the run without
deleting original data.  The UI surfaces a content-free recovery/error state.
It must never silently reset the store.  The repair/export choice requires
approval before implementation because an export itself contains sensitive
text.

Single-delete is transactional: delete the record and all search-index entries,
then refresh the UI.  Clear History uses an explicit confirmation, a single
transaction, WAL checkpoint, and a new empty database state; turning history
Off also runs clear/delete before persisting Off.  A concurrent write that began
under the previous policy must re-check policy inside the write transaction and
fail closed rather than recreate history after Off.  Best-effort VACUUM may be
offered only after deletion if it can be cancelled and its limitations are
documented; it is not a secure-wipe guarantee.  Users needing removal from
Time Machine, APFS snapshots, or other backups need OS-level backup controls;
the product must not claim otherwise.

## 4. Privacy, security, accessibility, and telemetry model

### 4.1 Data-flow rules

| Data | Allowed location/use | Forbidden |
| --- | --- | --- |
| Final transcript | in-memory delivery; opted-in local history database; user-initiated copy/reinsert | diagnostics, unified log, PostHog, crash payload, URL, filename, preferences, model benchmark output |
| Provisional/live text | transient HUD/field ownership state only | history, database, telemetry, log |
| Audio | active capture/inference buffers only | history, database, export, logs, telemetry |
| Search query | transient local UI/store query only | persistence, logs, telemetry, remote requests |
| App/focus/field/selection/clipboard data | current delivery primitive only where already required | history rows, delivery metadata, telemetry |
| Record id/timestamp/outcome | local database; aggregate content-free diagnostics | remote identity correlation or text-derived identifiers |

All errors crossing the history boundary are typed categories (`unavailable`,
`corrupt`, `migration_failed`, `permission_denied`, `busy`, `io_failed`) rather
than raw SQLite descriptions or SQL.  SQL must use bound parameters.  The
database is never exposed to plugins, scripts, model adapters, or arbitrary
file paths.  Do not support clickable links, rich text, or automatic execution
of transcript content in the list; render as plain, selectable text.

### 4.2 Privacy-safe telemetry and diagnostics

Remote telemetry remains disabled under the existing product policy.  If local
diagnostics are enabled, the only allowed history fields are reviewed scalar
counts/durations/categories, for example `history_enabled` (boolean),
`retention_kind` (enum), `history_query_result_count` (0–25),
`history_operation` (insert/query/delete/clear/purge), `history_outcome`
(success/failed category), and elapsed milliseconds.  Do not log record ids,
timestamps, retention durations that identify a person, text lengths precise
enough to fingerprint a short phrase, search term count, or delivery target.
New fields must be added to `SaymarkDiagnostics`' allowlist and its negative
privacy tests before use.

Test fixtures must use synthetic, non-personal text.  Test databases,
WAL/SHM, exports, and crash artifacts belong under temporary test directories
and are removed in teardown.  No real user history database may enter a bug
report, repository, CI artifact, video, or PR screenshot.

### 4.3 Accessibility and interaction requirements

- The history window has a labelled navigation hierarchy: retention summary,
  search field, result count, result list, selected-record content, delivery
  status, Copy, Reinsert, Delete, Clear History, and close controls.
- The list uses stable accessibility identifiers and announces results/empty
  state without reading every transcript on each refresh.  Screen-reader focus
  remains on the nearest surviving row after delete; after clear it moves to
  the empty-state heading.
- All actions are keyboard reachable with standard focus order.  Destructive
  actions require confirmation whose default button is non-destructive.  Copy
  and Reinsert expose their destination and fallback outcomes in accessible
  text, not color alone.
- Use Dynamic Type/system text sizing, high contrast, VoiceOver labels,
  reduced motion, localization-friendly strings, and no time-only error
  message.  Transcript text must be selectable and must not be truncated
  without an accessible way to read the full value.
- Opening history, search, deletion, and retention changes must not steal focus
  from the target app until a person explicitly opens history.  Reinsert warns
  before it changes the current target, which may differ from the app used for
  the original dictation.

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
4. **Destructive confirmation.**  Delete shows what will be removed without
   restating text in the confirmation; Clear/Off says that saved transcript
   text will be removed locally and explains backup limitations succinctly.

### Approval required

Implementation must pause for a user-approved mockup covering these decisions:

| Decision | Proposed default | Why approval is needed |
| --- | --- | --- |
| Enablement and retention selector | Off until an explicit choice; recommended 30 days | This changes how long sensitive user text persists. |
| Retention choices | This session, 7, 30, 90 days, Until I delete | The product must balance recovery with privacy. |
| History access and layout | Menu item opens a standard window with list/detail | Determines discoverability, information density, and accidental disclosure risk. |
| Result presentation | 20 initially, 25 maximum; full text selected in detail pane | Determines whether text is exposed in the menu or only on explicit open. |
| Failure affordance | HUD link to history only when a record exists | Affects the recovery path and visible failure copy. |
| Reinsert confirmation | Required; names current focused app only if safe to obtain without retaining it | Reinsert can change a different app than the original target. |
| Delete/Clear/Off confirmation and backup wording | Explicit confirmation, no secure-wipe claim | This is privacy-critical language. |
| Session-only crash behavior | Best-effort removal at next launch, not a durability claim | Users need a truthful expectation. |

**Minimum mockup package:** (a) Privacy settings before and after choosing an
enabled retention policy, including confirmation; (b) populated and empty
history window at normal and large text size; (c) secure-input/insertion-failed
HUD recovery state; (d) Reinsert confirmation when the current focused app is
different/unknown; and (e) Delete, Clear History, and turning-Off
confirmations.  Provide light and dark macOS appearances plus VoiceOver labels
or an accessibility annotation sheet.  Do not proceed to production UI until
these are approved.

## 6. Test-driven implementation plan

Every slice starts with a failing test.  Tests use an injected temporary store,
fixed clock, and fake delivery/insertion boundaries; no test records real audio
or production history text.

### Slice A — policy and store foundation

Implement `HistoryRetentionPolicy`, record value types, store URL/permission
validation, SQLite schema, transaction wrapper, and a disabled no-op store.
Unit tests must prove Off never creates a directory or accepts text, invalid
policy resolves to Off, expiry is calculated correctly across time zones/DST
(using epoch milliseconds), rows are newest-first, and any public query clamps
its requested limit to 25.

### Slice B — durable finalization and recovery state

Add the pre-delivery record write and content-free delivery-outcome transition.
Use a fake `TextInjector` to test inserted, unavailable Accessibility,
secure-input, synthetic-paste failure, HUD-only, unknown-after-crash, and
planned live-ownership-lost categories.  Prove delivery happens once even when
the state update fails, and history never makes a retry automatic.

### Slice C — retention, search, migration, and deletion

Add index/search, expiry purge, single delete, clear/Off transition, schema
migrations, corruption handling, concurrent policy/write interleavings, and
WAL/FTS cleanup.  Add the 10,000-record performance fixture and verify no
content escapes diagnostics.

### Slice D — approved native UI and accessibility

After mockup approval, add settings, history window, recovery route, copy,
reinsert confirmation, destructive confirmations, localization, and
accessibility identifiers.  XCUITest covers the visible approved flows and
test-only adapters isolate Accessibility/pasteboard/model boundaries.

### Slice E — acceptance and release evidence

Run unit, app, UI, security, privacy, and performance suites; inspect test
diagnostics/artifacts for text leakage; make a consented demo using synthetic
text only.  Record retention choice, test environment, migration version,
10,000-row query measurements, and unresolved risks in the PR.

## 7. Exhaustive acceptance cases

### 7.1 Unit and component tests

| ID | Requirement and exact assertion |
| --- | --- |
| RD-U01 | Fresh/default/invalid/future preferences resolve to Off; no history directory, DB, WAL, SHM, or text-bearing log is created. |
| RD-U02 | Each enabled policy produces the correct nullable expiry; 7/30/90 days use elapsed epoch duration, not a local calendar boundary. |
| RD-U03 | A final non-empty text is stored exactly once before a fake delivery call; the text has no synthetic trailing insertion space. |
| RD-U04 | Empty final, cancellation, pre-final failure, too-large final, and Off policy store no record; delivery semantics remain unchanged. |
| RD-U05 | A delivery-state transition supports only the reviewed enum, is idempotent, and cannot create a missing record. |
| RD-U06 | Final insertion, HUD-only, missing Accessibility, secure input, injection failure, and ownership loss map to the required content-free states. |
| RD-U07 | If outcome update fails or process restarts between write/update, one recoverable `pending_or_unknown` row exists and delivery is not invoked again. |
| RD-U08 | List/search are newest first, deterministic for equal timestamps via opaque id ordering, default 20, and caller values 0/negative/26/huge clamp safely to 1…25. |
| RD-U09 | Search is local literal token/prefix, case/diacritic insensitive, parameter-bound, returns no more than 25, and does not persist query values. |
| RD-U10 | Insertion/deletion/search text with quotes, SQL metacharacters, emoji, combining marks, RTL text, newlines, 100k-byte boundary, and malformed UTF-8 input is preserved/rejected safely. |
| RD-U11 | Expiry purge runs before read and after write; exact-boundary behavior is deterministic; clock rollback/advance cannot resurrect an expired row. |
| RD-U12 | Single delete and clear remove primary/search rows atomically; a failed transaction leaves both old rows intact. |
| RD-U13 | Switching to Off deletes store data before preference becomes Off; a concurrent stale writer re-checks policy and cannot recreate a row. |
| RD-U14 | Session policy removes an orderly-quit store and clears prior-session remnants on next launch; crash behavior is labelled best-effort. |
| RD-U15 | Schema vN→vN+1 migration preserves valid rows/state, is repeat-safe, and rolls back fully on injected failure. |
| RD-U16 | Corrupt DB, foreign application id, unsupported future schema, symlinked parent, wrong permissions, locked DB, and I/O failure fail closed with typed errors and no destructive reset. |
| RD-U17 | Store creates parent/database/WAL/SHM/temp files owner-only; file path/error text never enters diagnostics. |
| RD-U18 | Copy writes exact saved text only when user invokes it; Reinsert calls the existing injector once with the expected trailing-space policy and propagates its fallback result. |
| RD-U19 | Reinsert never consults saved original application/field/clipboard/selection metadata because none exists. |
| RD-U20 | Diagnostics permit only reviewed scalar history fields; a corpus containing transcript, search term, clipboard, field text, id, SQLite error, and URL is rejected. |

### 7.2 Integration, crash, concurrency, performance, and security tests

| ID | Requirement and exact assertion |
| --- | --- |
| RD-I01 | A real temporary SQLite store survives close/reopen after final write, including WAL recovery; it returns the exact record and pending state. |
| RD-I02 | Injected termination after committed insert/before delivery update and after outcome update reopens without corruption or duplicate delivery. |
| RD-I03 | Many simultaneous finalizations, reads, deletes, retention changes, and UI refreshes serialize without lost rows, deadlock, SQLite `BUSY` leak, stale resurrection, or main-thread blocking. |
| RD-I04 | A reader held during clear/delete sees either a consistent old snapshot or consistent empty snapshot, never half-indexed text; subsequent read is empty. |
| RD-I05 | Migration failure/corrupt input leaves source bytes available for user-directed repair and creates no automatic plaintext export/backup artifact. |
| RD-I06 | Fuzz 10,000 generated Unicode transcripts and query strings; no crash, SQL injection, invalid UTF-8 output, unbounded allocation, or log leak occurs. |
| RD-I07 | On reference Mac, a warm 10,000-record database returns list/search p95 <= 100 ms; 20 concurrent UI refreshes do not stall the main thread >100 ms. |
| RD-I08 | Retention purge and clear on 10,000 records complete within a documented budget, show cancellable progress only if UI work exceeds 250 ms, and do not leave orphan FTS/WAL rows. |
| RD-I09 | Static/dynamic privacy scan of JSONL, unified log test sink, PostHog fake, crash/error sink, URL/file names, and CI artifacts finds no sentinel final text, provisional text, search query, app text, or clipboard sentinel. |
| RD-I10 | Security audit verifies parameter binding, symlink rejection, permissions, constrained state enum, size cap, no network request, no UserDefaults text, and no key material in source/defaults. |

### 7.3 Native UI and accessibility tests (after approval)

| ID | Requirement and exact assertion |
| --- | --- |
| RD-UI01 | Fresh install shows History Off in Privacy settings, with no history menu/window entry that exposes transcript text. |
| RD-UI02 | Choosing an enabled policy displays the approved disclosure/confirmation; cancel leaves Off/no files, confirm exposes exactly approved controls. |
| RD-UI03 | A populated window opens on explicit action, announces result count, displays 20 newest records, and never shows a transcript in the menu-bar label or notification. |
| RD-UI04 | Search by keyboard changes only local results, supports clear/empty/no-result states, caps at 25, and retains accessibility focus. |
| RD-UI05 | Copy produces the expected pasteboard value and accessible confirmation without auto-closing the window. |
| RD-UI06 | Reinsert requires the approved confirmation, then exercises successful paste, missing-Accessibility, secure-input, and failed-paste feedback without duplicate events. |
| RD-UI07 | A failed final delivery with history enabled offers the approved history route; history Off shows only the ordinary clipboard fallback and does not prompt to enable retention. |
| RD-UI08 | Delete/clear/Off confirmations are keyboard operable, default to cancel, remove rows on confirmation, show the approved empty state, and do not repeat sensitive transcript text in a confirmation. |
| RD-UI09 | VoiceOver labels/values/hints, keyboard traversal, large text, high contrast, dark/light appearance, reduced motion, localization expansion, and selected-text copy all meet the approved mockup contract. |
| RD-UI10 | Opening/closing/history refresh does not steal focus from the former target app except after explicit Reinsert confirmation, and the app releases observers/windows after close. |

## 8. Requirements-to-tests traceability

| Requirement | Primary tests | Release evidence |
| --- | --- | --- |
| Local text-only history, no audio/provisional text | RD-U01, U03–U04, U20, I09–I10 | Privacy scan and fixture review |
| Explicit default-Off retention controls | RD-U01–U02, U13–U14, UI01–UI02, UI08 | Approved settings mockup and UI run |
| 20 initial / 25 max results and local search | RD-U08–U10, I06–I07, UI03–UI04 | 10k p95 report |
| Copy and explicit Reinsert | RD-U18–U19, UI05–UI06 | Target/fallback matrix |
| Final/live insertion recovery | RD-U03, U05–U07, U18, I01–I03, UI07 | Failure-injection report |
| Crash consistency / migration / concurrency | RD-U07, U11–U17, I01–I05 | Migration and crash fixtures |
| Delete/clear/Off semantics | RD-U12–U14, I04, I08, UI08 | DB/FTS/WAL inspection |
| Data protection and injection resistance | RD-U10, U16–U17, I06, I10 | Security review/check output |
| Accessibility and disclosure-safe UI | RD-UI01–UI10 | Approved mockups and XCUITest artifacts |
| Privacy-safe diagnostics/telemetry | RD-U20, I09–I10 | Logger allowlist diff and negative scan |

## 9. Open questions and risks

1. **Approval gate:** the retention choices, indefinite option, window layout,
   failure affordance, and Reinsert confirmation materially affect privacy and
   require the mockups above.
2. **macOS backup semantics:** the UI can accurately state local storage and
   deletion limitations, but cannot ensure removal from Time Machine/APFS
   snapshots.  Product/legal wording needs review.
3. **App-level encryption:** FileVault is optional and ordinary permissions do
   not protect an unlocked account.  Decide whether a future Keychain-backed
   encrypted store is needed before representing history as “encrypted.”
4. **Session-only guarantee:** a process crash can leave bytes until next launch
   or OS-level recovery.  The wording must say best effort, or omit this option.
5. **FTS footprint:** FTS improves the 10k target but duplicates sensitive text
   in shadow tables.  The implementation/security review must choose FTS versus
   a bounded normalized-index strategy and test deletion of every artifact.
6. **Export:** the roadmap mentions export, but this focused recovery feature
   deliberately does not add it.  It needs a separate format, destination,
   overwrite, content-warning, and privacy design.
7. **Live-insertion dependency:** this feature can record a reserved ownership
   loss category now, but must not imply live revision behavior exists before
   that feature is independently approved and implemented.
8. **Video evidence:** the final demo must use synthetic transcript text and a
   test profile, never a real person's retained history.

## 10. Claude Opus independent-review package

Authenticate the Claude CLI before implementation and submit this document plus
these repository files as read-only context:

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
