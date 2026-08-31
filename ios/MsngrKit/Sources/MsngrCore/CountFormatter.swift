import Foundation

/// The count next to a menu row that leads to a list: short for a bar, exact
/// under it. Below 1000 the number is itself; above it, one decimal place while
/// that decimal is still meaningful (1.2k), none once it would round to a whole
/// ten (12k), the same step again at a million.
public enum CountFormatter {
    public static func short(_ count: Int) -> String {
        switch count {
        case ..<1000:
            return String(count)
        case ..<1_000_000:
            return scaled(count, by: 1000, suffix: "k")
        default:
            return scaled(count, by: 1_000_000, suffix: "M")
        }
    }

    private static func scaled(_ count: Int, by unit: Int, suffix: String) -> String {
        let value = Double(count) / Double(unit)
        if value < 10 {
            let rounded = (value * 10).rounded() / 10
            if rounded.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(rounded))\(suffix)"
            }
            return "\(rounded)\(suffix)"
        }
        return "\(Int(value.rounded()))\(suffix)"
    }
}
