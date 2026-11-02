<!--
Translating? Please stop and read this first.

Translations are not accepted as pull requests. They live on Crowdin:

    https://crowdin.com/project/nekokolpa2

Anything committed to l10n/app_*.arb is overwritten by the next Crowdin sync,
so a translation PR is thrown away even after it is merged. Crowdin needs no
git and no build, and your work reaches the app on the next release.

The one exception is l10n/app_en.arb, the English source, which is where a new
string is added.
-->

## What this changes

<!-- One or two sentences. What is different after this PR? -->

## Why

<!-- The problem being solved, or the behaviour being fixed. Link an issue if
     there is one. -->

## How it was verified

<!-- Tests, or the manual check you ran. If it touches the card path, say which
     eUICC or reader you tried it on. -->

- [ ] `flutter test` passes
- [ ] `dart analyze lib test` is clean
- [ ] `dart format` applied to changed files

## Checklist

- [ ] This PR contains **no** edits to `l10n/app_*.arb` other than `app_en.arb`
      (translations go to [Crowdin](https://crowdin.com/project/nekokolpa2))
- [ ] New user-facing strings were added to `l10n/app_en.arb` and
      `flutter gen-l10n` was run
- [ ] Commit messages say what changed and why, not just what file was touched
