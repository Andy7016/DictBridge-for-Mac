#!/bin/bash
# Converts every MDict dictionary under a folder WITHOUT installing it and writes a results table.
# Use it before a release to see whether a change broke any of the dictionaries you have.
#
#   scripts/compat-test.sh ~/Dictionaries              # all .mdx files, one after another
#   scripts/compat-test.sh ~/Dictionaries --keep       # keep the built .dictionary bundles
#   DICTBRIDGE=.build/release/dictbridge scripts/compat-test.sh ~/Dictionaries
#
# Results go to dictbridge-compat-<date>.md in the current folder; the full log of each
# conversion is kept next to it. Large dictionaries need a few GB of free space while they build.
set -uo pipefail

ROOT="${1:-}"
KEEP=0
[[ "${2:-}" == "--keep" ]] && KEEP=1
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "usage: $0 <folder with dictionaries> [--keep]" >&2
  exit 2
fi

CLI="${DICTBRIDGE:-}"
if [[ -z "$CLI" ]]; then
  for candidate in /Applications/DictBridge.app/Contents/Resources/dictbridge \
                   "$HOME/Applications/DictBridge.app/Contents/Resources/dictbridge" \
                   "$(command -v dictbridge 2>/dev/null)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { CLI="$candidate"; break; }
  done
fi
[[ -x "$CLI" ]] || { echo "dictbridge command-line tool not found; set DICTBRIDGE=/path/to/dictbridge" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M)"
REPORT="$PWD/dictbridge-compat-$STAMP.md"
LOGS="$PWD/dictbridge-compat-$STAMP-logs"
BUILD="$(mktemp -d)/build"
mkdir -p "$LOGS" "$BUILD"

VERSION="$("$CLI" --version 2>/dev/null | head -1)"
{
  echo "# DictBridge compatibility run"
  echo
  echo "- $VERSION, macOS $(sw_vers -productVersion), $(date '+%Y-%m-%d %H:%M')"
  echo "- Folder: \`$ROOT\`"
  echo
  echo "| Dictionary | Result | Entries | Time | Size | Warnings | Note |"
  echo "|---|---|---:|---:|---:|---:|---|"
} > "$REPORT"

total=0; ok=0
while IFS= read -r -d '' mdx; do
  total=$((total + 1))
  rel="${mdx#"$ROOT"/}"
  name="$(basename "$mdx" .mdx)"
  log="$LOGS/$(printf '%03d' "$total") $name.log"
  echo "[$total] $rel"

  start=$SECONDS
  "$CLI" convert "$mdx" --no-install --output "$BUILD" >"$log" 2>&1
  status=$?
  secs=$((SECONDS - start))

  entries="$(grep -oE '✓ [0-9]+ entries' "$log" | grep -oE '[0-9]+' | head -1)"
  warnings="$(grep -c 'warning:' "$log")"
  size="$(du -sh "$BUILD"/*.dictionary 2>/dev/null | head -1 | cut -f1)"
  if [[ $status -eq 0 && -n "$entries" ]]; then
    result="OK"; ok=$((ok + 1))
    note="$(grep -m1 -oE 'style sheets: .*' "$log" | cut -c1-80)"
  else
    result="**FAILED**"
    note="$(grep -m1 -E '^error:' "$log" | cut -c1-120)"
    [[ -z "$note" ]] && note="exit status $status"
  fi
  note="${note//|/\\|}"
  echo "| ${rel//|/\\|} | $result | ${entries:--} | ${secs} s | ${size:--} | $warnings | $note |" >> "$REPORT"
  echo "    $result in ${secs} s"

  if [[ $KEEP -eq 1 ]]; then
    mkdir -p "$LOGS/bundles" && mv "$BUILD"/*.dictionary "$LOGS/bundles/" 2>/dev/null
  else
    rm -rf "$BUILD"/*.dictionary
  fi
done < <(find "$ROOT" -type f -iname '*.mdx' -print0 | sort -z)

{
  echo
  echo "$ok of $total converted. Logs: \`$LOGS\`"
} >> "$REPORT"
rm -rf "$(dirname "$BUILD")"
echo
echo "$ok of $total converted. Report: $REPORT"
