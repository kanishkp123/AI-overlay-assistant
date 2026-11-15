import Foundation
import AppKit

/// On-device OCR service powered by Tesseract CLI.
/// Runs entirely locally — no API key, no network access, no Apple Vision framework.
final class TesseractOCRService: ObservableObject {

    // MARK: - Types

    struct OCRResult {
        let fullText: String
        let blocks: [TextBlock]
        let confidence: Float

        struct TextBlock {
            let text: String
            let boundingBox: CGRect
            let confidence: Float
        }
    }

    enum TesseractError: Error, LocalizedError {
        case tesseractNotFound
        case invalidImage
        case noTextDetected
        case processingError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .tesseractNotFound: return "Tesseract not found. Install with: brew install tesseract"
            case .invalidImage: return "Invalid image data"
            case .noTextDetected: return "No text detected in image"
            case .processingError(let msg): return "OCR processing error: \(msg)"
            case .timeout: return "OCR timed out"
            }
        }
    }

    // MARK: - Published State

    @Published var isProcessing = false
    @Published var lastOCRResult: OCRResult?

    // MARK: - Properties

    private let tesseractPath: String
    private let tessdataPath: String?

    // MARK: - Init

    init() {
        // Find tesseract binary
        let possiblePaths = [
            "/opt/homebrew/bin/tesseract",  // Apple Silicon Homebrew
            "/usr/local/bin/tesseract",     // Intel Homebrew
            "/opt/homebrew/opt/tesseract/bin/tesseract",
            "/usr/local/opt/tesseract/bin/tesseract"
        ]

        var foundPath: String?
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                foundPath = path
                break
            }
        }

        self.tesseractPath = foundPath ?? "/opt/homebrew/bin/tesseract"

        // Find tessdata directory
        let possibleTessdataPaths = [
            "/opt/homebrew/share/tessdata",
            "/usr/local/share/tessdata",
            "/opt/homebrew/opt/tesseract/share/tessdata",
            "/usr/local/opt/tesseract/share/tessdata"
        ]

        var foundTessdata: String?
        for path in possibleTessdataPaths {
            if FileManager.default.fileExists(atPath: path) {
                foundTessdata = path
                break
            }
        }
        self.tessdataPath = foundTessdata

        print("🔍 TesseractOCRService initialized")
        print("   tesseract: \(self.tesseractPath)")
        print("   tessdata: \(self.tessdataPath ?? "not found (using default)")")
    }

    // MARK: - OCR

    /// Performs OCR on a base64-encoded image using Tesseract CLI.
    func performOCR(imageBase64: String) async throws -> OCRResult {
        guard let data = Data(base64Encoded: imageBase64) else {
            throw TesseractError.invalidImage
        }
        return try await performOCR(imageData: data)
    }

    /// Performs OCR on raw image data using Tesseract CLI.
    func performOCR(imageData: Data) async throws -> OCRResult {
        await MainActor.run { self.isProcessing = true }
        defer {
            Task { @MainActor in self.isProcessing = false }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runTesseract(imageData: imageData)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runTesseract(imageData: Data) throws -> OCRResult {
        // Create temporary files
        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("ocr_input_\(UUID().uuidString).png")
        let outputBase = tempDir.appendingPathComponent("ocr_output_\(UUID().uuidString)")

        // Write image data to temp file
        try imageData.write(to: inputFile)

        defer {
            // Cleanup temp files
            try? FileManager.default.removeItem(at: inputFile)
            try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("txt"))
            try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("tsv"))
            try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("hocr"))
        }

        // Build tesseract command
        // Use TSV output for structured data with bounding boxes and confidence
        var arguments = [
            inputFile.path,
            outputBase.deletingPathExtension().path,
            "-l", "eng",
            "--psm", "6",  // Assume a single uniform block of text
            "tsv"
        ]

        if let tessdataPath = tessdataPath {
            arguments.insert("--tessdata-dir", at: 0)
            arguments.insert(tessdataPath, at: 1)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Wait with timeout
            let timeout: TimeInterval = 30
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                process.terminate()
                throw TesseractError.timeout
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw TesseractError.processingError("Tesseract exited with code \(process.terminationStatus): \(errorOutput)")
            }

            // Read TSV output
            let tsvFile = outputBase.appendingPathExtension("tsv")
            guard FileManager.default.fileExists(atPath: tsvFile.path) else {
                throw TesseractError.processingError("TSV output file not created")
            }

            let tsvData = try Data(contentsOf: tsvFile)
            guard let tsvString = String(data: tsvData, encoding: .utf8) else {
                throw TesseractError.processingError("Failed to read TSV output")
            }

            return try parseTSVOutput(tsvString)

        } catch let error as TesseractError {
            throw error
        } catch {
            throw TesseractError.processingError(error.localizedDescription)
        }
    }

    private func parseTSVOutput(_ tsv: String) throws -> OCRResult {
        let lines = tsv.components(separatedBy: .newlines).filter { !$0.isEmpty }

        guard lines.count > 1 else {  // Header line + at least one data line
            throw TesseractError.noTextDetected
        }

        // TSV header: level	page_num	block_num	par_num	line_num	word_num	left	top	width	height	conf	text
        var blocks: [OCRResult.TextBlock] = []
        var allText: [String] = []
        var totalConfidence: Float = 0
        var wordCount = 0

        for line in lines.dropFirst() {  // Skip header
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 12 else { continue }

            let confStr = columns[10]
            let text = columns[11]

            guard let confidence = Float(confStr), confidence > 0, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }

            let left = CGFloat(Int(columns[6]) ?? 0)
            let top = CGFloat(Int(columns[7]) ?? 0)
            let width = CGFloat(Int(columns[8]) ?? 0)
            let height = CGFloat(Int(columns[9]) ?? 0)

            let boundingBox = CGRect(x: left, y: top, width: width, height: height)

            blocks.append(OCRResult.TextBlock(
                text: text,
                boundingBox: boundingBox,
                confidence: confidence / 100.0  // Tesseract returns 0-100
            ))

            allText.append(text)
            totalConfidence += confidence
            wordCount += 1
        }

        guard !blocks.isEmpty else {
            throw TesseractError.noTextDetected
        }

        // Group words into lines for better readability
        let groupedBlocks = groupWordsIntoLines(blocks)

        let fullText = groupedBlocks.map { $0.text }.joined(separator: "\n")
        let averageConfidence = wordCount > 0 ? totalConfidence / Float(wordCount) / 100.0 : 0

        let result = OCRResult(
            fullText: fullText,
            blocks: groupedBlocks,
            confidence: averageConfidence
        )

        self.lastOCRResult = result
        return result
    }

    private func groupWordsIntoLines(_ words: [OCRResult.TextBlock]) -> [OCRResult.TextBlock] {
        guard !words.isEmpty else { return [] }

        // Sort by vertical position (top), then horizontal (left)
        let sorted = words.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 10 {
                return a.boundingBox.midY < b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        var lines: [OCRResult.TextBlock] = []
        var currentLineWords: [OCRResult.TextBlock] = []
        var currentLineY: CGFloat = -1

        for word in sorted {
            if currentLineY < 0 || abs(word.boundingBox.midY - currentLineY) <= 10 {
                // Same line
                currentLineWords.append(word)
                currentLineY = word.boundingBox.midY
            } else {
                // New line - flush current line
                if !currentLineWords.isEmpty {
                    lines.append(createLineBlock(from: currentLineWords))
                }
                currentLineWords = [word]
                currentLineY = word.boundingBox.midY
            }
        }

        // Flush last line
        if !currentLineWords.isEmpty {
            lines.append(createLineBlock(from: currentLineWords))
        }

        return lines
    }

    private func createLineBlock(from words: [OCRResult.TextBlock]) -> OCRResult.TextBlock {
        let text = words.map { $0.text }.joined(separator: " ")
        let minX = words.map { $0.boundingBox.minX }.min() ?? 0
        let maxX = words.map { $0.boundingBox.maxX }.max() ?? 0
        let minY = words.map { $0.boundingBox.minY }.min() ?? 0
        let maxY = words.map { $0.boundingBox.maxY }.max() ?? 0
        let avgConfidence = words.reduce(0) { $0 + $1.confidence } / Float(words.count)

        return OCRResult.TextBlock(
            text: text,
            boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            confidence: avgConfidence
        )
    }
}