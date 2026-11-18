import AppKit
import Combine
import Sparkle

/// In-app updates through Sparkle.
///
/// The feed (`SUFeedURL` in Info.plist) is `appcast.xml` attached to the latest GitHub release;
/// CI writes it and signs the `.zip` with the project's EdDSA key, and Sparkle only installs an
/// update whose signature matches `SUPublicEDKey`. Sparkle's own windows show the release notes
/// and the download and install progress.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// Defaults key that points the updater at another feed, for testing a pre-release:
    /// `defaults write org.dictbridge.DictBridge UpdateFeedURL https://…/appcast.xml`
    nonisolated static let feedOverrideKey = "UpdateFeedURL"

    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!
    private var observation: NSKeyValueObservation?
    /// Relaunch into an update that is waiting for the running conversion to end.
    private var postponedInstall: (() -> Void)?

    /// False when running outside a packaged app (`swift run`), which has no feed or key.
    let isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        guard isAvailable else { return }
        migrateOldSetting()
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Daily background check (Sparkle's `SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool {
        get { isAvailable && controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Called when a conversion ends: installs an update that was waiting for it.
    func conversionDidEnd() {
        guard let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }

    /// Up to 0.5 the app checked GitHub itself; keep a user's choice to turn checks off.
    private func migrateOldSetting() {
        let defaults = UserDefaults.standard
        if let old = defaults.object(forKey: "autoCheckUpdates") as? Bool {
            if !old { controller.updater.automaticallyChecksForUpdates = false }
            defaults.removeObject(forKey: "autoCheckUpdates")
            defaults.removeObject(forKey: "lastUpdateCheck")
        }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // Sparkle loads feeds over http(s) only; plain http just for a server on this Mac.
        guard let text = UserDefaults.standard.string(forKey: AppUpdater.feedOverrideKey),
              let url = URL(string: text) else { return nil }
        let local = url.host == "127.0.0.1" || url.host == "localhost"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return url.absoluteString
    }

    /// Installing relaunches the app, which would cancel a running conversion: wait for it.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard AppModel.shared?.job?.isRunning == true else { return false }
            postponedInstall = installHandler
            return true
        }
    }
}
