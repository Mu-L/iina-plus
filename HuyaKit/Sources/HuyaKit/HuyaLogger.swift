//
//  HuyaLogger.swift
//  HuyaKit
//
//  Injectable logger so HuyaKit stays independent of the host app.
//  The host sets `handler` once; the huyaproxy CLI points it at print.
//  Messages below `level` are dropped before reaching the handler.
//

import Foundation

public enum HuyaLogger {
    public enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case error = 2

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Host-provided log sink (defaults to no-op)
    nonisolated(unsafe) public static var handler: (@Sendable (String, Level) -> Void)?

    /// Only messages at or above this level reach the handler (default: .error)
    nonisolated(unsafe) public static var level: Level = .error

    public static func log(_ message: String, level: Level = .info) {
        guard level >= HuyaLogger.level else { return }
        handler?(message, level)
    }
}
