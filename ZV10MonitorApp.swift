import SwiftUI

@main
struct ZV10MonitorApp: App {
    @StateObject private var vm = MonitorViewModel()

    var body: some Scene {
        WindowGroup("ZV-E10 Monitor") {
            DashboardView(vm: vm)
        }
        .windowResizability(.contentMinSize)
        .commands { EffectsCommands(vm: vm) }
    }
}
