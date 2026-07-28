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
