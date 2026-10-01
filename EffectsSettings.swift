import Foundation

enum EffectsPreset: String, CaseIterable, Identifiable {
    case y2k = "Y2K Camcorder"
    case heavy = "VHS Rusak"
    case soft = "Handycam Lembut"
    case minimal = "Minimal (tanpa efek)"
    var id: String { rawValue }
}

/// Semua parameter efek. Satuan "px" = piksel virtual pada grid 640 lebar (hasil sama di 1080p maupun 4K).
struct EffectsSettings: Equatable {
    var vhsEnabled = false
    var osdEnabled = false
    /// true = efek ikut tertulis ke file rekaman (frame direkam sebagai BGRA -> ProRes).
    var burnIntoRecording = false

    // VHS
    var chromaBlur: Float = 1.6      // lebar blur chroma
    var chromaDelay: Float = 1.2     // chroma "menetes" ke kanan
    var aberration: Float = 1.2      // pemisahan kanal R/B
    var lowRes: Float = 0.6          // 0...1, turunkan resolusi (480 garis + luma lembut)
    var scanlines: Float = 0.15
    var grain: Float = 0.5
    var jello: Float = 0.4           // goyangan horizontal per baris
    var glitch: Float = 0.4          // frekuensi/intensitas tracking glitch
    var saturation: Float = 0.9

    // OSD
    var osdYear = 2000
    var osdBatteryBars = 3           // 0...3
    var osdTapeStartSeconds = 12 * 60 + 34     // counter kaset mulai 0:12:34
    var osdFontName = "VCR OSD Mono"           // fallback otomatis: Menlo Bold -> Courier

    mutating func apply(_ p: EffectsPreset) {
        switch p {
        case .y2k:
            (chromaBlur, chromaDelay, aberration, lowRes) = (1.6, 1.2, 1.2, 0.6)
            (scanlines, grain, jello, glitch, saturation) = (0.15, 0.5, 0.4, 0.4, 0.9)
        case .heavy:
            (chromaBlur, chromaDelay, aberration, lowRes) = (2.8, 2.5, 2.2, 0.9)
            (scanlines, grain, jello, glitch, saturation) = (0.3, 0.9, 1.0, 1.0, 0.75)
        case .soft:
            (chromaBlur, chromaDelay, aberration, lowRes) = (1.0, 0.6, 0.6, 0.3)
            (scanlines, grain, jello, glitch, saturation) = (0.08, 0.25, 0.15, 0.1, 0.95)
        case .minimal:
            (chromaBlur, chromaDelay, aberration, lowRes) = (0, 0, 0, 0)
            (scanlines, grain, jello, glitch, saturation) = (0, 0, 0, 0, 1)
        }
    }
}
