//
//  TVDiagLog.swift
//  MeloNX tvOS
//
//  Diagnostics, kept small. Everything goes to the unified log (os.Logger, one
//  category per area, cheap when nobody is reading). Warnings, errors and the
//  few lifecycle lines needed to understand a failure afterwards are also
//  appended to Logs/tvos-app.log, which is what can be collected from the box.
//

import Foundation
import OSLog

enum DiagCategory: String {
    case lifecycle = "Lifecycle"
    case emulation = "Emulation"
    case memory = "Memory"
    case input = "Input"
    case storage = "Storage"
    case ui = "UI"
}

struct DiagLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.stossy11.MeloNX.tvos"
    private static let lock = NSLock()
    private static var loggers: [DiagCategory: Logger] = [:]

    private static func logger(for category: DiagCategory) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let existing = loggers[category] {
            return existing
        }
        let created = Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = created
        return created
    }

    /// `persist`: also write to tvos-app.log (lifecycle facts worth keeping).
    static func info(_ category: DiagCategory, _ action: String, traceId: String = "-", detail: String = "", persist: Bool = false) {
        logger(for: category).info("[\(traceId, privacy: .public)] \(action, privacy: .public) | \(detail, privacy: .public)")
        if persist { TVLog.file("\(category.rawValue) [\(traceId)] \(action)\(detail.isEmpty ? "" : " | \(detail)")") }
    }

    static func warn(_ category: DiagCategory, _ action: String, traceId: String = "-", detail: String = "") {
        logger(for: category).warning("[\(traceId, privacy: .public)] WARN \(action, privacy: .public) | \(detail, privacy: .public)")
        TVLog.file("\(category.rawValue) [\(traceId)] WARN \(action)\(detail.isEmpty ? "" : " | \(detail)")")
    }

    static func error(_ category: DiagCategory, _ action: String, traceId: String = "-", error: Error, detail: String = "") {
        let nsErr = error as NSError
        let text = "ERR \(action) | domain=\(nsErr.domain) code=\(nsErr.code) msg=\(nsErr.localizedDescription) | \(detail)"
        logger(for: category).error("[\(traceId, privacy: .public)] \(text, privacy: .public)")
        TVLog.file("\(category.rawValue) [\(traceId)] \(text)")
    }
}
