import AVFoundation
import CoreMedia


enum RecordingCodec: String, CaseIterable, Identifiable {
    case proRes422HQ = "ProRes 422 HQ"
    case proRes4444  = "ProRes 4444"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .proRes422HQ ? .proRes422HQ : .proRes4444 }
}

enum ColorTag: String, CaseIterable, Identifiable {
    case rec709 = "Rec.709", hlg2020 = "HLG / Rec.2020", untagged = "Tanpa tag"
    var id: String { rawValue }
    var properties: [String: String]? {
        switch self {
        case .rec709:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .hlg2020:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .untagged: return nil
        }
    }
}

enum RecorderError: LocalizedError {
    case noFormat, cannotAdd, start(String)
    var errorDescription: String? {
        switch self {
        case .noFormat: return "Format video tidak ditemukan pada sampel pertama."
        case .cannotAdd: return "AVAssetWriter menolak input."
        case .start(let m): return "Gagal memulai penulisan: \(m)"
        }
    }
}

/// TIDAK thread-safe: semua pemanggilan harus dari `CaptureManager.sampleQueue`.
final class ProResRecorder: @unchecked Sendable {
    enum State { case idle, armed, recording }
    struct Config {
        var url: URL
        var codec: RecordingCodec
        var colorTag: ColorTag
        var recordAudio: Bool
        var audioOffset: CMTime      // positif = tunda audio (kompensasi latensi capture card)
        var cropAspect: Double? = nil   // lebar/tinggi; nil = frame penuh
    }
    struct Stats { var frames = 0; var dropped = 0; var seconds = 0.0 }

    var onStats: (@Sendable (Stats) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private(set) var state: State = .idle
    private var cfg: Config?
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?
    private var aIn: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var start: CMTime = .invalid
    private var stats = Stats()
    private var waitedFrames = 0
    private var cropper: FrameCropper?

    // MARK: Kontrol
    func arm(_ config: Config) {
        cfg = config; state = .armed; audioFormat = nil; stats = Stats(); waitedFrames = 0; cropper = nil
    }

    func stop(completion: @escaping @Sendable (URL?, Error?) -> Void) {
        guard state != .idle, let w = writer else { state = .idle; completion(nil, nil); return }
        state = .idle
        guard w.status == .writing else { completion(nil, w.error); return }
        vIn?.markAsFinished(); aIn?.markAsFinished()
        w.finishWriting { completion(w.status == .completed ? w.outputURL : nil, w.error) }
        writer = nil; vIn = nil; aIn = nil
    }

    // MARK: Sampel
    func appendVideo(_ input: CMSampleBuffer) {
        switch state {
        case .idle: return
        case .armed:
            guard let c = cfg else { return }
            var withAudio = c.recordAudio
            if withAudio && audioFormat == nil {          // tunggu sampel audio pertama (butuh format)
                waitedFrames += 1
                if waitedFrames < 90 { return }
                withAudio = false
                onError?("Audio tidak terdeteksi — merekam video saja.")
            }
            guard let sb = cropIfNeeded(input, c) else { stats.dropped += 1; return }
            do { try startWriter(first: sb, config: c, withAudio: withAudio) }
            catch { fail(error); return }
            state = .recording
            write(sb)
        case .recording:
            guard let c = cfg, let sb = cropIfNeeded(input, c) else { stats.dropped += 1; return }
            write(sb)
        }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        switch state {
        case .idle: return
        case .armed:
            if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sb) }
        case .recording:
            guard let aIn, let cfg, aIn.isReadyForMoreMediaData else { return }
            let pts = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), cfg.audioOffset)
            if CMTimeCompare(pts, start) < 0 { return }   // buang pre-roll sebelum frame video pertama
            let out = (cfg.audioOffset == .zero) ? sb : (retimed(sb, by: cfg.audioOffset) ?? sb)
            if !aIn.append(out) { fail(writer?.error) }
        }
    }

    // MARK: Internal
    private func cropIfNeeded(_ sb: CMSampleBuffer, _ c: Config) -> CMSampleBuffer? {
        guard let aspect = c.cropAspect else { return sb }
        if cropper == nil, let pb = CMSampleBufferGetImageBuffer(sb) { cropper = FrameCropper(source: pb, aspect: aspect) }
        guard let cropper else { return sb }     // tidak perlu/tidak bisa crop -> frame penuh
        return cropper.crop(sb)
    }

    private func startWriter(first sb: CMSampleBuffer, config c: Config, withAudio: Bool) throws {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { throw RecorderError.noFormat }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        try? FileManager.default.removeItem(at: c.url)

        let w = try AVAssetWriter(outputURL: c.url, fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)  // tahan crash/cabut kabel

        var vs: [String: Any] = [AVVideoCodecKey: c.codec.avCodec,
                                 AVVideoWidthKey: Int(dims.width),
                                 AVVideoHeightKey: Int(dims.height)]
        if let props = c.colorTag.properties { vs[AVVideoColorPropertiesKey] = props }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: vs, sourceFormatHint: fd)
        vin.expectsMediaDataInRealTime = true
        guard w.canAdd(vin) else { throw RecorderError.cannotAdd }
        w.add(vin)

        var ain: AVAssetWriterInput?
        if withAudio, let af = audioFormat,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee {
            let s: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: s, sourceFormatHint: af)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); ain = a }
        }

        guard w.startWriting() else { throw RecorderError.start(w.error?.localizedDescription ?? "?") }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        w.startSession(atSourceTime: pts)       // titik nol timeline = frame video pertama
        start = pts; writer = w; vIn = vin; aIn = ain
    }

    private func write(_ sb: CMSampleBuffer) {
        guard let vIn, let writer else { return }
        if writer.status == .failed { fail(writer.error); return }
        guard vIn.isReadyForMoreMediaData else { stats.dropped += 1; return }
        if vIn.append(sb) {
            stats.frames += 1
            if stats.frames % 30 == 0 {
                stats.seconds = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sb), start).seconds
                onStats?(stats)
            }
        } else { fail(writer.error) }
    }

    private func fail(_ error: Error?) {
        writer?.cancelWriting()
        writer = nil; vIn = nil; aIn = nil; state = .idle
        onError?(error?.localizedDescription ?? "Penulisan file gagal.")
    }

    private func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var n: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &n)
        var info = [CMSampleTimingInfo](repeating: .invalid, count: n)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &info, entriesNeededOut: &n)
        for i in 0..<n {
            info[i].presentationTimeStamp = CMTimeAdd(info[i].presentationTimeStamp, offset)
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = CMTimeAdd(info[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: n,
                                              sampleTimingArray: info, sampleBufferOut: &out)
        return out
    }
}
