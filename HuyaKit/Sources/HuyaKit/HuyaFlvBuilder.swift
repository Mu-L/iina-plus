//
//  HuyaFlvBuilder.swift
//  HuyaProxy
//
//  FLV tag construction + H.264/H.265 seq header handling
//

import Foundation
import NIOCore

// HEVC NAL types (official vplayer.js: NAL_VPS=32, NAL_SPS=33, NAL_PPS=34)
let HEVC_NAL_VPS = 32
let HEVC_NAL_SPS = 33
let HEVC_NAL_PPS = 34

// MARK: - FLV Header

enum HuyaFlvBuilder {
    /// FLV file header: 9-byte header + previousTagSize=0
    static let flvHeader: ByteBuffer = {
        var buffer = ByteBufferAllocator().buffer(capacity: 13)
        buffer.writeBytes([0x46, 0x4c, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00])
        return buffer
    }()
}

// MARK: - H.264 (AVC) seq header

extension HuyaFlvBuilder {
    /// Wrap an AVCDecoderConfigurationRecord into an FLV video tag
    static func buildAvcSeqTag(seqHeaderData: ByteBuffer) -> ByteBuffer {
        var tagData = ByteBufferAllocator().buffer(capacity: 5 + seqHeaderData.readableBytes)
        tagData.writeBytes([0x17, 0x00, 0x00, 0x00, 0x00]) // keyframe|AVC + seq header
        tagData.writeImmutableBuffer(seqHeaderData)
        return wrapFlvVideoTag(tagData: tagData, timestamp: 0)
    }
}

// MARK: - H.265 (HEVC) seq header (AnnexB → hvcC)

extension HuyaFlvBuilder {
    /// Extract all NALUs from AnnexB data, split by start code
    ///
    /// Official hevcFindNextStartCode (vplayer.js L14351-14364):
    /// - `00 00 01` → 3-byte start code
    /// - `00 00 00 01` → 4-byte start code
    static func parseHevcAnnexB(_ data: ByteBuffer) -> [(naluType: Int, naluData: ByteBuffer)] {
        let bytes = data.readableBytesView
        var nalus: [ByteBuffer] = []
        var naluStart: Int? = nil
        var i = 0

        while i < bytes.count {
            if i + 3 <= bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                if let start = naluStart {
                    nalus.append(data.getSlice(at: start, length: i - start)!)
                }
                naluStart = i + 3
                i += 3
                continue
            }
            if i + 4 <= bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                if let start = naluStart {
                    nalus.append(data.getSlice(at: start, length: i - start)!)
                }
                naluStart = i + 4
                i += 4
                continue
            }
            i += 1
        }

        if let start = naluStart, start < bytes.count {
            nalus.append(data.getSlice(at: start, length: bytes.count - start)!)
        }

        return nalus.compactMap { nalu -> (naluType: Int, naluData: ByteBuffer)? in
            let naluBytes = nalu.readableBytesView
            guard naluBytes.count >= 2 else { return nil }
            // HEVC NAL header: 2 bytes, nal_unit_type = (byte0 >> 1) & 0x3F
            let naluType = Int((naluBytes[0] >> 1) & 0x3F)
            return (naluType: naluType, naluData: nalu)
        }
    }

    /// Build a HEVCDecoderConfigurationRecord (hvcC)
    ///
    /// Official getExtradata265() (vplayer.js L44980-44988) + hvc1() (L21849-21864):
    /// - profile/tier/level from SPS fill the 22-byte hvcC header
    /// - 3 arrays: VPS(32), SPS(33), PPS(34)
    /// - each NALU prefixed by 2-byte BE length
    static func buildHvcc(vps: [ByteBuffer], sps: [ByteBuffer], pps: [ByteBuffer]) -> ByteBuffer? {
        guard let firstSps = sps.first else { return nil }
        let spsBytes = firstSps.readableBytesView
        guard spsBytes.count >= 15 else { return nil }

        var hvcc = ByteBufferAllocator().buffer(capacity: 1024)
        hvcc.writeInteger(UInt8(1))                    // [0] configurationVersion = 1
        hvcc.writeBytes(spsBytes[3..<4])               // [1] general_profile_space + tier + profile_idc
        hvcc.writeBytes(spsBytes[4..<8])               // [2:6] general_profile_compatibility_flags
        hvcc.writeBytes(spsBytes[8..<14])              // [6:12] general_constraint_indicator_flags
        hvcc.writeBytes(spsBytes[14..<15])             // [12] general_level_idc
        hvcc.writeBytes([0xf0, 0x00])                  // [13:15] min_spatial_segmentation_idc
        hvcc.writeInteger(UInt8(0xfc))                 // [15] parallelismType
        hvcc.writeInteger(UInt8(0xfd))                  // [16] chroma_format_idc
        hvcc.writeInteger(UInt8(0xf8))                  // [17] bit_depth_luma_minus8
        hvcc.writeInteger(UInt8(0xf8))                  // [18] bit_depth_chroma_minus8
        hvcc.writeBytes([0x00, 0x00])                   // [19:21] avg_frame_rate = 0
        hvcc.writeInteger(UInt8(0x0f))                  // [21] length_size_minus_one(3)

        // numOfArrays = 3
        hvcc.writeInteger(UInt8(3))

        // VPS array
        hvcc.writeInteger(UInt8(0xa0 | UInt8(HEVC_NAL_VPS)))
        hvcc.writeInteger(UInt16(vps.count), endianness: .big)
        for nalu in vps {
            hvcc.writeInteger(UInt16(nalu.readableBytes), endianness: .big)
            hvcc.writeImmutableBuffer(nalu)
        }

        // SPS array
        hvcc.writeInteger(UInt8(0xa0 | UInt8(HEVC_NAL_SPS)))
        hvcc.writeInteger(UInt16(sps.count), endianness: .big)
        for nalu in sps {
            hvcc.writeInteger(UInt16(nalu.readableBytes), endianness: .big)
            hvcc.writeImmutableBuffer(nalu)
        }

        // PPS array
        hvcc.writeInteger(UInt8(0xa0 | UInt8(HEVC_NAL_PPS)))
        hvcc.writeInteger(UInt16(pps.count), endianness: .big)
        for nalu in pps {
            hvcc.writeInteger(UInt16(nalu.readableBytes), endianness: .big)
            hvcc.writeImmutableBuffer(nalu)
        }

        return hvcc
    }

    /// Wrap hvcC into an FLV video tag (Enhanced FLV HEVC seq header)
    ///
    /// Uses the Enhanced FLV 4CC 'hvc1' format: FFmpeg 6.1+ flvdec only
    /// recognizes 4CC 'hvc1'; standard codecId=12 needs FFmpeg 8.1+
    ///
    /// byte0 = 0x90: IsEx(bit7=1) | FrameType(key=1<<4) | PacketType(0=seq)
    /// bytes1-4 = 'hvc1'
    static func buildHevcSeqTag(hvccData: ByteBuffer) -> ByteBuffer {
        var tagData = ByteBufferAllocator().buffer(capacity: 6 + hvccData.readableBytes)
        tagData.writeBytes([0x90, 0x68, 0x76, 0x63, 0x31]) // 0x90 + 'hvc1'
        tagData.writeImmutableBuffer(hvccData)
        return wrapFlvVideoTag(tagData: tagData, timestamp: 0)
    }

    /// Convert AnnexB NALU stream to 4-byte BE length-prefixed format
    ///
    /// FFmpeg/mpv FLV HEVC demuxer expects length-prefixed NALU
    /// (lengthSizeMinusOne=3 → 4 bytes)
    static func annexBToLengthPrefixed(_ data: ByteBuffer) -> ByteBuffer {
        let nalus = parseHevcAnnexB(data)
        var out = ByteBufferAllocator().buffer(capacity: data.readableBytes)
        for (_, nalu) in nalus {
            out.writeInteger(UInt32(nalu.readableBytes), endianness: .big)
            out.writeImmutableBuffer(nalu)
        }
        return out
    }
}

// MARK: - Timestamp rewrite

extension HuyaFlvBuilder {
    /// Rewrite an FLV tag's timestamp (bytes 4-7, big-endian)
    ///
    /// - data[4:7] = timestamp low 3 bytes (DTS)
    /// - data[7] = timestamp high byte
    ///
    /// For video NALU tags:
    /// - H.264 (codecId=7): zero the cts (composition time offset, data[13:16])
    ///   so mpv's PTS = DTS + cts stays monotonic (B-frame reordering)
    /// - H.265 (codecId=12): keep original cts (matching official vplayer.js
    ///   L14084-14085, which preserves cts for MSE B-frame reordering)
    static func rewriteFlvTagTs(_ tagData: ByteBuffer, newTs: Int) -> ByteBuffer {
        var out = tagData
        let ts = UInt32(newTs & 0xFFFFFFFF)
        // ts low 3 bytes (BE) + tsExt
        out.setInteger(UInt8((ts >> 16) & 0xFF), at: 4)
        out.setInteger(UInt8((ts >> 8) & 0xFF), at: 5)
        out.setInteger(UInt8(ts & 0xFF), at: 6)
        out.setInteger(UInt8((ts >> 24) & 0xFF), at: 7)

        // H.264 video NALU tag (packetType=1): zero cts
        // H.265: keep original cts
        let tagType = out.getInteger(at: 0, as: UInt8.self) ?? 0
        let frameCodec = out.getInteger(at: 11, as: UInt8.self) ?? 0
        let packetType = out.getInteger(at: 12, as: UInt8.self) ?? 0
        if out.readableBytes >= 16 && tagType == 9 && packetType == 1 && (frameCodec & 0x0F) == 7 {
            out.setInteger(UInt8(0), at: 13)
            out.setInteger(UInt8(0), at: 14)
            out.setInteger(UInt8(0), at: 15)
        }
        return out
    }
}

// MARK: - Helpers

private extension HuyaFlvBuilder {
    /// Wrap FLV video tag header around the tag body
    static func wrapFlvVideoTag(tagData: ByteBuffer, timestamp: Int) -> ByteBuffer {
        let dataSize = tagData.readableBytes
        var tag = ByteBufferAllocator().buffer(capacity: 11 + dataSize + 4)
        tag.writeInteger(UInt8(0x09)) // tagType = 9 (video)
        // dataSize (3 bytes BE)
        tag.writeInteger(UInt8((dataSize >> 16) & 0xFF))
        tag.writeInteger(UInt8((dataSize >> 8) & 0xFF))
        tag.writeInteger(UInt8(dataSize & 0xFF))
        // timestamp (3 bytes BE) + tsExt
        let ts = UInt32(timestamp & 0xFFFFFFFF)
        tag.writeInteger(UInt8((ts >> 16) & 0xFF))
        tag.writeInteger(UInt8((ts >> 8) & 0xFF))
        tag.writeInteger(UInt8(ts & 0xFF))
        tag.writeInteger(UInt8((ts >> 24) & 0xFF))
        // streamId (3 bytes = 0)
        tag.writeBytes([0x00, 0x00, 0x00])
        // data
        tag.writeImmutableBuffer(tagData)
        // prevTagSize (4 bytes BE)
        tag.writeInteger(UInt32(11 + dataSize), endianness: .big)
        return tag
    }
}