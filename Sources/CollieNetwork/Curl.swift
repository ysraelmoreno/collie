import Foundation

/// A flow's request as a runnable POSIX-shell cURL command.
public enum Curl {
    /// Hop-by-hop and framing headers curl sets itself (RFC 9110 §7.6.1), plus Content-Length; Host is in the
    /// URL already (mitmproxy's pretty_url is built from it).
    private static let dropped: Set<String> = ["connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
                                               "content-length", "host"]

    public static func render(_ flow: Flow) -> String {
        var args: [String] = []
        let body = flow.reqBody.flatMap { $0.size > 0 ? $0 : nil }
        switch (flow.method.uppercased(), body != nil) {
        case ("GET", false), ("POST", true): break   // curl's implicit method
        case ("HEAD", false): args.append("--head")   // -X HEAD makes curl wait for a body
        default: args.append("-X " + quote(flow.method))
        }
        if flow.httpVersion.uppercased().hasPrefix("HTTP/2") { args.append("--http2") }
        // --compressed sends curl's own Accept-Encoding (only what it can decode, e.g. no zstd): the original goes
        let compressed = flow.reqHeaders.contains { $0.name.lowercased() == "accept-encoding" }
        for h in flow.reqHeaders {
            let n = h.name.lowercased()
            guard !n.hasPrefix(":"), !n.hasPrefix("proxy-"), !dropped.contains(n), n != "accept-encoding" else { continue }
            args.append("-H " + quote("\(h.name): \(h.value)"))
        }
        if compressed { args.append("--compressed") }

        var prefix = ""
        if let body {
            if body.truncated { prefix = "# warning: request body truncated (\(body.data.count) of \(body.size) bytes)\n" }
            // Text without NUL goes inline (multipart included, raw with its CRLFs); anything else through base64.
            if body.contentEncoding == nil, let text = String(data: body.data, encoding: .utf8), !text.contains("\0") {
                args.append("--data-raw " + quote(text))
            } else {
                prefix += "printf %s " + quote(body.data.base64EncodedString()) + " | base64 -d | "
                args.append("--data-binary @-")
            }
        }
        return prefix + (["curl " + quote(flow.url)] + args).joined(separator: " \\\n  ")
    }

    /// POSIX single quotes: nothing inside is special; a ' becomes '\''.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}
