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

## Fonts and themes

Settings (⌘,) has a font list and a theme list with a live preview.

- 12 bundled font families (OFL-1.1 / MIT), registered for Shellter only:
  JetBrains Mono, Fira Code, Cascadia Code, Iosevka, Monaspace (5 styles),
  Geist Mono, Maple Mono, Victor Mono, Commit Mono, IBM Plex Mono,
  Source Code Pro, Hack. `scripts/fetch-fonts.sh` downloads them.
  Installed monospaced fonts are listed too.
- Nerd Font icons work with every font (libghostty embeds the symbols).
- Themes: the 450+ themes that ship with Ghostty, the themes of installed
  editors (VS Code, Cursor, VSCodium, Windsurf), and imported files
  (`.itermcolors`, VS Code theme `.json`, Ghostty theme files).
- "Same as VS Code" follows the editor's `workbench.colorTheme` (and the
  preferred light/dark themes when `window.autoDetectColorScheme` is on).

## Configuration

Config files, in load order (later files win):

1. Shellter defaults (`Resources/defaults.config`)
2. Your Ghostty config (`~/.config/ghostty/config`)
3. Choices from the Settings window
   (`~/Library/Application Support/Shellter/appearance.config`)
4. `~/.config/shellter/config` for manual overrides

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘W | New tab (same directory) / close tab |
| ⌘1 … ⌘8, ⌘9 | Select tab n / last tab |
| ⌃Tab, ⌃⇧Tab, ⌘⌥↓, ⌘⌥↑ | Next / previous tab |
| ⌘J | Next tab that needs input |
| ⌃⌘S | Toggle sidebar |
| ⌘, | Settings |

## Launch arguments (for testing)

```sh
open Shellter.app --args -ShellterCwd ~/some/dir -ShellterRun "npm run dev"
```

## License notes

Keyboard, IME, mouse and clipboard handling is adapted from the Ghostty macOS
app (MIT, © Mitchell Hashimoto and Ghostty contributors).
