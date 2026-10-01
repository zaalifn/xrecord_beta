import Metal
import MetalKit
import CoreVideo

/// Mirror persis dari `struct Uniforms` di Shaders.metal.
struct GPUUniforms {
    var sourceKind: UInt32 = 0
    var fullRange: UInt32 = 0
    var matrixKind: UInt32 = 0
    var lutEnabled: UInt32 = 0
    var zebraEnabled: UInt32 = 0
    var peakingEnabled: UInt32 = 0
    var gridW: UInt32 = 0
    var gridH: UInt32 = 0
    var zebraLow: Float = 0.7
    var zebraHigh: Float = 0.95
    var peakingThreshold: Float = 0.08
    var texelX: Float = 0
    var texelY: Float = 0
    var time: Float = 0
    var waveGain: Float = 0.35
    var vecGain: Float = 0.08
    var histScale: Float = 1
}

enum PipelineError: LocalizedError {
    case metalUnavailable, textureCache, missingFunction(String)
    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "Metal / default library tidak tersedia (pastikan Shaders.metal ada di target)."
        case .textureCache: return "Gagal membuat CVMetalTextureCache."
        case .missingFunction(let n): return "Fungsi Metal '\(n)' tidak ditemukan."
        }
    }
}

final class MetalPipeline: @unchecked Sendable {
    enum ScopeKind { case waveform, histogram, vectorscope }

    static let waveW = 512, waveH = 256
    static let histW = 512, histH = 160
    static let vecN = 256
    static let gridW = 960, gridH = 540

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let monitorPSO: MTLRenderPipelineState
    private let texturePSO: MTLRenderPipelineState
    private let accumPSO: MTLComputePipelineState
    private let wavePSO: MTLComputePipelineState
    private let histPSO: MTLComputePipelineState
    private let vecPSO: MTLComputePipelineState
    private let histBuf: MTLBuffer
    private let waveBuf: MTLBuffer
    private let vecBuf: MTLBuffer
    private let waveTex: MTLTexture
    private let histTex: MTLTexture
    private let vecTex: MTLTexture
    private var lutTex: MTLTexture

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var settings = MonitorSettings()
    private var frameIndex: UInt64 = 0
    private let t0 = ProcessInfo.processInfo.systemUptime

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary() else { throw PipelineError.metalUnavailable }

        var cacheRef: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, dev, nil, &cacheRef) == kCVReturnSuccess,
              let c = cacheRef else { throw PipelineError.textureCache }

        func function(_ n: String) throws -> MTLFunction {
            guard let f = lib.makeFunction(name: n) else { throw PipelineError.missingFunction(n) }
            return f
        }
        func compute(_ n: String) throws -> MTLComputePipelineState {
            try dev.makeComputePipelineState(function: try function(n))
        }
        func texture(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return dev.makeTexture(descriptor: d)!
        }
        func buffer(_ count: Int) -> MTLBuffer {
            dev.makeBuffer(length: count * MemoryLayout<UInt32>.stride, options: .storageModePrivate)!
        }

        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = try function("vs_fullscreen")
        rd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rd.fragmentFunction = try function("fs_monitor")
        let mPSO = try dev.makeRenderPipelineState(descriptor: rd)
        rd.fragmentFunction = try function("fs_texture")
        let tPSO = try dev.makeRenderPipelineState(descriptor: rd)

        device = dev; queue = q; cache = c
        monitorPSO = mPSO; texturePSO = tPSO
        accumPSO = try compute("scopes_accumulate")
        wavePSO = try compute("render_waveform")
        histPSO = try compute("render_histogram")
        vecPSO = try compute("render_vectorscope")
        histBuf = buffer(4 * 256)
        waveBuf = buffer(Self.waveW * Self.waveH)
        vecBuf = buffer(Self.vecN * Self.vecN)
        waveTex = texture(Self.waveW, Self.waveH)
        histTex = texture(Self.histW, Self.histH)
        vecTex = texture(Self.vecN, Self.vecN)
        lutTex = Self.makeLUTTexture(dev, LUTLoader.identity(size: 2))
    }

    // MARK: API thread-safe
    func submit(_ pb: CVPixelBuffer) { lock.lock(); latest = pb; lock.unlock() }
    func update(_ s: MonitorSettings) { lock.lock(); settings = s; lock.unlock() }
    func setLUT(_ lut: CubeLUT) {
        let t = Self.makeLUTTexture(device, lut)
        lock.lock(); lutTex = t; lock.unlock()
    }

    static func makeLUTTexture(_ dev: MTLDevice, _ lut: CubeLUT) -> MTLTexture {
        let n = lut.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D; d.pixelFormat = .rgba32Float
        d.width = n; d.height = n; d.depth = n; d.usage = .shaderRead
        let t = dev.makeTexture(descriptor: d)!
        lut.rgba.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: n * 16, bytesPerImage: n * n * 16)
        }
        return t
    }

    // MARK: Sumber -> MTLTexture (zero-copy lewat IOSurface)
    private struct Source { let tex: MTLTexture; let hold: CVMetalTexture; let kind: UInt32 }

    private func makeSource(_ pb: CVPixelBuffer) -> Source? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt: MTLPixelFormat, kind: UInt32
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_422YpCbCr8:      fmt = .bgrg422;   kind = 1   // '2vuy' = Cb Y0 Cr Y1
        case kCVPixelFormatType_422YpCbCr8_yuvs: fmt = .gbgr422;   kind = 1   // 'yuvs' = Y0 Cb Y1 Cr
        case kCVPixelFormatType_32BGRA:          fmt = .bgra8Unorm; kind = 0
        default: return nil
        }
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, 0, &ref) == kCVReturnSuccess,
              let ref, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return Source(tex: tex, hold: ref, kind: kind)
    }

    private func uniforms(_ s: MonitorSettings, src: Source) -> GPUUniforms {
        var u = GPUUniforms()
        u.sourceKind = src.kind
        u.fullRange = s.fullRange ? 1 : 0
        u.matrixKind = s.matrix.rawValue
        u.lutEnabled = s.lutEnabled ? 1 : 0
        u.zebraEnabled = s.zebraEnabled ? 1 : 0
        u.peakingEnabled = s.peakingEnabled ? 1 : 0
        u.gridW = UInt32(Self.gridW); u.gridH = UInt32(Self.gridH)
        u.zebraLow = s.zebraLow; u.zebraHigh = s.zebraHigh
        u.peakingThreshold = s.peakingThreshold
        u.texelX = 1 / Float(src.tex.width); u.texelY = 1 / Float(src.tex.height)
        u.time = Float(ProcessInfo.processInfo.systemUptime - t0)
        u.waveGain = s.waveGain; u.vecGain = s.vecGain
        u.histScale = Float(Self.gridW * Self.gridH) * s.histScaleFraction
        return u
    }

    // MARK: Draw
    func drawMonitor(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        lock.lock()
        let pb = latest, s = settings, lut = lutTex
        lock.unlock()

        guard let pb, let src = makeSource(pb) else {          // belum ada sinyal: layar hitam
            cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
            cb.present(drawable); cb.commit(); return
        }

        var u = uniforms(s, src: src)
        if s.scopesEnabled && frameIndex % 2 == 0 { encodeScopes(cb, src: src.tex, u: &u) }
        frameIndex &+= 1

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(monitorPSO)
        enc.setFragmentTexture(src.tex, index: 0)
        enc.setFragmentTexture(lut, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cb.present(drawable)
        let hold = src.hold                                     // jaga CVMetalTexture sampai GPU selesai
        cb.addCompletedHandler { _ in withExtendedLifetime(hold) {} }
        cb.commit()
    }

    func drawScope(_ kind: ScopeKind, in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let tex: MTLTexture
        switch kind {
        case .waveform: tex = waveTex
        case .histogram: tex = histTex
        case .vectorscope: tex = vecTex
        }
        enc.setRenderPipelineState(texturePSO)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable); cb.commit()
    }

    private func encodeScopes(_ cb: MTLCommandBuffer, src: MTLTexture, u: inout GPUUniforms) {
        if let blit = cb.makeBlitCommandEncoder() {
            for b in [histBuf, waveBuf, vecBuf] { blit.fill(buffer: b, range: 0..<b.length, value: 0) }
            blit.endEncoding()
        }
        guard let ce = cb.makeComputeCommandEncoder() else { return }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let size = MemoryLayout<GPUUniforms>.stride

        ce.setComputePipelineState(accumPSO)
        ce.setTexture(src, index: 0)
        ce.setBuffer(histBuf, offset: 0, index: 0)
        ce.setBuffer(waveBuf, offset: 0, index: 1)
        ce.setBuffer(vecBuf, offset: 0, index: 2)
        ce.setBytes(&u, length: size, index: 3)
        ce.dispatchThreads(MTLSize(width: Self.gridW, height: Self.gridH, depth: 1), threadsPerThreadgroup: tg)

        func render(_ pso: MTLComputePipelineState, _ buf: MTLBuffer, _ out: MTLTexture) {
            ce.setComputePipelineState(pso)
            ce.setBuffer(buf, offset: 0, index: 0)
            ce.setTexture(out, index: 0)
            ce.setBytes(&u, length: size, index: 1)
            ce.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1), threadsPerThreadgroup: tg)
        }
        render(wavePSO, waveBuf, waveTex)
        render(histPSO, histBuf, histTex)
        render(vecPSO, vecBuf, vecTex)
        ce.endEncoding()
    }
}
