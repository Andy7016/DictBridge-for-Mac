# CLI reference

## Contents

- Discovery and safety
- `doctor.sh`
- `dictbridge info`
- `dictbridge convert`
- `dictbridge list`
- `dictbridge remove`
- `dictbridge ddk`
- `make-report.sh`

## Discovery and safety

The CLI is normally located at:

```text
/Applications/DictBridge.app/Contents/Resources/dictbridge
```

It can also be linked into `PATH`:

```bash
sudo ln -s /Applications/DictBridge.app/Contents/Resources/dictbridge /usr/local/bin/dictbridge
```

Read-only commands:

```bash
dictbridge --version
dictbridge info file.mdx
dictbridge list
dictbridge ddk
```

Stateful commands require explicit user approval:

```bash
dictbridge convert file.mdx --install
dictbridge remove "Name"
dictbridge ddk --download
dictbridge ddk --use "/path/to/Dictionary Development Kit"
```

## `doctor.sh`

```bash
bash scripts/doctor.sh
bash scripts/doctor.sh --cli "/custom/path/dictbridge"
```

Environment override:

```bash
DICTBRIDGE_BIN="/custom/path/dictbridge" bash scripts/doctor.sh
```

Output is JSON on stdout. Diagnostics go to stderr.

Exit codes:

| Code | Meaning |
|---:|---|
| 0 | CLI and DDK ready |
| 2 | CLI missing or not executable |
| 3 | DDK not set up |
| 4 | Platform is not macOS |
| 5 | Invalid argument or missing helper dependency |

## `dictbridge info`

```bash
dictbridge info "/path/to/dictionary.mdx"
dictbridge info "/path/to/resources.mdd"
```

Use this before conversion to identify format, encoding, compression, encryption, entry count, and resource layout.

## `dictbridge convert`

```bash
dictbridge convert <file.mdx|folder> [options]
```

Common options:

| Option | Meaning |
|---|---|
| `--name <text>` | Display name in Dictionary.app |
| `--short-name <text>` | Compact toolbar/tab name |
| `--copyright <text>` | Original copyright notice |
| `--publisher <text>` | Original publisher |
| `--credits <text>` | Conversion attribution |
| `--identifier <id>` | Unique bundle identifier |
| `--no-audio` | Exclude pronunciation audio |
| `--no-chinese-variants` | Do not add Simplified/Traditional aliases |
| `--headword auto\|always\|never` | Headword insertion behavior |
| `--dark-mode auto\|light` | Dark-mode adaptation |
| `--no-install` | Build without installing |
| `--output <folder>` | Output directory with `--no-install` |
| `--keep-work` | Preserve intermediate files for debugging |
| `--no-restart` | Do not restart Dictionary.app |

Output-only example:

```bash
mkdir -p "./output"
dictbridge convert "/path/to/dictionary.mdx" \
  --name "My Dictionary" \
  --no-audio \
  --no-install \
  --output "./output"
```

Install only after approval:

```bash
dictbridge convert "/path/to/dictionary.mdx" \
  --name "My Dictionary" \
  --dark-mode auto \
  --install
```

## `dictbridge list`

```bash
dictbridge list
```

Lists dictionaries installed in `~/Library/Dictionaries`.

## `dictbridge remove`

```bash
dictbridge remove "Dictionary Name"
dictbridge remove "/path/to/Dictionary.dictionary"
```

Moves the dictionary to the Trash. Get explicit approval first.

## `dictbridge ddk`

```bash
dictbridge ddk
dictbridge ddk --download
dictbridge ddk --use "/path/to/Dictionary Development Kit"
```

`dictbridge ddk` is read-only. Downloading or selecting a DDK changes local state and requires approval.

## `make-report.sh`

```bash
bash scripts/make-report.sh \
  --log conversion.log \
  --output dictbridge-issue.md \
  --dictionary "Dictionary name and edition" \
  --dictbridge-version "0.6.0" \
  --macos "macOS 26.0" \
  --chip apple-silicon \
  --kind "Conversion failed" \
  --files "dictionary.mdx 54 MB; dictionary.mdd 138 MB"
```

The report contains metadata and a redacted log excerpt only. Review it before sharing.
