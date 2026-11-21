#!/bin/bash
set -u

usage() {
  cat <<'EOF'
Usage: make-report.sh --log FILE --output FILE [options]

Create a sanitized Markdown issue report from a DictBridge conversion log.

Required:
  --log FILE          Conversion log to redact.
  --output FILE       Destination Markdown file.

Optional:
  --dictionary TEXT   Dictionary name and edition.
  --dictbridge-version TEXT
  --macos TEXT        macOS version.
  --chip VALUE        apple-silicon, intel, or unknown.
  --kind VALUE        Conversion failed, Conversion hangs, Installed but looks wrong,
                      A word cannot be found, or Other.
  --files TEXT        File names and sizes only; never attach the files.
  --max-lines N       Maximum log lines (default: 200).
  --max-chars N       Maximum log characters (default: 20000).
  --help              Show this help.

Exit codes:
  0  Report written
  2  Missing or unreadable input
  5  Invalid argument or missing helper dependency
EOF
}

log_file=""
output_file=""
dictionary=""
dictbridge_version=""
macos_version=""
chip="unknown"
kind="Other"
files=""
max_lines=200
max_chars=20000

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log)
      [ "$#" -ge 2 ] || { printf 'Error: --log requires a file.\n' >&2; exit 5; }
      log_file="$2"; shift 2 ;;
    --output)
      [ "$#" -ge 2 ] || { printf 'Error: --output requires a file.\n' >&2; exit 5; }
      output_file="$2"; shift 2 ;;
    --dictionary)
      [ "$#" -ge 2 ] || { printf 'Error: --dictionary requires text.\n' >&2; exit 5; }
      dictionary="$2"; shift 2 ;;
    --dictbridge-version)
      [ "$#" -ge 2 ] || { printf 'Error: --dictbridge-version requires text.\n' >&2; exit 5; }
      dictbridge_version="$2"; shift 2 ;;
    --macos)
      [ "$#" -ge 2 ] || { printf 'Error: --macos requires text.\n' >&2; exit 5; }
      macos_version="$2"; shift 2 ;;
    --chip)
      [ "$#" -ge 2 ] || { printf 'Error: --chip requires a value.\n' >&2; exit 5; }
      chip="$2"; shift 2 ;;
    --kind)
      [ "$#" -ge 2 ] || { printf 'Error: --kind requires a value.\n' >&2; exit 5; }
      kind="$2"; shift 2 ;;
    --files)
      [ "$#" -ge 2 ] || { printf 'Error: --files requires text.\n' >&2; exit 5; }
      files="$2"; shift 2 ;;
    --max-lines)
      [ "$#" -ge 2 ] || { printf 'Error: --max-lines requires a number.\n' >&2; exit 5; }
      max_lines="$2"; shift 2 ;;
    --max-chars)
      [ "$#" -ge 2 ] || { printf 'Error: --max-chars requires a number.\n' >&2; exit 5; }
      max_chars="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      printf 'Error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 5 ;;
  esac
done

if [ -z "$log_file" ] || [ -z "$output_file" ]; then
  printf 'Error: --log and --output are required.\n' >&2
  exit 5
fi
if [ ! -f "$log_file" ] || [ ! -r "$log_file" ]; then
  printf 'Error: log file is missing or unreadable: %s\n' "$log_file" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'Error: python3 is required for make-report.sh.\n' >&2
  exit 5
fi
case "$max_lines" in ''|*[!0-9]*) printf 'Error: --max-lines must be a positive integer.\n' >&2; exit 5 ;; esac
case "$max_chars" in ''|*[!0-9]*) printf 'Error: --max-chars must be a positive integer.\n' >&2; exit 5 ;; esac
if [ "$max_lines" -le 0 ] || [ "$max_chars" -le 0 ]; then
  printf 'Error: limits must be greater than zero.\n' >&2
  exit 5
fi

python3 - \
  "$log_file" "$output_file" "$dictionary" "$dictbridge_version" \
  "$macos_version" "$chip" "$kind" "$files" "$max_lines" "$max_chars" <<'PY'
import json
import os
import pathlib
import re
import sys

(
    log_file,
    output_file,
    dictionary,
    dictbridge_version,
    macos_version,
    chip,
    kind,
    files,
    max_lines_raw,
    max_chars_raw,
) = sys.argv[1:]

max_lines = int(max_lines_raw)
max_chars = int(max_chars_raw)
home = os.path.expanduser("~")

text = pathlib.Path(log_file).read_text(encoding="utf-8", errors="replace")
text = text.replace(home, "$HOME")
text = re.sub(r"/Users/[^/\s]+", "/Users/<redacted>", text)
text = re.sub(r"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer <redacted>", text)
text = re.sub(r"(?i)(api[_-]?key|token|password|secret|registration[_-]?key)\s*[:=]\s*\S+", r"\1=<redacted>", text)
text = re.sub(r"\bgh[pousr]_[A-Za-z0-9_]+\b", "<redacted-token>", text)
text = re.sub(r"\bgithub_pat_[A-Za-z0-9_]+\b", "<redacted-token>", text)
text = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "<redacted-token>", text)
text = re.sub(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "<email>", text)
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", text)
text = re.sub(r"https?://\S+", "<url>", text)

lines = text.splitlines()[:max_lines]
text = "\n".join(lines)
truncated = len(text) > max_chars
if truncated:
    text = text[:max_chars]

def clean(value):
    value = value.replace(home, "$HOME")
    value = re.sub(r"https?://\S+", "<url>", value)
    value = re.sub(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "<email>", value)
    return value or "Not provided"

report = f"""### 问题类型 / What happened

{clean(kind)}

### 具体情况 / Details

Generated from a DictBridge conversion log. Review this report before submitting.

### 日志 / Log

```text
{text}
```

### 词典名称和版本 / Dictionary and edition

{clean(dictionary)}

### 词典文件 / Dictionary files

{clean(files)}

### DictBridge 版本 / DictBridge version

{clean(dictbridge_version)}

### macOS 版本 / macOS version

{clean(macos_version)}

### Mac 芯片 / Chip

{clean(chip)}

### 确认 / Checklist

- [ ] I did not attach dictionary files or link to downloads.
- [ ] I reviewed the redacted log for personal information and credentials.
"""

if truncated:
    report += "\n_Log truncated to the configured character limit._\n"

path = pathlib.Path(output_file)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(report, encoding="utf-8")
print(json.dumps({
    "ok": True,
    "output": str(path),
    "log_lines": len(lines),
    "log_chars": len(text),
    "truncated": truncated,
}, ensure_ascii=False))
PY
