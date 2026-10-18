//
//  StatementFileLoaderTests.swift
//  Investment AppTests
//

import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Investment_App

@MainActor
@Suite("Statement file loading")
struct StatementFileLoaderTests {
    /// A solid-colour image of the given pixel size.
    func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func encode(_ image: UIImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func mediaType(_ source: StatementSource) -> String? {
        (source.contentBlock["source"] as? [String: Any])?["media_type"] as? String
    }

    func imageData(_ source: StatementSource) throws -> Data {
        let base64 = try #require((source.contentBlock["source"] as? [String: Any])?["data"] as? String)
        return try #require(Data(base64Encoded: base64))
    }

    @Test("PDFs become document blocks")
    func pdf() throws {
        let source = try StatementFileLoader.load(data: Data("%PDF-1.4".utf8), type: .pdf, name: "statement.pdf")
        #expect(source.name == "statement.pdf")
        #expect(source.contentBlock["type"] as? String == "document")
        #expect(mediaType(source) == "application/pdf")
    }

    @Test("Small PNGs are sent as-is")
    func smallPNG() throws {
        let png = try #require(image(width: 400, height: 300).pngData())
        let source = try StatementFileLoader.load(data: png, type: .png, name: "shot.png")
        #expect(source.contentBlock["type"] as? String == "image")
        #expect(mediaType(source) == "image/png")
        #expect(try imageData(source) == png)
    }

    @Test("Large images are downscaled to 2000px and re-encoded as JPEG")
    func largeImage() throws {
        let png = try #require(image(width: 4000, height: 1000).pngData())
        let source = try StatementFileLoader.load(data: png, type: .png, name: "big.png")
        #expect(mediaType(source) == "image/jpeg")
        let decoded = try #require(UIImage(data: try imageData(source)))
        #expect(max(decoded.size.width, decoded.size.height) * decoded.scale == 2000)
    }

    @Test("Formats Claude can't read directly (e.g. TIFF, like iPhone HEIC) are converted to JPEG")
    func convertsUnsupportedImageFormat() throws {
        let tiff = try encode(image(width: 300, height: 200), as: .tiff)
        let source = try StatementFileLoader.load(data: tiff, type: .tiff, name: "scan.tiff")
        #expect(mediaType(source) == "image/jpeg")
    }

    @Test("CSV and other text files become text blocks with their contents")
    func csv() throws {
        let csv = "Ticker,Shares\nAAPL,10\n"
        let source = try StatementFileLoader.load(data: Data(csv.utf8), type: .commaSeparatedText, name: "export.csv")
        #expect(source.contentBlock["type"] as? String == "text")
        let text = try #require(source.contentBlock["text"] as? String)
        #expect(text.contains("export.csv"))
        #expect(text.contains("AAPL,10"))
    }

    @Test("Spreadsheets and unknown types are rejected with a clear message")
    func unsupported() {
        let xlsx = UTType(filenameExtension: "xlsx")
        #expect(throws: StatementFileError.self) {
            try StatementFileLoader.load(data: Data([0x50, 0x4B]), type: xlsx, name: "book.xlsx")
        }
        #expect(throws: StatementFileError.self) {
            try StatementFileLoader.load(data: Data(), type: nil, name: "mystery")
        }
        #expect(StatementFileError.unsupported(name: "book.xlsx").errorDescription?.contains("PDF or CSV") == true)
    }

    @Test("Corrupt image data is reported as unreadable")
    func corruptImage() {
        #expect(throws: StatementFileError.self) {
            try StatementFileLoader.load(data: Data("not an image".utf8), type: .png, name: "broken.png")
        }
    }

    @Test("Loads from a file URL using its extension")
    func fromURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        try Data("a,b\n1,2".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try StatementFileLoader.load(fileAt: url)
        #expect(source.name == url.lastPathComponent)
        #expect(source.contentBlock["type"] as? String == "text")
    }

    @Test("A missing file is unreadable")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.pdf")
        #expect(throws: StatementFileError.self) {
            try StatementFileLoader.load(fileAt: url)
        }
    }
}
