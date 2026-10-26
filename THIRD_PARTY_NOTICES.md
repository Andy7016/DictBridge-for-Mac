# Third-party notices

DictBridge's own code is MIT-licensed. It builds on knowledge and work from these projects:

| What | Project | Licence | How it is used |
|---|---|---|---|
| Apple Dictionary Development Kit | Apple, "Additional Tools for Xcode" | Apple licence | **Not redistributed.** Downloaded on the user's machine at first use (or supplied by the user) and run locally. |
| DDK mirror | [nanoskript/dictionary-development-kit](https://github.com/nanoskript/dictionary-development-kit) | — | Download source, pinned to commit `d4127fd9` and checked against SHA-256 hashes. |
| Mirror choice and file hashes | [Sangyop-Lee/stardict2mac](https://github.com/Sangyop-Lee/stardict2mac) | MIT | DictBridge uses the same pinned mirror and hash list. |
| MDict file format | [mdict-analysis / readmdict](https://bitbucket.org/xwang/mdict-analysis) by Xiaoqiang Wang | GPL-3.0 | Reference for the file format, including MDict 3.0 (as published in mdict-utils' `readmdict.py`). MDictKit is a separate implementation written in Swift. |
| LZO1X decoder | [liuyug/mdict-utils](https://github.com/liuyug/mdict-utils) (`base/lzo.py`) | MIT | `MDictCodec.lzo1xDecompress` is a port of its pure-Python decoder. |
| RIPEMD-128 | [zhansliu/writemdict](https://github.com/zhansliu/writemdict) | MIT | Reference for `RIPEMD128.swift`. The test fixtures are generated with writemdict. |
| xxHash64, Salsa20 | Algorithms by Yann Collet and Daniel J. Bernstein | BSD-2-Clause / public domain | Own Swift implementations in `Ciphers.swift`, checked against published test values. |
| MDict 3.0 test fixtures | [liuyug/mdict-utils](https://github.com/liuyug/mdict-utils) | MIT | `scripts/make_fixtures.py` writes the 3.0 fixtures itself and checks them with mdict-utils' reader. |
| HTML parsing | libxml2 (part of macOS) | MIT | System library. |
