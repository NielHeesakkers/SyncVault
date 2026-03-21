import Foundation
import Sparkle

class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater {
        updaterController.updater
    }

    init() {
        // Set the appcast feed URL before the updater starts so Sparkle can read it.
        UserDefaults.standard.register(defaults: [
            "SUFeedURL": "https://raw.githubusercontent.com/NielHeesakkers/SyncVault/main/docs/appcast.xml"
        ])

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
