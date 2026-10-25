import WebKit

/// What every Collie web panel that must stay offline (external plug-ins, Diagram, Design) sets on its configuration
/// on top of its content rules. WebRTC goes first: ICE traffic (STUN/TURN, DNS) is not a resource load, so neither a
/// `WKContentRuleList` nor a CSP sees it. Its switch is a private preference, so `peerConnectionsOff` checks the result
/// in the view's empty initial document before anything loads, and the panel refuses to load (fails closed) when WebRTC
/// is still there.
enum WebLockdown {
    static let failure = "bloqueio de rede indisponível"

    static func harden(_ c: WKWebViewConfiguration) {
        // ponytail: private key (WebKit's own name); if a WebKit drops it, `peerConnectionsOff` fails closed
        let p = c.preferences
        if p.responds(to: NSSelectorFromString("setPeerConnectionEnabled:")) || p.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) {
            p.setValue(false, forKey: "peerConnectionEnabled")
        }
    }

    /// True when the page world has no `RTCPeerConnection` (nor the prefixed one).
    @MainActor static func peerConnectionsOff(_ web: WKWebView) async -> Bool {
        let r = try? await web.callAsyncJavaScript(
            "return typeof RTCPeerConnection === 'undefined' && typeof webkitRTCPeerConnection === 'undefined'", contentWorld: .page)
        return (r as? Bool) == true
    }
}
