import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EffectsPanel: View {
    @ObservedObject var vm: MonitorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Aktifkan") {
                    Toggle("Y2K / VHS Camcorder", isOn: $vm.effects.vhsEnabled)
                    Toggle("OSD Camcorder (REC, baterai, counter, tanggal)", isOn: $vm.effects.osdEnabled)
                    Toggle("Burn ke rekaman", isOn: $vm.effects.burnIntoRecording).disabled(vm.isRecording)
                    Text("Mati: efek hanya di monitor, file ProRes tetap bersih. Nyala: frame direkam sebagai BGRA → ProRes; pilihan dikunci selama merekam. Scope/zebra membaca gambar yang sudah berefek.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Preset") {
                    HStack {
                        ForEach(EffectsPreset.allCases) { p in
                            Button(p.rawValue) { vm.effects.apply(p) }
                        }
                    }
                }

                Section("VHS") {
                    slider("Blur chroma", $vm.effects.chromaBlur, 0...4)
                    slider("Chroma tertunda", $vm.effects.chromaDelay, 0...4)
                    slider("Aberrasi R/B", $vm.effects.aberration, 0...4)
                    slider("Resolusi rendah", $vm.effects.lowRes, 0...1)
                    slider("Scanline", $vm.effects.scanlines, 0...0.5)
                    slider("Grain", $vm.effects.grain, 0...1.5)
                    slider("Jello", $vm.effects.jello, 0...2)
                    slider("Tracking glitch", $vm.effects.glitch, 0...1)
                    slider("Saturasi", $vm.effects.saturation, 0.4...1.2)
                }

                Section("OSD") {
                    Stepper("Tahun: \(vm.effects.osdYear)", value: $vm.effects.osdYear, in: 1990...2009)
                    Stepper("Baterai: \(vm.effects.osdBatteryBars) batang", value: $vm.effects.osdBatteryBars, in: 0...3)
                    Stepper("Counter kaset awal: \(tape(vm.effects.osdTapeStartSeconds))",
                            value: $vm.effects.osdTapeStartSeconds, in: 0...7199, step: 30)
                    HStack {
                        TextField("Nama font", text: $vm.effects.osdFontName)
                        Button("Muat font…") { loadFont() }
                    }
                    Text("Font tidak ditemukan → otomatis Menlo Bold / Courier Bold.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack { Spacer(); Button("Selesai") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }
        .frame(width: 580, height: 700)
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        LabeledContent("\(title): \(String(format: "%.2f", value.wrappedValue))") {
            Slider(value: value, in: range)
        }
    }

    private func tape(_ s: Int) -> String { String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }

    private func loadFont() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.font]
        p.message = "Pilih file font (.ttf / .otf), mis. VCR OSD Mono"
        guard p.runModal() == .OK, let url = p.url else { return }
        if let name = OSDRenderer.registerFont(at: url) { vm.effects.osdFontName = name }
        else { vm.errorMessage = "Font gagal dimuat." }
    }
}
