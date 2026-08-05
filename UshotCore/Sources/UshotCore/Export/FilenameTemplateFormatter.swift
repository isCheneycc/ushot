import Foundation

public struct FilenameTemplateFormatter: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func filename(
        template: String,
        date: Date,
        fileExtension: String = "png"
    ) -> String {
        let components = calendar.dateComponents(
            in: calendar.timeZone,
            from: date
        )
        let replacements: [(String, String)] = [
            ("{yyyy}", padded(components.year, width: 4)),
            ("{MM}", padded(components.month, width: 2)),
            ("{dd}", padded(components.day, width: 2)),
            ("{HH}", padded(components.hour, width: 2)),
            ("{mm}", padded(components.minute, width: 2)),
            ("{ss}", padded(components.second, width: 2))
        ]
        var result = template
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }

        let invalid = CharacterSet(charactersIn: "/:")
        result = result.components(separatedBy: invalid).joined(separator: "-")
        if !result.lowercased().hasSuffix(".\(fileExtension.lowercased())") {
            result += ".\(fileExtension)"
        }
        return result
    }

    private func padded(_ value: Int?, width: Int) -> String {
        String(format: "%0*d", width, value ?? 0)
    }
}
