import Combine
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class MonitorViewModel: ObservableObject {
    let pipeline: MetalPipeline
    let engine: EffectsEngine
    private let capture = CaptureManager()
    private let recorder = ProResRecorder()
    private var reconfigTask: Task<Void, Never>?
    private var currentURL: URL?

    // Perangkat & format
    @Published var videoDevices: [AVCaptureDevice] = []
    @Published var audioDevices: [AVCaptureDevice] = []
    @Published var formats: [VideoFormatOption] = []
    @Published var selectedVideoID = "" { didSet { if oldValue != selectedVideoID { videoDeviceChanged() } } }
    @Published var selectedFormatID = "" { didSet { if oldValue != selectedFormatID { scheduleReconfigure() } } }
    @Published var selectedAudioID = "" { didSet { if oldValue != selectedAudioID { scheduleReconfigure() } } }

    // Perekaman
    @Published var codec: RecordingCodec = .proRes422HQ
    @Published var colorTag: ColorTag = .rec709
    @Published var audioOffsetMS: Double = 0
    @Published var isRecording = false
    @Published var recStats = ProResRecorder.Stats()
    @Published var recBytes: Int64 = 0
    @Published var lastSavedURL: URL?

    // Monitor
    @Published var settings = MonitorSettings() { didSet { pipeline.update(settings); engine.updateDecode(fullRange: settings.fullRange, matrix: settings.matrix.rawValue) } }
    @Published var overlay = OverlaySettings() {
        didSet { if overlay.anyScope != settings.scopesEnabled { settings.scopesEnabled = overlay.anyScope } }
    }
    @Published var signalFPS: Double = 30
    @Published var signalResolution = "—"
    @Published var signalFormat = "—"
    @Published var recStartDate: Date?
    @Published var showSettings = false
    @Published var effects = EffectsSettings() { didSet { engine.update(effects) } }
    @Published var showEffects = false
    @Published var lutName = "Tanpa LUT"
    @Published var isRunning = false
    @Published var signalInfo = "Tidak ada sinyal"
    @Published var signalAspect: CGFloat = 16.0 / 9.0
    @Published var audioLevelDB: Float = -80
    @Published var captureDrops = 0
    @Published var errorMessage: String?

    init() {
        do { let p = try MetalPipeline(); pipeline = p; engine = EffectsEngine(device: p.device) } catch { fatalError("Metal gagal: \(error.localizedDescription)") }
        let pipeline = self.pipeline, recorder = self.recorder, engine = self.engine

        // Callback berjalan di sampleQueue (bukan main thread).
        capture.onVideo = { [pipeline, recorder, engine] sb in
            let fx = engine.process(sb)                       // nil = efek mati -> frame asli
            if let pb = CMSampleBufferGetImageBuffer(fx ?? sb) { pipeline.submit(pb) }
            recorder.appendVideo(engine.recordingFrame(original: sb, processed: fx))
        }
        capture.onAudio = { [recorder] sb in recorder.appendAudio(sb) }
        capture.onAudioLevel = { [weak self] db in Task { @MainActor in self?.audioLevelDB = db } }
        capture.onDrop = { [weak self] in Task { @MainActor in self?.captureDrops += 1 } }
        recorder.onStats = { [weak self] s in Task { @MainActor in self?.handleStats(s) } }
        recorder.onError = { [weak self, engine] m in
            engine.setRecording(start: nil)
            Task { @MainActor in self?.isRecording = false; self?.errorMessage = m }
        }
    }

    // MARK: Startup
    func bootstrap() async {
        guard await CaptureManager.requestAccess(.video) else {
            errorMessage = "Izin kamera ditolak. Aktifkan di System Settings › Privacy & Security › Camera."
            return
        }
        _ = await CaptureManager.requestAccess(.audio)
        refreshDevices()
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) { self?.refreshDevices() }
            }
        }
    }

    func refreshDevices() {
        videoDevices = CaptureManager.videoDevices()
        audioDevices = CaptureManager.audioDevices()
        if !videoDevices.contains(where: { $0.uniqueID == selectedVideoID }) {
            let pick = videoDevices.first { $0.deviceType == .external } ?? videoDevices.first
            selectedVideoID = pick?.uniqueID ?? ""
        }
    }

    private func videoDeviceChanged() {
        guard let dev = videoDevices.first(where: { $0.uniqueID == selectedVideoID }) else { formats = []; return }
        formats = CaptureManager.formats(for: dev)
        selectedFormatID = formats.first?.id ?? ""
        // Audio: cari perangkat audio dengan nama mirip capture card, jika tidak ada pakai mic default.
        let name = dev.localizedName
        if let m = audioDevices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.localizedName)
        }) { selectedAudioID = m.uniqueID }
        else if selectedAudioID.isEmpty { selectedAudioID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? "" }
    }

    private func scheduleReconfigure() {
        reconfigTask?.cancel()
        reconfigTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))      // debounce perubahan beruntun
            guard !Task.isCancelled else { return }
            self?.applyConfiguration()
        }
    }

    private func applyConfiguration() {
        guard !isRecording,
              let v = videoDevices.first(where: { $0.uniqueID == selectedVideoID }),
              let opt = formats.first(where: { $0.id == selectedFormatID }) else { return }
        let a = audioDevices.first { $0.uniqueID == selectedAudioID }
        capture.apply(video: v, option: opt, audio: a) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.isRunning = true
                    self.signalInfo = opt.label
                    self.signalAspect = CGFloat(opt.width) / CGFloat(opt.height)
                    self.signalFPS = opt.fps
                    self.engine.setFPS(opt.fps)
                    self.signalResolution = "\(opt.width)×\(opt.height)"
                    self.signalFormat = opt.subtype.fourCC.uppercased()
                case .failure(let e):
                    self.isRunning = false
                    self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    // MARK: Perekaman
    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        guard isRunning else { errorMessage = "Tidak ada sinyal video."; return }
        do {
            let movies = try FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let dir = movies.appendingPathComponent("ZV-E10 Monitor", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
            let url = dir.appendingPathComponent("ZV-E10_\(f.string(from: Date())).mov")

            let cfg = ProResRecorder.Config(
                url: url, codec: codec, colorTag: colorTag,
                recordAudio: !selectedAudioID.isEmpty,
                audioOffset: CMTime(seconds: audioOffsetMS / 1000, preferredTimescale: 48000),
                cropAspect: overlay.aspect.ratio)
            currentURL = url; recStats = .init(); recBytes = 0; lastSavedURL = nil
            let recorder = self.recorder
            capture.sampleQueue.async { recorder.arm(cfg) }
            isRecording = true
            let started = Date()
            recStartDate = started
            engine.setRecording(start: started)
        } catch { errorMessage = error.localizedDescription }
    }

    private func stopRecording() {
        isRecording = false
        let recorder = self.recorder
        let engine = self.engine
        capture.sampleQueue.async {
            defer { engine.setRecording(start: nil) }   // setelah recorder berhenti -> tak ada format campur
            recorder.stop { url, err in
                Task { @MainActor [weak self] in
                    if let url { self?.lastSavedURL = url }
                    if let err { self?.errorMessage = err.localizedDescription }
                }
            }
        }
    }

    private func handleStats(_ s: ProResRecorder.Stats) {
        recStats = s
        if let u = currentURL,
           let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber {
            recBytes = n.int64Value
        }
    }

    // MARK: LUT
    func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Pilih 3D LUT (.cube), mis. S-Log2 → Rec.709 atau HLG → Rec.709"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pipeline = self.pipeline
        Task.detached { [weak self] in
            do {
                let lut = try LUTLoader.parseCube(try String(contentsOf: url, encoding: .utf8))
                pipeline.setLUT(lut)
                await MainActor.run {
                    self?.lutName = url.deletingPathExtension().lastPathComponent
                    self?.settings.lutEnabled = true
                }
            } catch {
                await MainActor.run { self?.errorMessage = "LUT gagal dimuat: \(error.localizedDescription)" }
            }
        }
    }

    func revealLastFile() {
        if let u = lastSavedURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}
