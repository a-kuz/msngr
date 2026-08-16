import Foundation

/// BlurHash (the Wolt algorithm, https://github.com/woltapp/blurhash): a compact
/// placeholder string for an image. Encoding is a DCT over linear RGB, written in base83.
public enum BlurHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let charToValue: [Character: Int] = {
        var map = [Character: Int]()
        for (i, c) in alphabet.enumerated() { map[c] = i }
        return map
    }()

    // MARK: - Encode

    /// `pixels` is RGBA8 row by row (width*height*4 bytes); alpha is ignored.
    public static func encode(pixels: [UInt8], width: Int, height: Int, componentsX: Int = 4, componentsY: Int = 3) -> String? {
        guard (1...9).contains(componentsX), (1...9).contains(componentsY),
              width > 0, height > 0,
              pixels.count == width * height * 4 else { return nil }

        // Convert to linear once, instead of once per component
        var linear = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            linear[i * 3 + 0] = sRGBToLinear(pixels[i * 4 + 0])
            linear[i * 3 + 1] = sRGBToLinear(pixels[i * 4 + 1])
            linear[i * 3 + 2] = sRGBToLinear(pixels[i * 4 + 2])
        }

        var factors: [(Float, Float, Float)] = []
        factors.reserveCapacity(componentsX * componentsY)
        for y in 0..<componentsY {
            for x in 0..<componentsX {
                // Normalisation per the spec: 1 for DC, 2 for AC
                let normalisation: Float = (x == 0 && y == 0) ? 1 : 2
                var r: Float = 0, g: Float = 0, b: Float = 0
                for py in 0..<height {
                    let cosY = cos(Float.pi * Float(y) * Float(py) / Float(height))
                    for px in 0..<width {
                        let basis = cosY * cos(Float.pi * Float(x) * Float(px) / Float(width))
                        let i = (py * width + px) * 3
                        r += basis * linear[i]
                        g += basis * linear[i + 1]
                        b += basis * linear[i + 2]
                    }
                }
                let scale = normalisation / Float(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = factors.dropFirst()

        var hash = ""
        hash += encode83((componentsX - 1) + (componentsY - 1) * 9, length: 1)

        let maximumValue: Float
        if !ac.isEmpty {
            let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
            let quantised = max(0, min(82, Int(floor(actualMax * 166 - 0.5))))
            maximumValue = Float(quantised + 1) / 166
            hash += encode83(quantised, length: 1)
        } else {
            maximumValue = 1
            hash += encode83(0, length: 1)
        }

        hash += encode83(encodeDC(dc), length: 4)
        for factor in ac {
            hash += encode83(encodeAC(factor, maximumValue: maximumValue), length: 2)
        }
        return hash
    }

    private static func encodeDC(_ value: (Float, Float, Float)) -> Int {
        (linearToSRGB(value.0) << 16) + (linearToSRGB(value.1) << 8) + linearToSRGB(value.2)
    }

    private static func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
        func quantise(_ v: Float) -> Int {
            max(0, min(18, Int(floor(signPow(v / maximumValue, 0.5) * 9 + 9.5))))
        }
        return quantise(value.0) * 19 * 19 + quantise(value.1) * 19 + quantise(value.2)
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in stride(from: length, to: 0, by: -1) {
            var divisor = 1
            for _ in 1..<i { divisor *= 83 }
            result.append(alphabet[(value / divisor) % 83])
        }
        return result
    }

    // MARK: - Decode

    /// Returns width*height RGBA8 pixels (alpha=255), or nil if the hash is malformed.
    public static func decodePixels(_ hash: String, width: Int, height: Int, punch: Float = 1) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let chars = Array(hash)
        guard chars.count >= 6, let sizeFlag = decode83(chars[0..<1]) else { return nil }

        let componentsY = sizeFlag / 9 + 1
        let componentsX = sizeFlag % 9 + 1
        guard chars.count == 4 + 2 * componentsX * componentsY else { return nil }

        guard let quantisedMax = decode83(chars[1..<2]),
              let dcValue = decode83(chars[2..<6]) else { return nil }
        let maximumValue = Float(quantisedMax + 1) / 166

        var colours: [(Float, Float, Float)] = []
        colours.reserveCapacity(componentsX * componentsY)
        colours.append((
            sRGBToLinear(UInt8((dcValue >> 16) & 255)),
            sRGBToLinear(UInt8((dcValue >> 8) & 255)),
            sRGBToLinear(UInt8(dcValue & 255))
        ))
        for i in 1..<(componentsX * componentsY) {
            guard let acValue = decode83(chars[(4 + i * 2)..<(6 + i * 2)]) else { return nil }
            func dequantise(_ q: Int) -> Float {
                signPow((Float(q) - 9) / 9, 2) * maximumValue * punch
            }
            colours.append((
                dequantise(acValue / (19 * 19)),
                dequantise((acValue / 19) % 19),
                dequantise(acValue % 19)
            ))
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<componentsY {
                    let cosY = cos(Float.pi * Float(y) * Float(j) / Float(height))
                    for i in 0..<componentsX {
                        let basis = cosY * cos(Float.pi * Float(x) * Float(i) / Float(width))
                        let colour = colours[j * componentsX + i]
                        r += colour.0 * basis
                        g += colour.1 * basis
                        b += colour.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset + 0] = UInt8(linearToSRGB(r))
                pixels[offset + 1] = UInt8(linearToSRGB(g))
                pixels[offset + 2] = UInt8(linearToSRGB(b))
            }
        }
        return pixels
    }

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for c in chars {
            guard let digit = charToValue[c] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    // MARK: - Colour conversion

    private static func sRGBToLinear(_ value: UInt8) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> Int {
        let v = max(0, min(1, value))
        let s: Float = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return Int(s * 255 + 0.5)
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }
}
