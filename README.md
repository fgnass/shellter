# Shellter

A macOS terminal with vertical tabs, grouped by project. Built on libghostty.

- Tabs are grouped by Git root (or the working directory).
- Each tab shows an icon: the favicon of a dev server that the tab started,
  else an icon file from the project directory, else a colored initial.
- Status per tab: a spinner while a program works (OSC 9;4 progress, or an
  animated spinner in the title), a bell when it wants input (BEL, OSC 9/777
  notification, or work finished while the tab was not visible).
- Tabs and their directories persist across restarts.

## Build

Requirements: Xcode, Zig 0.17+ (`brew install zig`), XcodeGen, and the Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
git submodule update --init
./scripts/build-ghostty.sh   # builds GhosttyKit.xcframework (slow, once)
./scripts/build.sh           # builds Shellter.app, prints its path
```

## Configuration

Shellter reads your normal Ghostty config (`~/.config/ghostty/config`), then
`~/.config/shellter/config` for Shellter-only overrides.

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘W | New tab (same directory) / close tab |
| ⌘1 … ⌘8, ⌘9 | Select tab n / last tab |
| ⌃Tab, ⌃⇧Tab, ⌘⌥↓, ⌘⌥↑ | Next / previous tab |
| ⌘J | Next tab that needs input |
| ⌃⌘S | Toggle sidebar |

## Launch arguments (for testing)

```sh
open Shellter.app --args -ShellterCwd ~/some/dir -ShellterRun "npm run dev"
```

## License notes

Keyboard, IME, mouse and clipboard handling is adapted from the Ghostty macOS
app (MIT, © Mitchell Hashimoto and Ghostty contributors).
