import Foundation

/// UI strings (Simplified Chinese when the system prefers Chinese, English otherwise).
/// Kept in code so the app needs no resource bundle.
enum L {
    static let zh: Bool = {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return lang.hasPrefix("zh")
    }()

    private static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    static var subtitle: String { t("Put MDict dictionaries into the macOS Dictionary app", "把 MDict 词典装进 Mac 自带的「词典」App") }
    static var addDictionary: String { t("Add Dictionary…", "添加词典…") }
    static var installedHeader: String { t("Installed dictionaries", "已安装的词典") }
    static var dropTitle: String { t("Drop an .mdx file here", "把 .mdx 文件拖到这里") }
    static var dropHint: String {
        t("The .mdd resources and .css style sheets next to it are picked up automatically.",
          "同一文件夹里的 .mdd 资源和 .css 样式会自动一起导入。")
    }
    static var chooseFile: String { t("Choose File…", "选择文件…") }
    static var openDictionaryApp: String { t("Open Dictionary", "打开词典 App") }
    static var showInFinder: String { t("Show in Finder", "在访达中显示") }
    static var remove: String { t("Remove", "删除") }
    static var removeQuestion: String { t("Move this dictionary to the Trash?", "把这个词典移到废纸篓？") }
    static var removeDetail: String {
        t("You can put it back from the Trash. Dictionary will restart if it is open.",
          "之后仍可从废纸篓恢复。如果「词典」App 正在运行，会自动重启它。")
    }
    static var cancel: String { t("Cancel", "取消") }
    static var done: String { t("Done", "完成") }
    static var close: String { t("Close", "关闭") }
    static var otherDictionary: String { t("Not made by DictBridge", "非 DictBridge 生成") }
    static var refresh: String { t("Refresh", "刷新") }
    static var dictionariesFolder: String { t("Dictionaries folder", "词典文件夹") }

    // Import sheet
    static var importTitle: String { t("Add a dictionary", "添加词典") }
    static var nameLabel: String { t("Name in Dictionary", "在「词典」中显示的名称") }
    static var filesLabel: String { t("Files", "文件") }
    static var includeAudio: String { t("Include pronunciation audio", "包含真人发音音频") }
    static var includeAudioHint: String {
        t("Audio is often most of the size. Turn off to save space.", "音频往往占大部分体积，关闭可节省空间。")
    }
    static var advanced: String { t("Advanced", "高级") }
    static var headwordLabel: String { t("Show headword on top", "在词条顶部显示词头") }
    static var headwordAuto: String { t("When missing", "缺少时自动添加") }
    static var headwordAlways: String { t("Always", "总是") }
    static var headwordNever: String { t("Never", "从不") }
    static var convert: String { t("Convert & Install", "转换并安装") }
    static func replaces(_ name: String) -> String {
        t("Replaces the installed “\(name)” (the old version goes to the Trash).",
          "将替换已安装的「\(name)」（旧版本会移到废纸篓）。")
    }
    static var chineseVariants: String {
        t("Also find Chinese headwords in Simplified/Traditional script", "中文词头支持简繁互查（例如搜「苹果」也能找到「蘋果」）")
    }

    // Job
    static func converting(_ name: String) -> String { t("Converting “\(name)”", "正在转换「\(name)」") }
    static func finished(_ name: String) -> String { t("“\(name)” is ready", "「\(name)」已装好") }
    static func failed(_ name: String) -> String { t("Could not convert “\(name)”", "「\(name)」转换失败") }
    static var log: String { t("Log", "日志") }
    static var copyLog: String { t("Copy Log", "复制日志") }
    static func summary(entries: Int, keys: Int, seconds: Double) -> String {
        t("\(entries) entries, \(keys) search keys, \(Int(seconds)) s",
          "\(entries) 个词条，\(keys) 个检索词，用时 \(Int(seconds)) 秒")
    }
    static var enableHint: String {
        t("DictBridge enables new dictionaries in Dictionary automatically. If you do not see it, open Dictionary → Settings and tick it.",
          "DictBridge 会自动在「词典」里启用新词典；如果没看到，请到「词典」→「设置」里勾选它。")
    }
    static func stage(_ s: String) -> String {
        switch s {
        case "indexing": return t("Reading index", "读取索引")
        case "resources": return t("Extracting resources", "导出资源")
        case "converting": return t("Converting entries", "转换词条")
        case "compiling": return t("Building with Apple's tool", "苹果工具编译")
        case "installing": return t("Installing", "安装")
        default: return t("Finished", "完成")
        }
    }

    // DDK
    static var ddkTitle: String { t("One-time setup", "首次使用需要一次性设置") }
    static var ddkBody: String {
        t("Building a dictionary needs Apple's Dictionary Development Kit. Apple does not allow it to be bundled with DictBridge, so it is downloaded once (about 1.5 MB) from a public mirror and every file is checked against a fixed SHA-256 fingerprint.",
          "生成词典需要用到苹果的 Dictionary Development Kit（词典开发工具）。苹果不允许把它打包进 DictBridge，因此需要从公开镜像下载一次（约 1.5 MB），每个文件都会用固定的 SHA-256 指纹校验。")
    }
    static var ddkDownload: String { t("Download and Verify", "下载并校验") }
    static var ddkChoose: String { t("Use My Own Copy…", "使用我已有的版本…") }
    static var ddkChooseHint: String {
        t("If you installed “Additional Tools for Xcode”, choose its “Dictionary Development Kit” folder.",
          "如果你装过「Additional Tools for Xcode」，可以选择其中的 Dictionary Development Kit 文件夹。")
    }
    static var ddkReady: String { t("Dictionary Development Kit is ready.", "词典开发工具已就绪。") }
    static var applePage: String { t("Apple's download page", "苹果官方下载页") }

    static var errorTitle: String { t("Something went wrong", "出错了") }
    static var notMDX: String { t("Please choose an .mdx file (or a folder containing one).", "请选择 .mdx 文件（或包含它的文件夹）。") }
    static var busy: String { t("Please wait for the current conversion to finish.", "请等当前的转换完成。") }
}
