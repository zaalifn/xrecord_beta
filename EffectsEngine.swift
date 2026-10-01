import Foundation
import Metal
import CoreMedia
import CoreVideo

enum SampleBufferFactory {
    /// Membungkus pixel buffer menjadi CMSampleBuffer dengan timing (PTS/durasi) dari sampel asli.
    static func make(from pb: CVPixelBuffer, timingFrom sb: CMSampleBuffer) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb,
                                                           formatDescriptionOut: &fd) == noErr, let fd else { return nil }
        var timing = CMSampleTimingInfo()
        _ = CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}

/// Penghubung: efek VHS (GPU) + OSD. Dipanggil dari callback AVCaptureVideoDataOutput (sampleQueue).
final class EffectsEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var settings = EffectsSettings()
    private var fullRange = false
    private var matrix: UInt32 = 0
    private var fps = 30.0
    private var recordingStart: Date?
    private var recordingBurnIn = false          // dikunci saat REC dimulai (format file tak boleh berubah di tengah)

    private let device: MTLDevice
    private let vhs: VHSFilter?
    private let osd = OSDRenderer()
    private var osdTexture: MTLTexture?
    /// true = OSD digambar CPU lewat drawOSD(on:) setelah efek; false (default) = komposit di GPU.
    var useCPUOSD = false

    init(device: MTLDevice) {
        self.device = device
        vhs = VHSFilter(device: device)
    }

    // MARK: Dipanggil dari main thread
    func update(_ s: EffectsSettings) { lock.lock(); settings = s; lock.unlock() }
    func updateDecode(fullRange: Bool, matrix: UInt32) { lock.lock(); self.fullRange = fullRange; self.matrix = matrix; lock.unlock() }
    func setFPS(_ f: Double) { lock.lock(); fps = f; lock.unlock() }
    func setRecording(start: Date?) {
        lock.lock()
        recordingStart = start
        if start != nil { recordingBurnIn = settings.burnIntoRecording }
        lock.unlock()
    }

    /// Frame yang harus masuk recorder: hasil efek bila burn-in aktif, selain itu frame asli (bersih).
    func recordingFrame(original: CMSampleBuffer, processed: CMSampleBuffer?) -> CMSampleBuffer {
        lock.lock(); let burn = recordingStart != nil && recordingBurnIn; lock.unlock()
        return (burn ? processed : nil) ?? original
    }

    // MARK: Dipanggil dari sampleQueue
    /// nil = tidak ada pemrosesan (efek mati) -> pakai frame asli.
    func process(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        lock.lock()
        let s = settings, start = recordingStart, burn = recordingBurnIn
        let fr = fullRange, mx = matrix, fps = self.fps
        lock.unlock()

        let recording = start != nil
        // Bila REC memakai burn-in, semua frame harus lewat jalur BGRA walau efek dimatikan di tengah rekaman.
        guard s.vhsEnabled || s.osdEnabled || (recording && burn),
              let vhs, let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }

        var osdTex: MTLTexture?
        var state: OSDState?
        if s.osdEnabled {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            osd.setFontIfNeeded(s.osdFontName)
            osd.configure(aspect: Double(w) / Double(h))
            let now = Date()
            let st = OSDState(isRecording: recording, recordingElapsed: start.map { now.timeIntervalSince($0) } ?? 0,
                              fps: fps, now: now, year: s.osdYear, batteryBars: s.osdBatteryBars,
                              tapeStartSeconds: s.osdTapeStartSeconds)
            state = st
            if !useCPUOSD { osdTex = textureForOSD(st) }
        }

        guard let out = vhs.process(pb, settings: s, effectsOn: s.vhsEnabled, fullRange: fr, matrix: mx, osd: osdTex) else { return nil }
        if useCPUOSD, let state { osd.drawOSD(on: out, state: state) }
        return SampleBufferFactory.make(from: out, timingFrom: sb)
    }

    private func textureForOSD(_ st: OSDState) -> MTLTexture? {
        var needsUpload = osd.update(st)
        let gw = osd.gridWidth, gh = osd.gridHeight
        if osdTexture == nil || osdTexture!.width != gw || osdTexture!.height != gh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: gw, height: gh, mipmapped: false)
            d.usage = .shaderRead
            osdTexture = device.makeTexture(descriptor: d)
            needsUpload = true
        }
        if needsUpload, let tex = osdTexture, let bytes = osd.pixelData {
            tex.replace(region: MTLRegionMake2D(0, 0, gw, gh), mipmapLevel: 0, withBytes: bytes, bytesPerRow: gw * 4)
        }
        return osdTexture
    }
}
