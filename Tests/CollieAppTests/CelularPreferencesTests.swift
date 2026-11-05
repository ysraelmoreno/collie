import Testing
import Foundation
import CoreImage
import AppKit
import CollieProtocol
@testable import CollieApp

/// Remote API slice 10: the pairing sheet's data and its QR.
@Test func pairOfferFromBegin() {
    let o = PairOffer.from(.object(["pairingId": .string("p1"), "qr": .string("collie://pair?v=1&s=x"), "expiresAt": .string("2026-11-05T15:05:00Z")]))
    #expect(o?.id == "p1" && o?.qr == "collie://pair?v=1&s=x" && o?.expiresAt == ISO8601DateFormatter().date(from: "2026-11-05T15:05:00Z"))
    #expect(PairOffer.from(.object(["pairingId": .string("p1")])) == nil)
}

/// The QR reads back as the exact pairing URL (secret, hosts and fingerprint included).
@Test func qrReadsBackAsThePairingURL() throws {
    let url = "collie://pair?v=1&id=6F1C2A90-0000-4000-8000-000000000001&n=Mac%20de%20Ana&h=192.168.1.10,100.101.22.7&p=47820"
        + "&fp=kJ3vAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA9Qe2&s=Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE"
    let img = try #require(QRCode.image(url))
    var r = CGRect(origin: .zero, size: img.size)
    let cg = try #require(img.cgImage(forProposedRect: &r, context: nil, hints: nil))
    // scaled up with a quiet zone, as it is shown: the detector wants more than 1 px a module
    let side = cg.width * 8 + 64
    let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .none
    ctx.draw(cg, in: CGRect(x: 32, y: 32, width: cg.width * 8, height: cg.height * 8))
    let big = try #require(ctx.makeImage())
    let d = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let found = d?.features(in: CIImage(cgImage: big)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(found == [url], "\(String(describing: found))")
}
