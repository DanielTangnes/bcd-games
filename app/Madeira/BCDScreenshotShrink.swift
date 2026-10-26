// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import ImageIO
import UniformTypeIdentifiers

// The copy of a screenshot that goes with Send Log (owner, 2026-10-25: a picture of about 80-100 KB is enough, never a 1-2 MB one). The kept
// screenshot (Files, Photos) is not touched: this makes a second, small JPEG from it, only for the upload.
//
// The search goes down by steps and stops at the first copy that is 100 KB or less: from 1280 px on the long side at JPEG quality 0.75, then
// lower qualities (0.6, 0.5, 0.4) at that size, then the same at 1120, 960, 800, 720 and 640 px. 640 px at quality 0.4 is the floor: if even that
// is over 100 KB, that is what is sent (the intake takes up to 160 KB). A picture smaller than a step is never made larger. The copy is made by
// ImageIO from the kept file (a scaled decode, no full-size bitmap) and carries no metadata.
//
// Foundation and ImageIO only: tests/host/check-bcd-screenshot.py compiles this file alone and runs the search on generated pictures.

enum BCDScreenshotShrink {
    /// What one search ended with.
    struct Copy: Equatable {
        var data: Data
        var width: Int
        var height: Int
        var quality: Double
        /// How many pictures were made before this one, itself included.
        var tries: Int
        /// At or under the target. False: the floor's picture, the smallest this makes.
        var fits: Bool
    }

    /// The long edges to try, in pixels, largest first (the first and the last are the rules' start and floor).
    static let edges = [BCDScreenshotRules.uploadStartEdge, 1120, 960, 800, 720, BCDScreenshotRules.uploadFloorEdge]
    /// The JPEG qualities to try at each size, best first (the last is the floor's).
    static let qualities = [0.75, 0.6, 0.5, BCDScreenshotRules.uploadFloorQuality]

    /// The steps for a picture whose long edge is `sourceLongEdge` pixels: every size in `edges` no larger than it (the first step is the
    /// picture's own size when that is smaller than the start), each with every quality.
    static func steps(sourceLongEdge: Int) -> [(edge: Int, quality: Double)] {
        var sizes: [Int] = []
        for edge in edges {
            let size = max(1, min(edge, sourceLongEdge))
            if sizes.last != size { sizes.append(size) }
        }
        return sizes.flatMap { size in qualities.map { (edge: size, quality: $0) } }
    }

    /// The search itself, with the encoder given (so a test can stand in for ImageIO). `encode(edge, quality)` makes the picture or nil. The
    /// first picture at or under `target` bytes wins; else the last one made (the floor's); nil when none could be made.
    static func search(steps: [(edge: Int, quality: Double)], target: Int,
                       encode: (Int, Double) -> (data: Data, width: Int, height: Int)?) -> Copy? {
        var last: Copy?
        var tries = 0
        for step in steps {
            guard let made = encode(step.edge, step.quality) else { continue }
            tries += 1
            let copy = Copy(data: made.data, width: made.width, height: made.height, quality: step.quality, tries: tries,
                            fits: made.data.count <= target)
            if copy.fits { return copy }
            last = copy
        }
        return last
    }

    /// The small copy of a JPEG (or any picture ImageIO reads) on disk, or nil when it cannot be read or made.
    static func smallCopy(of file: URL, target: Int = BCDScreenshotRules.uploadTargetBytes) -> Copy? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        var cachedEdge = 0
        var cached: CGImage?
        return search(steps: steps(sourceLongEdge: max(width, height)), target: target) { edge, quality in
            if edge != cachedEdge {
                cachedEdge = edge
                cached = scaled(source, edge: edge)
            }
            guard let image = cached, let data = jpeg(image, quality: quality) else { return nil }
            return (data, image.width, image.height)
        }
    }

    /// The picture scaled so that its long edge is `edge` pixels, decoded at that size.
    private static func scaled(_ source: CGImageSource, edge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
