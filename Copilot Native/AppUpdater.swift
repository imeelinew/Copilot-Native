import Combine
import Observation
import Sparkle
import SwiftUI

@MainActor
@Observable
final class AppUpdater {
    let controller: SPUStandardUpdaterController

    private(set) var canCheckForUpdates = false

    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = canCheckForUpdates
                }
            }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

struct CheckForUpdatesView: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Button("检查更新…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
