//
//  BiliVideo.swift
//  iina+
//
//  Created by xjbeta on 2018/8/6.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal

actor BiliVideo: SupportSiteProtocol {
    
	func liveInfo(_ url: String) async throws -> any LiveInfo {
		let isBangumi = SupportSites(url: url) == .bangumi
		
		if isBangumi {
            return try await Bilibili.shared.bangumi.liveInfo(url)
		} else {
			let data = try await getBilibiliHTMLDatas(url)
			
			let initialStateJson: JSONObject = try JSONParser.JSONObjectWithData(data.initialStateData)
			
			var info = BilibiliInfo()
			info.title = try initialStateJson.value(for: "videoData.title")
			info.cover = try initialStateJson.value(for: "videoData.pic")
			info.cover = info.cover.https()
			info.name = try initialStateJson.value(for: "videoData.owner.name")
			info.isLiving = true
			
			return info
		}
	}
	
	func decodeUrl(_ url: String) async throws -> YouGetJSON {
		var re: YouGetJSON!
		if SupportSites(url: url) == .bangumi {
            re = try await Bilibili.shared.bangumi.decodeUrl(url)
		} else {
			re = try await getBilibili(url)
		}
		
		let ss = re.streams.filter {
			$0.value.url != nil && $0.value.url != ""
		}.max {
			$0.value.quality < $1.value.quality
		}
		
		if let ss {
			re.streams.filter {
				$0.value.quality > ss.value.quality
			}.forEach {
				re.streams[$0.key] = nil
			}
		}
		return re
	}
    
// MARK: - BiliVideo
    
    func getBilibili(_ url: String) async throws -> YouGetJSON {
        
        await Bilibili.shared.setBilibiliQuality()

		func decodeMobileHTML() async throws -> YouGetJSON {
			let datas = try await getBilibiliHTMLDatas(url)
			return try await decodeBilibiliDatas(
				url,
				playInfoData: datas.playInfoData,
				initialStateData: datas.initialStateData)
		}
		
		func decodeDesktopHTML() async throws -> YouGetJSON {
			let datas = try await getBilibiliDesktopHTMLDatas(url)
			return try await decodeBilibiliDatas(
				url,
				playInfoData: datas.playInfoData,
				initialStateData: datas.initialStateData)
		}
		
		func decodeAPI() async throws -> YouGetJSON {
			let json = try await bilibiliPrepareID(url)
			return try await Bilibili.shared.bilibiliPlayUrl(yougetJson: json)
		}
		
		let preferHTML = Preferences.shared.bilibiliHTMLDecoder
		
		if preferHTML {
			do { return try await decodeMobileHTML() } catch { Log("\(error), fallback") }
			do { return try await decodeDesktopHTML() } catch { Log("\(error), fallback") }
			return try await decodeAPI()
		} else {
			do { return try await decodeAPI() } catch { Log("\(error), fallback") }
			do { return try await decodeMobileHTML() } catch { Log("\(error), fallback") }
			return try await decodeDesktopHTML()
		}
    }
    
    func getBilibiliDesktopHTMLDatas(_ url: String) async throws -> (playInfoData: Data, initialStateData: Data) {
        let headers = HTTPHeaders(["Referer": "https://www.bilibili.com/",
                                   "User-Agent": Bilibili.shared.bilibiliUA])

        let response = try await AF.request(url, headers: headers).serializingString(automaticallyCancelling: true).response
        let re = response.value ?? ""
        
        let playinfoStrig = {
            var s = re.subString(from: "window.__playinfo__=", to: "</script>")
            if s == "" {
                s = re.subString(from: "const playurlSSRData = ", to: "\n")
            }
            return s
        }()
        
        let playInfoData = playinfoStrig.data(using: .utf8) ?? Data()
        let initialStateString = re.subString(from: "window.__INITIAL_STATE__=", to: ";(function()")
        let initialStateData = initialStateString.data(using: .utf8) ?? Data()
		
		return (playInfoData, initialStateData)
    }
    
    func getBilibiliHTMLDatas(_ url: String) async throws -> (playInfoData: Data, initialStateData: Data) {
        let mobileUa = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let mobileHeaders = HTTPHeaders([
            "Referer": "https://m.bilibili.com/",
            "User-Agent": mobileUa
        ])
        
        let mobileResponse = try await AF.request(url, headers: mobileHeaders).serializingString(automaticallyCancelling: true).response
        let mobileHtml = mobileResponse.value ?? ""
        
        let mobilePlayinfoStr = mobileHtml.subString(from: "window.__playinfo__=", to: "</script>")
        let mobileInitialStateStr = mobileHtml.subString(from: "window.__INITIAL_STATE__=", to: ";(function()")
        let mobilePlayInfoData = mobilePlayinfoStr.data(using: .utf8) ?? Data()
        let mobileInitialStateData = mobileInitialStateStr.data(using: .utf8) ?? Data()
        
        if mobileInitialStateData.count > 0,
           let json = try? JSONParser.JSONObjectWithData(mobileInitialStateData),
           json["videoData"] == nil,
           let video = try? BilibiliInitialStateVideo(object: json) {
            var normalized = json
            normalized["videoData"] = video.videoDataDictionary
            if let normalizedData = try? JSONSerialization.data(withJSONObject: normalized, options: []) {
                return (mobilePlayInfoData, normalizedData)
            }
        }
        
        if mobileInitialStateData.count > 0 || mobilePlayInfoData.count > 0 {
            return (mobilePlayInfoData, mobileInitialStateData)
        }
        
        return try await getBilibiliDesktopHTMLDatas(url)
    }
    
    func decodeBilibiliDatas(_ url: String,
                             playInfoData: Data,
                             initialStateData: Data) async throws -> YouGetJSON {
        var yougetJson = YouGetJSON(rawUrl: url)
        
		let playInfoJson: JSONObject = try JSONParser.JSONObjectWithData(playInfoData)
		let initialStateJson: JSONObject = try JSONParser.JSONObjectWithData(initialStateData)
		
		yougetJson.title = try initialStateJson.value(for: "videoData.title")
		yougetJson.duration = try initialStateJson.value(for: "videoData.duration")

		let pages: [JSONObject] = (try? initialStateJson.value(for: "videoData.pages")) ?? []
		let requestPage: Int? = (try? initialStateJson.value(for: "p")) ?? (try? initialStateJson.value(for: "video.p"))
		if pages.count > 1,
		   let pageIndex = requestPage,
		   pageIndex > 0,
		   pageIndex <= pages.count {
			let page = pages[pageIndex - 1]
			if let cid: Int = try? page.value(for: "cid"), cid > 0 {
				yougetJson.id = cid
			}
			if let part: String = try? page.value(for: "part"), part != "" {
				yougetJson.title = part
			}
		} else {
			yougetJson.id = try initialStateJson.value(for: "videoData.cid")
		}

		if let playInfo: BilibiliPlayInfo = try? playInfoJson.value(for: "data") {
			yougetJson = playInfo.write(to: yougetJson)
			return yougetJson
		} else if let info: BilibiliSimplePlayInfo = try? playInfoJson.value(for: "data") {
			yougetJson = info.write(to: yougetJson)
			return yougetJson
		} else {
			throw VideoGetError.notFindUrls
		}
    }
    
    func bilibiliPrepareID(_ url: String) async throws -> YouGetJSON {
        guard let bUrl = BilibiliUrl(url: url) else {
			throw VideoGetError.invalidLink
        }
        var json = YouGetJSON(rawUrl: url)
        json.site = .bilibili
        json.bvid = bUrl.id
        
        let eps = try await getVideoList(url)
        let pages = eps.flattened.flatMap { $0.children.filter(\.isLeaf) }
        guard let s = pages.first(where: { $0.bvid == bUrl.id && $0.index == bUrl.p })
                ?? pages.first(where: { $0.bvid == bUrl.id })
                ?? pages.first else { throw VideoGetError.notFountData }
        json.id = Int(s.id) ?? -1
        json.title = s.title
        json.duration = Int(s.duration)
        
        return json
    }
    
    
// MARK: - Bilibili Account API
    
    
    func biliVideoTreeNode(from json: MarshaledObject, bvid: String? = nil) throws -> VideoTreeNode {
        let cid: Int = try json.value(for: "cid")
        let id = "\(cid)"
        
        if let pic: String = try? json.value(for: "arc.pic") {
            return VideoTreeNode(
                site: .bilibili,
                title: try json.value(for: "title"),
                id: id,
                coverUrl: URL(string: pic),
                bvid: bvid ?? (try? json.value(for: "bvid")) ?? "",
                duration: (try? json.value(for: "arc.duration")) ?? 0,
                isCollection: true)
        } else {
            let page: Int = try json.value(for: "page")
            let part: String = try json.value(for: "part")
            let duration: Int = (try? json.value(for: "duration")) ?? 0
            return VideoTreeNode(
                site: .bilibili,
                index: page,
                title: part,
                id: id,
                bvid: bvid ?? "",
                duration: duration,
                isCollection: false)
        }
    }
    
    func getVideoList(_ url: String) async throws -> [VideoTreeNode] {
        var aid = -1
        var bvid = ""
        
        let pathComponents = URL(string: url)?.pathComponents ?? []
        guard pathComponents.count >= 3 else {
            throw VideoGetError.cantFindIdForDM
        }
        let idP = pathComponents[2]
        if idP.starts(with: "av"), let id = Int(idP.replacingOccurrences(of: "av", with: "")) {
            aid = id
        } else if idP.starts(with: "BV") {
            bvid = idP
        } else {
			throw VideoGetError.cantFindIdForDM
        }
        
        var r: DataRequest
        if aid != -1 {
            r = AF.request("https://api.bilibili.com/x/web-interface/view?aid=\(aid)")
        } else if bvid != "" {
            r = AF.request("https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)")
        } else {
			throw VideoGetError.cantFindIdForDM
        }
		
		let data = try await r.serializingData().value
		let json: JSONObject = try JSONParser.JSONObjectWithData(data)
		
		if let sectionsJSON: [JSONObject] = try? json.value(for: "data.ugc_season.sections") {
			let seasonTitle: String? = try? json.value(for: "data.ugc_season.title")
			var sections: [VideoTreeNode] = []
			for sec in sectionsJSON {
				guard let episodes: [JSONObject] = try? sec.value(for: "episodes") else { continue }
				var singlePageNodes: [VideoTreeNode] = []
				var multiPageSections: [VideoTreeNode] = []
				for ep in episodes {
					guard let bvid: String = try? ep.value(for: "bvid") else { continue }
					if let pagesJSON: [JSONObject] = try? ep.value(for: "pages"), pagesJSON.count > 1 {
						let items: [VideoTreeNode] = pagesJSON.compactMap { pageJSON in
							try? biliVideoTreeNode(from: pageJSON, bvid: bvid)
						}
						guard !items.isEmpty else { continue }
						let epTitle: String = (try? ep.value(for: "title")) ?? ""
						multiPageSections.append(VideoTreeNode(title: epTitle, children: items))
					} else {
						guard let node = try? biliVideoTreeNode(from: ep) else { continue }
						singlePageNodes.append(node)
					}
				}
				if !singlePageNodes.isEmpty {
					sections.append(VideoTreeNode(title: seasonTitle ?? "", children: singlePageNodes))
				}
				sections.append(contentsOf: multiPageSections)
			}
			if !sections.isEmpty { return sections }
		}
		
		let pagesArray: [JSONObject] = try json.value(for: "data.pages")
		let bvidStr: String = try json.value(for: "data.bvid")
		let mainTitle: String = try json.value(for: "data.title")
		let pageSelectors: [VideoTreeNode] = try pagesArray.enumerated().map { (i, pageJSON) in
			let node = try biliVideoTreeNode(from: pageJSON, bvid: bvidStr)
			guard pagesArray.count == 1 else { return node }
			return VideoTreeNode(
				site: .bilibili,
				index: node.index,
				title: mainTitle,
				id: node.id,
				coverUrl: node.coverUrl,
				bvid: node.bvid,
				duration: node.duration,
				isCollection: node.isCollection)
		}
		return [VideoTreeNode(title: "", children: pageSelectors)]
	}
}

struct BilibiliInitialStateVideo: Unmarshaling {
    let title: String
    let pic: String
    let ownerName: String
    let pages: [BilibiliVideoPage]
    let cid: Int
    let duration: Int
    let bvid: String
    
    init(object: MarshaledObject) throws {
        let prefix: String
        if (try? object.value(for: "videoData.title") as String) != nil {
            prefix = "videoData"
        } else {
            prefix = "video.viewInfo"
        }
        title = try object.value(for: "\(prefix).title")
        pic = try object.value(for: "\(prefix).pic")
        ownerName = try object.value(for: "\(prefix).owner.name")
        pages = try object.value(for: "\(prefix).pages")
        cid = try object.value(for: "\(prefix).cid")
        duration = try object.value(for: "\(prefix).duration")
        bvid = try object.value(for: "\(prefix).bvid")
    }
    
    var videoDataDictionary: [String: Any] {
        [
            "title": title,
            "pic": pic,
            "owner": ["name": ownerName],
            "pages": pages.map(\.dictionaryValue),
            "cid": cid,
            "duration": duration,
            "bvid": bvid
        ]
    }
}

struct BilibiliVideoPage: Unmarshaling {
    let page: Int
    let part: String
    let cid: Int
    
    init(object: MarshaledObject) throws {
        page = try object.value(for: "page")
        part = try object.value(for: "part")
        cid = try object.value(for: "cid")
    }
    
    var dictionaryValue: [String: Any] {
        ["page": page, "part": part, "cid": cid]
    }
}
