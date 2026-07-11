//
//  Danmaku.swift
//  iina+
//
//  Created by xjbeta on 2018/10/27.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal
import Gzip
import JavaScriptCore
import CryptoSwift
import Marshal
import SDWebImage

protocol DanmakuDelegate {
    @MainActor func send(_ event: DanmakuEvent, sender: Danmaku)
}

protocol DanmakuSubDelegate {
    @MainActor func send(_ event: DanmakuEvent)
}

@MainActor
class Danmaku: NSObject {
    var socket: WebSocketClient? = nil
    var liveSite: SupportSites = .unsupported
    var url = ""
    var id = ""
    var delegate: DanmakuDelegate?
    
    private var heartBeatCount = 0
    private var eventLoopTask: Task<Void, Never>?
    
    let biliLiveServer = URL(string: "wss://broadcastlv.chat.bilibili.com:443/sub")
	var biliLiveIDs = (rid: "", token: "", uid: 1)
    var bililiveEmoticons = [BiliLiveEmoticon]()
    
    let douyuBlockList = [
        "#挑战666#",
        "#签到",
        "#超管来了#",
        "#让火箭飞#",
        "#消消乐#"
    ]
    
    let douyuServer = URL(string: "wss://danmuproxy.douyu.com:8506")
    var douyuRoomID = ""
    var douyuSavedData = Data()
    
    let huyaBlockList = [
        "分享了直播间，房间号",
        "录制并分享了小视频",
        "进入直播间",
        "刚刚在打赏君活动中",
        "竟然抽出了",
        "车队召集令在此",
        "微信公众号“虎牙志愿者”",
    ]
    let huyaServer = URL(string: "wss://wsapi.huya.com")
    var huyaAnchorUid = -1
    let huyaJSContext = JSContext()
    
    struct HuYaDanmuMsg: Decodable {
        let ePushType: Int
        let iUri: Int
        let sMsg: String
        let iProtocolType: Int
        let sGroupId: String
        let lMsgId: String
    }

    let cc163Server = URL(string: "wss://weblink.cc.163.com")
    
    var socketClosed = false
    
    var douyinDM: DouYinDM?
    
    let qieTVDMServer = URL(string: "wss://node-18-danmaku.qiecdn.com/sub")
    var qieTVSeq: UInt32 = 0
    var qieTVRoomID: String = ""
    

    init(_ url: String) {
        liveSite = .init(url: url)
        self.url = url
        
        switch liveSite {
        case .huya:
            if let huyaFilePath = Bundle.main.path(forResource: "huya", ofType: "js") {
                huyaJSContext?.evaluateScript(try? String(contentsOfFile: huyaFilePath))
            } else {
                Log("Not found huya.js.")
            }
        default:
            break
        }
    }
    
    func stop() {
		Log("Stop Danmaku")
        eventLoopTask?.cancel()
		
        Task { await socket?.close() }
        socket = nil
        stopHeartbeat()
        douyuSavedData = Data()
        heartBeatCount = 0
        
		Task {
			douyinDM?.stop()
			douyinDM = nil
		}
    }

	func loadDM() async {
		do {
			try await loadDanmaku()
		} catch let error {
			Log("loadDM failed, \(error)")
		}
	}
	
    
	func loadDanmaku() async throws {
        guard let url = URL(string: self.url) else { return }
        let roomID = url.lastPathComponent
        let videoDecoder = Processes.shared.videoDecoder
        switch liveSite {
        case .biliLive:

			let rid = try await self.bililiveRid(roomID)
			let token = try await bililiveToken(rid)
			let emoticons = try await bililiveEmoticons(rid)
			let uid = try await Bilibili.shared.getUid()
			
			biliLiveIDs.rid = rid
				biliLiveIDs.token = token
				bililiveEmoticons = emoticons
				biliLiveIDs.uid = uid
				let ws = WebSocketClient()
				await runEventLoop(ws, url: biliLiveServer!)
        case .douyu:
            
            Log("Processes.shared.videoDecoder.getDouyuHtml")
			
			let info = try await videoDecoder.douyu.getDouyuHtml(url.absoluteString)
            await initDouYuSocket(info.roomId)
			
        case .huya:
			let str = try await AF.request(url.absoluteString).serializingString().value
			let js = str.subString(from: "var TT_ROOM_DATA = ", to: "};")
			let roomData = (js + "}").data(using: .utf8) ?? Data()
			let roomInfo: JSONObject = try JSONParser.JSONObjectWithData(roomData)

				if let id: String = try? roomInfo.value(for: "id"),
					let uid = Int(id) {
					self.huyaAnchorUid = uid
				} else {
					self.huyaAnchorUid = try roomInfo.value(for: "id")
				}

				let ws = WebSocketClient()
				await runEventLoop(ws, url: self.huyaServer!)

		case .douyin:
		douyinDM = .init()
			douyinDM?.requestPrepared = { request in
				let ws = WebSocketClient()
				Task { await self.runEventLoop(ws, request: request) }
			}
			douyinDM?.start(self.url)
			socketClosed = false
			startHeartbeat()
		case .qieTV:
			let ws = WebSocketClient()
			await runEventLoop(ws, url: qieTVDMServer!)
        default:
            break
        }
    }
    
    func sendMsg(_ data: Data) async {
        try? await socket?.send(data: data)
    }
    
    private func sendDM(_ event: DanmakuEvent) {
        if event.method == .sendDM,
           let dms = event.dms,
           dms.count == 0 {
            return
        }
        delegate?.send(event, sender: self)
    }
    
    private func initDouYuSocket(_ roomID: String) async {
        Log("initDouYuSocket")
        douyuRoomID = roomID
		let ws = WebSocketClient()
		await runEventLoop(ws, url: self.douyuServer!)
    }
    
    private func douyuSocketFormatter(_ str: String) -> Data {
        let str = str + "\0"
        let data = pack(format: "VVV", values: [str.count + 8, str.count + 8, 689])
        data.append(str.data(using: .utf8) ?? Data())
        return data as Data
    }
    
    
    private var heartbeatTask: Task<Void, Never>?
    
    @MainActor
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval: Duration = liveSite == .douyin ? .seconds(15) : .seconds(30)
        heartBeatCount = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                do {
                    switch self.liveSite {
                    case .biliLive:
                        let data = self.pack(format: "NnnNN", values: [16, 16, 1, 2, 1]) as Data
                        try await self.socket?.send(data: data)
                    case .douyu:
                        let keeplive = "type@=mrkl/"
                        let data = self.douyuSocketFormatter(keeplive)
                        try await self.socket?.send(data: data)
                    case .huya:
                        let result = self.huyaJSContext?.evaluateScript("new Uint8Array(sendHeartBeat());")
                        let data = Data(result?.toArray() as? [UInt8] ?? [])
                        await self.sendMsg(data)
                    case .douyin:
                        guard self.socket != nil else { return }
                        if self.socketClosed {
                            Log("Reconnect douyin dm")
                            self.stop()
                            await self.loadDM()
                            return
                        }
                        var pf = Douyin_PushFrame()
                        pf.payloadType = "hb"
                        try await self.socket?.send(data: pf.serializedData())
                    case .qieTV:
                        self.qieTVSeq += 1
						try await self.socket?.send(data: self.qieTVPacket(op: 2, body: Data()))
                    default:
                        try await self.socket?.sendPing()
                    }
                    if liveSite != .douyin {
                        await self.incrementHeartbeat()
                    }
                } catch {
                    if (error as NSError).code == 2134 {
                        Log("Danmaku Error 2134, restart.")
                        self.stop()
                        await self.loadDM()
                    } else {
                        Log("Heartbeat error: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    private func incrementHeartbeat() async {
        heartBeatCount += 1
        if heartBeatCount > 5 {
            Log("HeartBeat no response, restart: \(url)")
            stop()
            await loadDM()
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }


	@MainActor
	private func runEventLoop(_ ws: WebSocketClient, url: URL) async {
		var request = URLRequest(url: url)
		request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3.1 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
		await runEventLoop(ws, request: request)
	}

	@MainActor
	private func runEventLoop(_ ws: WebSocketClient, request: URLRequest) async {
		eventLoopTask?.cancel()
		await socket?.close()
		_ = await eventLoopTask?.result
		socket = ws
		eventLoopTask = Task { @MainActor in
			for await event in await ws.open(request) {
				switch event {
				case .didOpen:
					await handleWebSocketOpen()
				case .message(let data):
					handleWebSocketMessage(data)
				case .close(_, let reason, _):
					Log("webSocketdidClose \(reason ?? "")")
					switch liveSite {
					case .biliLive:
						stopHeartbeat()
					case .douyin:
						socketClosed = true
					default:
						break
					}
					delegate?.send(.init(method: .liveDMServer, text: "error"), sender: self)
				case .error(let desc):
					Log(desc)
					switch liveSite {
					case .douyin:
						socketClosed = true
					default:
						break
					}
					delegate?.send(.init(method: .liveDMServer, text: "error"), sender: self)
				}
			}
		}
	}
	

	@MainActor
	private func handleWebSocketOpen() async {
		Log("webSocketDidOpen")
		switch liveSite {
		case .biliLive:
			let buvid = UUID().uuidString + "\(Int.random(in: 10000...90000))" + "infoc"
			let key = biliLiveIDs.token
			let json = "{\"uid\":\(biliLiveIDs.uid),\"roomid\":\(biliLiveIDs.rid),\"protover\":2,\"buvid\":\"\(buvid)\",\"platform\":\"web\",\"type\":2,\"key\":\"\(key)\"}"
			let data = pack(format: "NnnNN", values: [json.count + 16, 16, 1, 7, 1])
			data.append(json.data(using: .utf8)!)
			await sendMsg(data as Data)
			startHeartbeat()
		case .huya:
			let id = huyaAnchorUid
			let result = huyaJSContext?.evaluateScript("""
new Uint8Array(sendRegisterGroups(["live:\(id)", "chat:\(id)"]));
""")
			let data = Data(result?.toArray() as? [UInt8] ?? [])
			await sendMsg(data)
			startHeartbeat()
		case .douyu:
			let loginreq = "type@=loginreq/roomid@=\(douyuRoomID)/"
			let joingroup = "type@=joingroup/rid@=\(douyuRoomID)/gid@=-9999/"
			await sendMsg(douyuSocketFormatter(loginreq))
			await sendMsg(douyuSocketFormatter(joingroup))
			startHeartbeat()
		case .qieTV:
			qieTVSeq = 1
			let rid = URL(string: self.url)?.lastPathComponent ?? ""
			qieTVRoomID = rid
			let json = """
			{"uid":0,"token":"","roomId":"online://\(rid)","deviceId":"\(UUID().uuidString)","platform":"pc_web","unAccepts":[]}
			"""
			await sendMsg(qieTVPacket(op: 7, body: json.data(using: .utf8)!))
		default:
			break
		}
	}

	@MainActor
	private func handleWebSocketMessage(_ data: Data) {
		switch liveSite {
		case .biliLive:
			if data.count == 20 {
				heartBeatCount = 0
				return
			} else if data.count == 26 {
				Log("bililive connect success")
				self.delegate?.send(.init(method: .liveDMServer, text: ""), sender: self)
				return
			}

			func checkIntegrity(_ data: Data) -> Data? {
				var d = data
				var r = PacketReader(data: d)
				guard let raw = r.readUInt32() else { return nil }
				let count = Int(raw)
				guard count == data.count else {
					Log("BiliLive Checking for integrity failed.")
					return nil
				}
				d = d.subdata(in: 16..<count)
				do {
					return try d.gunzipped()
				} catch let error {
					if let str = String(data: data, encoding: .utf8), str.contains("cmd") {
						return nil
					} else if let str = String(data: d, encoding: .utf8), str.contains("cmd") {
						return nil
					} else {
						Log("decode bililive msg error \(error)")
					}
				}
				return nil
			}

			var datas: [Data] = []
			guard var d = checkIntegrity(data) else { return }
			while d.count > 20 {
				var r2 = PacketReader(data: d)
				guard let raw = r2.readUInt32() else { break }
				let endIndex = Int(raw)
				if endIndex <= d.endIndex {
					datas.append(d.subdata(in: 16..<endIndex))
					d = d.subdata(in: endIndex..<d.endIndex)
				} else {
					d.removeAll()
				}
			}

			let dms = datas.compactMap(decodeBiliLiveDM(_:))
			if !dms.isEmpty {
				sendDM(.init(method: .sendDM, text: "", dms: dms))
			}
		case .huya:
			let bytes = [UInt8](data)
			guard let re = huyaJSContext?.evaluateScript("test(\(bytes));"),
				  re.isString,
				  let str = re.toString() else {
				return
			}

			if str == "EWebSocketCommandType.EWSCmdS2C_RegisterGroupRsp" {
				Log("huya connect success")
				self.delegate?.send(.init(method: .liveDMServer, text: ""), sender: self)
				return
			} else if str.starts(with: "EWebSocketCommandType") {
				guard str != "EWebSocketCommandType.EWSCmdS2C_MsgPushReq_V2" else { return }
				Log("huya websocket info \(str)")
				return
			} else if str == "EWebSocketCommandType.EWSCmdS2C_HeartBeatRsp" {
				heartBeatCount = 0
				return
			}

			guard let data = str.data(using: .utf8),
				  let msg = try? JSONDecoder().decode(HuYaDanmuMsg.self, from: data) else {
				Log("huya msg unknown \(str)")
				return
			}

			if msg.ePushType == 5,
			   msg.iUri == 1400,
			   msg.iProtocolType == 2,
			   !huyaBlockList.contains(where: msg.sMsg.contains) {
				let dm = DanmakuComment(text: msg.sMsg)
				sendDM(.init(method: .sendDM, text: "", dms: [dm]))
			}
		case .douyu:
			var d = data
			if douyuSavedData.count != 0 {
				douyuSavedData.append(d)
				d = douyuSavedData
				douyuSavedData = Data()
			}

			var msgDatas: [Data] = []
			while d.count > 12 {
				var r3 = PacketReader(data: d)
				guard let raw = r3.readUInt32(endianness: .little) else { break }
				let endIndex = Int(raw)
				if d.count < endIndex+2 {
					douyuSavedData.append(douyuSavedData)
					d = Data()
				} else {
					guard endIndex+2 > 12, endIndex+2 < d.endIndex else {
						Log("endIndex out of range.")
						return
					}
					let msg = d.subdata(in: 12..<endIndex+2)
					msgDatas.append(msg)
					d = d.subdata(in: endIndex+2..<d.endIndex)
				}
			}

			var dms = [DanmakuComment]()
			msgDatas.forEach {
				guard let msg = String(data: $0, encoding: .utf8) else { return }
				if msg.starts(with: "type@=chatmsg") {
					if !msg.contains("dms@=") { return }
					let dm = msg.split(separator: "/").filter { $0.starts(with: "txt@=") }
						.filter { !douyuBlockList.contains(where: $0.contains) }.first
					if let dm = dm {
						dms.append(.init(text: String(dm.dropFirst("txt@=".count))))
					}
				} else if msg.starts(with: "type@=error") {
					Log("douyu socket disconnected: \(msg)")
					self.delegate?.send(.init(method: .liveDMServer, text: "error"), sender: self)
					Task { await socket?.close() }
				} else if msg.starts(with: "type@=loginres") {
					Log("douyu content success")
					self.delegate?.send(.init(method: .liveDMServer, text: ""), sender: self)
				} else if msg == "type@=mrkl" {
					heartBeatCount = 0
				}
			}
			sendDM(.init(method: .sendDM, text: "", dms: dms))
		case .douyin:
			do {
				let re = try DouYinResponse(serializedBytes: data)
				let ree = try Douyin_Response(serializedBytes: re.data.gunzipped())
				let dms = ree.messagesList.filter { $0.method == "WebcastChatMessage" }.compactMap {
					try? Douyin_ChatMessage(serializedBytes: $0.payload)
				}.map { DanmakuComment(text: $0.content) }
				sendDM(.init(method: .sendDM, text: "", dms: dms))
				guard ree.needAck else { return }
				var pf = Douyin_PushFrame()
				pf.payloadType = "ack"
				pf.logID = UInt64(re.wssPushLogID)
				let payload: [UInt8] = {
					var t = [UInt8]()
					func push(_ e: UInt32) {
						t.append(UInt8(e))
					}
					ree.internalExt.unicodeScalars.forEach {
						let e = $0.value
						switch e {
						case _ where e < 128: push(e)
						case _ where e < 2048: push(192 + (e >> 6)); push(128 + (63 & e))
						case _ where e < 65536: push(224 + (e >> 12)); push(128 + (e >> 6 & 63)); push(128 + (63 & e))
						default: break
						}
					}
					return t
				}()
				pf.payload = Data(payload)
				Task { try? await socket?.send(data: pf.serializedData()) }
			} catch let error {
				Log("\(error)")
			}
		case .qieTV:
			var reader = PacketReader(data: data)
			guard let totalLen = reader.readInt32(),
				  let headerLen = reader.readInt16() else { return }
			reader.skip(2) // version
			guard let op = reader.readInt32() else { return }
			reader.skip(4) // seq
			if op == 9 {
				while reader.available > 0 {
					guard let subTotal = reader.readInt32(),
						  let subHeader = reader.readInt16() else { break }
					reader.skip(2) // version
					guard let subOp = reader.readInt32() else { break }
					reader.skip(4) // seq
					let bodyLen = Int(subTotal) - Int(subHeader)
					guard bodyLen >= 0, reader.available >= bodyLen else { break }
					let body = reader.bytes(bodyLen)
					processQieTVMessage(op: subOp, body: Data(body))
				}
			} else {
				let bodyLen = Int(totalLen) - Int(headerLen)
				guard bodyLen >= 0, reader.available >= bodyLen else { return }
				let body = reader.bytes(bodyLen)
				processQieTVMessage(op: op, body: Data(body))
			}
		default:
			break
		}
	}
	
	private func qieTVPacket(op: Int32, body: Data) -> Data {
		var p = PacketWriter()
		p.write(Int32(16 + body.count))
		p.write(UInt16(16))
		p.write(UInt16(1))
		p.write(op)
		p.write(qieTVSeq)
		qieTVSeq += 1
		p.write(body)
		return p.data
	}
	
	private func processQieTVMessage(op: Int32, body: Data) {
		switch op {
		case 3:
			heartBeatCount = 0
		case 8:
			if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
			   json["status"] as? Int == 0 {
				Log("qieTV connect success")
			}
		case 2000:
			if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
			   let msg = json["msg"] as? [String: Any],
			   let content = msg["content"] as? String {
				let dm = DanmakuComment(text: content)
				sendDM(.init(method: .sendDM, text: "", dms: [dm]))
			}
		default:
			break
		}
	}
	
    func pack(format: String, values: [Int]) -> NSMutableData {
        let data = NSMutableData()
        
        format.enumerated().forEach {
            let value = values[$0.offset]
            switch $0.element {
            case "n":
                let number: UInt16 = UInt16(value)
                var convertedNumber = CFSwapInt16(number)
                data.append(&convertedNumber, length: 2)
            case "N":
                let number: UInt32 = UInt32(value)
                var convertedNumber = CFSwapInt32(number)
                data.append(&convertedNumber, length: 4)
            case "V":
                let number: UInt32 = UInt32(value)
                var convertedNumber = CFSwapInt32LittleToHost(number)
                data.append(&convertedNumber, length: 4)
            default:
                Log("Unrecognized character: \($0.element)")
            }
        }
        return data
    }
}


extension Danmaku: DanmakuSubDelegate {
    func send(_ event: DanmakuEvent) {
        delegate?.send(event, sender: self)
    }
}

fileprivate extension String {
    func kkBase64() -> String {
        let s = self.bytes.toBase64()
        return s.kkFormatterBase64()
    }
    
    func kkFormatterBase64() -> String {
        var s = self
        s = s.replacingOccurrences(of: "=", with: "")
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        return s
    }
}
