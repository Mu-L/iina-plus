//
//  HuyaTupParser.swift
//  HuyaProxy
//
//  TUP/JCE packet parsing + PP2pSliceData extraction
//
//  SwiftNIO ByteBuffer based, avoids Data._Representation COW concurrency crash
//

import Foundation
import NIOCore

// MARK: - URI constants (official vplayer.js ProtoUri L3856-3861)

let URI_VIDEO = 512291      // PP2pSliceVideoData
let URI_AUDIO = 512035      // PP2pSliceAudioData (V1)
let URI_AUDIO_V2 = 517411   // PP2pSliceAudioDataV2
let URI_AUDIO_V3 = 517667   // PP2pSliceAudioDataV3
let URI_DATA = 511779       // PP2pSliceControlData

// MARK: - HuyaTupPacket

struct HuyaTupPacket: Sendable {
    let seq: UInt64
    let uri: UInt32
    let payload: ByteBuffer
}

// MARK: - HuyaVideoSlice

struct HuyaVideoSlice: Sendable {
    let checkSum: UInt8
    let seqNum: UInt16
    let frameNum: UInt16
    let frameId: UInt32
    let config: [UInt8: UInt32]
    let streamData: ByteBuffer

    /// Frame type: 0=I, 1=P, 2=B
    var frameType: Int { Int(seqNum) & 3 }
    var isKeyframe: Bool { frameType == 0 }
}

// MARK: - HuyaAudioSlice

struct HuyaAudioSlice: Sendable {
    let checkSum: UInt8
    let codecType: UInt16
    let streamData: ByteBuffer
}

// MARK: - HuyaJceReader

/// TUP/JCE little-endian reader over ByteBuffer
///
/// Reads the 10-byte header `len(4) + uri(4) + resCode(2)` on init
struct HuyaJceReader {
    private var buffer: ByteBuffer
    let length: UInt32
    let uri: UInt32
    let resCode: UInt16

    var pos: Int { buffer.readerIndex }

    init(buffer: ByteBuffer) {
        self.buffer = buffer
        self.length = self.buffer.readInteger(endianness: .little, as: UInt32.self) ?? 0
        self.uri = self.buffer.readInteger(endianness: .little, as: UInt32.self) ?? 0
        self.resCode = self.buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
    }

    mutating func readUInt8() -> UInt8 {
        buffer.readInteger(as: UInt8.self) ?? 0
    }

    mutating func readUInt16() -> UInt16 {
        buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
    }

    mutating func readUInt32() -> UInt32 {
        buffer.readInteger(endianness: .little, as: UInt32.self) ?? 0
    }

    mutating func readUInt64() -> UInt64 {
        buffer.readInteger(endianness: .little, as: UInt64.self) ?? 0
    }

    /// uint16 length-prefixed byte array
    mutating func readUInt8Array() -> ByteBuffer {
        let length = Int(readUInt16())
        return buffer.readSlice(length: length) ?? ByteBuffer()
    }
}

// MARK: - HuyaTupParser (one shot parse)

enum HuyaTupParser {
    /// Parse TUP packets from a full .slice buffer
    static func parse(data: ByteBuffer) -> [HuyaTupPacket] {
        var buffer = data
        var packets: [HuyaTupPacket] = []

        while buffer.readableBytes >= 10 {
            let readerIndex = buffer.readerIndex
            let h = Int(buffer.getInteger(at: readerIndex + 8, endianness: .little, as: UInt16.self) ?? 0)
            if h < 10 {
                buffer.moveReaderIndex(forwardBy: 1)
                continue
            }
            if buffer.readableBytes < h {
                break
            }
            let seq = buffer.getInteger(at: readerIndex, endianness: .little, as: UInt64.self) ?? 0
            let uri = buffer.getInteger(at: readerIndex + 14, endianness: .little, as: UInt32.self) ?? 0
            let payload = buffer.getSlice(at: readerIndex + 10, length: h - 10) ?? ByteBuffer()
            packets.append(HuyaTupPacket(seq: seq, uri: uri, payload: payload))
            buffer.moveReaderIndex(forwardBy: h)
        }
        return packets
    }
}

// MARK: - HuyaTupStreamParser (streaming parse)

/// Incremental TUP packet parser (official vplayer.js ProtoLinkFetch.pump L11839-11852)
///
/// `feed(data:)` parses complete packets; partial ones are buffered
/// across chunks (HTTP chunked transfer)
struct HuyaTupStreamParser: Sendable {
    private var buffer = ByteBuffer()
    private(set) var totalFed = 0
    private(set) var totalPackets = 0

    mutating func feed(_ data: ByteBuffer) -> [HuyaTupPacket] {
        buffer.writeBytes(data.readableBytesView)
        totalFed += data.readableBytes

        var packets: [HuyaTupPacket] = []

        while buffer.readableBytes >= 10 {
            let readerIndex = buffer.readerIndex

            // packet length at offset 8-10, LE
            let h = Int(buffer.getInteger(at: readerIndex + 8, endianness: .little, as: UInt16.self) ?? 0)
            if h < 10 {
                buffer.moveReaderIndex(forwardBy: 1)
                continue
            }
            // incomplete packet, wait for more data
            if buffer.readableBytes < h {
                break
            }

            let seq = buffer.getInteger(at: readerIndex, endianness: .little, as: UInt64.self) ?? 0
            let uri = buffer.getInteger(at: readerIndex + 14, endianness: .little, as: UInt32.self) ?? 0
            let payload = buffer.getSlice(at: readerIndex + 10, length: h - 10) ?? ByteBuffer()
            packets.append(HuyaTupPacket(seq: seq, uri: uri, payload: payload))

            buffer.moveReaderIndex(forwardBy: h)
        }

        if buffer.readerIndex > 0 {
            buffer.discardReadBytes()
        }

        totalPackets += packets.count
        return packets
    }

    mutating func reset() {
        buffer.clear()
        totalFed = 0
        totalPackets = 0
    }
}

// MARK: - Slice parsers

enum HuyaSliceParser {
    /// Parse PP2pSliceVideoData
    static func parseVideo(payload: ByteBuffer) -> HuyaVideoSlice? {
        var reader = HuyaJceReader(buffer: payload)
        let checkSum = reader.readUInt8()
        let seqNum = reader.readUInt16()
        let frameNum = reader.readUInt16()
        let frameId = reader.readUInt32()

        let configCount = Int(reader.readUInt32())
        var config: [UInt8: UInt32] = [:]
        for _ in 0..<configCount {
            let key = reader.readUInt8()
            let val = reader.readUInt32()
            config[key] = val
        }

        let streamData = reader.readUInt8Array()

        return HuyaVideoSlice(
            checkSum: checkSum,
            seqNum: seqNum,
            frameNum: frameNum,
            frameId: frameId,
            config: config,
            streamData: streamData
        )
    }

    /// Parse PP2pSliceAudioData (V1, URI=512035)
    static func parseAudio(payload: ByteBuffer) -> HuyaAudioSlice? {
        var reader = HuyaJceReader(buffer: payload)
        let checkSum = reader.readUInt8()
        let codecType = reader.readUInt16()
        let streamData = reader.readUInt8Array()

        return HuyaAudioSlice(
            checkSum: checkSum,
            codecType: codecType,
            streamData: streamData
        )
    }
}

// MARK: - First keyframe tracker (packet-header only)

/// Incremental header-only check for the first complete video keyframe.
/// Keyframe flag lives in the slice header (frameType = seqNum&3, 0=keyframe),
/// so streamData is never decoded. Frame complete = received count == pktNum (frameNum).
/// Used for adaptive early stop of the first-slice download, replacing
/// the coarse per-128KB full re-decode (O(n²)); stops at the keyframe chunk boundary.
struct HuyaFirstKeyframeTracker: Sendable {
    private var parser = HuyaTupStreamParser()
    // frameId → (received count, expected pktNum, is keyframe)
    private var frames: [UInt32: (count: Int, pktNum: Int, isKey: Bool)] = [:]

    mutating func feed(_ data: ByteBuffer) -> Bool {
        for pkt in parser.feed(data) where pkt.uri == UInt32(URI_VIDEO) {
            guard let v = HuyaSliceParser.parseVideo(payload: pkt.payload) else { continue }
            var entry = frames[v.frameId] ?? (count: 0, pktNum: Int(v.frameNum), isKey: v.isKeyframe)
            entry.count += 1
            entry.isKey = entry.isKey || v.isKeyframe
            frames[v.frameId] = entry
            if entry.isKey && entry.count >= entry.pktNum {
                return true
            }
        }
        return false
    }
}
