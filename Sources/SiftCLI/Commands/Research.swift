import ArgumentParser
import Foundation
import SiftCore

/// Helpers shared by every research command. Each command opens its
/// own Store / AlephClient lazily — the CLI is short-lived, no point
/// keeping them around.

func openSessionStore() throws -> Store {
    try Session.openStore()
}

func emit(_ result: String) {
    print(result)
}
