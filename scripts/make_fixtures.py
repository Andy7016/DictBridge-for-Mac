#!/usr/bin/env python3
"""Generate the small synthetic MDict files used by the unit tests.

Requires:  pip install mdict-utils
Usage:     python3 scripts/make_fixtures.py Tests/MDictKitTests/Fixtures

All content is invented for testing; no third-party dictionary data is used.
"""
import hashlib
import json
import os
import struct
import sys
import types

from mdict_utils.base import writemdict


# --- a minimal LZO1X "compressor" that only emits literal runs ---------------------
# Real LZO encoders are not pip-installable everywhere; a literal-only stream is still a
# valid LZO1X stream, which is enough to exercise the decoder's literal + EOF paths.
def lzo_literal_only(data: bytes) -> bytes:
    out = bytearray()
    n = len(data)
    if n == 0:
        return bytes([0x11, 0, 0])
    if n <= 238:
        out.append(17 + n)
    else:
        t = n - 3
        if t <= 15:
            out.append(t)
        else:
            out.append(0)
            rem = t - 15
            while rem > 255:
                out.append(0)
                rem -= 255
            out.append(rem)
    out += data
    out += bytes([0x11, 0, 0])
    return bytes(out)


fake_lzo = types.SimpleNamespace(compress=lambda d: b"\xf0" + struct.pack(">I", len(d)) + lzo_literal_only(d))
writemdict.lzo = fake_lzo
writemdict.HAVE_LZO = True


ENTRIES = {
    "apple": (
        '<link rel="stylesheet" type="text/css" href="sample.css">'
        '<script type="text/javascript" src="sample.js"></script>'
        '<div class="entry"><span class="hw">apple</span> <span class="pos">noun</span> '
        '<a href="sound://snd/apple.mp3"><img src="img/spk.png"></a>'
        '<span class="btn" onclick="sample.toggle(this)">Examples</span><div class="pop">An apple a day.</div>'
        '<EN>a round fruit</EN><TRAN>苹果</TRAN>'
        '<p>See <a href="entry://banana">banana</a> and <a href="entry://#sense2">sense 2</a>.</p>'
        '<a name="sense2"></a><p class="sense">2. something else &amp; more&nbsp;text</p>'
        '<exat></exat></div>'
    ),
    "banana": '<div class="entry"><b>banana</b> a long yellow fruit<br>香蕉</div>',
    "Bananas": "@@@LINK=banana",
    "cherry": '<div class="entry"><b>cherry</b> <img src="/img/cherry.png"> small red fruit</div>',
    "cherries": "@@@LINK=cherry",
    "durian": '<div class="entry"><b>durian</b> see <a href="bword://cherry">cherry</a></div>',
}

PNG_1x1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000154a24f5f0000000049454e44ae426082"
)

RESOURCES = {
    "\\img\\spk.png": PNG_1x1,
    "\\img\\cherry.png": PNG_1x1,
    "\\snd\\apple.mp3": b"ID3" + b"\x00" * 64,
    "\\sample.css": b".hw{color:blue}\nEN{display:block}\n.pop{display:none}\n",
    "\\sample.js": b"var sample={toggle:function(e){var n=e.nextSibling;n.style.display=n.style.display=='block'?'none':'block';}};\n",
}


def write(path, d, **kw):
    with open(path, "wb") as f:
        writemdict.MDictWriter(d, **kw).write(f)


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    expected = {}

    def mdx(name, entries, **kw):
        kw.setdefault("title", "DictBridge Sample")
        kw.setdefault("description", "<b>Synthetic</b> test dictionary &amp; fixture")
        write(os.path.join(outdir, name), entries, **kw)
        sample = entries if len(entries) <= 50 else {k: v for i, (k, v) in enumerate(sorted(entries.items())) if i % 97 == 0}
        expected[name] = {
            "count": len(entries),
            "entries": sample,
            "title": kw["title"],
        }

    mdx("basic.mdx", ENTRIES)
    mdx("encrypted.mdx", ENTRIES, encrypt_index=True)
    mdx("utf16.mdx", ENTRIES, encoding="utf16")
    gbk_entries = {"苹果": "<b>苹果</b>：一种水果", "香蕉": "<b>香蕉</b>：黄色的水果", "fruit": "@@@LINK=苹果"}
    mdx("gbk.mdx", gbk_entries, encoding="gbk")
    mdx("v12.mdx", ENTRIES, version="1.2")
    mdx("lzo.mdx", ENTRIES, compression_type=1, version="1.2")
    mdx("stored.mdx", ENTRIES, compression_type=0)
    # Header claims Big5 but the data is UTF-8 (seen in real 1.2-era dictionaries), with
    # syllable-dotted headwords and compact-format style markers.
    mislabeled = {
        "ap.ple": "`1`ap.ple`2`蘋果",
        "beau.ti.ful": "`1`beau.ti.ful`2`美麗的",
        "蘋果": "<b>蘋果</b> apple",
    }
    w = writemdict.MDictWriter(mislabeled, title="Mislabeled", description="utf-8 data, big5 header",
                               encoding="utf8", version="1.2")
    w._encoding = "BIG5"
    with open(os.path.join(outdir, "mislabeled.mdx"), "wb") as f:
        w.write(f)
    expected["mislabeled.mdx"] = {"count": len(mislabeled), "entries": mislabeled, "title": "Mislabeled"}

    many = {f"word{i:05d}": f"<p>definition number {i} " + ("x" * (i % 97)) + "</p>" for i in range(3000)}
    mdx("multiblock.mdx", many, block_size=2048)

    write(os.path.join(outdir, "basic.mdd"), RESOURCES, title="", description="", is_mdd=True)
    expected["basic.mdd"] = {
        "count": len(RESOURCES),
        "files": {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in RESOURCES.items()},
    }

    # sanity-check every fixture with an independent reader (pure-Python LZO for lzo.mdx)
    from mdict_utils.base import lzo as pure_lzo
    sys.modules["lzo"] = types.SimpleNamespace(decompress=lambda b: pure_lzo.decompress(b[5:]))
    from mdict_utils.base.readmdict import MDX, MDD
    for name, exp in expected.items():
        if name == "stored.mdx":
            continue  # writemdict stores the key index uncompressed; readmdict rejects that variant
        p = os.path.join(outdir, name)
        r = MDD(p) if name.endswith(".mdd") else MDX(p)
        n = sum(1 for _ in r.items())
        assert n == exp["count"], (name, n, exp["count"])

    with open(os.path.join(outdir, "expected.json"), "w", encoding="utf-8") as f:
        json.dump(expected, f, ensure_ascii=False, indent=1, sort_keys=True)
    print("fixtures written to", outdir)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Tests/MDictKitTests/Fixtures")
