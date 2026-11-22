import Foundation

/// The frame a Device panel draws around the screen, by device type (PRD D1, docs/superpowers/roadmap/2026-11-22-device-molduras).
/// Stored by the daemon as the panel's `state["frame"]`; a panel without it is `bare`.
public enum DeviceFrame {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case phone, fold, tablet, island, classic, ipad, bare
    }

    /// Old tablet profiles whose `hw.device.name` lacks "tablet".
    static let oldTablets: Set<String> = ["pixel_c", "nexus_9", "nexus_10"]

    /// An Android device's frame from its AVD's `hw.device.name`; a physical device (`emulator == false`) is `bare`.
    public static func android(hwDeviceName: String?, emulator: Bool) -> Kind {
        guard emulator else { return .bare }
        let n = (hwDeviceName ?? "").lowercased()
        if n.contains("fold") { return .fold }
        if n.contains("tablet") || oldTablets.contains(n) { return .tablet }
        return .phone
    }

    /// A simulator's frame from simctl's `deviceTypeIdentifier` (`com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro`).
    public static func ios(deviceTypeIdentifier: String?) -> Kind {
        guard let id = deviceTypeIdentifier, let t = id.split(separator: ".").last.map(String.init) else { return .bare }
        if t.contains("iPad") { return .ipad }
        guard t.hasPrefix("iPhone-") else { return .bare }
        if t.contains("iPhone-SE") { return .classic }
        let classic = ["iPhone-6", "iPhone-6s", "iPhone-7", "iPhone-8"]
        if classic.contains(where: { t == $0 || t == $0 + "-Plus" }) { return .classic }
        return .island
    }

    /// `hw.device.name` from an AVD's config.ini text (`key=value`, any spacing); nil when absent or empty.
    public static func hwDeviceName(configIni: String) -> String? {
        for line in configIni.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "hw.device.name", !kv[1].isEmpty { return kv[1] }
        }
        return nil
    }
}
