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

`AccountsView` now carries a fifth `makeDefault()` as a property default, but
`DashboardView` passes its own store, so the default is never evaluated in the
running app. It is a latent fifth connection, not an actual one — which is
exactly how the other four started.

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
