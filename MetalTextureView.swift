import SwiftUI
import MetalKit

struct MetalTextureView: NSViewRepresentable {
    enum Target { case monitor, scope(MetalPipeline.ScopeKind) }

    let pipeline: MetalPipeline
    let target: Target
    var fps: Int = 30

    func makeCoordinator() -> Coordinator { Coordinator(pipeline: pipeline, target: target) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: pipeline.device)
        v.delegate = context.coordinator
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.preferredFramesPerSecond = fps
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Beri tahu macOS bahwa piksel adalah Rec.709 agar color management di layar benar.
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let pipeline: MetalPipeline
        let target: Target
        init(pipeline: MetalPipeline, target: Target) { self.pipeline = pipeline; self.target = target }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            switch target {
            case .monitor: pipeline.drawMonitor(in: view)
            case .scope(let k): pipeline.drawScope(k, in: view)
            }
        }
    }
}
