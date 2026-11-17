import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ReferenceText {
    static func extract(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw AppFailure("資料を読み込めません：\(url.lastPathComponent)")
            }
            return document.string ?? ""
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func restoreFullText(_ reference: Reference) throws -> Reference {
        guard reference.fullTextAvailable != true else { return reference }
        var result = reference
        // Only the old exact cutoff can contain truncated text. Reuse the copied
        // original, not the user's possibly moved source file.
        if reference.text.count == 20_000 {
            do { result.text = try extract(from: URL(fileURLWithPath: reference.path)) }
            catch { throw AppFailure("「\(reference.name)」の全文を復元できません。資料を開き直してください。\n\(error.localizedDescription)") }
        }
        result.fullTextAvailable = true
        return result
    }
}
