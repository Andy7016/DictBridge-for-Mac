---
name: dictbridge
description: Diagnoses, converts, installs, verifies, and troubleshoots MDict (.mdx/.mdd) dictionaries on macOS using the DictBridge CLI. Use when the user asks to import MDict into macOS Dictionary, fix conversion failures, inspect MDX files, manage installed dictionaries, or prepare a sanitized DictBridge issue report. Do not use for non-macOS dictionary applications.
license: MIT
compatibility: Requires macOS 13+, DictBridge installed, the dictbridge CLI, and python3 for helper scripts.
metadata:
  version: "0.1.0"
---

# DictBridge

Use the existing DictBridge CLI to convert local MDict dictionaries into native macOS Dictionary bundles. Do not reimplement MDict parsing or Apple Dictionary compilation.

Run all commands from this skill directory. Use forward slashes in paths.

## Safety boundaries

- Treat `doctor`, `info`, and `list` as read-only.
- Get explicit user approval before `convert --install`, `remove`, `ddk --download`, `ddk --use`, or any command that changes installed dictionaries.
- Never upload, attach, or quote dictionary content. Issue reports must not contain `.mdx`, `.mdd`, dictionary bundles, or download links.
- Never ask for or store credentials.
- Preserve the user's source files. Convert into a fresh output directory unless the user explicitly requests replacement.

## Workflow

Copy this checklist and track progress:

```text
DictBridge progress:
- [ ] Locate the CLI and run the environment doctor
- [ ] Inspect the source dictionary
- [ ] Confirm the conversion plan
- [ ] Convert or install with approval
- [ ] Verify the installed dictionary
- [ ] Diagnose failures or prepare a sanitized report
```

### 1. Locate the CLI and check the environment

Run:

```bash
bash scripts/doctor.sh
```

The script checks, in order:

1. `DICTBRIDGE_BIN`, if set;
2. `dictbridge` on `PATH`;
3. `/Applications/DictBridge.app/Contents/Resources/dictbridge`.

If the CLI is missing, stop and ask the user to install DictBridge. Do not install software automatically.

Exit codes:

- `0`: CLI and DDK are ready;
- `2`: CLI not found or not executable;
- `3`: DDK is not set up;
- `4`: unsupported platform;
- `5`: helper dependency or invalid argument.

If the DDK is missing, explain that `dictbridge ddk --download` uses the network and requires approval. Do not run it without confirmation.

### 2. Inspect the source dictionary

Require a local `.mdx` path. Run:

```bash
dictbridge info "/path/to/dictionary.mdx"
```

Summarize:

- MDict engine version;
- declared and effective encoding;
- compression;
- encryption status;
- entry count;
- companion `.mdd` files and resource size;
- known compatibility risks.

Use [references/commands.md](references/commands.md) for the full CLI reference.

### 3. Confirm the conversion plan

Before conversion, confirm:

- display name;
- whether to include audio;
- dark-mode behavior;
- output-only versus install;
- output directory;
- whether an existing dictionary with the same name may be replaced.

Default to the least invasive option. Create the output directory first:

```bash
mkdir -p "./output"
dictbridge convert "/path/to/dictionary.mdx" \
  --name "Dictionary Name" \
  --dark-mode auto \
  --no-install \
  --output "./output"
```

Use `--install` only after explicit approval.

### 4. Convert

Quote every path. Use `--keep-work` only when diagnosing a failure.

For installation:

```bash
dictbridge convert "/path/to/dictionary.mdx" \
  --name "Dictionary Name" \
  --dark-mode auto \
  --install
```

Large dictionaries can take several minutes and need several GB of free space. Do not treat a slow compile step as a failure while progress is still moving.

### 5. Verify

After installation:

```bash
dictbridge list
```

Ask the user to:

1. open Dictionary.app;
2. enable the new dictionary in Settings;
3. place it at the desired priority;
4. test one ordinary word, one inflected form, and one domain-specific term;
5. check images, audio, and dark mode when relevant.

The system Look Up popover has known interaction limits. Use Dictionary.app for full verification.

### 6. Diagnose failures

Read [references/troubleshooting.md](references/troubleshooting.md) when a command fails or the result looks wrong.

- Preserve the original error and the failing stage.
- Do not blindly retry the same command.
- Do not edit the source dictionary to work around a converter bug.
- If a fix requires changing CSS or resources, work on a copy and record the change.

### 7. Prepare a sanitized issue report

When the user wants to report a problem:

```bash
bash scripts/make-report.sh \
  --log "/path/to/conversion.log" \
  --output "./dictbridge-issue.md" \
  --dictionary "Dictionary name and edition" \
  --dictbridge-version "0.6.0" \
  --kind "Conversion failed"
```

Read [references/privacy.md](references/privacy.md) before sharing the report. The script redacts common secrets and personal paths, but the user must review the final file.

## Gotchas

- `.mdd` files must share the `.mdx` base name, including split names such as `name.1.mdd`.
- `Encrypted="1"` dictionaries require a registration key and are best-effort only.
- `.spx` audio is not playable in Dictionary.app.
- The Look Up popover does not support reliable expander or audio clicks; open the full Dictionary.app entry.
- Dark-mode rendering can differ between Dictionary.app and the system popover.
- Older DictBridge versions may fail on large resource sets; use the current release before debugging further.
- The directory passed to `--output` must already exist.
- Apple Silicon may require Rosetta for the Dictionary Development Kit.

## References

- CLI options and examples: [references/commands.md](references/commands.md)
- Failure diagnosis: [references/troubleshooting.md](references/troubleshooting.md)
- Privacy and issue-report rules: [references/privacy.md](references/privacy.md)
