import Foundation

enum ColorMatrix: UInt32, CaseIterable, Identifiable {
    case rec709 = 0, rec2020 = 1
    var id: UInt32 { rawValue }
    var label: String { self == .rec709 ? "Rec.709" : "Rec.2020" }
}

/// Seluruh pengaturan monitor yang dibaca renderer (disalin sebagai nilai -> thread-safe).
struct MonitorSettings: Equatable {
    var scopesEnabled = false
    var lutEnabled = false

    var zebraEnabled = false
    var zebraLow: Float = 0.70      // band kulit (0...1 = 0...100 IRE)
    var zebraHigh: Float = 0.95     // ambang clipping

    var peakingEnabled = false
    var peakingThreshold: Float = 0.08

    var fullRange = false           // false = video range 16-235 (tipikal HDMI)
    var matrix: ColorMatrix = .rec709

    var waveGain: Float = 0.35
    var vecGain: Float = 0.08
    var histScaleFraction: Float = 0.02
}

// MARK: - Rasio aspek rekaman & overlay monitor

enum AspectPreset: String, CaseIterable, Identifiable {
    case source = "Full"
    case a239 = "2.39:1"
    case a200 = "2:1"
    case a185 = "1.85:1"
    case a169 = "16:9"
    case a43  = "4:3"
    case a11  = "1:1"
    case a45  = "4:5"
    case a916 = "9:16"

    var id: String { rawValue }
    var label: String { rawValue }
    /// lebar/tinggi; nil = pakai frame sumber apa adanya
    var ratio: Double? {
        switch self {
        case .source: return nil
        case .a239: return 2.39
        case .a200: return 2.0
        case .a185: return 1.85
        case .a169: return 16.0 / 9.0
        case .a43:  return 4.0 / 3.0
        case .a11:  return 1.0
        case .a45:  return 0.8
        case .a916: return 9.0 / 16.0
        }
    }
}

enum GridKind: String, CaseIterable, Identifiable {
    case thirds = "Rule of Thirds"
    case center = "Center Cross"
    case golden = "Golden Ratio"
    case diagonals = "Diagonal"
    case safe90 = "Safe Area 90%"
    case safe80 = "Safe Area 80%"
    var id: String { rawValue }
}

/// Pengaturan tampilan saja (tidak masuk file rekaman), kecuali `aspect` yang juga memotong rekaman.
struct OverlaySettings: Equatable {
    var grids: Set<GridKind> = []
    var aspect: AspectPreset = .source
    var showMask = true
    var showWaveform = false
    var showHistogram = false
    var showVectorscope = false
    var anyScope: Bool { showWaveform || showHistogram || showVectorscope }
}
