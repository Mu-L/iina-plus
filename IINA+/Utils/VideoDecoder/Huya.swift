//
//  Huya.swift
//  IINA+
//
//  Created by xjbeta on 4/22/22.
//  Copyright © 2022 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import SwiftSoup
import HuyaKit

actor Huya: SupportSiteProtocol {
    
	func liveInfo(_ url: String) async throws -> any LiveInfo {
		try await getHuyaInfo(url)
	}
	
    func decodeUrl(_ url: String) async throws -> YouGetJSON {
		try await getHuyaVideos(url)
	}
    
    // MARK: - Huya
    
    struct HuyaRoomList {
        var current: String
        var list = [VideoTreeNode]()
    }
    
    
    // href, name
    func getHuyaRoomList(_ url: String) async throws -> HuyaRoomList {
		let text = try await AF.request(url).serializingString().value
		var re = HuyaRoomList(current: "")
		
		try SwiftSoup.parse(text).getElementsByClass("match-nav").first()?.children().enumerated().forEach {
			
			if try $0.element.attr("class") == "on" {
				re.current = try $0.element.attr("href")
			}
			
			try re.list.append(VideoTreeNode(
				site: .huya,
				index: $0.offset,
				title: $0.element.text(),
				id: $0.element.attr("href"),
				url: "https://www.huya.com/\($0.element.attr("href"))",
				isLiving: $0.element.getChildNodes().contains(where: { try $0.attr("class") == "live" })
			))
		}
		return re
    }
	
	func getHuyaInfo(_ url: String) async throws -> HuyaStream.GameLiveInfo {
		let stream = try await getHuyaStream(url)
		
		guard let data = stream.data.first else {
			throw VideoGetError.notFountData
		}
		var info = data.liveInfo
		info.isLiving = data.streamInfoList.count > 0
		
		return info
	}
    
    func getHuyaVideos(_ url: String) async throws -> YouGetJSON {
		let stream = try await getHuyaStream(url)
		let yougetJson = YouGetJSON(rawUrl: url)
		return stream.write(to: yougetJson)
    }
	
	func getHuyaStream(_ url: String) async throws -> HuyaStream {
		let ucs = url.pathComponents
		guard ucs.count >= 3 else {
			throw VideoGetError.invalidLink
		}
		
		if let rid = Int(ucs[2]) {
			return try await HuyaStream.fetch(roomId: "\(rid)")
		}
		
		// Non-numeric path (e.g. /lpl): one fetch, the rid comes with the stream
		return try await HuyaStream.fetch(url: url)
	}
}

// MARK: - HuyaStream app extensions

extension HuyaStream {
	func write(to yougetJson: YouGetJSON) -> YouGetJSON {
		var yougetJson = yougetJson
		
		if let infoData = data.first {
			yougetJson.title = infoData.liveInfo.title
			yougetJson.id = infoData.liveInfo.rid
			
			let isLiving = infoData.streamInfoList.count > 0
			guard isLiving, infoData.liveInfo.rid > 0 else {
				return yougetJson
			}
			
			// Local proxy (.slice -> FLV); path token = uuid, matched by startPrewarm(uuid:)
			let port = Preferences.shared.dmPort
			let huyaUrl = "http://127.0.0.1:\(port)/huya/\(yougetJson.uuid).flv"
			
			// One entry per resolution (sDisplayName + iBitRate).
			// Resolution stays app-side (Stream.quality = iBitRate, 0 original -> 9999999),
			// never in the URL; open() passes rate to startPrewarm, the proxy
			// recognizes the tier via the /huya/{uuid}.flv session.
			// A resolution may exist as both H.264 and H.265 (same sDisplayName,
			// different iCodecType): when deduping same-name entries prefer 265
			var chosen: [String: StreamInfo] = [:]
			vMultiStreamInfo.forEach { info in
				if let cur = chosen[info.sDisplayName],
				   cur.iCodecType != 0 && info.iCodecType == 0 {
					return  // 265 already kept, skip 264
				}
				chosen[info.sDisplayName] = info
			}
			chosen.values.forEach { info in
				var s = Stream(url: huyaUrl)
				s.quality = info.iBitRate == 0 ? 9999999 : info.iBitRate
				yougetJson.streams[info.sDisplayName] = s
			}
			
			// Fallback: single "默认" entry when no resolution info is available
			if yougetJson.streams.isEmpty {
				var s = Stream(url: huyaUrl)
				s.quality = 9999999
				yougetJson.streams["默认"] = s
			}
		}
		
		return yougetJson
	}
}

extension HuyaStream.GameLiveInfo: LiveInfo {
	var site: SupportSites { .huya }
}

