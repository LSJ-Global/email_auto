import AppKit
import Foundation

struct SliceInfo: Encodable {
    let file: String
    let width: Int
    let height: Int
}

struct Manifest: Encodable {
    let sourceWidth: Int
    let sourceHeight: Int
    let slices: [SliceInfo]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    fail("usage: slice-image.swift <source> <output-dir> <display-width> <max-slice-height>")
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let displayWidth = Int(arguments[3]), displayWidth > 0 else {
    fail("display-width must be a positive integer")
}
guard let maxSliceHeight = Int(arguments[4]), maxSliceHeight > 0 else {
    fail("max-slice-height must be a positive integer")
}

do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let data = try Data(contentsOf: sourceURL)
    guard let bitmap = NSBitmapImageRep(data: data), let sourceImage = bitmap.cgImage else {
        fail("could not decode image: \(sourceURL.path)")
    }

    let sourceWidth = sourceImage.width
    let sourceHeight = sourceImage.height
    let sourceSliceHeight = max(1, Int((Double(maxSliceHeight) * Double(sourceWidth) / Double(displayWidth)).rounded(.down)))
    var y = 0
    var index = 1
    var slices: [SliceInfo] = []

    while y < sourceHeight {
        let cropHeight = min(sourceSliceHeight, sourceHeight - y)
        let displayHeight = max(1, Int((Double(cropHeight) * Double(displayWidth) / Double(sourceWidth)).rounded()))
        let cropRect = CGRect(x: 0, y: y, width: sourceWidth, height: cropHeight)
        guard let croppedImage = sourceImage.cropping(to: cropRect) else {
            fail("could not crop image at y=\(y)")
        }

        let outputName = String(format: "slice_%02d.png", index)
        let destinationURL = outputURL.appendingPathComponent(outputName)
        let resizedImage = NSImage(size: NSSize(width: displayWidth, height: displayHeight))
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight).fill()
        NSImage(cgImage: croppedImage, size: NSSize(width: croppedImage.width, height: croppedImage.height)).draw(
            in: NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight),
            from: NSRect(x: 0, y: 0, width: croppedImage.width, height: croppedImage.height),
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()

        guard
            let tiff = resizedImage.tiffRepresentation,
            let outputBitmap = NSBitmapImageRep(data: tiff),
            let png = outputBitmap.representation(using: .png, properties: [:])
        else {
            fail("could not encode \(outputName)")
        }

        try png.write(to: destinationURL)
        slices.append(SliceInfo(file: outputName, width: displayWidth, height: displayHeight))
        y += cropHeight
        index += 1
    }

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let json = try encoder.encode(Manifest(sourceWidth: sourceWidth, sourceHeight: sourceHeight, slices: slices))
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail(String(describing: error))
}
