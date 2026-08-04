//
//  Huya.swift
//  HuyaKit
//
//  Live room info: PC webpage fetch + typed stream models.
//  - Marshal: JSON parsing (same model shape as iina-plus Huya.swift)
//  - SwiftSoup: locate the <script> holding the stream JSON
//  - Alamofire: HTTP requests
//

import Foundation
import Alamofire
import Marshal
import SwiftSoup

// MARK: - HuyaStream

public struct HuyaStream: Unmarshaling, Sendable {
    public var data: [InfoData]
    public var vMultiStreamInfo: [StreamInfo]
    /// Top-level bitRate from the page (not part of the stream JSON)
    public var bitRate: Int = 0

    public init(object: any MarshaledObject) throws {
        data = try object.value(for: "data")
        vMultiStreamInfo = try object.value(for: "vMultiStreamInfo")
    }

    /// Fetch stream info from the Huya PC webpage (full URL)
    public static func fetch(url: String) async throws -> HuyaStream {
        let html = try await AF.request(url).serializingString().value

        // Locate the stream JSON inside a <script> via SwiftSoup, then
        // brace-match the value (skips braces inside strings)
        let doc = try SwiftSoup.parse(html)
        for script in try doc.getElementsByTag("script") {
            let content = script.data()
            guard let idx = content.range(of: "stream:") else { continue }

            guard let jsonSubstring = braceMatchedJSON(content, after: idx.upperBound),
                  let jsonData = jsonSubstring.data(using: .utf8) else {
                continue
            }
            let jsonObj: JSONObject = try JSONParser.JSONObjectWithData(jsonData)
            var stream: HuyaStream = try HuyaStream(object: jsonObj)
            stream.bitRate = html.bitRateValue()
            return stream
        }

        throw HuyaError.parseError("stream field not found")
    }

    /// Fetch stream info from the Huya PC webpage (roomId)
    public static func fetch(roomId: String) async throws -> HuyaStream {
        try await fetch(url: "https://www.huya.com/\(roomId)")
    }

    /// First gameStreamInfo entry (sP2pUrl/sStreamName/sP2pAntiCode)
    public var primaryStream: GameStreamInfo? {
        data.first?.streamInfoList.first
    }

    /// Top-level codecType (gameLiveInfo.codecType, basis of official isH265CodecType)
    public var codecType: Int {
        data.first?.liveInfo.codecType ?? 0
    }

    static func braceMatchedJSON(_ s: String, after: String.Index) -> String? {
        let afterStream = s[after...]
        guard let braceStart = afterStream.firstIndex(of: "{") else { return nil }

        var depth = 0
        var end = braceStart
        var inStr = false
        var escape = false
        var i = braceStart
        while i < afterStream.endIndex {
            let c = afterStream[i]
            if escape { escape = false; i = afterStream.index(after: i); continue }
            if c == "\\" { escape = true; i = afterStream.index(after: i); continue }
            if c == "\"" { inStr.toggle(); i = afterStream.index(after: i); continue }
            if inStr { i = afterStream.index(after: i); continue }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = afterStream.index(after: i); break }
            }
            i = afterStream.index(after: i)
        }
        return String(afterStream[braceStart..<end])
    }

    public struct StreamInfo: Unmarshaling, Sendable {
        public var sDisplayName: String
        public var iBitRate: Int
        public var iCodecType: Int
        public var iCompatibleFlag: Int
        public var iHEVCBitRate: Int

        public init(object: any MarshaledObject) throws {
            sDisplayName = try object.value(for: "sDisplayName")
            iBitRate = try object.value(for: "iBitRate")
            iCodecType = try object.value(for: "iCodecType")
            iCompatibleFlag = try object.value(for: "iCompatibleFlag")
            iHEVCBitRate = try object.value(for: "iHEVCBitRate")
        }
    }

    public struct InfoData: Unmarshaling, Sendable {
        public var liveInfo: GameLiveInfo
        public var streamInfoList: [GameStreamInfo]

        public init(object: any MarshaledObject) throws {
            liveInfo = try object.value(for: "gameLiveInfo")
            streamInfoList = try object.value(for: "gameStreamInfoList")
        }
    }

    public struct GameLiveInfo: Unmarshaling, Sendable {
        public var title: String = ""
        public var name: String = ""
        public var isLiving = false
        public var avatar: String
        public var rid: Int
        public var cover: String = ""
        public let uid: Int
        public var isSeeTogetherRoom = false
        public let isSecret: Int
        /// Top-level codecType, basis of official isH265CodecType()
        public var codecType: Int = 0

        public init(object: any MarshaledObject) throws {
            let name1: String = try object.value(for: "roomName")
            let name2: String = try object.value(for: "introduction")

            title = name1 == "" ? name2 : name1
            name = try object.value(for: "nick")

            avatar = try object.value(for: "avatar180")
            avatar = avatar.https()
            rid = try object.value(for: "profileRoom")
            cover = try object.value(for: "screenshot")
            cover = cover.https()

            if let uid: Int = try? object.value(for: "uid") {
                self.uid = uid
            } else if let uid: String = try? object.value(for: "uid"),
                      let iuid = Int(uid) {
                self.uid = iuid
            } else {
                throw MarshalError.keyNotFound(key: "huya.GameLiveInfo.uid")
            }

            isSecret = try object.value(for: "isSecret")
            let gameHostName: String = try object.value(for: "gameHostName")
            isSeeTogetherRoom = gameHostName == "seeTogether"
            codecType = (try? object.value(for: "codecType")) ?? 0
        }
    }

    public struct GameStreamInfo: Unmarshaling, Sendable {
        public var sStreamName: String
        public var sP2pUrl: String
        public var sP2pAntiCode: String

        public init(object: any MarshaledObject) throws {
            sStreamName = try object.value(for: "sStreamName")
            sP2pUrl = try object.value(for: "sP2pUrl")
            sP2pAntiCode = try object.value(for: "sP2pAntiCode")
        }
    }
}

extension String {
    func https() -> String {
        replacingOccurrences(of: "http://", with: "https://")
    }

    /// Page-level bitRate (official page layout, e.g. "bitRate":4000)
    func bitRateValue() -> Int {
        guard let range = range(of: #""bitRate":(\d+)"#, options: .regularExpression),
              let num = self[range].split(separator: ":").last else {
            return 0
        }
        return Int(num) ?? 0
    }
}
