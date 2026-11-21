#!/bin/bash
set -u

usage() {
  cat <<'EOF'
Usage: doctor.sh [--cli PATH]

Check whether DictBridge and its Dictionary Development Kit are ready.

Options:
  --cli PATH   Use an explicit dictbridge executable.
  --help       Show this help.

Environment:
  DICTBRIDGE_BIN   Explicit dictbridge executable, unless --cli is set.

Exit codes:
  0  CLI and DDK are ready
  2  CLI not found or not executable
  3  DDK is not set up
  4  Platform is not macOS
  5  Invalid argument or missing helper dependency
EOF
}

cli_override=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cli)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf 'Error: --cli requires a path.\n' >&2
        exit 5
      fi
      cli_override="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 5
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  printf 'Error: python3 is required for doctor.sh. Install Xcode Command Line Tools.\n' >&2
  exit 5
fi

platform="$(uname -s 2>/dev/null || printf unknown)"
if [ "$platform" != "Darwin" ]; then
  python3 - "$platform" <<'PY'
import json
import sys
print(json.dumps({
    "ok": False,
    "platform": sys.argv[1],
    "error": "DictBridge requires macOS.",
    "exit_code": 4,
}, ensure_ascii=False))
PY
  exit 4
fi

cli_path=""
if [ -n "$cli_override" ]; then
  cli_path="$cli_override"
elif [ -n "${DICTBRIDGE_BIN:-}" ]; then
  cli_path="$DICTBRIDGE_BIN"
elif command -v dictbridge >/dev/null 2>&1; then
  cli_path="$(command -v dictbridge)"
elif [ -x "/Applications/DictBridge.app/Contents/Resources/dictbridge" ]; then
  cli_path="/Applications/DictBridge.app/Contents/Resources/dictbridge"
fi

cli_found=false
cli_version=""
ddk_ready=false
ddk_status=""
ddk_exit_code=""

if [ -n "$cli_path" ] && [ -x "$cli_path" ]; then
  cli_found=true
  cli_version="$("$cli_path" --version 2>/dev/null | head -n 1 || true)"
  ddk_status="$("$cli_path" ddk 2>&1 || true)"
  case "$ddk_status" in
    *"not set up"*) ddk_ready=false ;;
    *) ddk_ready=true ;;
  esac
fi

macos_version="$(sw_vers -productVersion 2>/dev/null || printf unknown)"
architecture="$(uname -m 2>/dev/null || printf unknown)"
free_kb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
python_version="$(python3 --version 2>&1 || true)"

exit_code=0
if [ "$cli_found" != true ]; then
  exit_code=2
elif [ "$ddk_ready" != true ]; then
  exit_code=3
fi

python3 - \
  "$cli_path" "$cli_found" "$cli_version" \
  "$ddk_ready" "$ddk_status" \
  "$macos_version" "$architecture" "$free_kb" \
  "$python_version" "$exit_code" <<'PY'
import json
import sys

(
    cli_path,
    cli_found,
    cli_version,
    ddk_ready,
    ddk_status,
    macos_version,
    architecture,
    free_kb,
    python_version,
    exit_code,
) = sys.argv[1:]

free_bytes = int(free_kb) * 1024 if free_kb.isdigit() else None
exit_code_value = int(exit_code)
print(json.dumps({
    "ok": exit_code_value == 0,
    "platform": "Darwin",
    "macos_version": macos_version,
    "architecture": architecture,
    "free_disk_bytes": free_bytes,
    "python_version": python_version,
    "cli": {
        "found": cli_found == "true",
        "path": cli_path or None,
        "version": cli_version or None,
    },
    "ddk": {
        "ready": ddk_ready == "true",
        "status": ddk_status or None,
    },
    "exit_code": int(exit_code),
}, ensure_ascii=False, indent=2))
PY

exit "$exit_code"
