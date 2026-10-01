import SwiftUI

/// Menu "Effects" di menu bar macOS (berdampingan dengan File, Edit, View ...).
struct EffectsCommands: Commands {
    @ObservedObject var vm: MonitorViewModel

    var body: some Commands {
        CommandMenu("Effects") {
            Toggle("Y2K / VHS Camcorder", isOn: $vm.effects.vhsEnabled)
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("OSD Camcorder", isOn: $vm.effects.osdEnabled)
                .keyboardShortcut("2", modifiers: [.command, .option])
            Toggle("Burn ke rekaman", isOn: $vm.effects.burnIntoRecording)
                .disabled(vm.isRecording)
            Divider()
            Menu("Preset") {
                ForEach(EffectsPreset.allCases) { p in
                    Button(p.rawValue) { vm.effects.apply(p) }
                }
            }
            Divider()
            Button("Pengaturan Effects…") { vm.showEffects = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
