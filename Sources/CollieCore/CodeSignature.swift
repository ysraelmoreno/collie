import Foundation
import Security

/// Developer ID checks shared by the daemon (the design engine, the downloaded dmg) and the app (the updated bundle).
public enum CodeSignature {
    /// Collie's Developer ID team (the OU of its Developer ID Application certificate).
    public static let team = "AG8JQAH6YB"

    /// Developer ID Application of `teamId`, with `identifier`.
    public static func requirement(identifier: String, teamId: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamId)\""
    }

    /// A disk image signed by `teamId` and notarized (the stapled ticket makes this hold offline).
    public static func dmgRequirement(teamId: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\" and notarized"
    }

    /// `path` satisfies the Developer ID requirement, strict, every architecture; `nested` also checks nested code.
    public static func signedByTeam(_ path: URL, identifier: String, teamId: String, nested: Bool = false) -> Bool {
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if nested { flags |= kSecCSCheckNestedCode }
        return check(path, requirement(identifier: identifier, teamId: teamId), flags)
    }

    public static func dmgNotarized(_ dmg: URL, teamId: String) -> Bool {
        check(dmg, dmgRequirement(teamId: teamId), kSecCSStrictValidate)
    }

    /// The app bundle (`dev.collie.app`, nested code included) and each helper under its own identifier.
    public static func appAndHelpers(_ app: URL, teamId: String) -> Bool {
        let helpers = app.appendingPathComponent("Contents/Helpers")
        return signedByTeam(app, identifier: "dev.collie.app", teamId: teamId, nested: true)
            && ["collied", "collie", "collie-ctty"].allSatisfy {
                signedByTeam(helpers.appendingPathComponent($0), identifier: $0, teamId: teamId)
            }
    }

    private static func check(_ path: URL, _ req: String, _ flags: UInt32) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: flags), requirement, nil) == errSecSuccess
    }
}
