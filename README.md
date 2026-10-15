<p align="center"><img src="Resources/AppIcon.png" width="128" alt="DictBridge icon"></p>

<h1 align="center">DictBridge for Mac</h1>

<p align="center">
把 MDict（.mdx / .mdd）词典装进 macOS 自带的「词典」App。<br>
Put MDict (.mdx / .mdd) dictionaries into the built-in macOS Dictionary app.
</p>

---

**中文** · [English](#english)

macOS 的「词典」App 很好用：查词快，系统里任何地方三指轻点（或按住 ⌃⌘D）都能调出。但它只认苹果自己的 `.dictionary` 格式，不能直接导入大家常用的 MDict 词典。DictBridge 负责这个转换：把 `.mdx` 拖进窗口，它会读出词条和发音、图片资源，生成「词典」App 能识别的格式，并装进 `~/Library/Dictionaries`。装好的词典都列在窗口里，不想要了随时可以删掉。

## 功能

- **拖进来就行**：同一文件夹里的 `.mdd`（包括 `name.1.mdd`、`name.2.mdd` 分卷）、`.css` 和 `.js` 会自动一起导入
- **尽量保持原样**：保留原词典的排版样式、配图、真人发音、词条间的交叉链接，以及变形词跳转（went → go、apples → apple）
- **针对「词典」App 做了适配**，详见 [docs/how-it-works.md](docs/how-it-works.md)：
  - 修复词与词之间空格丢失
  - 展开按钮（例句、搭配、词源等）可以正常点击
  - 发音按钮可以播放
- **词典管理**：列出 `~/Library/Dictionaries` 中的所有词典；删除时移到废纸篓，可以恢复；安装或删除后会自动重启「词典」App
- **格式支持**：MDict 1.2 和 2.0，UTF-8、UTF-16、GBK、Big5 编码，zlib 和 LZO 压缩，加密索引（`Encrypted="2"`）
- **附带命令行工具** `dictbridge`，方便批量处理或写脚本

## 安装

1. 从 [Releases](../../releases) 下载 `DictBridge-x.y.z.dmg`，把 DictBridge 拖进「应用程序」。
2. 第一次打开时，macOS 可能提示无法验证开发者，因为当前版本还没有经过 Apple 公证。处理方法：打开「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」；或者在终端里运行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/DictBridge.app
   ```
3. 第一次转换前，DictBridge 会请你下载苹果的 **Dictionary Development Kit**（约 1.5 MB）。苹果的许可不允许把它打包进本软件，所以它会从[公开镜像](https://github.com/nanoskript/dictionary-development-kit)下载，每个文件都用写死在代码里的 SHA-256 校验。如果你装过苹果的「Additional Tools for Xcode」，也可以直接选择其中的 Dictionary Development Kit 文件夹。

系统要求：macOS 13 Ventura 或更新版本，Apple 芯片和 Intel 均可。

## 使用

1. 打开 DictBridge，把 `.mdx` 文件（或包含它的文件夹）拖进窗口，也可以点「添加词典…」。
2. 确认名称，选择是否包含发音音频（音频往往占大部分体积），点「转换并安装」。
3. 完成后打开「词典」App。新词典一般会自动启用；如果没看到，到「词典 → 设置」里勾选它，还可以拖动调整顺序。

大型词典（例如约 1.3 GB 的《朗文当代》第 6 版英汉双解）在 Apple 芯片的 Mac 上转换大约需要 5 分钟，过程中需要几 GB 的临时空间，结束后会自动清理。

### 命令行

```bash
/Applications/DictBridge.app/Contents/Resources/dictbridge convert ~/Dicts/LDOCE6/LDOCE6.mdx --name "朗文当代 6"
dictbridge list
dictbridge remove "朗文当代 6"
dictbridge info some.mdx
dictbridge ddk --download
```

运行 `dictbridge help` 查看全部选项，例如 `--no-audio`、`--no-install`、`--output`、`--keep-work`。

## 已知限制

- 不支持 MDict 3.0 新格式。
- 需要注册码才能打开的词典（`Encrypted="1"`）只能尽力读取，不保证成功。
- `.spx`（Speex）格式的发音，「词典」App 无法播放。
- 依赖复杂 JavaScript 的词典，部分交互可能失效。
- 「词典」App 的弹出式查词（三指轻点）里，点击按钮和播放发音可能不起作用；在「词典」App 窗口里可以正常使用。

## 从源码构建

```bash
git clone https://github.com/Andy7016/DictBridge-for-Mac.git && cd DictBridge-for-Mac
swift build && swift test          # 需要 Xcode 15 或更新版本（Swift 5.9+）
swift run DictBridgeApp            # 直接运行 App
scripts/build-app.sh               # 生成 dist/DictBridge.app、.zip 和 .dmg
```

| 目录 | 内容 |
|---|---|
| `Sources/MDictKit` | 纯 Swift 编写的 MDict 读取器：索引、zlib/LZO、RIPEMD-128 解密、多种编码 |
| `Sources/DictBridgeCore` | 转换流程：HTML→XHTML、链接与资源处理、CSS 适配、调用苹果编译工具、词典库管理 |
| `Sources/DictBridgeApp` | SwiftUI 界面 |
| `Sources/dictbridge` | 命令行工具 |
| `scripts/make_fixtures.py` | 生成测试用的小型合成词典（不包含任何第三方词典内容） |

欢迎提交 Issue 和 PR，尤其欢迎反馈某部词典转换后显示不正常的问题。反馈时请附上词典名称、出问题的词条截图，以及 App 里的日志，但请不要上传词典文件本身。

## 版权说明

DictBridge 只是格式转换工具，不包含、也不分发任何词典内容。请只转换你有权使用的词典文件，转换结果仅供个人使用。

---

## English

macOS's Dictionary app is great: fast, and a three-finger tap (or ⌃⌘D) looks up any word anywhere. But it only reads Apple's `.dictionary` bundles. DictBridge converts MDict dictionaries (`.mdx` + `.mdd` + `.css`) into that format and installs them into `~/Library/Dictionaries`. Its window also lists your installed dictionaries so you can remove them again.

**Features**
- Drop an `.mdx` file in. Companion `.mdd` files (including `name.1.mdd`, `name.2.mdd`…), `.css` and `.js` files in the same folder come along automatically.
- Keeps styles, pictures, audio pronunciations, cross-references and redirect entries (inflections such as *went → go*).
- Handles Dictionary.app quirks: lost spaces, clickable expanders, playable audio. See [docs/how-it-works.md](docs/how-it-works.md).
- Supports MDict 1.2/2.0; UTF-8, UTF-16, GBK and Big5 encodings; zlib and LZO compression; encrypted key index (`Encrypted="2"`).
- Includes a `dictbridge` command-line tool.

**Install.** Download the `.dmg` from [Releases](../../releases). The app is not notarized yet, so on first launch go to System Settings → Privacy & Security → *Open Anyway*, or run `xattr -dr com.apple.quarantine /Applications/DictBridge.app`.

The first conversion asks to download Apple's Dictionary Development Kit (about 1.5 MB). Apple's licence does not allow bundling it, so it is fetched from a [public mirror](https://github.com/nanoskript/dictionary-development-kit) and checked against SHA-256 hashes pinned in the source. You can point DictBridge at your own copy from *Additional Tools for Xcode* instead.

Requires macOS 13 or later, on Apple silicon or Intel.

**Build.** Run `swift build && swift test`, then `scripts/build-app.sh` to produce `dist/DictBridge.app`.

**Copyright.** DictBridge ships no dictionary content. Only convert dictionaries you have the right to use.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
