#!/bin/bash
set -euo pipefail

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dictbridge-skill-test.XXXXXX")"
trap 'rm -r "$tmp_dir"' EXIT

for script in "$skill_dir"/scripts/*.sh; do
  bash -n "$script"
done

ready_cli="$tmp_dir/dictbridge-ready"
cat > "$ready_cli" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version) printf '9.9.9\n' ;;
  ddk) printf 'Dictionary Development Kit: /tmp/fake-ddk\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$ready_cli"

doctor_output="$(bash "$skill_dir/scripts/doctor.sh" --cli "$ready_cli")"
python3 - "$doctor_output" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["ok"] is True
assert report["cli"]["found"] is True
assert report["cli"]["version"] == "9.9.9"
assert report["ddk"]["ready"] is True
PY

missing_cli="$tmp_dir/dictbridge-missing"
cat > "$missing_cli" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version) printf '9.9.9\n' ;;
  ddk) printf 'Dictionary Development Kit: not set up (run: dictbridge ddk --download)\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$missing_cli"

set +e
bash "$skill_dir/scripts/doctor.sh" --cli "$missing_cli" > "$tmp_dir/doctor-missing-ddk.json"
doctor_status=$?
set -e
[ "$doctor_status" -eq 3 ]
python3 - "$tmp_dir/doctor-missing-ddk.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["ok"] is False
assert report["ddk"]["ready"] is False
PY

set +e
bash "$skill_dir/scripts/doctor.sh" --cli "$tmp_dir/does-not-exist" > "$tmp_dir/doctor-missing-cli.json"
doctor_status=$?
set -e
[ "$doctor_status" -eq 2 ]
python3 - "$tmp_dir/doctor-missing-cli.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["ok"] is False
assert report["cli"]["found"] is False
PY

cat > "$tmp_dir/conversion.log" <<'EOF'
DictBridge 0.6.0
Error: conversion failed
token=gho_FAKE_TOKEN
Authorization: Bearer secret-value
/home/testuser/Library/Caches/DictBridge/build-1/dict.xml
Contact: user@example.com
Download: https://example.com/private-dictionary.zip
EOF

bash "$skill_dir/scripts/make-report.sh" \
  --log "$tmp_dir/conversion.log" \
  --output "$tmp_dir/issue.md" \
  --dictionary "Synthetic Dictionary 1.0" \
  --dictbridge-version "0.6.0" \
  --macos "macOS 26.0" \
  --chip apple-silicon \
  --kind "Conversion failed" \
  --files "synthetic.mdx 1 KB; synthetic.mdd 1 KB" \
  > "$tmp_dir/report-result.json"

python3 - "$tmp_dir/issue.md" "$tmp_dir/report-result.json" <<'PY'
import json
import pathlib
import sys
report = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
result = json.load(open(sys.argv[2], encoding="utf-8"))
assert result["ok"] is True
assert "Synthetic Dictionary 1.0" in report
assert "gho_FAKE_TOKEN" not in report
assert "secret-value" not in report
assert "user@example.com" not in report
assert "https://example.com/private-dictionary.zip" not in report
assert "<redacted>" in report
assert "<email>" in report
assert "<url>" in report
PY

printf 'DictBridge Skill smoke tests passed.\n'
