import Foundation
import OSLog

public enum IdeaForgeLog {
    public static let subsystem = "com.s1kor.ideaforge"

    public static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    public static let recording = Logger(subsystem: subsystem, category: "Recording")
    public static let workspace = Logger(subsystem: subsystem, category: "Workspace")
    public static let workflow = Logger(subsystem: subsystem, category: "Workflow")
    public static let sync = Logger(subsystem: subsystem, category: "Sync")
    public static let export = Logger(subsystem: subsystem, category: "Export")
    public static let settings = Logger(subsystem: subsystem, category: "Settings")
}
