# How DictBridge works

```
.mdx ─┐                                                     ┌─ Body.data
.mdd ─┼─► MDictKit ─► DictBridgeCore ─► DDK source ─► build_dict.sh ─► KeyText.index ─► ~/Library/Dictionaries
.css ─┘   (read)      (transform)        (XML/CSS/plist)    (Apple)    └─ OtherResources
```

1. **Index.** MDictKit reads the key index. If the header declares GBK, Big5 or another legacy
   encoding but a sample of keys and records is valid UTF-8, UTF-8 is used instead (many older
   dictionaries are mislabeled). The first pass over the records separates real entries from
   `@@@LINK=target` redirects. Each redirect becomes an extra `<d:index>` on its target entry,
   so searching *went* finds *go*.
2. **Resources.** Style sheets, scripts, fonts and images lying next to the `.mdx` are copied into
   `OtherResources/` first, then every `.mdd` volume is extracted there. Files next to the `.mdx`
   win over same-named files in the `.mdd`, as in MDict and GoldenDict. Backslash paths become
   `/` and names are deduplicated case-insensitively. Files the entries load that are in
   neither place (such as `oalecd8e.ini`) are picked up from the folder after the entries pass.
3. **Entries.** Records are parsed with libxml2's forgiving HTML parser in parallel batches,
   rewritten (see below), and streamed into one XML file. Each entry also gets extra search
   keys, because Dictionary.app matches keys exactly while MDict programs look words up loosely:
   - headwords with syllable marks (`ap.ple`, `beau·ti·ful`, `ˈapple`) get the plain form
     (`apple`), which is also used as the title in the result list;
   - Chinese headwords get their Simplified and Traditional counterparts (`蘋果` ↔ `苹果`),
     using ICU's character tables (can be turned off).
4. **Style sheet.** The style sheets the entries link to, plus `<name>.css`, are merged into
   `DefaultStyle.css` with type selectors lower-cased and `url()` paths fixed. Other sheets in the
   `.mdd` are usually alternatives (`*_large.css`, `*_switch.css`) and are left out. If none of
   the linked sheets exist, the ones next to the `.mdx` are used.
5. **Build.** Apple's `build_dict.sh -v 10.11` compiles the bundle. The result is moved into
   `~/Library/Dictionaries`. An older bundle with the same file name, or an older DictBridge
   build of the same `.mdx`, goes to the Trash. Non-Latin names are transliterated for the
   bundle's file name (`新牛津英汉双解大词典` → `xin-niu-jin-ying-han-shuang-jie-da-ci-dian`).
6. **Enable.** Dictionary.app is quit, the new bundle is added to its list of enabled
   dictionaries (`DCSActiveDictionaries` in the `com.apple.DictionaryServices` preferences), and
   Dictionary.app is reopened if it was running, because it only notices new dictionaries when
   it launches.

## Dictionary.app quirks (and what DictBridge does about them)

| Problem | Fix |
|---|---|
| Whitespace-only text nodes are dropped, so `<b>be</b> <i>noun</i>` renders as *benoun*. | Whitespace between two inline nodes is written as U+00A0. Whitespace next to block elements is dropped. |
| A click on plain text looks that word up, so `<span onclick=…>` buttons never fire. | Clickable non-link elements get an inner `<a class="dictbridge-click" href="javascript:void(0)">`. The original handler stays on the outer element, so `this` and sibling navigation keep working. |
| Dictionaries load jQuery and their own scripts with `<script src>`; copying the code into every entry made big dictionaries several GB. | Inline and external scripts both run, in the window and in the popover, and `<script src>` loads from the bundle. Script files stay in `OtherResources/` and entries keep their `<script src>` tags, so a 90 KB jQuery is stored once rather than in every entry. Inline scripts are wrapped in CDATA. |
| The look-up popover (force click, ⌃⌘D) shows only the first lines of each dictionary, ignores clicks, and marks its page with `<html class="apple_client-panel">`. | Small click-only elements (tabs, menu buttons, speaker icons; not phonetics, the headword, pictures or long expandable text) get the class `dictbridge-control`, and `html.apple_client-panel .dictbridge-control { display: none }` hides them in the popover. |
| `sound://` links do nothing. | `href="javascript:void(0)" onclick="new Audio('path').play()"`, with the audio file in the bundle. |
| `entry://word#anchor`, `bword://word` | `x-dictionary:r:<entry-id>:<bundle-id>`, resolved through redirects. Unknown words fall back to `x-dictionary:d:word`. |
| `entry://#anchor`, `#anchor` | `scrollIntoView()` on the element with that id. Named anchors `<a name>` become `<span id>`. |
| CSS type selectors are case-sensitive in XHTML. | `EXAMPLE{…}` becomes `example{…}`, matching the lower-cased tags. |
| Resource paths like `/img/a.png`, `\img\a.png` or `file://a.png` | Rewritten as bundle-relative `img/a.png`. |
| A dictionary without `DCSDictionaryUseSystemAppearance` in its `Info.plist` is treated as not Dark Mode aware: Dictionary.app adds `apple_appearance-incompliant` to `<html>` and applies `-apple-color-filter: apple-invert-lightness()` in Dark Mode. On many MDict style sheets this gives a white page with washed-out text ([#3](https://github.com/Andy7016/DictBridge-for-Mac/issues/3)). | Every dictionary declares `DCSDictionaryUseSystemAppearance` and handles Dark Mode in its style sheet (see below). |

## Dark Mode

`--dark-mode auto` (the default) rewrites every color in the dictionary's style sheets, `<style>` blocks, `style` attributes, `<font color>` and `bgcolor`:

```css
.pos { color: #36363c }
/* becomes */
.pos { color: #36363c; color: light-dark(#36363c, #adadb4) }
```

The original declaration stays first, so a system without `light-dark()` drops the second one. The dark color keeps the hue and mirrors the lightness in Oklab, mapped so that white lands on the Dark Mode page (about `#1e1e1e`) and black on the Dark Mode text (about `#dfdfdf`):

- text colors (`color`, `fill`, `text-decoration-color`…) that are dark become light, at least Oklab L 0.75; light text, often on a colored button, stays;
- backgrounds lighter than Oklab L 0.7 become dark; darker or strongly colored ones stay, so their light text stays readable;
- borders and outlines are always mirrored; shadows are left alone;
- `var()`, `currentColor`, `transparent` and declarations that already use `light-dark()` are left alone.

The appended style sheet sets `:root { color-scheme: light dark }` and `html { color: CanvasText }`, so text without a color of its own follows the system. `light-dark()` needs Safari 17.5 (macOS 14.5); on older systems `@supports not (color: light-dark(#000, #fff))` switches the page to `color-scheme: light only` with a white background, so the dictionary looks as it does in light mode.

`--dark-mode light` skips the rewriting and always uses the light page. Pictures are never changed.

## Apple's Dictionary Development Kit

The DDK's scripts and binaries come from Apple's *Additional Tools for Xcode*. They are not
redistributed. `DDKToolkit` looks for a kit in this order:

1. the `DICTBRIDGE_DDK` environment variable;
2. a folder the user picked;
3. `~/Library/Application Support/DictBridge/DDK/bin`;
4. standard install locations.

If none is found, it downloads the 21 files from a mirror pinned to one commit, checks each file
against a SHA-256 written into the source, and installs them only if every check passes.

The kit needs `/usr/bin/perl`, `xsltproc`, `xmllint` and `plutil`, all of which are part of macOS.
