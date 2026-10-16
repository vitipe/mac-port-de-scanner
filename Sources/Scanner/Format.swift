import Foundation

enum Format {
    static func bytes(_ count: Int64) -> String {
        // "0 KB" en vez de "Zero KB".
        count.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 archivo" : "\(count.formatted()) archivos"
    }

    static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "" }
        return (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }
}
