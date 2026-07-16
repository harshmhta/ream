import AppKit
import Foundation

/// The stamp catalogue: built-in text stamps (rendered to images so they carry
/// an appearance stream any reader can show), user-supplied image stamps, and
/// dynamic stamps whose `{date}`/`{user}`/`{time}` tokens are filled at
/// placement time.
enum StampLibrary {

    /// A built-in rubber stamp.
    struct BuiltIn: Identifiable {
        let id: String          // stampName written into the annotation
        let label: String       // rendered text (may contain tokens)
        let color: NSColor
        var isDynamic: Bool { label.contains("{") }
    }

    /// The default built-in library from the brief.
    static let builtIns: [BuiltIn] = [
        BuiltIn(id: "Approved",        label: "APPROVED",        color: stampGreen),
        BuiltIn(id: "Draft",           label: "DRAFT",           color: stampBlue),
        BuiltIn(id: "Confidential",    label: "CONFIDENTIAL",    color: stampRed),
        BuiltIn(id: "Reviewed",        label: "REVIEWED",        color: stampBlue),
        BuiltIn(id: "DoNotCopy",       label: "DO NOT COPY",     color: stampRed),
        BuiltIn(id: "Void",            label: "VOID",            color: stampRed),
        BuiltIn(id: "ForCommentOnly",  label: "FOR COMMENT ONLY", color: stampBlue),
        // Dynamic examples — tokens resolved at placement.
        BuiltIn(id: "ReceivedDynamic", label: "RECEIVED {date}", color: stampGreen),
        BuiltIn(id: "ByUserDynamic",   label: "{user} · {time}", color: stampBlue)
    ]

    static func builtIn(id: String) -> BuiltIn? { builtIns.first { $0.id == id } }

    /// Resolve dynamic tokens against the current user/date/time.
    static func resolve(_ text: String, date: Date = Date()) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return text
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{user}", with: NSFullUserName())
    }

    /// Render a built-in stamp's (resolved) text into a badge image with a
    /// rounded border, matching the classic rubber-stamp look.
    static func image(for stamp: BuiltIn, date: Date = Date()) -> NSImage {
        let text = resolve(stamp.label, date: date)
        return textStampImage(text, color: stamp.color)
    }

    /// Suggested placement size (points) for a built-in stamp given its text.
    static func suggestedSize(for stamp: BuiltIn, date: Date = Date()) -> CGSize {
        let text = resolve(stamp.label, date: date)
        let font = NSFont.boldSystemFont(ofSize: 24)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(textSize.width) + 32, height: ceil(textSize.height) + 20)
    }

    /// Draw a text stamp badge into an image with transparent background.
    static func textStampImage(_ text: String, color: NSColor) -> NSImage {
        let font = NSFont.boldSystemFont(ofSize: 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = CGSize(width: ceil(textSize.width) + 32, height: ceil(textSize.height) + 20)
        let image = NSImage(size: size)
        image.lockFocus()
        let inset = NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        let border = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        color.setStroke()
        border.lineWidth = 2.5
        border.stroke()
        let textRect = NSRect(x: (size.width - textSize.width) / 2,
                              y: (size.height - textSize.height) / 2,
                              width: textSize.width, height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    // MARK: Rubber-stamp palette

    private static let stampRed = NSColor(srgbRed: 0.80, green: 0.13, blue: 0.13, alpha: 1)
    private static let stampGreen = NSColor(srgbRed: 0.13, green: 0.55, blue: 0.24, alpha: 1)
    private static let stampBlue = NSColor(srgbRed: 0.13, green: 0.33, blue: 0.70, alpha: 1)
}
