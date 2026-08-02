# Contributing

Thanks for looking. Issues and pull requests are welcome.

Nobody has push access except the owner, so the route is the usual one: fork
the repository, work on a branch, and open a pull request.

## Fixing a translation

This is the most useful thing most people can send, and it needs no Xcode.

Every string lives in `Glyphline/Resources/Localizable.xcstrings`, a JSON file
Xcode calls a String Catalog. Find your language's entry for the string, fix
the wording, and open a pull request. English is the source language; the other
seven have not been reviewed by native speakers, so corrections are genuinely
wanted rather than merely tolerated.

Two things to leave alone: the **keys** and the `%@`/`%lld` placeholders. A key
is an identifier, not text, and a placeholder is where a number or a name gets
substituted at runtime — dropping one crashes the format at the point it is
used, and reordering them changes which value lands where.

## Building

```bash
brew install xcodegen          # if you do not have it
xcodegen generate
./scripts/run.sh               # builds Release, installs to ~/Applications, launches
```

macOS 26 or later. The deployment target is deliberate — the app uses Liquid
Glass, which has no back-deployment — so please do not lower it to make a build
work.

## Tests

```bash
xcodebuild test -project Glyphline.xcodeproj -scheme Glyphline -destination 'platform=macOS'
```

**Read the executed count, not just the result.** A test file that is not
registered in the project runs zero tests while `xcodebuild` still prints
`TEST SUCCEEDED`, which is the most convincing false green this project has.

```
Executed <n> tests, with 0 failures
```

The count should go up when you add tests and never down.

If you add a test file, run `xcodegen generate` and commit the regenerated
`Glyphline.xcodeproj/project.pbxproj` with it. It is generated *and* checked
in, so a new file that is not regenerated simply never runs.

## Adding a user-visible string

`scripts/run.sh` and `scripts/release.sh` fail the build when the String
Catalog has drifted from the source, because a string that never reaches the
catalog never reaches a translator and looks perfectly fine in English. Run
`scripts/check-l10n.sh --fix` and commit the updated catalog.

## appcast.xml

Generated, not written. `scripts/release.sh` adds one entry per release, with a
signature over the exact ZIP that was uploaded — edit the file by hand and the
signature no longer matches the download, which every user's update check will
reject. If something in it looks wrong, fix the script.

## Commits

Follow what `git log` already does: `feat(scope):`, `fix(scope):`,
`refactor(scope):`, an imperative subject, and a body that explains *why* when
the change is not obvious. The why is the part that is expensive to reconstruct
later.

## Tests earn their keep

Where a change can break something, the pull request should carry a test that
catches it. The bar used here is that an assertion has to fail when the thing
it describes is broken — worth checking by breaking it on purpose once and
watching the test go red. A test that passes either way is worse than no test,
because it reads like cover.
