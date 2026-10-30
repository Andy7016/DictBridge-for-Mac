# 更新日志 / Changelog

这里记录 DictBridge for Mac 每个版本的主要变化。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [0.4.0] - 2026-10-30

### 新增

- 支持 MDict 3.0 格式（[#1](https://github.com/Andy7016/DictBridge-for-Mac/issues/1)）：UTF-8 文件头、新的分区结构，以及 3.0 的块加密（字节混淆和 Salsa20，密钥由文件头的 UUID 经 xxHash64 得出）。`.mdx` 和 `.mdd` 都支持。

### 修复

- 根目录下有大量音频文件的词典（牛津高阶 9/10、剑桥高阶英英、麦克米伦等）在「苹果工具编译」最后一步失败（`cp: Argument list too long`）。现在由 DictBridge 自己把资源移进词典，不再交给苹果的脚本复制，转换也省掉一次大文件复制。

### 维护

- 新增 CHANGELOG（本文件）和 Issue 模板：转换问题、词典兼容性反馈、功能建议。
- README：更正复制日志的方法，常见问题里补充「转换失败或卡住」的处理办法。
- LICENSE 和 App「关于」里的版权署名改为 Andy7016。
- CI 用到的 GitHub Actions 升级到 Node 24 版本（checkout v7、upload-artifact v7、action-gh-release v3），消除 Node 20 弃用提示。

## [0.3.0] - 2026-10-15

### 改进

- 词典脚本只保存一份，所有词条用 `<script src>` 共用，不再把脚本复制进每个词条。带 jQuery 的大型词典转换后不会因此膨胀到几 GB。`<head>` 里的脚本按原顺序保留。
- 只合并词条实际引用的样式表，外加和词典同名的 `.css`；都没有时才用 `.mdx` 旁边的样式表。避免词典自带的几套备选样式互相覆盖。
- 词典文件夹里的文件优先于 `.mdd` 里的同名文件；词条引用了、但 `.mdd` 里没有的文件（例如 `oalecd8e.ini`）会从文件夹里补上。
- 重按弹出的查询窗口（`html.apple_client-panel`）里，隐藏只能点击的小控件（标签页、菜单按钮、发音图标），让释义排到最前面。
- 「在访达中显示」改用文件夹图标；没有 `.mdd` 时不显示音频选项。
- 新增 `scripts/compat-test.sh`：把一个文件夹里的词典逐个转换（不安装），输出兼容性结果表。

### 修复

- 编译阶段点「取消」时，连苹果编译工具的子进程一起终止，并显示为已取消。
- CI：单元测试失败（或测试代码编译不过）时，构建现在会如实报错，失败信息显示为注释。

## [0.2.0] - 2026-10-15

### 新增

- 带音节点的词头（`ap·ple`、`ap.ple`）可以直接搜 apple 找到，结果列表里也显示成 apple。
- 中文词头支持简繁互查（搜「苹果」也能找到「蘋果」），可在导入时的「高级」里关闭。
- 转换完成后自动在「词典」里启用新词典，并重启「词典」App。
- 重新导入同一部词典时替换旧版本，旧版移到废纸篓。
- 日志里记录每一步的用时。

### 改进

- 自动识别标错编码的词典：文件里标的是 GBK 或 Big5，实际内容却是 UTF-8。
- 中文等非拉丁文字的词典名转成拼音作为文件名（`21世纪…` → `21-shi-ji-…`）。
- 导入资源时跳过 `.DS_Store` 和 `__MACOSX` 文件。

## [0.1.0] - 2026-10-15

第一个版本。

- 纯 Swift 编写的 MDict 读取器：支持 MDict 1.2 / 2.0，UTF-8、UTF-16、GBK、Big5 编码，zlib 和 LZO 压缩，加密索引（`Encrypted="2"`）。
- 把 `.mdx` 拖进窗口即可转换：同一文件夹里的 `.mdd`（包括分卷）、`.css`、`.js` 自动一起导入；保留排版样式、配图、发音、交叉链接和变形词跳转。
- 调用苹果的 Dictionary Development Kit 编译，装进 `~/Library/Dictionaries`。DDK 首次使用时从固定版本的公开镜像下载，并逐个文件校验 SHA-256；也可以选择自己的 DDK 文件夹。
- 针对「词典」App 的适配：修复空格丢失；展开按钮可点击；`sound://` 发音可播放；`entry://` 交叉链接可跳转；CSS 类型选择器转小写以匹配 XHTML。
- 词典管理：列出已安装的词典，删除时移到废纸篓。
- 命令行工具 `dictbridge`（`convert`、`list`、`remove`、`info`、`ddk`）。
- GitHub Actions：编译、单元测试、用真实 DDK 端到端转换测试词典、打包 universal `.app` / `.zip` / `.dmg`；发布 Release 时自动附加安装包，带后缀的标签（如 `v1.0.0-beta.1`）标为预发布。

[未发布]: https://github.com/Andy7016/DictBridge-for-Mac/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Andy7016/DictBridge-for-Mac/releases/tag/v0.4.0
[0.3.0]: https://github.com/Andy7016/DictBridge-for-Mac/releases/tag/v0.3.0
