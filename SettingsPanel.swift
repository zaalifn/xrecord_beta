import SwiftUI
import AVFoundation

struct SettingsPanel: View {
    @ObservedObject var vm: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Input") {
                    Picker("Video", selection: $vm.selectedVideoID) {
                        ForEach(vm.videoDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    Picker("Format", selection: $vm.selectedFormatID) {
                        ForEach(vm.formats) { Text($0.label).tag($0.id) }
                    }
                    Picker("Audio", selection: $vm.selectedAudioID) {
                        Text("Tanpa audio").tag("")
                        ForEach(vm.audioDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
                .disabled(vm.isRecording)

                Section("Rekaman") {
                    Picker("Codec", selection: $vm.codec) {
                        ForEach(RecordingCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Tag warna", selection: $vm.colorTag) {
                        ForEach(ColorTag.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Rasio aspek", selection: $vm.overlay.aspect) {
                        ForEach(AspectPreset.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Offset audio: \(Int(vm.audioOffsetMS)) ms",
                            value: $vm.audioOffsetMS, in: -300...300, step: 10)
                }
                .disabled(vm.isRecording)

                Section("Monitoring") {
                    Toggle("Full range (0–255)", isOn: $vm.settings.fullRange)
                    Picker("Matriks warna", selection: $vm.settings.matrix) {
                        ForEach(ColorMatrix.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Zebra clipping: \(Int(vm.settings.zebraHigh * 100))%") {
                        Slider(value: $vm.settings.zebraHigh, in: 0.5...1.0)
                    }
                    LabeledContent("Zebra band kulit: \(Int(vm.settings.zebraLow * 100))%") {
                        Slider(value: $vm.settings.zebraLow, in: 0.3...0.9)
                    }
                    LabeledContent("Sensitivitas peaking") {
                        Slider(value: $vm.settings.peakingThreshold, in: 0.02...0.3)
                    }
                    LabeledContent("3D LUT: \(vm.lutName)") {
                        Button("Muat .cube…") { vm.chooseLUT() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Selesai") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 540, height: 640)
    }
}
