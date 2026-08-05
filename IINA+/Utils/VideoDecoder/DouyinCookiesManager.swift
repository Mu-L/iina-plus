//
//  DouyinCookiesManager.swift
//  IINA+
//
//  Created by xjbeta on 2024/8/19.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import JavaScriptCore
import Marshal

@MainActor
class DouyinCookiesManager: NSObject {
    let douyinUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    
    private let emptyRoomURL = URL(string: "https://live.douyin.com/1")!
    
    private var _cookies = [String: String]()
    private var cookiesUpdatedAt = Date.distantPast
    private let cookiesTTL: TimeInterval = 3600
    
    private var lastFailureAt: Date?
    private let failureBackoff: TimeInterval = 10
    
    private var cookiesTask: Task<[String: String], Error>?    
    enum CookiesError: Error {
        case signature, invalid, timeout, unknown
    }
    
    private var douyuJSContext: JSContext = {
        let context = JSContext()!
        if #available(macOS 13.3, *) {
            context.isInspectable = true
        }
        
        if let path = Bundle.main.path(forResource: "douyin", ofType: "js") {
            context.evaluateScript(try? String(contentsOfFile: path))
        } else {
            Log("Not found douyin.js.")
        }
        return context
    }()
    
    func request(_ url: String, headers: HTTPHeaders = .init(), cookies: [String: String]? = nil) async throws -> DataRequest {
        var cookies = cookies ?? [:]
        if cookies["ttwid"] == nil {
            cookies = try await self.cookies()
        }
        
        let msToken = generateRandomString(length: 180)
        let msTokenString = "&msToken=\(msToken)"
        
        let up = url.split(separator: "?", maxSplits: 1).map(String.init)
        
        guard let ttwid = cookies["ttwid"],
              up.count == 2,
              let abogus = douyuJSContext.evaluateScript("generate_a_bogus('\(up[1] + msTokenString)', '\(douyinUA)')").toString().addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else {
            Log("Not found ttwid or abogus.")
            throw CookiesError.signature
        }
        
        let u = url + msTokenString + "&a_bogus=\(abogus)"
        
        var headers = headers
        headers.add(name: "User-Agent", value: douyinUA)
        headers.add(name: "Cookie", value: "ttwid=\(ttwid)")
        
        return AF.request(u, headers: headers)
    }
    
    func cookies() async throws -> [String: String] {
        try await internelCookies()
    }
    
    func invalidateCookies() {
        updateInternalCookies([:])
    }
    
    private func internelCookies() async throws -> [String: String] {
        if _cookies.count > 0,
           Date().timeIntervalSince(cookiesUpdatedAt) < cookiesTTL {
            return _cookies
        }

        if let task = cookiesTask {
            return try await task.value
        }
        
        if let failure = lastFailureAt {
            let elapsed = Date().timeIntervalSince(failure)
            if elapsed < failureBackoff {
                Log("cookies backoff \(Int(failureBackoff - elapsed))s")
                try await Task.sleep(seconds: UInt64(failureBackoff - elapsed))
            }
        }

        let task = Task {
            try await prepareAndVerify()
        }
        cookiesTask = task
        defer { cookiesTask = nil }
        
        do {
            return try await task.value
        } catch {
            lastFailureAt = .init()
            updateInternalCookies([:])
            throw error
        }
    }

    private func prepareAndVerify() async throws -> [String: String] {
        var lastError: Error = CookiesError.unknown
        for attempt in 0..<2 {
            do {
                let cookies = try await prepareCookies()
                try await verifyCookies(cookies)
                lastFailureAt = nil
                updateInternalCookies(cookies)
                return cookies
            } catch {
                lastError = error
                Log("cookies attempt \(attempt + 1) failed: \(error)")
            }
        }
        Log("cookies failed: \(lastError)")
        throw lastError
    }
    
    private func updateInternalCookies(_ cookies: [String: String]) {
        _cookies = cookies
        cookiesUpdatedAt = .init()
    }
    
    private func prepareCookies() async throws -> [String: String] {
        let headers = HTTPHeaders([
            "User-Agent": douyinUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ])
        
        let res = await AF.request(
            emptyRoomURL,
            headers: headers,
            requestModifier: { $0.timeoutInterval = 20 }
        ).serializingData().response
        
        guard let http = res.response else {
            throw CookiesError.timeout
        }
        guard let all = http.allHeaderFields as? [String: String] else {
            throw CookiesError.unknown
        }
        
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: all, for: emptyRoomURL)
        guard let ttwid = setCookies.first(where: { $0.name == "ttwid" })?.value else {
            throw CookiesError.invalid
        }
        
        return ["ttwid": ttwid]
    }
    
    private func verifyCookies(_ cookies: [String: String]) async throws {
        let u = "https://live.douyin.com/webcast/room/web/enter/?aid=6383&web_rid=1"
        
        do {
            let data = try await self.request(u, cookies: cookies).serializingData().value
            let jsonObj: JSONObject = try JSONParser.JSONObjectWithData(data)
            let statusCode: Int = (try? jsonObj.value(for: "status_code")) ?? 0
            guard statusCode == 0 else {
                throw CookiesError.invalid
            }
        } catch {
            throw CookiesError.invalid
        }
    }
    
    private func generateRandomString(length: Int) -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
        return (0..<length).map { _ in
            String(characters.randomElement() ?? "G")
        }.joined()
    }
}
