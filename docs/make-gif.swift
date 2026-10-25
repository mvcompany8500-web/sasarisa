// Writes an animated GIF from still frames with a delay per frame, using macOS ImageIO (no ffmpeg — ffmpeg 9's
// palette filters gave every frame the last scene or crashed, 10/25).
//   swift docs/make-gif.swift out.gif 960 frame1.png:1.6 frame2.png:0.7 …
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

let a = CommandLine.arguments
guard a.count > 3, let width = Int(a[2]) else { print("usage: make-gif.swift out.gif width frame.png:seconds …"); exit(1) }
let frames = a.dropFirst(3).map { s -> (URL, Double) in
    let i = s.lastIndex(of: ":")!
    return (URL(fileURLWithPath: String(s[..<i])), Double(s[s.index(after: i)...]) ?? 1)
}
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(2) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (url, delay) in frames {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: width,
                                                                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { print("can't read \(url.path)"); exit(3) }
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                           kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { print("couldn't write"); exit(4) }
print("\(frames.count) frames → \(a[1])")
