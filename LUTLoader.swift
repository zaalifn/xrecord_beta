import Foundation

struct CubeLUT {
    let size: Int
    /// RGBA float32, R tercepat (sama dengan .cube) -> langsung cocok dengan MTLTexture 3D.
    let rgba: [Float]
}

enum LUTError: LocalizedError {
    case unsupported1D, invalid(String)
    var errorDescription: String? {
        switch self {
        case .unsupported1D: return "LUT 1D belum didukung, gunakan LUT_3D_SIZE."
        case .invalid(let m): return "File .cube tidak valid: \(m)"
        }
    }
}

enum LUTLoader {
    static func identity(size n: Int) -> CubeLUT {
        var d = [Float](); d.reserveCapacity(n * n * n * 4)
        let s = Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            d += [Float(r) / s, Float(g) / s, Float(b) / s, 1]
        } } }
        return CubeLUT(size: n, rgba: d)
    }

    /// Parser .cube (Adobe/Resolve). DOMAIN_MIN/MAX diabaikan (asumsi 0...1, umum untuk LUT kamera).
    static func parseCube(_ text: String) throws -> CubeLUT {
        var size = 0
        var rgba = [Float]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = p.first else { continue }
            switch head {
            case "LUT_3D_SIZE":
                size = p.count > 1 ? Int(p[1]) ?? 0 : 0
                guard size >= 2, size <= 129 else { throw LUTError.invalid("ukuran \(size)") }
                rgba.reserveCapacity(size * size * size * 4)
            case "LUT_1D_SIZE":
                throw LUTError.unsupported1D
            default:
                guard p.count >= 3, let r = Float(p[0]), let g = Float(p[1]), let b = Float(p[2]) else { continue }
                rgba += [r, g, b, 1]
            }
        }
        guard size > 0 else { throw LUTError.invalid("LUT_3D_SIZE tidak ditemukan") }
        guard rgba.count == size * size * size * 4 else {
            throw LUTError.invalid("jumlah entri \(rgba.count / 4) ≠ \(size * size * size)")
        }
        return CubeLUT(size: size, rgba: rgba)
    }
}
