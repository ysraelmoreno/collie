import Vision
import AppKit
// usage: ocr2 <png> <fast|accurate> <scale> <runs>   -> JSON {runsMs:[...], items:[{t,c,x,y,w,h}]}
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let scale = Double(a[3])!
if scale < 1 {
    let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); cg = ctx.makeImage()!
}
var runs: [Int] = []; var items: [[String: Any]] = []
for _ in 0..<Int(a[4])! {
    let t0 = Date(); let req = VNRecognizeTextRequest()
    req.recognitionLevel = a[2] == "fast" ? .fast : .accurate
    req.recognitionLanguages = ["pt-BR", "en-US"]; req.usesLanguageCorrection = a[2] != "fast"
    try VNImageRequestHandler(cgImage: cg).perform([req])
    runs.append(Int(Date().timeIntervalSince(t0) * 1000))
    items = (req.results ?? []).map { o in let b = o.boundingBox; let c = o.topCandidates(1)[0]
        return ["t": c.string, "c": c.confidence, "x": b.minX, "y": 1 - b.maxY, "w": b.width, "h": b.height] }
}
let d = try JSONSerialization.data(withJSONObject: ["runsMs": runs, "items": items])
print(String(data: d, encoding: .utf8)!)
