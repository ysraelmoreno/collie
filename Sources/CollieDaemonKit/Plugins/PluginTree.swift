import Foundation
import CollieProtocol

/// `collie plugin tree-hash` (PRD M4): the CI computes a catalog's `treeSha256` with the install's own `scan` (limits,
/// no links, no special files) and `treeHash`, so it is the number installed.json pins.
public enum PluginTree {
    public static func hash(_ root: URL) throws(ProtocolError) -> String {
        try PluginStore.treeHash(root, PluginStore.scan(root))
    }
}
