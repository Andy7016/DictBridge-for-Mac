#!/usr/bin/env python3
"""Generate the small synthetic MDict files used by the unit tests.

Requires:  pip install mdict-utils xxhash
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


# --- a minimal MDict 3.0 writer ------------------------------------------------------
# writemdict cannot produce version 3.0 files, so this writes the layout documented by
# readmdict (Xiaoqiang Wang's mdict-analysis): a UTF-8 header, then typed sections
# (1 record data, 2 record index, 3 key data, 4 key index), each holding blocks whose
# 8-byte header packs compression, encryption method and encrypted length. Every file
# written here is read back with readmdict below, an independent implementation.
import zlib
import xxhash
from mdict_utils.base.ripemd128 import ripemd128
from mdict_utils.base.pureSalsa20 import Salsa20


def _fast_encrypt(data: bytes, key: bytes) -> bytes:
    out = bytearray()
    previous = 0x36
    for i, p in enumerate(data):
        t = p ^ previous ^ (i & 0xFF) ^ key[i % len(key)]
        c = ((t >> 4) | (t << 4)) & 0xFF
        out.append(c)
        previous = c
    return bytes(out)


def _v3_block(payload: bytes, compression: int, encryption: int = 0, enc_size: int = 0, key: bytes = None) -> bytes:
    if compression == 0:
        comp = payload
    elif compression == 1:
        comp = lzo_literal_only(payload)
    else:
        comp = zlib.compress(payload)
    adler = zlib.adler32(comp) & 0xFFFFFFFF  # version 3: checksum of the unencrypted payload
    k = key or ripemd128(struct.pack(">I", adler))
    head, tail = comp[:enc_size], comp[enc_size:]
    if encryption == 1:
        comp = _fast_encrypt(head, k) + tail
    elif encryption == 2:
        comp = Salsa20(key=k, IV=b"\x00" * 8, rounds=8).encryptBytes(head) + tail
    info = compression | (encryption << 4) | (enc_size << 8)
    return struct.pack("<I", info) + struct.pack(">I", adler) + comp


def _v3_section(blocks) -> bytes:
    """blocks: list of (decompressed_size, encoded_block)"""
    body = struct.pack(">I", len(blocks)) + struct.pack(">Q", sum(d for d, _ in blocks))
    for dsize, b in blocks:
        body += struct.pack(">II", dsize, len(b)) + b
    return body


def write_v3(path, entries, *, is_mdd=False, uuid=None, title="DictBridge Sample", description="",
             key_style=(2, 0, 0), record_styles=((2, 0, 0),), keys_per_block=3, record_block=200,
             order=(1, 2, 3, 4)):
    """key_style / record_styles: (compression, encryption, encrypted length) per block, cycled."""
    key = None
    if uuid:
        u = uuid.encode()
        mid = (len(u) + 1) // 2
        key = xxhash.xxh64_digest(u[:mid]) + xxhash.xxh64_digest(u[mid:])

    items = sorted(entries.items(), key=lambda kv: kv[0].lower())
    records, offsets, pos = [], [], 0
    for k, v in items:
        data = v if is_mdd else v.encode("utf-8") + b"\x00"
        offsets.append(pos)
        records.append(data)
        pos += len(data)

    def key_text(k):
        return k.encode("utf-8") + b"\x00"

    key_blocks = []
    for i in range(0, len(items), keys_per_block):
        payload = b"".join(struct.pack(">Q", offsets[j]) + key_text(items[j][0])
                           for j in range(i, min(i + keys_per_block, len(items))))
        c, e, n = key_style
        key_blocks.append((len(payload), _v3_block(payload, c, e, n, key)))

    # whole records per block (MDict writers never split a record across blocks)
    groups, current = [], b""
    for data in records:
        current += data
        if len(current) >= record_block:
            groups.append(current)
            current = b""
    if current:
        groups.append(current)
    record_blocks = []
    for n, payload in enumerate(groups):
        c, e, size = record_styles[n % len(record_styles)]
        record_blocks.append((len(payload), _v3_block(payload, c, e, size, key)))
    index_payload = b"".join(struct.pack(">QQ", len(b) + 8, d) for d, b in record_blocks)

    sections = {
        1: _v3_section(record_blocks),
        2: _v3_section([(len(index_payload), _v3_block(index_payload, 0))]),
        3: _v3_section(key_blocks),
        4: _v3_section([]),  # key index: not needed for reading; left empty
    }

    def esc(s):
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

    tag = "Library_Data" if is_mdd else "Dictionary"
    attrs = (f'GeneratedByEngineVersion="3.0" RequiredEngineVersion="3.0" Encrypted="0" Encoding="UTF-8" '
             f'Format="Html" CreationDate="2026-10-26" Title="{esc(title)}" Description="{esc(description)}"')
    if uuid:
        attrs += f' UUID="{uuid}"'
    header = f"<{tag} {attrs}/>\r\n".encode("utf-8") + b"\x00"
    with open(path, "wb") as f:
        f.write(struct.pack(">I", len(header)) + header + struct.pack("<I", zlib.adler32(header) & 0xFFFFFFFF))
        for t in order:
            body = sections[t]
            f.write(struct.pack(">I", t << 24) + struct.pack(">Q", len(body)) + body)


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
    resource_info = {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in RESOURCES.items()}
    expected["basic.mdd"] = {"count": len(RESOURCES), "files": resource_info}

    # MDict 3.0: plain zlib blocks, sections in file order 1-4, record blocks scrambled with
    # the per-block key (no UUID).
    v3_entries = dict(ENTRIES, **{"蘋果": "<b>蘋果</b> apple", "ap.ple": "<b>ap.ple</b> fruit"})
    write_v3(os.path.join(outdir, "v3.mdx"), v3_entries, description="<b>Synthetic</b> 3.0 fixture",
             record_styles=((2, 0, 0), (2, 1, 16)))
    expected["v3.mdx"] = {"count": len(v3_entries), "entries": v3_entries, "title": "DictBridge Sample"}
    # MDict 3.0 with a UUID-derived key: Salsa20 key blocks, mixed compression and encryption in
    # the record blocks, sections in reverse order.
    write_v3(os.path.join(outdir, "v3-encrypted.mdx"), v3_entries, uuid="5c3f1a2e-8d4b-4c7a-9e61-0b2d3f4a5c6d",
             key_style=(2, 2, 64), record_styles=((2, 2, 255), (1, 1, 40), (0, 2, 12)), order=(4, 3, 2, 1))
    expected["v3-encrypted.mdx"] = {"count": len(v3_entries), "entries": v3_entries, "title": "DictBridge Sample"}
    write_v3(os.path.join(outdir, "v3.mdd"), RESOURCES, is_mdd=True, uuid="0f9e8d7c-6b5a-4938-8271-605f4e3d2c1b",
             title="", key_style=(2, 2, 32), record_styles=((2, 2, 128),), record_block=64)
    expected["v3.mdd"] = {"count": len(RESOURCES), "files": resource_info}

    # sanity-check every fixture with an independent reader (pure-Python LZO for lzo.mdx)
    from mdict_utils.base import lzo as pure_lzo
    sys.modules["lzo"] = types.SimpleNamespace(decompress=lambda b: pure_lzo.decompress(b[5:]))
    from mdict_utils.base.readmdict import MDX, MDD
    for name, exp in expected.items():
        if name == "stored.mdx":
            continue  # writemdict stores the key index uncompressed; readmdict rejects that variant
        p = os.path.join(outdir, name)
        r = MDD(p) if name.endswith(".mdd") else MDX(p)
        items = list(r.items())
        assert len(items) == exp["count"], (name, len(items), exp["count"])
        if name.startswith("v3"):
            # stricter for the hand-written 3.0 files: every key and record must round-trip
            got = {k.decode("utf-8"): v for k, v in items}
            if name.endswith(".mdd"):
                assert {k: hashlib.sha256(v).hexdigest() for k, v in got.items()} == \
                    {k: i["sha256"] for k, i in exp["files"].items()}, name
            else:
                assert {k: v.decode("utf-8") for k, v in got.items()} == exp["entries"], name

    with open(os.path.join(outdir, "expected.json"), "w", encoding="utf-8") as f:
        json.dump(expected, f, ensure_ascii=False, indent=1, sort_keys=True)
    print("fixtures written to", outdir)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Tests/MDictKitTests/Fixtures")
