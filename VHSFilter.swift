import Metal
import CoreVideo
import CoreMedia

/// Mirror `VHSUniforms` di VHS.metal — urutan & tipe harus sama persis.
struct GPUVHSUniforms {
    var sourceKind: UInt32 = 0
    var fullRange: UInt32 = 0
    var matrixKind: UInt32 = 0
    var osdEnabled: UInt32 = 0
    var frameIndex: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var effectsOn: UInt32 = 0
    var time: Float = 0
    var chromaBlur: Float = 0
    var chromaDelay: Float = 0
    var aberration: Float = 0
    var lowRes: Float = 0
    var scanlines: Float = 0
    var grain: Float = 0
    var jello: Float = 0
    var saturation: Float = 1
    var glitchY: Float = -1
    var glitchH: Float = 0
    var glitchShift: Float = 0
    var dropY: Float = -1
    var dropX0: Float = 0
    var dropX1: Float = 0
    var headSwitch: Float = 0
}

/// Menjadwalkan glitch acak: band tracking yang bergeser + dropout putih pendek.
struct GlitchScheduler {
    struct Output {
        var bandY: Float = -1, bandH: Float = 0, bandShift: Float = 0
        var dropY: Float = -1, dropX0: Float = 0, dropX1: Float = 0
    }
    private var nextBand = 2.0, bandEnd = 0.0
    private var bandY: Float = 0.5, bandH: Float = 0.03, bandShift: Float = 0
    private var nextDrop = 1.0, dropEnd = 0.0
    private var dropY: Float = 0.5, dropX0: Float = 0, dropX1: Float = 0.2
    private var last = 0.0

    mutating func step(time t: Double, intensity: Float) -> Output {
        var o = Output()
        let dt = Float(max(0, t - last)); last = t
        guard intensity > 0.001 else { return o }
        let k = Double(max(intensity, 0.05))

        if t >= nextBand {
            bandEnd = t + Double.random(in: 0.12...0.4)
            bandY = Float.random(in: 0.12...0.88)
            bandH = Float.random(in: 0.012...0.05) * (0.6 + intensity)
            bandShift = Float.random(in: 6...22) * (Bool.random() ? 1 : -1) * (0.5 + intensity)
            nextBand = t + Double.random(in: 1.5...5.0) / k          // intensitas tinggi = lebih sering
        }
        if t < bandEnd {
            bandY -= dt * 0.35                                         // band merambat naik
            o.bandY = bandY; o.bandH = bandH; o.bandShift = bandShift
        }
        if t >= nextDrop {
            dropEnd = t + Double.random(in: 0.04...0.12)
            dropY = Float.random(in: 0.05...0.95)
            dropX0 = Float.random(in: 0...0.7)
            dropX1 = dropX0 + Float.random(in: 0.05...0.3)
            nextDrop = t + Double.random(in: 0.6...3.0) / k
        }
        if t < dropEnd { o.dropY = dropY; o.dropX0 = dropX0; o.dropX1 = dropX1 }
        return o
    }
}

/// Filter Y2K / VHS di GPU. Input: pixel buffer 2vuy / yuvs / BGRA. Output: pixel buffer BGRA baru.
/// process() menunggu GPU selesai (±1–3 ms), jadi hasilnya aman dipakai CPU/ProRes/monitor sekaligus.
/// Dipanggil hanya dari satu antrean (sampleQueue).
final class VHSFilter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pso: MTLComputePipelineState
    private var cache: CVMetalTextureCache
    private let emptyOSD: MTLTexture
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var frameIndex: UInt32 = 0
    private var glitch = GlitchScheduler()
    private let t0 = ProcessInfo.processInfo.systemUptime

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let fn = lib.makeFunction(name: "vhs_effect"),
              let p = try? device.makeComputePipelineState(function: fn) else { return nil }
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let empty = device.makeTexture(descriptor: d) else { return nil }
        var zero: [UInt8] = [0, 0, 0, 0]
        empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)

        self.device = device; queue = q; pso = p; cache = c; emptyOSD = empty
    }

    private func nextBuffer(width w: Int, height h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize.w != w || poolSize.h != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p) == kCVReturnSuccess else { return nil }
            pool = p; poolSize = (w, h)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    func process(_ src: CVPixelBuffer, settings s: EffectsSettings, effectsOn: Bool,
                 fullRange: Bool, matrix: UInt32, osd: MTLTexture?) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let fmt: MTLPixelFormat, kind: UInt32
        switch CVPixelBufferGetPixelFormatType(src) {
        case kCVPixelFormatType_422YpCbCr8:      fmt = .bgrg422;    kind = 1
        case kCVPixelFormatType_422YpCbCr8_yuvs: fmt = .gbgr422;    kind = 1
        case kCVPixelFormatType_32BGRA:          fmt = .bgra8Unorm; kind = 0
        default: return nil
        }
        guard let dstPB = nextBuffer(width: w, height: h) else { return nil }

        var inRef: CVMetalTexture?, outRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, src, nil, fmt, w, h, 0, &inRef) == kCVReturnSuccess,
              let inRef, let inTex = CVMetalTextureGetTexture(inRef) else { return nil }
        // Jika baris ini error di versi SDK-mu, hapus `usage` dan kirim nil (tekstur IOSurface biasanya boleh ditulis).
        let usage = [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, dstPB, usage, .bgra8Unorm, w, h, 0, &outRef) == kCVReturnSuccess,
              let outRef, let outTex = CVMetalTextureGetTexture(outRef) else { return nil }

        let t = ProcessInfo.processInfo.systemUptime - t0
        let g = glitch.step(time: t, intensity: effectsOn ? s.glitch : 0)

        var u = GPUVHSUniforms()
        u.sourceKind = kind; u.fullRange = fullRange ? 1 : 0; u.matrixKind = matrix
        u.osdEnabled = osd != nil ? 1 : 0
        u.frameIndex = frameIndex; u.width = UInt32(w); u.height = UInt32(h)
        u.effectsOn = effectsOn ? 1 : 0
        u.time = Float(t)
        u.chromaBlur = s.chromaBlur; u.chromaDelay = s.chromaDelay; u.aberration = s.aberration
        u.lowRes = s.lowRes; u.scanlines = s.scanlines; u.grain = s.grain; u.jello = s.jello
        u.saturation = s.saturation
        u.glitchY = g.bandY; u.glitchH = g.bandH; u.glitchShift = g.bandShift
        u.dropY = g.dropY; u.dropX0 = g.dropX0; u.dropX1 = g.dropX1
        u.headSwitch = min(1, s.glitch + 0.3)

        guard let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() else { return nil }
        ce.setComputePipelineState(pso)
        ce.setTexture(inTex, index: 0)
        ce.setTexture(outTex, index: 1)
        ce.setTexture(osd ?? emptyOSD, index: 2)
        ce.setBytes(&u, length: MemoryLayout<GPUVHSUniforms>.stride, index: 0)
        ce.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        ce.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()                 // frame siap dipakai CPU/ProRes/monitor
        guard cb.status == .completed else { return nil }
        frameIndex &+= 1
        return dstPB
    }
}
