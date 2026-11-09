import Foundation

/// One line of a Claude terminal's chat body (`terminal.chat`): untrusted transcript content, already scrubbed of secrets.
public struct ChatEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, toolUse, toolResult }
    public var kind: Kind
    public var text: String            // message text; for toolResult the preview (≤ 8 KiB)
    public var tool: String?           // toolUse: the tool's name
    public var summary: String?        // toolUse: one line of its input (command, path, pattern…)
    public var toolId: String?         // toolUse id / the toolResult's tool_use_id
    public var old: String?, new: String?   // Edit/Write: the diff's sides (Write: old nil)
    public var isError: Bool?          // toolResult
    public var offset: UInt64          // the transcript byte where its line starts (stable id)
    public var id: String { "\(offset)-\(kind.rawValue)-\(toolId ?? "")-\(text.count)" }
    public init(kind: Kind, text: String = "", tool: String? = nil, summary: String? = nil, toolId: String? = nil,
                old: String? = nil, new: String? = nil, isError: Bool? = nil, offset: UInt64 = 0) {
        self.kind = kind; self.text = text; self.tool = tool; self.summary = summary; self.toolId = toolId
        self.old = old; self.new = new; self.isError = isError; self.offset = offset
    }
}
