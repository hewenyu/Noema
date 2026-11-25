import os

/// Unified logging for every Noema process, one `os.Logger` subsystem per component.
///
/// Privacy rule, at every level and every privacy annotation: never log raw keystrokes
/// (`KeyEvent.characters`, `NSEvent.characters`), `preedit`, candidates, or committed text.
/// Log lifecycle facts (boot, Safe Mode reason, process counts) and counts or booleans
/// about user input, never the input itself.
public enum NoemaLog {
    /// Logging subsystems, one per Noema component.
    public enum Subsystem: String, Sendable, CaseIterable {
        case ime = "dev.noema.ime"
        case engine = "dev.noema.engine"
        case cli = "dev.noema.cli"
        case deployer = "dev.noema.deployer"
    }

    public static func logger(subsystem: Subsystem, category: String) -> Logger {
        Logger(subsystem: subsystem.rawValue, category: category)
    }

    /// `NoemaIME` and its shell (`NoemaIMEShell`).
    public static func ime(_ category: String) -> Logger { logger(subsystem: .ime, category: category) }
    /// `NoemaEngine` and its Rime host.
    public static func engine(_ category: String) -> Logger { logger(subsystem: .engine, category: category) }
    /// `noema-cli`.
    public static func cli(_ category: String) -> Logger { logger(subsystem: .cli, category: category) }
    /// `noema-rime-deployer`.
    public static func deployer(_ category: String) -> Logger { logger(subsystem: .deployer, category: category) }
}
