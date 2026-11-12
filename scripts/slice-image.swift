import AppKit
import Foundation

// Slices a tall eDM image into email-safe rows.
//
// usage: slice-image.swift <source> <output-dir> <display-width> <max-slice-height> [regions.json] [png|jpg]
//
// regions.json is an optional array of link regions in display pixels:
//   [{"x": 206, "y": 361, "width": 288, "height": 72}]
// Each region becomes its own cell so that only that cell can carry a link.
// Rows without a region stay full-width and are split every <max-slice-height> pixels.

struct Region: Decodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct CellInfo: Encodable {
    let file: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let region: Int?
}

struct RowInfo: Encodable {
    let y: Int
    let height: Int
    let cells: [CellInfo]
}

struct Manifest: Encodable {
    let sourceWidth: Int
    let sourceHeight: Int
    let displayWidth: Int
    let displayHeight: Int
    let background: String
    let rows: [RowInfo]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 && arguments.count <= 7 else {
    fail("usage: slice-image.swift <source> <output-dir> <display-width> <max-slice-height> [regions.json] [png|jpg]")
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let displayWidth = Int(arguments[3]), displayWidth > 0 else {
    fail("display-width must be a positive integer")
}
guard let maxSliceHeight = Int(arguments[4]), maxSliceHeight > 0 else {
    fail("max-slice-height must be a positive integer")
}
let regionsPath = arguments.count > 5 ? arguments[5] : ""
let outputFormat = arguments.count > 6 ? arguments[6].lowercased() : "png"
guard outputFormat == "png" || outputFormat == "jpg" else {
    fail("output format must be png or jpg")
}

do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let data = try Data(contentsOf: sourceURL)
    guard let bitmap = NSBitmapImageRep(data: data), let sourceImage = bitmap.cgImage else {
        fail("could not decode image: \(sourceURL.path)")
    }

    let sourceWidth = sourceImage.width
    let sourceHeight = sourceImage.height
    let scale = Double(sourceWidth) / Double(displayWidth)
    let displayHeight = max(1, Int((Double(sourceHeight) / scale).rounded()))

    var regions: [Region] = []
    if !regionsPath.isEmpty {
        let regionData = try Data(contentsOf: URL(fileURLWithPath: regionsPath))
        regions = try JSONDecoder().decode([Region].self, from: regionData)
    }
    for (index, region) in regions.enumerated() {
        guard region.width > 0, region.height > 0, region.x >= 0, region.y >= 0,
              region.x + region.width <= displayWidth, region.y + region.height <= displayHeight else {
            fail("link region \(index + 1) is outside the \(displayWidth)x\(displayHeight) display area")
        }
    }

    // Group regions that share the same vertical band into one row.
    var bands: [(y: Int, height: Int, regions: [Int])] = []
    for index in regions.indices.sorted(by: { (regions[$0].y, regions[$0].x) < (regions[$1].y, regions[$1].x) }) {
        let region = regions[index]
        if let last = bands.last, last.y == region.y, last.height == region.height {
            let previous = regions[last.regions[last.regions.count - 1]]
            guard region.x >= previous.x + previous.width else {
                fail("link regions \(last.regions.last! + 1) and \(index + 1) overlap horizontally")
            }
            bands[bands.count - 1].regions.append(index)
        } else {
            if let last = bands.last, region.y < last.y + last.height {
                fail("link regions must not overlap vertically unless they share the same y and height")
            }
            bands.append((region.y, region.height, [index]))
        }
    }

    // Convert a display coordinate to a source pixel edge. Shared edges keep the slices gap-free.
    func sourceX(_ value: Int) -> Int { min(sourceWidth, Int((Double(value) * scale).rounded())) }
    func sourceY(_ value: Int) -> Int {
        value >= displayHeight ? sourceHeight : min(sourceHeight, Int((Double(value) * scale).rounded()))
    }

    func render(x: Int, y: Int, width: Int, height: Int, name: String) throws {
        let left = sourceX(x), right = sourceX(x + width)
        let top = sourceY(y), bottom = sourceY(y + height)
        let cropRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard let cropped = sourceImage.cropping(to: cropRect) else {
            fail("could not crop image at x=\(x) y=\(y)")
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fail("could not create bitmap context for \(name)")
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            fail("could not render \(name)")
        }
        let rep = NSBitmapImageRep(cgImage: output)
        let encoded: Data?
        if outputFormat == "jpg" {
            encoded = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        } else {
            encoded = rep.representation(using: .png, properties: [:])
        }
        guard let bytes = encoded else {
            fail("could not encode \(name)")
        }
        try bytes.write(to: outputURL.appendingPathComponent(name))
    }

    var rows: [RowInfo] = []
    func nextName(_ suffix: String = "") -> String {
        String(format: "slice_%02d", rows.count + 1) + suffix + "." + outputFormat
    }

    func addPlainRows(from start: Int, to end: Int) throws {
        var y = start
        while y < end {
            let height = min(maxSliceHeight, end - y)
            let name = nextName()
            try render(x: 0, y: y, width: displayWidth, height: height, name: name)
            rows.append(RowInfo(y: y, height: height, cells: [
                CellInfo(file: name, x: 0, y: y, width: displayWidth, height: height, region: nil)
            ]))
            y += height
        }
    }

    var cursor = 0
    for band in bands {
        try addPlainRows(from: cursor, to: band.y)

        var cells: [CellInfo] = []
        var x = 0
        func addCell(width: Int, region: Int?) throws {
            let name = nextName("_" + String(cells.count + 1))
            try render(x: x, y: band.y, width: width, height: band.height, name: name)
            cells.append(CellInfo(file: name, x: x, y: band.y, width: width, height: band.height, region: region))
            x += width
        }
        for index in band.regions {
            let region = regions[index]
            if region.x > x {
                try addCell(width: region.x - x, region: nil)
            }
            try addCell(width: region.width, region: index)
        }
        if x < displayWidth {
            try addCell(width: displayWidth - x, region: nil)
        }
        rows.append(RowInfo(y: band.y, height: band.height, cells: cells))
        cursor = band.y + band.height
    }
    try addPlainRows(from: cursor, to: displayHeight)

    // Sample the page colour next to the first link row. It is used as a fallback
    // background so that sub-pixel rounding on scaled layouts never shows a seam.
    var background = "#ffffff"
    let sampleY = bands.first.map { sourceY($0.y + $0.height / 2) } ?? 0
    if let pixel = sourceImage.cropping(to: CGRect(x: 0, y: min(sampleY, sourceHeight - 1), width: 1, height: 1)) {
        var rgba = [UInt8](repeating: 0, count: 4)
        if let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            background = String(format: "#%02x%02x%02x", rgba[0], rgba[1], rgba[2])
        }
    }

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let json = try encoder.encode(Manifest(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        background: background,
        rows: rows
    ))
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail(String(describing: error))
}
