import SwiftUI
import AVFoundation

struct DashboardView: View {
    @ObservedObject var vm: MonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(vm: vm)
            ToolBar(vm: vm)
            monitorArea
            BottomBar(vm: vm)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 680)
        .task { await vm.bootstrap() }
        .sheet(isPresented: $vm.showSettings) { SettingsPanel(vm: vm) }
        .sheet(isPresented: $vm.showEffects) { EffectsPanel(vm: vm) }
        .alert("Terjadi masalah", isPresented: Binding(get: { vm.errorMessage != nil },
                                                       set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vm.errorMessage ?? "") }
    }

    private var monitorArea: some View {
        ZStack {
            Color.black
            MetalTextureView(pipeline: vm.pipeline, target: .monitor, fps: 60)
                .aspectRatio(vm.signalAspect, contentMode: .fit)
                .overlay { FrameOverlay(overlay: vm.overlay) }
                .overlay { if vm.isRecording { Rectangle().stroke(Color.red.opacity(0.9), lineWidth: 2) } }
                .overlay(alignment: .bottomTrailing) { scopeStack.padding(10) }
        }
    }

    private var scopeStack: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if vm.overlay.showWaveform {
                ScopeCell(title: "WAVEFORM") {
                    ZStack {
                        MetalTextureView(pipeline: vm.pipeline, target: .scope(.waveform))
                        WaveformGraticule()
                    }.frame(width: 250, height: 110)
                }
            }
            if vm.overlay.showHistogram {
                ScopeCell(title: "HISTOGRAM") {
                    ZStack {
                        MetalTextureView(pipeline: vm.pipeline, target: .scope(.histogram))
                        HistogramGraticule()
                    }.frame(width: 250, height: 70)
                }
            }
            if vm.overlay.showVectorscope {
                ScopeCell(title: "VECTORSCOPE") {
                    ZStack {
                        MetalTextureView(pipeline: vm.pipeline, target: .scope(.vectorscope))
                        VectorscopeGraticule()
                    }.frame(width: 150, height: 150)
                }
            }
        }
        .padding(vm.overlay.anyScope ? 8 : 0)
        .background(.black.opacity(vm.overlay.anyScope ? 0.55 : 0))
        .cornerRadius(6)
    }
}

// MARK: - Bar atas: status (FPS / TC / RES ...)
struct StatusBar: View {
    @ObservedObject var vm: MonitorViewModel

    var body: some View {
        HStack(spacing: 30) {
            HUDField(label: "FPS", value: String(format: "%.3f", vm.signalFPS))
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                HUDField(label: "TC", value: timecode(ctx.date),
                         valueColor: vm.isRecording ? .red : .white)
            }
            HUDField(label: "RES", value: vm.signalResolution)
            HUDField(label: "FMT", value: vm.signalFormat)
            HUDField(label: "ASPECT", value: vm.overlay.aspect.label,
                     valueColor: vm.overlay.aspect == .source ? .white : hudAmber)
            Spacer()
            if vm.captureDrops > 0 { HUDField(label: "DROP", value: "\(vm.captureDrops)", valueColor: .orange) }
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color.black)
    }

    private func timecode(_ now: Date) -> String {
        guard vm.isRecording, let start = vm.recStartDate else { return "00:00:00:00" }
        let s = max(0, now.timeIntervalSince(start))
        let fps = max(1, Int(vm.signalFPS.rounded()))
        let total = Int(s)
        let ff = min(fps - 1, Int((s - Double(total)) * Double(fps)))
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60, ff)
    }
}

// MARK: - Toolbar atas: Grid, Zebra, Peaking, LUT, Scopes, Aspek, Pengaturan
struct ToolBar: View {
    @ObservedObject var vm: MonitorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(GridKind.allCases) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { vm.overlay.grids.contains(kind) },
                        set: { on in
                            if on { vm.overlay.grids.insert(kind) } else { vm.overlay.grids.remove(kind) }
                        }))
                }
                Divider()
                Button("Matikan semua grid") { vm.overlay.grids.removeAll() }
            } label: {
                ToolLabel(icon: "grid", title: "GRID", on: !vm.overlay.grids.isEmpty)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Button { vm.settings.zebraEnabled.toggle() } label: {
                ToolLabel(icon: "circle.lefthalf.striped.horizontal", title: "ZEBRA", on: vm.settings.zebraEnabled)
            }.buttonStyle(.plain)

            Button { vm.settings.peakingEnabled.toggle() } label: {
                ToolLabel(icon: "scope", title: "PEAKING", on: vm.settings.peakingEnabled)
            }.buttonStyle(.plain)

            Button { vm.settings.lutEnabled.toggle() } label: {
                ToolLabel(icon: "camera.filters", title: "LUT", on: vm.settings.lutEnabled)
            }.buttonStyle(.plain)

            Menu {
                Toggle("Waveform", isOn: $vm.overlay.showWaveform)
                Toggle("Histogram", isOn: $vm.overlay.showHistogram)
                Toggle("Vectorscope", isOn: $vm.overlay.showVectorscope)
            } label: {
                ToolLabel(icon: "waveform", title: "SCOPES", on: vm.overlay.anyScope)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Menu {
                Picker("Aspek rekaman", selection: $vm.overlay.aspect) {
                    ForEach(AspectPreset.allCases) { Text($0.label).tag($0) }
                }
                .disabled(vm.isRecording)
                Toggle("Tampilkan masker di monitor", isOn: $vm.overlay.showMask)
            } label: {
                ToolLabel(icon: "aspectratio", title: "ASPECT", on: vm.overlay.aspect != .source)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Menu {
                Toggle("Y2K / VHS Camcorder", isOn: $vm.effects.vhsEnabled)
                Toggle("OSD Camcorder", isOn: $vm.effects.osdEnabled)
                Toggle("Burn ke rekaman", isOn: $vm.effects.burnIntoRecording).disabled(vm.isRecording)
                Divider()
                Button("Pengaturan Effects…") { vm.showEffects = true }
            } label: {
                ToolLabel(icon: "sparkles", title: "EFFECTS", on: vm.effects.vhsEnabled || vm.effects.osdEnabled)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Spacer()

            Button { vm.showSettings = true } label: {
                ToolLabel(icon: "gearshape", title: "SETUP", on: false)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(white: 0.06))
    }
}

// MARK: - Bar bawah: LUT / REC / MON / audio + tombol rekam
struct BottomBar: View {
    @ObservedObject var vm: MonitorViewModel

    var body: some View {
        HStack(spacing: 28) {
            HUDField(label: "LUT", value: vm.settings.lutEnabled ? vm.lutName : "OFF",
                     valueColor: vm.settings.lutEnabled ? hudAmber : .white)
            HUDField(label: "REC", value: "\(vm.codec.rawValue) · \(vm.overlay.aspect.label)")
            HUDField(label: "MON", value: "\(vm.settings.matrix.label) · \(vm.settings.fullRange ? "FULL" : "LEGAL")")
            audioMeter
            Spacer()
            if vm.isRecording {
                HUDField(label: "SIZE", value: ByteCountFormatter.string(fromByteCount: vm.recBytes, countStyle: .file))
                if vm.recStats.dropped > 0 {
                    HUDField(label: "DROP", value: "\(vm.recStats.dropped)", valueColor: .orange)
                }
            } else if vm.lastSavedURL != nil {
                Button("Tampilkan di Finder") { vm.revealLastFile() }.buttonStyle(.link)
            }
            recButton
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.black)
    }

    private var audioMeter: some View {
        let v = CGFloat(max(0, min(1, (vm.audioLevelDB + 60) / 60)))
        return HStack(spacing: 6) {
            Text("AUD").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 140 * v)
            }.frame(width: 140, height: 6)
        }
    }

    private var recButton: some View {
        Button { vm.toggleRecording() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 38, height: 38)
                if vm.isRecording {
                    RoundedRectangle(cornerRadius: 3).fill(.red).frame(width: 16, height: 16)
                } else {
                    Circle().fill(.red).frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!vm.isRunning)
        .opacity(vm.isRunning ? 1 : 0.4)
    }
}
