import AVFoundation
import CoreMedia
import CoreVideo

extension FourCharCode {
    var fourCC: String {
        let b = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                 UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }
}

/// Satu kombinasi resolusi + pixel format + frame rate yang ditawarkan capture card.
struct VideoFormatOption: Identifiable, Hashable {
    let id: String
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let subtype: FourCharCode
    let frameDuration: CMTime

    var fps: Double { 1.0 / frameDuration.seconds }

    /// Format tak terkompresi (YCbCr/BGRA). MJPEG/H.264 dari card = sudah terkompresi.
    var isUncompressed: Bool {
        let set: Set<FourCharCode> = [
            kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
        return set.contains(subtype)
    }

    var label: String {
        "\(width)×\(height) @ \(String(format: "%.2f", fps)) · \(subtype.fourCC)" + (isUncompressed ? "" : " (terkompresi)")
    }

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum CaptureError: LocalizedError {
    case cannotAddInput(String), cannotAddOutput
    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let n): return "Tidak dapat menambahkan input: \(n)"
        case .cannotAddOutput: return "Tidak dapat menambahkan output capture."
        }
    }
}

final class CaptureManager: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    /// SATU antrean serial untuk video + audio + recorder -> urutan sampel deterministik.
    let sampleQueue = DispatchQueue(label: "monitor.samples", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "monitor.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    var onVideo: (@Sendable (CMSampleBuffer) -> Void)?
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onDrop: (@Sendable () -> Void)?

    // MARK: Izin & discovery
    static func requestAccess(_ type: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: type)
    }

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// Prioritas: tak terkompresi > resolusi tertinggi (4K) > fps tertinggi.
    static func formats(for device: AVCaptureDevice) -> [VideoFormatOption] {
        var out: [VideoFormatOption] = []
        for (i, f) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            for (j, r) in f.videoSupportedFrameRateRanges.enumerated() {
                out.append(VideoFormatOption(id: "\(i)-\(j)", format: f, width: Int(d.width), height: Int(d.height),
                                             subtype: sub, frameDuration: r.minFrameDuration))
            }
        }
        return out.sorted { a, b in
            if a.isUncompressed != b.isUncompressed { return a.isUncompressed }
            if a.width != b.width { return a.width > b.width }
            return a.fps > b.fps
        }
    }

    // MARK: Konfigurasi
    func apply(video: AVCaptureDevice, option: VideoFormatOption, audio: AVCaptureDevice?,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            do {
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }

                let vin = try AVCaptureDeviceInput(device: video)
                guard session.canAddInput(vin) else { throw CaptureError.cannotAddInput(video.localizedName) }
                session.addInput(vin)

                try video.lockForConfiguration()
                video.activeFormat = option.format
                video.activeVideoMinFrameDuration = option.frameDuration
                video.activeVideoMaxFrameDuration = option.frameDuration
                video.unlockForConfiguration()

                // Minta format native 4:2:2 tanpa konversi; selain itu (MJPEG/NV12) konversi ke 2vuy.
                let native = CMFormatDescriptionGetMediaSubType(option.format.formatDescription)
                let target: OSType = (native == kCVPixelFormatType_422YpCbCr8 ||
                                      native == kCVPixelFormatType_422YpCbCr8_yuvs)
                    ? native : kCVPixelFormatType_422YpCbCr8
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: target,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = false   // jangan buang frame saat merekam
                videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
                session.addOutput(videoOutput)

                if let audio {
                    let ain = try AVCaptureDeviceInput(device: audio)
                    guard session.canAddInput(ain) else { throw CaptureError.cannotAddInput(audio.localizedName) }
                    session.addInput(ain)
                    audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                    guard session.canAddOutput(audioOutput) else { throw CaptureError.cannotAddOutput }
                    session.addOutput(audioOutput)
                }
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()
                completion(.failure(error)); return
            }
            session.startRunning()
            completion(.success(()))
        }
    }

    func stop() { sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            onVideo?(sampleBuffer)
        } else {
            onAudio?(sampleBuffer)
            if let db = connection.audioChannels.map(\.averagePowerLevel).max() { onAudioLevel?(db) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { onDrop?() }
    }
}
