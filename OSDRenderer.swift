import Foundation
import CoreGraphics
import CoreText
import CoreVideo

struct OSDState {
    var isRecording: Bool
    var recordingElapsed: Double       // detik sejak REC ditekan
    var fps: Double
    var now: Date
    var year: Int                      // tahun palsu, mis. 2000
    var batteryBars: Int               // 0...3
    var tapeStartSeconds: Int          // posisi awal counter kaset
}

/// Menggambar OSD ala camcorder dengan Core Graphics pada layer kecil (grid tinggi 270 px),
/// tanpa anti-aliasing, putih solid + border hitam. Layer di-upscale nearest-neighbor -> piksel kotak.
/// Layer hanya digambar ulang saat isinya berubah.
final class OSDRenderer {
    private(set) var gridWidth = 480
    let gridHeight = 270

    private var ctx: CGContext
    private var font: CTFont
    private var fontName = ""
    private var lastTexts: Texts?
    private var image: CGImage?
    private var regions: [CGRect] = []          // area berisi OSD (koordinat grid, origin kiri-bawah)
    private let fontSize: CGFloat = 18
    private let border: CGFloat = 2             // tebal border hitam (px grid)

    private struct Texts: Equatable {
        var recording: Bool, dotOn: Bool
        var counter: String, date: String, time: String
        var bars: Int, batteryBlink: Bool
    }

    init() {
        ctx = OSDRenderer.makeContext(480, 270)!
        font = OSDRenderer.resolveFont(preferred: "VCR OSD Mono", size: 18)
        fontName = "VCR OSD Mono"
    }

    // MARK: Font
    /// Mendaftarkan font kustom (mis. VCR OSD Mono .ttf) untuk proses ini. Mengembalikan nama PostScript.
    static func registerFont(at url: URL) -> String? {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let d = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else { return nil }
        return CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String
    }

    func setFontIfNeeded(_ name: String) {
        guard name != fontName else { return }
        fontName = name
        font = OSDRenderer.resolveFont(preferred: name, size: fontSize)
        lastTexts = nil
    }

    private static func resolveFont(preferred: String, size: CGFloat) -> CTFont {
        for name in [preferred, "Menlo-Bold", "CourierNewPS-BoldMT", "Courier-Bold"] {
            let f = CTFontCreateWithName(name as CFString, size, nil)
            let want = name.replacingOccurrences(of: " ", with: "").lowercased()
            let got = ((CTFontCopyPostScriptName(f) as String) + (CTFontCopyFamilyName(f) as String))
                .replacingOccurrences(of: " ", with: "").lowercased()
            if got.contains(want) { return f }          // font yang diminta benar-benar ada
        }
        return CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    }

    // MARK: Layer
    private static func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Sesuaikan lebar grid dengan rasio frame agar piksel OSD tetap persegi.
    func configure(aspect: Double) {
        var w = Int((Double(gridHeight) * aspect).rounded())
        w += w % 2
        guard w != gridWidth else { return }
        gridWidth = w
        ctx = OSDRenderer.makeContext(w, gridHeight)!
        lastTexts = nil
    }

    /// Memori layer RGBA premultiplied (siap di-upload ke MTLTexture .rgba8Unorm).
    var pixelData: UnsafeRawPointer? { UnsafeRawPointer(ctx.data) }

    /// Menggambar ulang hanya jika isi berubah. true = layer berubah.
    @discardableResult
    func update(_ s: OSDState) -> Bool {
        let t = texts(for: s)
        if t == lastTexts { return false }
        lastTexts = t
        draw(t)
        image = ctx.makeImage()
        return true
    }

    // MARK: drawOSD — komposit CPU langsung ke pixel buffer BGRA
    /// Hanya menyentuh area sudut yang berisi OSD (clip), jadi murah walau buffernya 4K.
    func drawOSD(on pixelBuffer: CVPixelBuffer, state: OSDState) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }
        let W = CVPixelBufferGetWidth(pixelBuffer), H = CVPixelBufferGetHeight(pixelBuffer)
        configure(aspect: Double(W) / Double(H))
        update(state)
        guard let image else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let c = CGContext(data: base, width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        c.interpolationQuality = .none                  // nearest-neighbor
        c.setShouldAntialias(false)
        let sx = CGFloat(W) / CGFloat(gridWidth), sy = CGFloat(H) / CGFloat(gridHeight)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        for r in regions {
            c.saveGState()
            c.clip(to: CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy).integral)
            c.draw(image, in: full)
            c.restoreGState()
        }
    }

    // MARK: Isi teks
    private func texts(for s: OSDState) -> Texts {
        let months = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"]
        let c = Calendar(identifier: .gregorian).dateComponents([.month, .day, .hour, .minute, .second], from: s.now)
        let date = String(format: "%@ %02d, %04d", months[(c.month ?? 1) - 1], c.day ?? 1, s.year)
        let hour = c.hour ?? 0
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let time = String(format: "%02d:%02d:%02d %@", h12, c.minute ?? 0, c.second ?? 0, hour < 12 ? "AM" : "PM")

        let elapsed = s.isRecording ? max(0, s.recordingElapsed) : 0
        let total = Double(s.tapeStartSeconds) + elapsed
        let whole = Int(total)
        let ff = min(max(1, Int(s.fps.rounded())) - 1, Int((total - Double(whole)) * s.fps))
        let counter = String(format: "SP  %d:%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60, ff)

        let sec = Int(s.now.timeIntervalSince1970)
        return Texts(recording: s.isRecording, dotOn: s.isRecording && sec % 2 == 0,   // titik merah berkedip tiap 1 dtk
                     counter: counter, date: date, time: time,
                     bars: max(0, min(3, s.batteryBars)), batteryBlink: sec % 2 == 0)
    }

    // MARK: Menggambar
    private func draw(_ t: Texts) {
        let gw = CGFloat(gridWidth), gh = CGFloat(gridHeight)
        ctx.clear(CGRect(x: 0, y: 0, width: gw, height: gh))
        ctx.setAllowsAntialiasing(false);          ctx.setShouldAntialias(false)
        ctx.setAllowsFontSmoothing(false);         ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false); ctx.setShouldSubpixelPositionFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
        regions.removeAll(keepingCapacity: true)

        let margin: CGFloat = 16
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        let lineH = (asc + desc + 3).rounded()
        let topBase = (gh - margin - asc).rounded()
        let botBase = (margin + desc).rounded()

        // Kiri atas: ● REC / STBY
        var x = margin
        let dotR: CGFloat = 6
        if t.recording {
            if t.dotOn {
                let c = CGPoint(x: x + dotR, y: topBase + (asc * 0.4).rounded())
                fillDot(center: c, radius: dotR)
                regions.append(CGRect(x: c.x - dotR - border - 1, y: c.y - dotR - border - 1,
                                      width: (dotR + border + 1) * 2, height: (dotR + border + 1) * 2))
            }
            x += dotR * 2 + 8
            regions.append(text("REC", x: x, y: topBase))
        } else {
            regions.append(text("STBY", x: x, y: topBase))
        }

        // Kanan atas: baterai batang
        regions.append(drawBattery(rightEdge: gw - margin, top: gh - margin, bars: t.bars, blink: t.batteryBlink))

        // Kiri bawah: counter kaset
        regions.append(text(t.counter, x: margin, y: botBase))

        // Kanan bawah: tanggal Y2K + jam digital di bawahnya
        regions.append(text(t.time, x: gw - margin, y: botBase, rightAligned: true))
        regions.append(text(t.date, x: gw - margin, y: botBase + lineH, rightAligned: true))
    }

    /// Putih solid + border hitam: stroke tebal (hitam) lalu fill (putih).
    @discardableResult
    private func text(_ s: String, x: CGFloat, y: CGFloat, rightAligned: Bool = false) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs) as CFAttributedString)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead)).rounded(.up)
        let x0 = (rightAligned ? x - width : x).rounded()

        ctx.textMatrix = .identity
        ctx.setLineJoin(.round)
        ctx.setLineWidth(border * 2)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setTextDrawingMode(.stroke)
        ctx.textPosition = CGPoint(x: x0, y: y); CTLineDraw(line, ctx)
        ctx.setTextDrawingMode(.fill)
        ctx.textPosition = CGPoint(x: x0, y: y); CTLineDraw(line, ctx)
        return CGRect(x: x0 - border - 1, y: y - desc - border - 1,
                      width: width + 2 * border + 2, height: asc + desc + 2 * border + 2)
    }

    private func fillDot(center c: CGPoint, radius r: CGFloat) {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - r - border, y: c.y - r - border, width: (r + border) * 2, height: (r + border) * 2))
        ctx.setFillColor(CGColor(red: 1, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// Indikator baterai kotak 3 batang. Saat ≤1 batang: batang merah berkedip.
    private func drawBattery(rightEdge: CGFloat, top: CGFloat, bars: Int, blink: Bool) -> CGRect {
        let bodyW: CGFloat = 38, bodyH: CGFloat = 16, nubW: CGFloat = 3
        let body = CGRect(x: rightEdge - bodyW - nubW, y: top - bodyH, width: bodyW, height: bodyH)
        let nub = CGRect(x: body.maxX, y: body.midY - 3, width: nubW, height: 6)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1), black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        ctx.setStrokeColor(black); ctx.setLineWidth(2 + border * 2); ctx.stroke(body)
        ctx.setFillColor(black);   ctx.fill(nub.insetBy(dx: -border, dy: -border))
        ctx.setStrokeColor(white); ctx.setLineWidth(2); ctx.stroke(body)
        ctx.setFillColor(white);   ctx.fill(nub)

        let gap: CGFloat = 2
        let inner = body.insetBy(dx: 4, dy: 4)
        let barW = ((inner.width - gap * 2) / 3).rounded(.down)
        let low = bars <= 1
        if !(low && !blink) {
            ctx.setFillColor(low ? CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1) : white)
            for i in 0..<bars {
                ctx.fill(CGRect(x: inner.minX + CGFloat(i) * (barW + gap), y: inner.minY, width: barW, height: inner.height))
            }
        }
        return body.union(nub).insetBy(dx: -(border + 2), dy: -(border + 2))
    }
}
