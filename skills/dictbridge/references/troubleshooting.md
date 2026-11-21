# Troubleshooting

## Contents

- CLI not found
- DDK not set up
- Conversion fails immediately
- Conversion hangs
- Dictionary does not appear
- Word cannot be found
- Audio does not play
- Images or layout are broken
- Dark mode looks wrong
- Large dictionary fails during compilation
- Encrypted dictionary cannot be read

## CLI not found

Check:

```bash
bash scripts/doctor.sh
ls -l "/Applications/DictBridge.app/Contents/Resources/dictbridge"
```

If the app exists but the CLI is not on `PATH`, pass the full path with `--cli` or set `DICTBRIDGE_BIN`. Do not create symlinks without approval because they may require administrator permission.

## DDK not set up

`dictbridge ddk` reports whether the Dictionary Development Kit is configured.

If missing, explain:

```bash
dictbridge ddk --download
```

This downloads Apple's DDK from a pinned public mirror and changes local state. Get approval before running it.

## Conversion fails immediately

Collect:

```bash
dictbridge --version
dictbridge info "/path/to/dictionary.mdx"
```

Check:

- the file is `.mdx`, not `.mdd` alone;
- the path exists and is readable;
- the `--output` directory already exists;
- companion `.mdd` files share the base name;
- the current DictBridge release is installed;
- free disk space is sufficient.

Do not retry unchanged after a deterministic parsing error.

## Conversion hangs

Determine the current stage from the log. The Apple compile stage can be slow for large dictionaries.

Ask the user to cancel only when:

- progress has not changed for an unusually long time;
- the log shows no active compile step;
- disk space is exhausted.

Preserve the log before retrying. Use `--keep-work` only for diagnosis.

## Dictionary does not appear

1. Confirm the bundle exists in `~/Library/Dictionaries`.
2. Quit and reopen Dictionary.app.
3. Open Dictionary → Settings and enable the dictionary.
4. Move it to the desired priority.
5. If an older same-name bundle exists, disable or remove it first.

## Word cannot be found

- Confirm the dictionary is enabled.
- Try the base form of an inflected word.
- Try a headword without syllable dots.
- For Chinese, try both Simplified and Traditional forms.
- Record the exact query and dictionary edition for an issue report.

## Audio does not play

- `.spx` audio is not supported by Dictionary.app.
- The Look Up popover may hide or disable audio controls.
- Verify playback in the full Dictionary.app entry.
- Check whether the source `.mdd` actually contains audio.

Do not transcode or modify the source dictionary without approval.

## Images or layout are broken

- Check whether referenced resources exist in the `.mdd`.
- Check for missing external CSS.
- Compare Dictionary.app with the Look Up popover.
- Record the affected headword and a screenshot.
- Work on a copy if a CSS override is needed.

## Dark mode looks wrong

- Use DictBridge 0.5.0 or newer.
- Re-convert dictionaries created by older versions.
- Try `--dark-mode light` as a diagnostic fallback.
- Remember that images are not automatically adapted.
- Report the macOS version, DictBridge version, dictionary edition, and screenshot.

## Large dictionary fails during compilation

Older builds could fail with `Argument list too long` while copying resources. Use the current release first.

Also check:

- several GB of free temporary space;
- whether the output directory is on a case-sensitive or network volume;
- whether the process was interrupted;
- whether `--keep-work` left stale build folders.

## Encrypted dictionary cannot be read

`Encrypted="1"` requires a registration key and is best-effort. Do not ask for registration keys or attempt to bypass access controls. Explain the limitation and suggest using a dictionary the user is authorized to open.
