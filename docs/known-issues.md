# Known Issues

Deliberately unfixed issues carried out of the data-layer implementation, with
the reasoning that led to deferring each one. Everything here was found in
review and left open on purpose — none of it is a surprise.

The backfill engine and the OpenAI, Cursor and Claude cost adapters were removed
in `c1d5ccf`, and every issue recorded against them went with them: the
watermark advancing on a degraded slice, the missing rate-limit backoff, decode
failures propagating out of `sync`, the untested final-bucket boundary, the
missing OpenAI cache-read price, cooperative backfill cancellation, and the
OpenAI bucket-boundary migration question.

## Correctness, contained today

### The pricing catalog has no time dimension

One price per model, applied to every period the statistics screen offers. Two
consequences, both understating nothing and overstating a little:

- Claude Sonnet 5 carried introductory pricing ($2/$10 per million rather than
  $3/$15) through 2026-08-31. The catalog holds the standard rate, so tokens
  spent inside that window are valued above what the API would have charged —
  permanently, since the window has closed and the history keeps it.
- A price change of any kind is applied retroactively to the whole history the
  moment the catalog is edited.

Fixing it means an effective-date range per entry and picking the entry by the
bucket's own date — the `effectiveDate` field is already there and already
unused for exactly this. Not worth it while the figure is labelled an estimate
of what API billing would have cost, but it is the reason two runs of the same
period can disagree after a catalog update.

## Storage and lifecycle

### Watermark rows are kept forever, by design

One `localScanWatermarks` row per transcript file ever scanned — 5,651 on the
reference install on 2026-10-12, 4,721 of them for files Claude Code had
already deleted. The rows are not deleted, because a row is what stops a
transcript restored from a backup being read again and counted twice; the seen
message ids only cover fourteen days.

What changed is the key. Each scan re-keys the rows whose file it no longer
found under a SHA-256 of the path (`LocalScanWatermark.retiredSourceKey`), so the
ledger no longer names projects the user has deleted, and the reader still finds
the row when the path comes back. Live rows keep the readable path. The table
grows by one small row per transcript; at this size that is not worth bounding.

Two edges: a scan that finds no transcripts at all retires nothing, since an
unmounted volume looks the same; and a subdirectory that is briefly unreadable
has its rows retired, which costs nothing because the path still resolves to
them.

### The ledger now has `-wal` and `-shm` siblings

`DatabaseQueueFactory` opens the on-disk ledger in WAL mode. Nothing copies or
deletes the database by path today, so nothing breaks — but any future export,
backup, or reset feature must handle all three files.

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

`ClaudeSignInWindow` now opens popups the page asks for, which is the one path
in this layer nobody has seen run: claude.ai does not route its sign-in through
one today. If it starts to, that is the first thing to check by hand.

## Attention notifications

### The watcher and the delivery have no automated coverage, by construction

`TranscriptChangeWatcher` and `SystemUserNotifier` are verified only by the
compiler and by using the app: the tests drive fakes for both, because a test
that drove the real ones would watch the developer's `~/.claude/projects` through
FSEvents and post notifications onto their screen. The rules in between — who
counts as waiting, when the delay has passed, what a click opens — are tested;
whether an FSEvents callback arrives and a banner actually appears is checked by
hand only: set the delay to one minute, let a Claude Code turn end without
answering, and a notification should arrive within about 75 seconds; in
menu-bar-only mode with no window open, clicking the notification opens the
Agentverse.

### A finished agent is reported like a waiting one

A transcript does not say whether the turn that ended was a finished task or a
question to the user; both stop at the same place and look the same. Glyphline
therefore notifies for both, and the Settings copy says so. This is a limit of
what the transcript records, not a bug to fix here.

### Warned quota cycles live in memory only

`SyncCoordinator` remembers which quota cycles it has already warned about in
`runwayWarned`, an in-memory set. Quitting and relaunching the app forgets it, so
a window still running out at the same pace is warned about once more after a
restart. Persisting it was not worth a schema change for one repeated banner.

## Cosmetic

- The Settings copy states that Glyphline syncs after the Mac wakes without
  qualifying it. Local usage is rescanned on every wake, but the quota windows
  are only refreshed on wake while automatic sync is enabled — that wake
  observer is installed by `SyncCoordinator`'s scheduler.
- Per-token-class integer division in `CostEstimator` truncates independently,
  losing up to three micros per snapshot. Deterministic, always toward zero, far
  below the pricing table's own noise floor.

---

# Subscription Quota — Known Issues

Carried out of the quota implementation. The access-route spike
(`docs/superpowers/specs/2026-07-28-quota-access-routes.md`) found no official
route to short-term rate windows at any provider; the one route that ships reads
them through the user's own claude.ai session.

## What actually ships today

`ProviderAdapterRegistry.rateWindowSource(for:)` resolves exactly one account
shape: a Claude account with a `web-session://` credential reference and a
resolved organisation id gets a `ClaudeWebQuotaSource`. Every other account gets
`nil` and renders "Quota reporting is not available for this subscription."

`FixtureRateWindowSource` stays in the app target for tests only; the registry no
longer hands it out. `RateWindowSourceError.notConfigured` is still a deliberate
keep for the Cursor situation the spike left undetermined.

## For whoever writes the next source

**`confirm` trusts the provider's `observedAt`.** Freshness is tracked per
account and window kind on the coordinator, keyed to the `observedAt` the
provider supplied, while `fetchLatestRateWindows` picks the newest row by
`observedAt DESC`. A provider that backdates `observedAt` below an
already-stored row of the same kind would hand its confirmation to a row it did
not confirm. `isPlausible` cannot catch this: it evaluates `resetAt > now` with
`now == window.observedAt`, so it is blind to `observedAt` itself.
`ClaudeWebQuotaSource` stamps `observedAt` from the local clock, so it cannot
backdate; a source that takes the time from a response must not.

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
- If every window in a result is implausible, `rateWindowMessages` has already
  been cleared, so the user sees a qualified stale row with no reason given.
- `QuotaIndicator`'s `light` and `rowGroups` remain `static` and
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

- `DashboardView.swift:87` — `agentverse.refresh()` used to have no trigger
  outside a view, so a session that started and went quiet while neither the
  dashboard nor the map was open was never seen on track and never parked.
  `AgentverseSweepController` now sweeps every fifteen minutes regardless, and
  the dashboard's call only makes an opened dashboard count the agents running
  now.

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
