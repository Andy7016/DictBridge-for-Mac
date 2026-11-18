# Releasing DictBridge

## One-time setup: the update signing key

In-app updates (Sparkle) only install an update whose `.zip` and `appcast.xml` are signed with
the project's EdDSA private key. The public half is in `Resources/sparkle-public-key.txt` and
goes into every build's `Info.plist`; the private half is the `SPARKLE_PRIVATE_KEY` secret of
the GitHub repository and never enters the repository.

1. Resolve the packages once so that Sparkle's tools are in `.build/artifacts`:

   ```bash
   swift package resolve
   ```

2. Create the key pair. The private key is stored in your login Keychain and the public key is
   printed:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

3. Save the public key (the text after `SUPublicEDKey`) and commit it:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -p > Resources/sparkle-public-key.txt
   ```

4. Give the private key to GitHub Actions, then delete the exported copy:

   ```bash
   KEY="$(mktemp)" && .build/artifacts/sparkle/Sparkle/bin/generate_keys -x "$KEY" && gh secret set SPARKLE_PRIVATE_KEY < "$KEY"; rm -P "$KEY"
   ```

5. Back up the private key, for example in a password manager (it is the Keychain item
   "Private key for signing Sparkle updates"; `generate_keys -f <file>` imports it on another
   Mac). If it is lost, released versions can no longer be updated in place: users would have to
   download a build with a new public key by hand.

Builds without `Resources/sparkle-public-key.txt` have in-app updates turned off; the CI run
for a published release fails instead.

## Every release

1. Set the version in `Sources/DictBridgeCore/DictBridge.swift`, move the CHANGELOG entries
   under the new version, update the version placeholders in `.github/ISSUE_TEMPLATE/`.
2. Commit, push, wait for CI.
3. Publish the release (the text is what the update window shows):

   ```bash
   gh release create vX.Y.Z --title "DictBridge X.Y.Z" --notes-file dist/release-notes-X.Y.Z.md
   ```

4. The CI run for the release builds the app, signs `DictBridge-X.Y.Z.zip`, writes and signs
   `appcast.xml` (`scripts/make-appcast.sh`) and attaches the `.zip`, `.dmg` and `appcast.xml`.
   Installed apps read `releases/latest/download/appcast.xml`, so they see the release as soon
   as the files are attached.

Pre-releases (`vX.Y.Z-beta.N`) get their own `appcast.xml` but are never "latest", so nobody
is offered them. To try the update path with one, point an installed app at its feed:

```bash
defaults write org.dictbridge.DictBridge UpdateFeedURL https://github.com/Andy7016/DictBridge-for-Mac/releases/download/vX.Y.Z-beta.N/appcast.xml
```

and remove the override afterwards:

```bash
defaults delete org.dictbridge.DictBridge UpdateFeedURL
```

`sparkle:version` in the feed is the build number (`git rev-list --count HEAD`), which Sparkle
compares with the installed app's `CFBundleVersion`; the beta must therefore be built from a
later commit than the installed app.
