import Foundation
import CollieProtocol
#if canImport(FoundationModels)
import FoundationModels
#endif

enum LocalModelAvailability: Equatable, Sendable {
    case available
    /// Why not, in Portuguese (shown to the user).
    case unavailable(String)
}

/// An on-device language model. Never the network: the only implementation is FoundationModels.
protocol LocalModel: Sendable {
    func availability() async -> LocalModelAvailability
    func respond(instructions: String, prompt: String, tools: [AssistantTool]) async throws -> String
}

/// A tool the model may call with one text argument.
struct AssistantTool: Sendable {
    let name: String
    let description: String
    let run: @Sendable (_ argument: String) async -> String
}

/// Apple's on-device model (macOS 26, Apple Intelligence). On macOS 15, or built without the SDK, it is unavailable.
/// The framework is linked weakly (`@available` + `canImport`), so the binary still loads where it does not exist.
struct FoundationLocalModel: LocalModel {
    static let needsMacOS26 = "precisa do macOS 26"

    func availability() async -> LocalModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return Self.map(SystemLanguageModel.default.availability) }
        #endif
        return .unavailable(Self.needsMacOS26)
    }

    func respond(instructions: String, prompt: String, tools: [AssistantTool]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            // a new session a call: no history between questions
            let session = LanguageModelSession(tools: tools.map(FoundationTool.init), instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw ProtocolError(code: .unavailable, message: Self.needsMacOS26)
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    static func map(_ a: SystemLanguageModel.Availability) -> LocalModelAvailability {
        switch a {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("este Mac não suporta Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence está desligada")
        case .unavailable(.modelNotReady): return .unavailable("o modelo ainda está sendo baixado")
        case .unavailable: return .unavailable(Self.needsMacOS26)   // a reason newer than this SDK
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private struct FoundationTool: Tool {
    let tool: AssistantTool
    var name: String { tool.name }
    var description: String { tool.description }

    @Generable struct Arguments {
        @Guide(description: "O que consultar") let query: String
    }

    func call(arguments: Arguments) async throws -> String { await tool.run(arguments.query) }
}
#endif
