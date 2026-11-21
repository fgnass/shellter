#!/usr/bin/env bash
# Downloads the bundled terminal fonts (all OFL-1.1 or MIT) into Resources/Fonts.
# Each family gets its own folder with the font files and the license text.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/font-cache"
OUT="$ROOT/Resources/Fonts"
mkdir -p "$CACHE"
rm -rf "$OUT"
mkdir -p "$OUT"

GH=https://github.com
RAW=https://raw.githubusercontent.com

# name | archive URL | space-separated paths inside the archive | license URL ("-" = in archive)
FONTS=(
  "JetBrains Mono|$GH/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip|fonts/variable/JetBrainsMono[[]wght].ttf fonts/variable/JetBrainsMono-Italic[[]wght].ttf OFL.txt|-"
  "Fira Code|$GH/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip|variable_ttf/FiraCode-VF.ttf|$RAW/tonsky/FiraCode/6.2/LICENSE"
  "Cascadia Code|$GH/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip|ttf/CascadiaCode.ttf ttf/CascadiaCodeItalic.ttf|$RAW/microsoft/cascadia-code/v2407.24/LICENSE"
  "Iosevka|$GH/be5invis/Iosevka/releases/download/v34.9.1/PkgTTF-Unhinted-Iosevka-34.9.1.zip|Iosevka-Regular.ttf Iosevka-Bold.ttf Iosevka-Italic.ttf Iosevka-BoldItalic.ttf|$RAW/be5invis/Iosevka/v34.9.1/LICENSE.md"
  "Monaspace|$GH/githubnext/monaspace/releases/download/v1.400/monaspace-variable-v1.400.zip|*Var.ttf|$RAW/githubnext/monaspace/v1.400/LICENSE"
  "Geist Mono|$GH/vercel/geist-font/releases/download/v1.9.2/geist-font-v1.9.2.zip|geist-font/GeistMono/variable/GeistMono[[]wght].ttf geist-font/GeistMono/variable/GeistMono-Italic[[]wght].ttf geist-font/OFL.txt|-"
  "Maple Mono|$GH/subframe7536/maple-font/releases/download/v7.9/MapleMono-Variable.zip|MapleMono[[]wght].ttf MapleMono-Italic[[]wght].ttf LICENSE.txt|-"
  "Victor Mono|https://rubjo.github.io/victor-mono/VictorMonoAll.zip|TTF/VictorMono-Regular.ttf TTF/VictorMono-Bold.ttf TTF/VictorMono-Italic.ttf TTF/VictorMono-BoldItalic.ttf LICENSE.txt|-"
  "Commit Mono|$GH/eigilnikolajsen/commit-mono/releases/download/v1.143/CommitMono-1.143.zip|CommitMono-1.143/CommitMono-400-Regular.otf CommitMono-1.143/CommitMono-700-Regular.otf CommitMono-1.143/CommitMono-400-Italic.otf CommitMono-1.143/CommitMono-700-Italic.otf CommitMono-1.143/license.txt|-"
  "IBM Plex Mono|$GH/IBM/plex/releases/download/%40ibm%2Fplex-mono%402.5.0/ibm-plex-mono.zip|ibm-plex-mono/fonts/complete/ttf/IBMPlexMono-Regular.ttf ibm-plex-mono/fonts/complete/ttf/IBMPlexMono-Bold.ttf ibm-plex-mono/fonts/complete/ttf/IBMPlexMono-Italic.ttf ibm-plex-mono/fonts/complete/ttf/IBMPlexMono-BoldItalic.ttf ibm-plex-mono/LICENSE.txt|-"
  "Source Code Pro|$GH/adobe-fonts/source-code-pro/releases/download/2.042R-u%2F1.062R-i%2F1.026R-vf/VF-source-code-VF-1.026R.zip|VF/SourceCodeVF-Upright.ttf VF/SourceCodeVF-Italic.ttf|$RAW/adobe-fonts/source-code-pro/release/LICENSE.md"
  "Hack|$GH/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.zip|ttf/Hack-Regular.ttf ttf/Hack-Bold.ttf ttf/Hack-Italic.ttf ttf/Hack-BoldItalic.ttf|$RAW/source-foundry/Hack/v3.003/LICENSE.md"
)

for entry in "${FONTS[@]}"; do
  IFS='|' read -r name url paths license <<<"$entry"
  echo "==> $name"
  archive="$CACHE/$(echo "$name" | tr ' ' '-').zip"
  [[ -s "$archive" ]] || curl -fsSL -o "$archive" "$url"
  dest="$OUT/$name"
  mkdir -p "$dest"
  # shellcheck disable=SC2086
  (set -f; unzip -qq -j -o "$archive" $paths -d "$dest")
  if [[ "$license" != "-" ]]; then
    curl -fsSL -o "$dest/LICENSE.txt" "$license"
  fi
done

du -sh "$OUT"/*
