//
//  HuyaError.swift
//  HuyaKit
//

import Foundation

enum HuyaError: Error, CustomStringConvertible {
    case parseError(String)
    case httpError(Int)
    case streamError(String)

    var description: String {
        switch self {
        case .parseError(let msg): return "parse error: \(msg)"
        case .httpError(let code): return "HTTP \(code)"
        case .streamError(let msg): return "stream error: \(msg)"
        }
    }
}
