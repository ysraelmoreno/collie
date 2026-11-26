import Foundation

/// Fixed fragments of `ProtocolError.message` that code matches on (`ProtocolError` has no field for the kind of failure).
/// The producer and the matcher both use these constants and they are never translated: a message may be translated
/// around them, the fragment stays (idiomas Task 4). Fragments of an external tool's output (the design engine's
/// "no changes to publish", git's "failed to read … commondir", the Android helper's "node gone") are not ours to tag.
public enum ErrorTag {
    public static let promptNotDelivered = "prompt not delivered"
    public static let notAcceptingInput = "not accepting input"
    public static let didNotSubmit = "did not submit the prompt"
    /// A terminal that waits for the user's approval or dialog.
    public static let approval = "approval"
    public static let alreadyExists = "already exists"
    public static let isNameOfPanel = "is the name of panel"
    public static let alreadyLaunching = "already being launched"
    public static let noSlides = "no slides"
    public static let answered404 = "answered 404"
    public static let mitmExited = "mitmdump exited"
    /// Starts a refusal because another job holds the Android setup.
    public static let busy = "busy:"
    public static let noSuchPage = "no such page"
    public static let unknownCommand = "unknown command"
}
