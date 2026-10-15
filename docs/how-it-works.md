# How DictBridge works

```
.mdx ─┐                                                     ┌─ Body.data
.mdd ─┼─► MDictKit ─► DictBridgeCore ─► DDK source ─► build_dict.sh ─► KeyText.index ─► ~/Library/Dictionaries
.css ─┘   (read)      (transform)        (XML/CSS/plist)    (Apple)    └─ OtherResources
```

1. **Index.** MDictKit reads the key index. The first pass over the records separates real
   entries from `@@@LINK=target` redirects. Each redirect becomes an extra `<d:index>` on its
   target entry, so searching *went* finds *go*.
2. **Resources.** Every `.mdd` volume is extracted into `OtherResources/`. Backslash paths become
   `/`, names are deduplicated case-insensitively, and `.css`/`.js` files are kept aside.
   Fonts and images lying next to the `.mdx` are copied as well.
3. **Entries.** Records are parsed with libxml2's forgiving HTML parser in parallel batches,
   rewritten (see below), and streamed into one XML file.
4. **Style sheet.** All CSS is merged into `DefaultStyle.css`, with type selectors lower-cased and
   `url()` paths fixed.
5. **Build.** Apple's `build_dict.sh -v 10.11` compiles the bundle. The result is moved into
   `~/Library/Dictionaries`. An older bundle with the same file name goes to the Trash.
   Dictionary.app is then restarted, because it only notices new dictionaries when it launches.

## Dictionary.app quirks (and what DictBridge does about them)

| Problem | Fix |
|---|---|
| Whitespace-only text nodes are dropped, so `<b>be</b> <i>noun</i>` renders as *benoun*. | Whitespace between two inline nodes is written as U+00A0. Whitespace next to block elements is dropped. |
| A click on plain text looks that word up, so `<span onclick=…>` buttons never fire. | Clickable non-link elements get an inner `<a class="dictbridge-click" href="javascript:void(0)">`. The original handler stays on the outer element, so `this` and sibling navigation keep working. |
| JavaScript runs, but only inline `<script>` is known to work. | The dictionary's `.js` files are inlined, wrapped in CDATA, into entries that use scripts or handlers. The limit is 256 KB. |
| `sound://` links do nothing. | `href="javascript:void(0)" onclick="new Audio('path').play()"`, with the audio file in the bundle. |
| `entry://word#anchor`, `bword://word` | `x-dictionary:r:<entry-id>:<bundle-id>`, resolved through redirects. Unknown words fall back to `x-dictionary:d:word`. |
| `entry://#anchor`, `#anchor` | `scrollIntoView()` on the element with that id. Named anchors `<a name>` become `<span id>`. |
| CSS type selectors are case-sensitive in XHTML. | `EXAMPLE{…}` becomes `example{…}`, matching the lower-cased tags. |
| Resource paths like `/img/a.png`, `\img\a.png` or `file://a.png` | Rewritten as bundle-relative `img/a.png`. |

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
