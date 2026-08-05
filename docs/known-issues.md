# Known Issues

Deliberately unfixed issues carried out of the data-layer implementation, with
the reasoning that led to deferring each one. Everything here was found in
review and left open on purpose — none of it is a surprise.

## Blocking a real user

### Backfill advances its watermark on a degraded sync result

`Glyphline/Sync/SyncCoordinator.swift` — `saveBackfillCompletedThrough` runs
after `scheduler.sync` returns, and a refused credential no longer throws: all
three adapters turn a 401/403 into a returned result with
`dataQuality: .unavailable`. The slice therefore "succeeds" and the watermark
advances.

A user who adds an account with a plain API key — the default selection in the
Add Account sheet — and starts backfill walks every slice issuing refused
requests, records the watermark all the way back to the horizon, and ends
`.idle`. When the key is later corrected, `resumePoint == horizon`, the
`while cursor > horizon` loop never executes, and the history is permanently
absent. There is no UI to clear the watermark.

Fixing it means `scheduler.sync` surfacing the result's data quality so a
degraded slice does not advance the watermark. That is a design change to the
sync contract, not a local repair, which is why it was not folded into the
final fix wave.

### Backfill has no rate-limit backoff

A full backfill is roughly 53 sequential round trips. A 429 surfaces as a slice
failure; the watermark is kept and the run resumes — but only on the next
manual Sync Now, and see the issue above for what "resumes" currently means.

## Correctness, contained today

### Decode failures propagate while credential rejections degrade

`ClaudeUsageAdapter`, `CursorUsageAdapter`, `OpenAIUsageAdapter` — a 401/403
degrades to an `.unavailable` result with a specific message, but a malformed
response body throws out of `sync`. `SyncScheduler` catches it and records a
`.providerSyncFailed` run, so no data is lost; the user simply gets the generic
failure text instead of something actionable. No test covers the decode-failure
path on any adapter.

### No test pins how a provider terminates the final bucket

If an API clamps the last bucket's `end_time` to the requested `end_time`
rather than to the nominal bucket boundary, every routine sync mints a fresh
`bucketEnd` for today and rows accumulate instead of replacing — the same
defect family as the three partial-bucket bugs this branch already fixed. It
cannot be verified from the code. Worth one live-API check per provider before
release.

### `pricing-v1.json` has no cache-read price for OpenAI

OpenAI's cached input is now classified as `cacheReadTokens`, and with no
explicit entry those tokens are priced through the
`inputMicrosPerMillionTokens / 10` fallback. Blast radius is near zero —
`estimateMissingCosts` only runs for accounts with no cost snapshots, and
OpenAI reports actual costs — and the fallback is closer to reality than
charging cached input at the full input rate. Still worth an explicit entry.

### The pricing catalog has no time dimension

One price per model, applied to every period the statistics screen offers. Two
consequences, both understating nothing and overstating a little:

- Claude Sonnet 5 carries introductory pricing ($2/$10 per million rather than
  $3/$15) through 2026-08-31. The catalog holds the standard rate, so tokens
  spent inside that window are valued above what the API would have charged.
- A price change of any kind is applied retroactively to the whole history the
  moment the catalog is edited.

Fixing it means an effective-date range per entry and picking the entry by the
bucket's own date — the `effectiveDate` field is already there and already
unused for exactly this. Not worth it while the figure is labelled an estimate
of what API billing would have cost, but it is the reason two runs of the same
period can disagree after a catalog update.

## Storage and lifecycle

### Watermark rows are never evicted

One `SyncWatermark` row per Claude Code transcript file, forever — 2,887 on the
reference install and growing. A once-per-sync sweep deleting rows whose file no
longer exists would bound the table.

That sweep also addresses the one version of the privacy question with teeth:
`sourceKey` stores absolute transcript paths, whose slugs encode real project
directory names. That was reviewed and accepted — the SQLite file lives under
the same user account as `~/.claude/projects`, whose transcripts are a strictly
larger disclosure the user has already accepted, and hashing the key would make
watermark rows undebuggable. But retaining directory names for projects the
user has since deleted is a different matter, and eviction fixes it.

### The ledger now has `-wal` and `-shm` siblings

`DatabaseQueueFactory` opens the on-disk ledger in WAL mode. Nothing copies or
deletes the database by path today, so nothing breaks — but any future export,
backup, or reset feature must handle all three files.

### Four independent `LedgerStore` handles

`GlyphlineApp`, `DashboardView`, `MenuBarView` and `AddAccountView` each open
their own `DatabaseQueue` on the same file. WAL plus a five-second busy timeout
makes this safe, but `LedgerStore`'s `@unchecked Sendable` justification is only
true per connection. Consolidating to a single injected store would make the
assertion true again and remove the four `makeDefault()` calls.

`AccountsView` carried a fifth `makeDefault()` as a property default. It was
recorded here as latent, on the grounds that its only caller passes a store — and
that was true of the *app*. It was not true of the suite: the test host is the
app itself, so two tests that omitted the argument opened the real ledger under
`~/Library/Application Support/Glyphline` and ran its migrations, once against a
database an installed copy was writing to at the same time. The default is gone;
the memberwise initialiser now defaults it to `nil`.

`SettingsScene.init` still carries the same default and is the one place that
genuinely needs it. Nothing in the suite constructs it, so nothing reaches it
today — which is precisely what was said about `AccountsView`.

### Web session stores orphaned before this branch

Both routes that created orphans are now closed. Deleting an account removes its
`WKWebsiteDataStore` *before* the ledger rows, so a failure can never strand a
session with no account naming it; and `AddAccountFlow` removes the store on
every exit that saves nothing — a cancelled sign-in, a failed verification, a
sign-in with no Max subscription, and a failing `saveAccount`.

That last one was found only by the whole-branch review, and it was the common
case: closing the sign-in window left a store on disk forever, because its
identifier derives from an account id that was never written. A per-task review
could not see it — the add path and the delete path are each correct alone.

Two things this does not cover:

**Cleanup is best-effort.** All four add-path exits use `try?`, because a cleanup
failure must not mask the outcome the user is already being told about. A WebKit
removal that fails there still strands a store. Worth watching specifically: the
cleanup fires immediately after the sign-in window tears its web view down, and
if WebKit still considers the store live at that instant, `remove(forIdentifier:)`
can fail silently.

**Stores orphaned before this branch are unreachable.** Nothing in the ledger can
name them. Only a sweep of `~/Library/WebKit/<bundle-id>/WebsiteDataStore/`
against the set of live account ids could find them, and that sweep is its own
task — it must not delete a store belonging to an account that merely failed to
load.

### Backfill cancellation is cooperative

`SyncCoordinator.deleteAccount` cancels the backfill *before* the durable delete,
which closes the window for a new slice. It cannot stop a slice already suspended
inside `scheduler.sync(...)` — that one completes and writes its snapshots under
an account id the ledger is about to forget. With no foreign keys those rows
survive invisibly, unreachable by every query that starts from an account.

Bounded and rare: it needs a delete issued during the seconds a slice is in
flight. Checking the account still exists before each snapshot write would close
it properly.

### Quota reporting is Max-only, by choice

`ClaudeOrganizationsDTOs` selects the organisation whose capabilities contain
`claude_max`. A Claude **Pro** subscriber signs in successfully and is then told
quota reporting is not available. That is honest and never reports a wrong
number, which is the property that matters — but it will read as a bug to a Pro
subscriber, so it belongs here rather than in a bug report.

### The WebKit layer has no automated coverage, by construction

`ClaudeWebPageLoader`, `ClaudeSignInWindow` and `ClaudeWebSessionStore.removeSession`
are verified only by the compiler and by using the app: every test drives a fake,
because a test that drove the real thing would open a browser window on the
developer's screen and reach claude.ai. One manual pass — add, sign in, let a tick
run, delete, confirm the store directory is gone — is the only thing that
exercises the branch's central mechanism end to end.

Three smaller items in the same layer, all noticed by review rather than by a
failure:

- `decidePolicyFor navigationResponse` does not check `isForMainFrame`, so
  `statusCode` is whatever the last response was, including a subframe's. Harmless
  on today's JSON endpoints, but that field decides `sessionExpired` versus
  `transportFailure`.
- `noteQuotaFailure` decides whether to notify by comparing a *rendered sentence*
  against `RateWindowSourceError.sessionExpired.message`. Reword two errors to the
  same sentence and the notification misfires. Threading the error case through
  instead of its message would make it structural.
- `ClaudeSignInWindow` sets no `WKUIDelegate`, so `window.open` returns nil. If
  claude.ai ever routes an identity provider through a popup, it would do nothing
  with no visible reason.

## Cosmetic

- `Glyphline/UI/AccountSummaryFormatting.swift` — the `endsAt` and `startsAt`
  branches are unreachable for every shipping provider: reaching them needs
  `supportsResetDate == true` with `resetAt == nil`, and every producer that
  sets the flag also sets the date.
- Claude and OpenAI still persist a `billingResetAt` that nothing can display,
  since both declare `supportsResetDate: false`. Harmless now, a trap if anyone
  later flips that flag.
- The Settings copy states that Glyphline syncs after the Mac wakes without
  qualifying it; the wake observer is only installed while automatic sync is
  enabled.
- Per-token-class integer division truncates independently, losing up to three
  micros per snapshot. Deterministic, always toward zero, far below the pricing
  table's own noise floor.

## Not an issue

**No migration is needed for the OpenAI bucket-boundary change.** Forcing
`OpenAIUsageAdapter` onto a UTC calendar changes where day buckets fall, so
pre-change and post-change rows could in principle coexist under different
`bucketStart` keys and be summed. They cannot, because nothing has shipped —
`main` carried only the spec and the plan, and the entire data layer arrived in
one branch. There is no user ledger to migrate.

The one real exposure is a development machine: if the app was ever run against
a live provider key before this change, delete
`~/Library/Application Support/Glyphline/glyphline.sqlite` once, along with its
`-wal` and `-shm` siblings.

---

# Subscription Quota — Known Issues

Carried out of the quota implementation. The feature ships with its primary
state being "unavailable", and that is the truth rather than a defect: the
access-route spike (`docs/superpowers/specs/2026-07-28-quota-access-routes.md`)
found no official route to short-term rate windows at any provider.

## What actually ships today

`ProviderAdapterRegistry.rateWindowSource(for:)` returns `nil` unconditionally.
No provider source exists yet, so the only window the app produces is the
billing cycle derived from what the cost path already knows. Every account
renders that plus "Quota reporting is not available for this subscription."

`FixtureRateWindowSource` and `RateWindowSourceError.notConfigured` remain in
the app target with no production referent. Both are deliberate keeps — the
fixture for tests, the error case for the Cursor situation the spike left
undetermined.

## For whoever writes the first real source

**`confirm` trusts the provider's `observedAt`.** Freshness is tracked per
account and window kind on the coordinator, keyed to the `observedAt` the
provider supplied, while `fetchLatestRateWindows` picks the newest row by
`observedAt DESC`. A provider that backdates `observedAt` below an
already-stored row of the same kind would hand its confirmation to a row it did
not confirm. `isPlausible` cannot catch this: it evaluates `resetAt > now` with
`now == window.observedAt`, so it is blind to `observedAt` itself. Unreachable
while no real source exists; it belongs in the first adapter's brief.

**The `resetAt` millisecond coupling — fixed, kept here as a warning.** GRDB
truncates `Date` to milliseconds, so a sub-millisecond `resetAt` — which the
real claude.ai parser produces and the second-granularity fixtures did not —
compared unequal to its own stored form and appended a spurious "change" row on
every poll. `LedgerStore.resetAtStorageTolerance` (0.002s) now absorbs it. The
lesson generalises to any future column: a fixture whose precision is coarser
than production's cannot detect a storage-precision mismatch, so the bug was
invisible to the whole suite until a live response hit it.

**Codex has a free billing-cycle source.** `~/.codex/auth.json`'s `id_token`
carries `chatgpt_subscription_active_until` in its `https://api.openai.com/auth`
claim — a `.billingCycle` window with no network call and no credential of our
own. Caveats: freshness depends on the Codex CLI's last token refresh, Glyphline
would read a file another tool owns, and the value is a subscription *term* end,
not a monthly renewal, so the copy must not call it "resets".

**Cursor is undetermined.** Resolving it needs a Cursor team API key plus one
focused probe of the documented Team API for a limits endpoint.

**Per-account cost for a Claude subscription is not obtainable.** The monthly
fee appears in no field of the usage response. `spend.used{amount_minor,
currency, exponent}` is a real money figure but belongs to the *extra usage*
wallet (`can_purchase_credits`, `balance`, `cap` sit beside it), which is off for
this user and therefore always zero. The window-level `limit_dollars` /
`used_dollars` / `remaining_dollars` are null even on an actively used
subscription — measured, not assumed. And local Claude Code logs carry no marker
of which subscription paid for a session, so a token-derived estimate cannot be
split per account. Route closed.

**The usage response also carries a `limits` array** — 3 elements on the
reference account, each with `kind`, `percent`, `resets_at`, `is_active`,
`severity`, `group`. It looks like a newer, richer form of the same quota data
that `five_hour` / `seven_day` express, and `is_active` would state directly what
this app currently infers from a null `resets_at`. Not adopted; recorded as the
obvious next source if the current keys ever stop being populated.

**Do not revisit `claude setup-token`.** Its authorisation URL requests
`scope=user:inference` and nothing else. That is a property of the grant, not a
setting to be found.

## Smaller items

- `SyncCoordinator.rateWindowConfirmations` is in-memory only. After a relaunch
  the `(as of …)` qualifier falls back to `observedAt`, which understates
  freshness rather than overstating it.
- `MenuBarView` evaluates `coordinator.quotaRows` twice per `body` pass, each
  building formatters. Correctness-neutral at menu scale.
- If every window in a result is implausible, `rateWindowMessages` has already
  been cleared, so the user sees a qualified stale row with no reason given.
  Worth a message once a real source lands.
- `QuotaIndicator`'s `light`, `nextFree` and `rowGroups` remain `static` and
  callable with an arbitrary freshness bound from inside the module. The class is
  closed at the view boundary — `quotaFreshness` is private and no view names a
  bound — but not at the type level.

## Deferred out of the 1.5 / 1.6 branch

Found in review while the window-mode and usage-counting work landed, and left
open on purpose. None of them is a surprise, and none blocks a user today.

### Two tests that read like cover

- `GlyphlineTests/LocalizedLayoutTests.swift` — `testTheAppModePickerGetsTheWidthItsSegmentsAskFor`
  measures against `SettingsRootView.minimumContentWidth` (640). No real
  translation can breach that: the three-segment period picker in the same file
  wants 221–234 points across all eight languages, so a two-segment picker wants
  less, and a breaking translation would have to be roughly three times longer
  than any plausible one. The `XCTAssertGreaterThan(wanted, 0)` half does earn
  its keep — it proves every language renders through the compiled table — but
  the width assertion is decorative. The real fix is to measure the settings form
  column off a built app and replace the constant; it was not done because the
  honest alternatives are worse (an invented tighter bound is exactly the failure
  this file exists to prevent, and hosting `SettingsView` in the suite starts
  Sparkle in the test process).

- `GlyphlineTests/LocalizedLayoutTests.swift` — `testTheResetLineFitsTheNarrowestCardInEveryLanguage`
  computes its budget as `AccountQuotaGrid.minimumCardWidth - 32 - 14`. Only the
  300 is read from the view; the card's `.padding(16)` (`AccountQuotaCards.swift`)
  and the reset line's `.padding(.leading, 14)` are bare literals with no
  test-reachable constant. Grow either and the test keeps measuring against a
  too-generous 254, stays green, and the line clips — the failure direction that
  matters. Hoist both to `static let`s and derive the budget from them.

### Session tokens have no independent expected-string coverage

- `GlyphlineTests/QuotaCardModelTests.swift` — `testResetTextIsExactlyQuotaIndicatorsForTheSameInput`
  is a delegation-equality test: it would still pass if `QuotaIndicator.resetText`
  itself were wrong. Acceptable because that function carries its own coverage,
  but the card's reset line is pinned only by agreement, not by an expected value.

### The rebuild is silent

- Nothing in the app says the one-time history rebuild ran. The release note is
  the only signal that figures changed, so a user who skips it sees a step in
  their charts with no explanation available anywhere in the UI.

- `localSeenMessages` spikes well above its documented steady state for the
  retention window after a rebuild, because the rebuild records an id for every
  message in every surviving transcript at once. Bounded and self-clearing; only
  the doc comment's sense of "normal size" is briefly wrong.

### Invariants held by construction order rather than by type

- `LocalHistoryWriteGate` — if `rebuildIsOutstanding` were ever true with nothing
  dispatched to release it, every `runScan` would suspend forever and local usage
  would silently never update again. `LocalHistoryRebuildController` now releases
  it on every declining path, so this is unreachable; what remains is that nothing
  *enforces* the pairing. A future maintainer who removes the controller and
  leaves the gate gets a silent permanent hang with no error and no bound.

- `AppActivationController` dereferences an implicitly-unwrapped `NSApp` through
  a private accessor that forces `NSApplication.shared` first, so the launch-path
  crash is structurally fixed. But `GlyphlineApp.init` constructs several
  observers in sequence and their ordering is load-bearing in ways only comments
  record.

- `syncIntervalMinutes` is clamped to a positive value in `AppSettingsStore.init`
  and the only runtime writer is the Settings picker (15/30/60), so a zero cannot
  reach `LocalScanScheduleController`'s loop. Nothing at the point of use enforces
  that; a zero would make the loop scan continuously. The same exposure exists in
  `SyncCoordinator`'s scheduler, which is why it was not fixed in one place only.

### Small behavioural rough edges

- Changing the sync interval while a local scan is in flight cancels the old loop
  while it still awaits that scan, and the new loop's first pass is a no-op via
  `isScanningLocalUsage`. The first scan after the change is therefore skipped
  until the next tick. Self-correcting, no leak.

- `ja` and `zh-Hans` use ASCII parentheses in some catalog entries where those
  locales conventionally take full-width ones. Pre-existing across the catalog
  rather than new.

### Verified by hand, not by a test

- That the reset line's 14-point indent lands under the status *text* rather than
  under the coloured dot. No test can see horizontal alignment; the height and
  width tests only prove the line draws and fits.

- That the menu bar panel reopens after being closed by the Dashboard or
  Agentverse buttons. `MenuBarPanelDismisser` calls `close()`; if a build ever
  fails to reopen the panel, `orderOut(nil)` is the one-word change. The panel is
  reachable neither by the accessibility API nor in process — a SwiftUI
  `MenuBarExtra` status button carries no target and no action — so this cannot
  be automated.

### What the move to local days does not fix

The daily buckets now follow the user's clock rather than UTC, and a second
one-time rebuild re-reads the transcripts on that grid. Two things survive it.

**Six dates cannot be corrected and stay inflated.** 2026-06-29 through
2026-07-04 on the reference machine hold about 9.3 Gtok that exists in no
surviving transcript — coverage against them runs from 0.000 to 0.841, so
`replacementCoverageThreshold` keeps the recorded figure rather than replacing it
with a partial one. The effect is confined to the periods that reach back that
far: Today, 7 Days and 30 Days agree with an independent count of the
transcripts, while All Time, 90 Days and a Year read roughly 9.3 Gtok high. That
is the deliberate trade — an over-count that can be explained beats destroying
history nothing can reconstruct — but it is why this app's all-time figure and
another tool's will not match.

The two days the first rebuild had to keep, 2026-07-30 and 2026-07-31, are *not*
in that set any more: they measure 1.003 and 0.993 on the second pass and are
corrected without the threshold moving.

**The grid is fixed at the moment a row is written.** `LocalUsageDay.calendar`
is autoupdating, so a Mac carried to another timezone starts bucketing on the new
clock at the next scan — but rows written before the move keep the boundaries
they were cut on, and migration `v15` only ran once. Nothing re-cuts history on a
timezone change, and nothing says so in the UI.

### Side effects still wired to views

Three times during the 1.5/1.6 work, something a running app needs turned out to
hang on a SwiftUI view's `.task` or `.onAppear`, and each time it only surfaced
because the menu bar default stopped that view from ever existing: the sync
scheduler (now `SyncScheduleController`), the one-time history rebuild (now
`LocalHistoryRebuildController`), and the local usage scan (now
`LocalScanScheduleController`). The pattern is worth a deliberate pass rather
than waiting for the next release to find the rest.

What a survey of `Glyphline/UI/` turns up today:

- **`DashboardView.swift:86` — `.task { await agentverse.refresh() }` has no
  trigger outside a view at all.** `AgentverseCoordinator` schedules nothing of
  its own, and no non-UI caller invokes `refresh()`. So the parked/on-track
  session state — and `workTokens`, which feeds the per-agent token column — is
  only ever swept when the dashboard or the map window is open. The comment on
  that line reasons about *which* view should own the sweep; the question the
  1.5/1.6 experience raises is whether a view should own it at all.

- `DashboardView.swift:76` — `refreshRateWindowsOnDemand()` is genuinely
  view-shaped (freshen quotas because someone is looking) and is also reached
  from the menu bar panel and the scheduler, so it is not stranded. Listed to
  say it was examined, not to imply it is wrong.

- `DashboardView.swift:83` — `scanLocalUsage()` is now correct: the cadence lives
  in `LocalScanScheduleController` and this call only makes an opened dashboard
  show current figures rather than up-to-an-interval-old ones.

- `AgentverseWindow.swift:148,165,181` — the render loop and the place/weather
  tasks are keyed on window occlusion by design; those belong to the window and
  should stay there.

The test to apply to each remaining one: *if this view never exists for the whole
life of the process, does the app still behave correctly?* Where the answer is
no, the work belongs to an app-level controller constructed in `GlyphlineApp.init`
— `SyncScheduleController` and `WindowActivationObserver` are the established
shape.
