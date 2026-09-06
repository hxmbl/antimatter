import AppKit

/// The ⌘P palette: a compact floating panel — a search field over the list
/// of dot-commands. Typing filters, ↑/↓ move, Return or double-click picks,
/// Esc dismisses. Picking calls `onPick`; anything that closes it calls
/// `onDismiss` so the pane stops referencing it.
@MainActor
final class CommandPalette: NSObject,
    NSWindowDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate
{
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView(frame: .zero)

    private var commands: [IntentExecution.PaletteCommand] = []
    private weak var anchorWindow: NSWindow?
    private var onPick: ((IntentExecution.PaletteCommand) -> Void)?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false
    private var isPicking = false

    // MARK: Layout

    private let rowHeight: CGFloat = 30
    private let searchHeight: CGFloat = 30
    private let padding: CGFloat = 10
    private let panelWidth: CGFloat = 380
    private let maxVisibleRows = 8

    override init() {
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let surface = NSVisualEffectView(frame: panel.contentView!.bounds)
        surface.material = .hudWindow
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.separatorColor.cgColor
        surface.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(surface)

        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Type to filter commands…"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        surface.addSubview(searchField)

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        surface.addSubview(scrollView)

        relayout()

        // Re-assert focus when the user comes back to the app with the
        // palette still showing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Present the palette as a child of `window`, anchored top-centre.
    func present(
        anchoredTo window: NSWindow,
        onPick: @escaping (IntentExecution.PaletteCommand) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onPick = onPick
        self.onDismiss = onDismiss
        anchorWindow = window
        commands = IntentExecution.paletteCommands(matching: "")
        searchField.stringValue = ""
        tableView.reloadData()
        selectRow(commands.isEmpty ? -1 : 0)
        resetAndPosition(over: window)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        DebugLog.log("command palette opened")
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.close()
        onDismiss?()
        onPick = nil
        onDismiss = nil
    }

    // MARK: Sizing / layout

    private func resetAndPosition(over window: NSWindow) {
        let rowCount = min(max(commands.count, 1), maxVisibleRows)
        let height = padding * 2 + searchHeight + 6 + CGFloat(rowCount) * rowHeight
        var frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        let windowFrame = window.frame
        frame.origin.x = windowFrame.midX - frame.width / 2
        frame.origin.y = windowFrame.maxY - frame.height - 120
        if let screen = window.screen {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        panel.setFrame(frame, display: false)
        relayout()
    }

    private func relayout() {
        let bounds = panel.contentView!.bounds
        searchField.frame = NSRect(
            x: padding,
            y: bounds.height - searchHeight - padding,
            width: bounds.width - padding * 2,
            height: searchHeight)
        scrollView.frame = NSRect(
            x: padding,
            y: padding,
            width: bounds.width - padding * 2,
            height: bounds.height - searchHeight - padding * 2 - 6)
    }

    // MARK: Selection

    private func selectRow(_ index: Int) {
        guard commands.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func pickSelected() {
        guard !commands.isEmpty else { return }
        let index = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard commands.indices.contains(index) else { return }
        // The palette owns the keyboard until it's gone: count the resign
        // that follows handing focus to the note as part of picking, not as
        // a reason to steal focus back after the commit landed.
        isPicking = true
        onPick?(commands[index])
        isPicking = false
        dismiss()
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        pickSelected()
    }

    // MARK: Search field editing

    func controlTextDidChange(_ obj: Notification) {
        commands = IntentExecution.paletteCommands(matching: searchField.stringValue)
        tableView.reloadData()
        selectRow(commands.isEmpty ? -1 : 0)
        if let anchorWindow {
            resetAndPosition(over: anchorWindow)
        }
    }

    func control(
        _ control: NSControl,
        textView fieldEditor: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:":
            pickSelected()
            return true
        case "moveUp:":
            selectRow(max(0, tableView.selectedRow - 1))
            return true
        case "moveDown:":
            selectRow(min(max(commands.count - 1, 0), tableView.selectedRow + 1))
            return true
        case "cancelOperation:":
            dismiss()
            return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: PaletteCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteCell {
            cell = reused
        } else {
            cell = PaletteCell()
            cell.identifier = identifier
        }
        cell.configure(commands[row])
        return cell
    }

    // MARK: Keyboard ownership

    /// The palette always owns the keyboard while the app is active — any
    /// in-app click that would hand focus to the note bounces it back to the
    /// search field. Only a switch to another app frees it.
    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing, !isPicking else { return }
        guard NSApplication.shared.isActive, isShowing else { return }
        reassertKeyboard()
    }

    /// Coming back to the app (with the palette still up) returns focus to
    /// the search field.
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard isShowing else { return }
        reassertKeyboard()
    }

    private var isShowing: Bool {
        panel.isVisible && (panel.parent?.isVisible ?? true)
    }

    private func reassertKeyboard() {
        guard isShowing else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }
}

/// A single palette row: monospaced command name, secondary description.
private final class PaletteCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ command: IntentExecution.PaletteCommand) {
        let name = NSAttributedString(string: command.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        let detail = NSAttributedString(string: "  \(command.description)", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let combined = NSMutableAttributedString()
        combined.append(name)
        combined.append(detail)
        textField?.attributedStringValue = combined
    }
}