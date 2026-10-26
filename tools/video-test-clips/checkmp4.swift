// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// checkmp4: decodes the video test's MP4 with macOS's own decoder (AVAssetReader) and prints what the video test measures on a
// device: the number of pictures, the length of the progress bar in each (green above 130 along row height - 4), the hue of the
// two top corners of the first picture, the video size and the duration. tests/host/check-bcd-tests.py runs it on a Mac.
// usage: checkmp4 <file.mp4>
import AVFoundation
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVAsset(url: url)
guard let v = asset.tracks(withMediaType: .video).first else { print("novideo"); exit(1) }
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out)
reader.startReading()
var bars: [Int] = []
var corners = ""
while let s = out.copyNextSampleBuffer() {
    let pb = CMSampleBufferGetImageBuffer(s)!
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), st = CVPixelBufferGetBytesPerRow(pb)
    let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var c = 0
    for x in 0..<w where b[(h - 4) * st + x * 4 + 1] > 130 { c += 1 }
    bars.append(c)
    if bars.count == 1 {
        let l = 4 * st + 4 * 4, r = 4 * st + (w - 5) * 4
        corners = "left \(b[l + 2]),\(b[l + 1]),\(b[l]) right \(b[r + 2]),\(b[r + 1]),\(b[r])"
        print("size \(w)x\(h)")
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
}
print("frames \(bars.count)")
print("bars \(bars.map(String.init).joined(separator: ","))")
print("corners (r,g,b) \(corners)")
print(String(format: "duration %.3f", CMTimeGetSeconds(asset.duration)))
print("audio tracks \(asset.tracks(withMediaType: .audio).count)")
