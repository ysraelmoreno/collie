import Foundation
import CoreGraphics
import ImageIO
import Vision
import CollieDevice
import CollieProtocol

/// The `OCRProvider` of `collied` (macOS Vision, `VNRecognizeTextRequest`): one resident instance per daemon. The actor
/// is the serial queue (one image at a time); the first call per level runs a warm-up recognition (a cold model costs
/// 120 to 700 ms, a warm one 14 to 200 ms). `fast` reads the image at 0.5x, `accurate` (the fallback's default) at full
/// size with language correction. Boxes come back in the PNG's pixels, top-left origin. The image stays in memory.
/// ponytail: the recognition runs on the actor's thread (~200 ms busy); a dedicated DispatchQueue if that ever starves the pool.
public actor VisionOCR: OCRProvider {
    public static let defaultLanguages = ["pt-BR", "en-US"]
    private let languages: [String]
    private var warm: Set<String> = []

    public init(languages: [String] = VisionOCR.defaultLanguages) { self.languages = languages }

    public func recognize(png: Data, level: OCRLevel, languages: [String]) async throws -> [OCRItem] {
        guard let image = OCRImage.decode(png) else { throw ProtocolError(code: .invalidArgs, message: "ocr: not a PNG") }
        let langs = languages.isEmpty ? self.languages : languages
        if !warm.contains(level.rawValue), let blank = OCRImage.blank() {
            _ = try? Self.read(blank, level: level, languages: langs)
            warm.insert(level.rawValue)
        }
        let input = level == .fast ? (OCRImage.scaled(image, by: 0.5) ?? image) : image
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision boxes are normalised with a bottom-left origin: the same box whatever the scale read
        return try Self.read(input, level: level, languages: langs).map { text, confidence, bb in
            OCRItem(text: text, confidence: confidence,
                    box: CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h))
        }
    }

    private static func read(_ image: CGImage, level: OCRLevel, languages: [String]) throws -> [(String, Double, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = level == .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { ($0.string, Double($0.confidence), o.boundingBox) }
        }
    }
}

/// In-memory PNG work for the OCR fallback: decode, the black/uniform check, `--region` crops. Nothing touches disk.
enum OCRImage {
    static func decode(_ png: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func scaled(_ image: CGImage, by f: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(image.width) * f)), h = max(1, Int(CGFloat(image.height) * f))
        guard let ctx = rgba(w, h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A small white image for the warm-up.
    static func blank() -> CGImage? {
        guard let ctx = rgba(64, 64) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()
    }

    /// Black or one flat colour (`FLAG_SECURE` screens come black): every channel within `spread` over a 32×32 sample.
    /// Undecodable counts as uniform (nothing to read).
    static func uniform(_ png: Data, spread: UInt8 = 8) -> Bool {
        guard let image = decode(png), let ctx = rgba(32, 32) else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let data = ctx.data else { return true }
        let px = data.bindMemory(to: UInt8.self, capacity: 32 * 32 * 4)
        for c in 0..<3 {
            var lo = UInt8.max, hi = UInt8.min
            for i in stride(from: c, to: 32 * 32 * 4, by: 4) { lo = min(lo, px[i]); hi = max(hi, px[i]) }
            if hi - lo > spread { return false }
        }
        return true
    }

    /// The PNG cut to `rect` (image pixels, top-left origin, clipped to the image) and the rect actually used; nil when
    /// the rect misses the image.
    static func crop(_ png: Data, to rect: CGRect) -> (png: Data, rect: CGRect)? {
        guard let image = decode(png) else { return nil }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width > 0, r.height > 0, let cut = image.cropping(to: r), let data = encode(cut) else { return nil }
        return (data, r)
    }

    private static func rgba(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
