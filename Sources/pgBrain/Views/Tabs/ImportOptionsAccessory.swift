import AppKit

/// Import options shown inside the Open panel, so picking the file and
/// describing it is one step (encoding matters for legacy Excel exports,
/// delimiter for European CSVs that use `;`).
@MainActor
final class ImportOptionsAccessory {
    private static let delimiters: [(label: String, value: Character)] = [
        ("Comma  ,", ","), ("Semicolon  ;", ";"), ("Tab", "\t"), ("Pipe  |", "|"),
    ]

    let view: NSView
    private let encodingPopup = NSPopUpButton()
    private let delimiterPopup = NSPopUpButton()
    private let headerCheck = NSButton(checkboxWithTitle: "First row is a header", target: nil, action: nil)
    private let emptyNullCheck = NSButton(checkboxWithTitle: "Empty cells are NULL", target: nil, action: nil)

    init(json: Bool) {
        for encoding in Importer.TextEncoding.allCases {
            encodingPopup.addItem(withTitle: encoding.uiLabel)
        }
        for delimiter in Self.delimiters {
            delimiterPopup.addItem(withTitle: delimiter.label)
        }
        headerCheck.state = .on
        emptyNullCheck.state = .on

        let rows: [[NSView]] = json
            ? [[Self.label("Encoding:"), encodingPopup]]
            : [[Self.label("Encoding:"), encodingPopup],
               [Self.label("Delimiter:"), delimiterPopup],
               [NSView(), headerCheck],
               [NSView(), emptyNullCheck]]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        view = container
    }

    var encoding: Importer.TextEncoding {
        Importer.TextEncoding.allCases[max(0, encodingPopup.indexOfSelectedItem)]
    }

    var csvOptions: Importer.Options {
        var options = Importer.Options()
        options.encoding = encoding
        options.delimiter = Self.delimiters[max(0, delimiterPopup.indexOfSelectedItem)].value
        options.hasHeader = headerCheck.state == .on
        options.matchHeaderToColumns = options.hasHeader
        options.emptyAsNull = emptyNullCheck.state == .on
        return options
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }
}
