import Foundation
import ResultSchemaKit

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "capture-schema", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "usage: capture-schema source.m methods-catalog.tsv",
        ])
    }
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let catalog = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    guard let row = catalog.split(separator: "\n").first(where: { $0.hasPrefix("display.capture_active\t") }) else {
        throw NSError(domain: "capture-schema", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Pinned catalogue lacks display.capture_active",
        ])
    }
    let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
    guard columns.count > 4 else {
        throw NSError(domain: "capture-schema", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Pinned capture catalogue row is malformed",
        ])
    }
    let expected = String(columns[4]).replacingOccurrences(of: "*", with: "")
    let actual = catalogCell(try NativeExtractor.extract(source: source, function: "vpCapturePerform"))
    guard actual == expected else {
        throw NSError(domain: "capture-schema", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "display.capture_active schema drift\nexpected: \(expected)\nactual: \(actual)",
        ])
    }
    print("display.capture_active native result types and presence passed")
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
