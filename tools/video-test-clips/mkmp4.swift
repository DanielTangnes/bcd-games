// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// mkmp4: writes the video test's MP4 (tools/gen-video-test-clips.sh): H.264 Baseline video and AAC-LC audio from the raw
// frames and the raw tone that tools/video-test-clips/genframes.py makes, with macOS's own encoders (AVAssetWriter).
// The frames and the tone are BCD's own synthetic picture and sine wave; no third-party media goes in.
import AVFoundation
import CoreVideo
import Foundation

// usage: mkmp4 frames.bgra tone.pcm out.mp4 width height frames fps rate
let a = CommandLine.arguments
guard a.count == 9 else { FileHandle.standardError.write("usage\n".data(using: .utf8)!); exit(2) }
let W = Int(a[4])!, H = Int(a[5])!, N = Int(a[6])!, FPS = Int32(a[7])!, RATE = Double(a[8])!
let frames = try Data(contentsOf: URL(fileURLWithPath: a[1]))
let pcm = try Data(contentsOf: URL(fileURLWithPath: a[2]))
let out = URL(fileURLWithPath: a[3])
try? FileManager.default.removeItem(at: out)

let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let vsettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
        AVVideoAllowFrameReorderingKey: false,
        AVVideoMaxKeyFrameIntervalKey: 15,
        AVVideoAverageBitRateKey: 250_000,
    ] as [String: Any],
]
let vin = AVAssetWriterInput(mediaType: .video, outputSettings: vsettings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
let asettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: RATE, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000,
]
let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: asettings)
writer.add(vin); writer.add(ain)
guard writer.startWriting() else { print("startWriting failed: \(String(describing: writer.error))"); exit(1) }
writer.startSession(atSourceTime: .zero)

let frameBytes = W * H * 4
var fmt = AudioStreamBasicDescription(mSampleRate: RATE, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
    mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
var desc: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &fmt, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
let totalSamples = pcm.count / 2
var apos = 0
var framesDone = 0
var audioFinished = false

func waitReady(_ input: AVAssetWriterInput, _ what: String) {
    var spins = 0
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.002)
        spins += 1
        if spins > 5000 { print("timeout waiting for the \(what) input at frame \(framesDone), audio sample \(apos) (status \(writer.status.rawValue), \(String(describing: writer.error)))"); exit(1) }
    }
}

// Video and audio go in together, in time order: the writer interleaves them and stops asking for one input
// until the other has caught up.
func appendAudio(upTo samples: Int) {
    while apos < samples && apos < totalSamples {
        let n = min(1024, totalSamples - apos)
        waitReady(ain, "audio")
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n * 2, flags: 0, blockBufferOut: &block)
        _ = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!.advanced(by: apos * 2), blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 2)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!, sampleCount: n,
            presentationTimeStamp: CMTime(value: Int64(apos), timescale: Int32(RATE)), packetDescriptions: nil, sampleBufferOut: &sample)
        ain.append(sample!)
        apos += n
    }
    if apos >= totalSamples && !audioFinished { ain.markAsFinished(); audioFinished = true }
}

for i in 0..<N {
    waitReady(vin, "video")
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!)
    frames.withUnsafeBytes { raw in
        for y in 0..<H {
            memcpy(base + y * stride, raw.baseAddress!.advanced(by: i * frameBytes + y * W * 4), W * 4)
        }
    }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: FPS))
    framesDone = i + 1
    appendAudio(upTo: Int((Double(i + 1) / Double(FPS) + 0.7) * RATE))
}
appendAudio(upTo: totalSamples)
vin.markAsFinished()

let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status != .completed { print("failed: \(String(describing: writer.error))"); exit(1) }
print("wrote \(out.path)")
