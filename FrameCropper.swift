import Foundation
import CoreMedia
import CoreVideo

/// Memotong frame packed (2vuy / yuvs / BGRA) tanpa re-encode dan tanpa konversi warna:
/// hanya menyalin baris piksel ke pixel buffer baru. Crop selalu di tengah frame.
final class FrameCropper {
    let cropWidth: Int
    let cropHeight: Int
    private let x0: Int
    private let y0: Int
    private let bytesPerPixel: Int
    private let pool: CVPixelBufferPool

    /// nil bila format tidak didukung, rasio sama dengan sumber, atau hasil terlalu kecil.
    init?(source pb: CVPixelBuffer, aspect: Double) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        switch fmt {
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: bytesPerPixel = 2
        case kCVPixelFormatType_32BGRA: bytesPerPixel = 4
        default: return nil
        }
        let srcAspect = Double(w) / Double(h)
        guard abs(aspect - srcAspect) > 0.005 else { return nil }

        var cw = w, ch = h
        if aspect > srcAspect { ch = Int((Double(w) / aspect).rounded()) }     // lebih lebar -> potong tinggi
        else { cw = Int((Double(h) * aspect).rounded()) }                      // lebih tinggi -> potong lebar
        cw &= ~1; ch &= ~1                                                     // genap (wajib untuk 4:2:2)
        guard cw >= 16, ch >= 16 else { return nil }
        cropWidth = cw; cropHeight = ch
        x0 = ((w - cw) / 2) & ~1
        y0 = ((h - ch) / 2) & ~1

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: fmt,
            kCVPixelBufferWidthKey as String: cw,
            kCVPixelBufferHeightKey as String: ch,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else { return nil }
        pool = p
    }

    func crop(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let src = CMSampleBufferGetImageBuffer(sb) else { return nil }
        var dstRef: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstRef) == kCVReturnSuccess, let dst = dstRef else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src), let dBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sStride = CVPixelBufferGetBytesPerRow(src), dStride = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = cropWidth * bytesPerPixel
        for row in 0..<cropHeight {
            memcpy(dBase + row * dStride, sBase + (y0 + row) * sStride + x0 * bytesPerPixel, rowBytes)
        }
        CVBufferPropagateAttachments(src, dst)

        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: dst,
                                                           formatDescriptionOut: &fd) == noErr, let fd else { return nil }
        var timing = CMSampleTimingInfo()
        _ = CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: dst, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}
