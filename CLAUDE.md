# CLAUDE.md — PR Menubar

Native macOS menu bar app that lists your open GitHub PRs via the `gh` CLI.
Single build, no Xcode project: `app/build.sh` compiles `app/PRCore.swift` +
`app/App.swift` with `swiftc` into `PRMenubar.app`, ad-hoc signed.

- **Test:** `cd app && ./test.sh` (pure logic in `PRCore.swift`, run as a standalone binary).
- **Build + run:** `cd app && ./build.sh`.
- **Regenerate icons:** `cd app && swift make_icon.swift`.

## Names and ids

Deliberately mixed — don't "fix" them:

- Repo, cask token, `brew install` slug: `pr-menubar`.
- Display name / `CFBundleName` / logo / cask `name`: **PR Menubar**.
- Executable + bundle: `PRMenubar` / `PRMenubar.app`.
- **Bundle id: `com.djalma.prbar`** — kept from the original "PR Bar" name. The
  `UserDefaults` suite and the cask's `zap` plist follow this id. Changing it
  orphans everyone's stored filter/favorites.

## Release checklist

Ships as a Homebrew cask in a **separate repo**:
`git@github.com:djalmaaraujo/homebrew-tap.git`, file `Casks/pr-menubar.rb`. A GitHub
release here is not enough on its own — the cask pins an exact `version` + `sha256`,
so it keeps serving the old build until that file is updated too. Every release
needs both halves.

1. Bump `CFBundleShortVersionString` in `app/Info.plist`, then build clean and zip:
   ```bash
   cd app
   ./build.sh
   cd build
   ditto -c -k --sequesterRsrc --keepParent PRMenubar.app PRMenubar.app.zip
   shasum -a 256 PRMenubar.app.zip
   ```
2. Tag + push, then create the GitHub release with that zip attached:
   ```bash
   gh release create vX.Y.Z app/build/PRMenubar.app.zip --title vX.Y.Z --notes "..."
   ```
3. **Update the tap** — clone/pull `homebrew-tap`, edit `Casks/pr-menubar.rb`:
   `version`, `sha256`, and the `vX.Y.Z` in the `url` to match what you just built.
   Commit + push there too.
4. Verify end to end before calling it done:
   ```bash
   brew update
   brew upgrade --cask pr-menubar   # or: brew reinstall --cask pr-menubar
   defaults read /Applications/PRMenubar.app/Contents/Info.plist CFBundleShortVersionString
   ```
   Confirm it reports the new version and actually installs.

Skipping step 3 is the most likely mistake — the GitHub release succeeding gives no
signal that the tap is still stale.

## Gotchas learned the hard way

- **Never force-push the tap.** Only ADD commits to `homebrew-tap`. Amending or
  rebasing after it's been pushed corrupts every consumer's local clone — `brew
  update` merges the rewritten commit and leaves Git conflict markers inside the
  `.rb`, so `brew install/reinstall` then fails with a Ruby `unexpected ')'` parse
  error. To recover a broken clone:
  `git -C "$(brew --repository djalmaaraujo/tap)" fetch origin && reset --hard origin/main && clean -fdq`.
- **`Text("\(someInt)")` localizes the number.** SwiftUI's `LocalizedStringKey`
  interpolation adds the locale's thousands separator (in pt-BR, `#4.821`). Use
  `Text(verbatim: "#\(n)")` for ids and counts.
- **Menu bar icon: no `.resizable()`/`.frame()`** on the `Image(nsImage:)` inside a
  `MenuBarExtra` label — it needs an intrinsic size before its own layout pass, or
  it renders nothing. Set `NSImage.size` directly (aspect-preserving) instead.
- **`MenuBarExtra(title:systemImage:)` drops the title** under
  `.menuBarExtraStyle(.window)`. Build the label as an explicit `HStack { Image; Text }`.
- **Drain a `Process`'s stdout and stderr concurrently**, then `waitUntilExit()`.
  Reading one pipe to EOF and only then the other deadlocks if the child fills the
  second buffer while blocked — its EOF never comes until it exits.
- **`gh search prs` has no CI or branch fields.** It only enumerates PRs; enrich each
  with `gh pr view … --json …statusCheckRollup,headRefName,baseRefName`.
- **The org dropdown must union `gh api user/orgs` with owners seen in results** —
  orgs with private membership are absent from `user/orgs` but appear in your PRs.
- **Interactive controls beyond `Toggle`/`Picker`/`Button` don't work inside an
  NSMenu-backed `Menu`.** Keep them in the popover body (`.window` style), not a gear menu.
