import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// A QR code as the other shape of a string the user would otherwise type or
/// compare by eye: the link code of a device being added, the safety number
/// of a pair. Made with Core Image, read back with Vision — from a picture in
/// the library, so the pair of simulators can exercise it, or from a camera
/// frame where there is one.
enum QRCode {
    /// The code as a crisp picture: every module is `scale` points wide, and
    /// the image is opaque so it reads the same on any background.
    static func image(_ text: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The first QR code found in the picture, as its text; nil when there is
    /// none the detector can read.
    static func read(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        if (try? handler.perform([request])) != nil,
           let text = request.results?.compactMap(\.payloadStringValue).first(where: { !$0.isEmpty }) {
            return text
        }
        // Core Image's detector reads where Vision's barcode request has no
        // backing, the simulator among them
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: cg))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first { !$0.isEmpty }
    }

    /// The link code as a QR payload, and the code back out of one. The same
    /// code typed by hand and the code from the picture are one and the same
    /// on the server's side.
    static let linkScheme = "msngr://link/"
    static func linkPayload(code: String) -> String { linkScheme + code }
    static func linkCode(from payload: String) -> String? {
        guard payload.hasPrefix(linkScheme) else { return nil }
        return String(payload.dropFirst(linkScheme.count))
    }

    /// The safety number as a QR payload: the sixty digits, nothing else, so
    /// what the other side scans is what it would otherwise read out.
    static let safetyScheme = "msngr://safety/"
    static func safetyPayload(number: String) -> String { safetyScheme + number }
    static func safetyNumber(from payload: String) -> String? {
        guard payload.hasPrefix(safetyScheme) else { return nil }
        let digits = String(payload.dropFirst(safetyScheme.count))
        return digits.allSatisfy(\.isNumber) ? digits : nil
    }
}
