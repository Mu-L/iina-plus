//
//  main.swift
//  huyaproxy
//
//  Huya .slice proxy CLI (multi-room).
//
//  Usage:
//    huyaproxy [port]
//    huyaproxy --server 18080
//    # play:
//    mpv http://127.0.0.1:18080/huya/11342412.flv
//

import Foundation
import NIO
import NIOHTTP1
import HuyaKit

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

HuyaLogger.handler = { message, level in
    print("[HuyaKit] \(message)")
}
HuyaLogger.level = .debug

let args = Array(CommandLine.arguments.dropFirst())
var serverMode = false
var port = 18080

var positional: [String] = []
for arg in args {
    if arg.hasPrefix("--") {
        switch arg {
        case "--server": serverMode = true
        default:
            print("unknown option: \(arg)")
            exit(1)
        }
    } else {
        positional.append(arg)
    }
}

if serverMode {
    port = positional.first.flatMap { Int($0) } ?? 18080
} else if let first = positional.first {
    port = Int(first) ?? 18080
}

// MARK: - HTTP byte buffer response handler

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

// MARK: - Server bootstrap

let group = MultiThreadedEventLoopGroup.singleton

let channel = try await ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .bind(host: "127.0.0.1", port: port) { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withPipeliningAssistance: false
            )
            try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
            return try NIOAsyncChannel(
                wrappingChannelSynchronously: channel,
                configuration: .init(
                    inboundType: HTTPServerRequestPart.self,
                    outboundType: HTTPPart<HTTPResponseHead, ByteBuffer>.self
                )
            )
        }
    }

print("HuyaProxy server started on http://127.0.0.1:\(port)")

try await channel.executeThenClose { inbound, _ in
    for try await requestChannel in inbound {
        Task {
            await handleChannel(requestChannel)
        }
    }
}

func handleChannel(
    _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
) async {
    do {
        try await channel.executeThenClose { inbound, outbound in
            var currentURL = ""
            var currentMethod: HTTPMethod = .UNBIND

            for try await part in inbound {
                switch part {
                case .head(let head):
                    currentURL = head.uri.split(separator: "?", maxSplits: 1).map(String.init).first ?? ""
                    currentMethod = head.method
                case .body:
                    break
                case .end:
                    if currentURL.hasPrefix("/huya/"), currentMethod == .GET {
                        let token = currentURL
                            .replacingOccurrences(of: "/huya/", with: "")
                            .replacingOccurrences(of: ".flv", with: "")
                        print("stream request roomId=\(token)")
                        try await HuyaProxyServer.shared.handleHuyaRequest(roomId: token, outbound: outbound)
                        return
                    }
                    // Not found
                    var headers = NIOHTTP1.HTTPHeaders()
                    headers.add(name: "Content-Length", value: "0")
                    headers.add(name: "Connection", value: "close")
                    let head = HTTPResponseHead(version: .http1_1, status: .notFound, headers: headers)
                    try await outbound.write(contentsOf: [
                        .head(head),
                        .end(nil),
                    ])
                }
            }
        }
    } catch {
        print("connection error: \(error)")
    }
}
