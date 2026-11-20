import Foundation
import VizinhoKit

// Helper of the Vizinho plug-in: one event on stdin, one verdict on stdout. Any failure is `{}` and exit 0.
FileHandle.standardOutput.write(Vizinho.respond(eventJSON: FileHandle.standardInput.readDataToEndOfFile()))
