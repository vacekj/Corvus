import AppKit
import CorvusCore
import SwiftUI

// The message list in AppKit: an NSTableView whose rows are SwiftUI message rows, each in a hosting view of
// its own. SwiftUI's lazy stack updated its whole view graph and built and measured rows on the main thread on
// every scrolled frame; here a frame only moves the table.
//
// A message's row view is built once (a few milliseconds) and kept while it is near the screen, so scrolling
// back and forth only moves views. The same view measures the row: its root layout reports the content's
// height at the table's width, so a row is laid out once for both. Rows are built ahead of the scroll while
// the app is idle.
//
// Heights: rows never built use an estimate. When a measurement replaces an estimate above the visible part,
// the scroll position is corrected so that nothing on screen moves. A row whose content changes height by
// itself (an image arriving, a long text expanded) reports it and the table follows.

/// What a row shows besides its message; together with the message and the width it decides the height.
struct MessageRowShape: Equatable {
    var newDay = false
    var divider = false
    var grouping = MessageGrouping()
    var pending = false
    var avatar = false
}

/// Handle the SwiftUI list uses to scroll the table (and the table's delegate).
@MainActor
final class MessageTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    // Inputs from the SwiftUI list.
    private(set) var key = ""
    private var msgs: [Message] = []
    private var isGroup = false
    private var divider: ChatScrollState.Divider?
    private var pendingTs: Set<Int64> = []
    private var typing = false
    var environment = Environment()
    weak var model: AppModel?

    struct Environment: Equatable {
        var searchHighlightId: String?
        var searchHighlightQuery: String?
        var memberLabels: [String: String] = [:]
        var avatarsVersion = 0
        // Rows are built outside the window: they get the window's look from here.
        var displayScale: CGFloat = 2
        var colorScheme: ColorScheme = .light
    }

    /// Everything a row's view is made from: a kept view whose signature still matches needs no update.
    struct RowSignature: Equatable {
        var message: Message?
        var shape = MessageRowShape()
        var isGroup = false
        var key = ""
        var environment = Environment()
    }

    // State.
    private var shapes: [MessageRowShape] = []
    private var heights: [CGFloat?] = []
    /// Estimates are asked for every row whenever the table reloads: computed once per row and width.
    private var estimates: [CGFloat?] = []
    private var typingRowHeight: CGFloat = 50
    private var measuredWidth: CGFloat = 0
    fileprivate weak var table: NSTableView?
    fileprivate weak var scrollView: NSScrollView?
    private var didInitialScroll = false
    private var boundsObserver: NSObjectProtocol?
    private var idleMeasureScheduled = false
    /// Row views by message id, kept while near the screen (least recently used ones go first).
    private var cells: [String: MessageCellView] = [:]
    private var useCounter = 0
    private var indexOf: [String: Int] = [:]
    /// Rows on screen whose content changed height by itself, applied after the layout pass.
    private var refitted: Set<String> = []

    static let cellLimit = 200
    private static let typingID = "\u{1}typing"

    var rowCount: Int { msgs.count + (typing ? 1 : 0) }

    // MARK: Inputs

    /// New contents from SwiftUI. Rows whose look did not change keep their measured height.
    func update(key: String, msgs newMsgs: [Message], isGroup: Bool, divider: ChatScrollState.Divider?,
                pendingTs: Set<Int64>, typing: Bool, environment env: Environment) {
        let sameMessages = msgs.count == newMsgs.count
            && msgs.withUnsafeBufferPointer { a in newMsgs.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        let envChanged = env != environment
        environment = env
        if sameMessages && key == self.key && isGroup == self.isGroup && divider == self.divider
            && pendingTs == self.pendingTs && typing == self.typing {
            if envChanged { reloadVisible() }
            return
        }
        let oldMsgs = msgs, oldShapes = shapes, oldHeights = heights, oldTyping = self.typing
        let keyChanged = key != self.key
        self.key = key
        msgs = newMsgs
        self.isGroup = isGroup
        self.divider = divider
        self.pendingTs = pendingTs
        self.typing = typing
        shapes = Self.shapes(newMsgs, isGroup: isGroup, divider: divider, pendingTs: pendingTs)
        indexOf.removeAll(keepingCapacity: true)
        for (i, m) in newMsgs.enumerated() { indexOf[m.id] = i }
        if keyChanged { dropCells() }

        guard let table, !keyChanged else {
            heights = Array(repeating: nil, count: newMsgs.count)
            estimates = Array(repeating: nil, count: newMsgs.count)
            table?.reloadData()
            return
        }

        // Which rows changed: matched by message id (messages can be removed, edited, or arrive late).
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(oldMsgs.count)
        for (i, m) in oldMsgs.enumerated() { oldIndex[m.id] = i }
        var newHeights = [CGFloat?](repeating: nil, count: newMsgs.count)
        var newEstimates = [CGFloat?](repeating: nil, count: newMsgs.count)
        let oldEstimates = estimates
        var changed = IndexSet()
        var sameOrder = newMsgs.count >= oldMsgs.count
        for i in newMsgs.indices {
            if let j = oldIndex[newMsgs[i].id] {
                if j != i { sameOrder = false }
                if oldMsgs[j] == newMsgs[i] && oldShapes[j] == shapes[i] {
                    newHeights[i] = oldHeights[j]
                    newEstimates[i] = j < oldEstimates.count ? oldEstimates[j] : nil
                    continue
                }
            } else if i < oldMsgs.count {
                sameOrder = false
            }
            changed.insert(i)
        }
        heights = newHeights
        estimates = newEstimates
        if typing { measureTypingRow() }
        let appended = sameOrder ? IndexSet(integersIn: oldMsgs.count..<newMsgs.count) : IndexSet()

        let anchor = Anchor(self)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        if sameOrder {
            // The usual case: messages added at the end, a few rows changed (receipts, reactions, edits).
            if oldTyping && !typing { table.removeRows(at: IndexSet(integer: oldMsgs.count), withAnimation: []) }
            if !appended.isEmpty { table.insertRows(at: appended, withAnimation: []) }
            if typing && !oldTyping { table.insertRows(at: IndexSet(integer: newMsgs.count), withAnimation: []) }
            let reload = changed.subtracting(appended)
            if !reload.isEmpty {
                measure(reload)
                table.noteHeightOfRows(withIndexesChanged: reload)
                table.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0))
            }
            if typing && oldTyping { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: newMsgs.count)) }
        } else {
            table.reloadData()
        }
        NSAnimationContext.endGrouping()
        anchor.restore()
        measureAroundVisible()
    }

    /// The row views on screen are rebuilt (search hit, member labels, avatars changed).
    func reloadVisible() {
        guard let table else { return }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<rows.location + rows.length),
                         columnIndexes: IndexSet(integer: 0))
    }

    private static func sameRun(_ a: Message, _ b: Message) -> Bool {
        !a.isNotice && !b.isNotice && a.outgoing == b.outgoing && a.authorKey == b.authorKey && abs(a.ts - b.ts) <= Theme.groupGapMs
            && LocalDay.of(a.ts) == LocalDay.of(b.ts)
    }

    private static func shapes(_ msgs: [Message], isGroup: Bool, divider: ChatScrollState.Divider?,
                               pendingTs: Set<Int64>) -> [MessageRowShape] {
        var out = [MessageRowShape](repeating: MessageRowShape(), count: msgs.count)
        msgs.withUnsafeBufferPointer { m in
            var day: Int64 = .min
            for i in m.indices {
                let d = LocalDay.of(m[i].ts)
                var s = MessageRowShape()
                s.newDay = i == 0 || d != day
                day = d
                if let divider { s.divider = m[i].ts == divider.ts && m[i].authorKey == divider.authorKey }
                s.grouping = MessageGrouping(joinedAbove: i > 0 && sameRun(m[i - 1], m[i]),
                                             joinedBelow: i + 1 < m.count && sameRun(m[i], m[i + 1]))
                s.pending = !pendingTs.isEmpty && pendingTs.contains(m[i].ts)
                s.avatar = isGroup && !m[i].outgoing && !s.grouping.joinedBelow
                out[i] = s
            }
        }
        return out
    }

    // MARK: Rows

    /// The SwiftUI view of row `i` (a message, or the typing bubble after the last one), in the layout that
    /// reports its height to `cell`.
    private func rowView(_ i: Int, cell: MessageCellView) -> AnyView {
        guard let model else { return AnyView(EmptyView()) }
        let content: AnyView
        if i >= msgs.count {
            content = AnyView(TypingBubbleRow(key: key, isGroup: isGroup))
        } else {
            let m = msgs[i], s = shapes[i]
            content = AnyView(VStack(spacing: 0) {
                if s.newDay { DateSeparator(date: m.time) }
                if s.divider { UnreadDivider() }
                if m.isNotice {
                    ChatNoticeRow(message: m).padding(.top, s.newDay ? 2 : 10)
                } else {
                    MessageRow(message: m, isGroup: isGroup, grouping: s.grouping, pending: s.pending,
                               avatar: s.avatar ? authorAvatar(m) : nil)
                        .padding(.top, s.grouping.joinedAbove ? 2 : (s.newDay ? 2 : 10))
                }
            }
            .id(m.id)) // state of a reused row (hover, popovers) belongs to its message
        }
        let fit = RowFit { [weak cell] height, width in cell?.fitted(height, width: width) }
        return AnyView(fit {
            content
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(model)
        .environment(\.conversationKey, key)
        .environment(\.searchHighlightId, environment.searchHighlightId)
        .environment(\.searchHighlightQuery, environment.searchHighlightQuery)
        .environment(\.groupMemberLabels, environment.memberLabels)
        .environment(\.displayScale, environment.displayScale)
        .environment(\.colorScheme, environment.colorScheme)
        // What the rows would otherwise inherit from the chat view around the table: set here, a row lays out
        // the same wherever its view is (built off screen, then shown).
        .font(TypeScale.body)
        .environment(\.backgroundProminence, .standard)
        .tint(Theme.signalBlue))
    }

    private func signature(_ i: Int) -> RowSignature {
        if i >= msgs.count { return RowSignature(isGroup: isGroup, key: key, environment: environment) }
        return RowSignature(message: msgs[i], shape: shapes[i], isGroup: isGroup, key: key, environment: environment)
    }

    /// Row `i`'s view: the kept one (updated if its message or look changed) or a new one.
    private func cell(for i: Int) -> MessageCellView {
        let id = i < msgs.count ? msgs[i].id : Self.typingID
        let cell: MessageCellView
        if let c = cells[id] {
            cell = c
        } else {
            cell = MessageCellView()
            cell.rowID = id
            cell.controller = self
            cells[id] = cell
            if cells.count > Self.cellLimit + 20 { evictCells() }
            if cells.count % 50 == 0 { trimOtherLists() }
        }
        let sig = signature(i)
        if cell.signature != sig {
            cell.signature = sig
            cell.setContent(rowView(i, cell: cell))
        }
        useCounter += 1
        cell.lastUse = useCounter
        return cell
    }

    /// Drops the least recently used row views that are not on screen.
    private func evictCells() {
        let idle = cells.values.filter { !$0.isShown }.sorted { $0.lastUse < $1.lastUse }
        for c in idle.prefix(cells.count - Self.cellLimit) {
            cells[c.rowID] = nil
            c.removeFromSuperview()
        }
    }

    private func dropCells() {
        for c in cells.values { c.removeFromSuperview() }
        cells.removeAll()
    }

    /// Row views off screen wait in a hidden view inside the window: a row view that leaves the window and
    /// comes back has its whole layout redone (a few milliseconds), one that stays in it does not.
    fileprivate weak var staging: NSView?

    fileprivate func park(_ cell: MessageCellView) {
        guard let staging, cell.superview !== staging else { return }
        staging.addSubview(cell)
    }

    /// All lists' controllers: the kept lists of chats not on screen give back their row views first.
    private static let all = NSHashTable<MessageTableController>.weakObjects()
    static let totalCellLimit = 400

    override init() {
        super.init()
        Self.all.add(self)
    }

    /// Keeps the row views of all lists under the total: lists not on screen keep only their shown rows.
    private func trimOtherLists() {
        var total = 0
        for c in Self.all.allObjects { total += c.cells.count }
        guard total > Self.totalCellLimit else { return }
        for c in Self.all.allObjects where c !== self && c.key != c.model?.current {
            for cell in c.cells.values where !cell.isShown {
                c.cells[cell.rowID] = nil
                cell.removeFromSuperview()
            }
        }
    }

    /// A row on screen laid out its content at a new height (called inside a layout pass).
    fileprivate func cellRefitted(_ cell: MessageCellView) {
        let first = refitted.isEmpty
        refitted.insert(cell.rowID)
        guard first else { return }
        DispatchQueue.main.async { [weak self] in self?.applyRefitted() }
    }

    private func applyRefitted() {
        let ids = refitted
        refitted.removeAll()
        guard let table else { return }
        let w = width
        var changed = IndexSet()
        for id in ids {
            guard let c = cells[id], c.fittedWidth == w else { continue }
            if id == Self.typingID {
                if typing && typingRowHeight != c.fittedHeight { typingRowHeight = c.fittedHeight; changed.insert(msgs.count) }
            } else if let i = indexOf[id], i < heights.count, heights[i] != c.fittedHeight {
                heights[i] = c.fittedHeight
                changed.insert(i)
            }
        }
        guard !changed.isEmpty else { return }
        let anchor = Anchor(self)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: changed)
        NSAnimationContext.endGrouping()
        anchor.restore()
    }

    private func authorAvatar(_ m: Message) -> NSImage {
        model?.avatars[m.authorKey] ?? Media.placeholderAvatar(key: m.authorKey, title: m.sender.isEmpty ? m.authorKey : m.sender)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row >= msgs.count { return typingRowHeight }
        if let h = heights[row] { return h }
        if let e = estimates[row] { return e }
        let e = estimate(row)
        estimates[row] = e
        return e
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // No identifier: the table does not reuse the view for another row; it stays with its message.
        cell(for: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = PlainRowView()
        v.controller = self
        return v
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Heights

    private var width: CGFloat { table?.tableColumns.first?.width ?? table?.bounds.width ?? 600 }

    private func measureTypingRow() {
        typingRowHeight = cell(for: msgs.count).fit(width: width)
    }

    /// A cheap guess for a row never measured: text lines at the bubble's width, media at their shown size.
    private func estimate(_ i: Int) -> CGFloat {
        let m = msgs[i], s = shapes[i]
        var h: CGFloat = s.grouping.joinedAbove ? 2 : (s.newDay ? 2 : 10)
        if s.newDay { h += 46 }
        if s.divider { h += 36 }
        if m.isNotice { return h + 26 }
        let textWidth = max(120, min(width - 32 - 80 - 44, 620) - 24)
        if !m.text.isEmpty {
            let perLine = max(8, Double(textWidth) / 7.6)
            var lines = 0.0
            for part in m.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines += max(1, (Double(part.count) / perLine).rounded(.up))
            }
            h += CGFloat(lines) * 18
        }
        h += 22 // padding and time row
        for a in m.attachments {
            if a.isImage || a.isVideo || a.isSticker {
                let side: CGFloat = a.isSticker ? 160 : 300
                h += a.width > 0 && a.height > 0 ? min(side, side * CGFloat(a.height) / CGFloat(max(a.width, 1))) + 6 : side * 0.75
            } else {
                h += 48
            }
        }
        if m.quote.valid { h += 52 }
        if !m.reactions.isEmpty { h += 14 }
        if isGroup && !m.outgoing && !s.grouping.joinedAbove { h += 18 }
        return h.rounded()
    }

    /// Measures rows (as laid out at the table's width) that have no height yet, building their views, in the
    /// order given; with a `budget` (seconds), stops once it is spent.
    @discardableResult
    private func measure<S: Sequence<Int>>(_ rows: S, budget: CFTimeInterval = .infinity) -> IndexSet {
        let w = width
        if w != measuredWidth {
            measuredWidth = w
            // another width: every height is different
            heights = Array(repeating: nil, count: msgs.count)
            estimates = Array(repeating: nil, count: msgs.count)
        }
        let started = budget.isFinite ? CACurrentMediaTime() : 0
        var changed = IndexSet()
        for i in rows where i >= 0 && i < msgs.count && heights[i] == nil {
            let h = cell(for: i).fit(width: w)
            if h != (estimates[i] ?? estimate(i)) { changed.insert(i) }
            heights[i] = h
            if budget.isFinite && CACurrentMediaTime() - started > budget { break }
        }
        return changed
    }

    /// Row numbers from `mid` outwards (nearest first) within `lo..<hi`.
    private static func outwards(from mid: Int, _ lo: Int, _ hi: Int) -> [Int] {
        guard lo < hi else { return [] }
        let m = min(max(mid, lo), hi - 1)
        var out: [Int] = []
        out.reserveCapacity(hi - lo)
        var d = 0
        while m - d >= lo || m + d < hi {
            if m - d >= lo { out.append(m - d) }
            if d > 0 && m + d < hi { out.append(m + d) }
            d += 1
        }
        return out
    }

    /// The visible rows are measured, and as many as a few milliseconds allow within a screen above and below
    /// (nearest first), before they are seen; the scroll position is kept where the user put it.
    func measureAroundVisible() {
        guard let table, let scrollView, msgs.count > 0 else { return }
        let visible = scrollView.contentView.bounds
        let shown = table.rows(in: visible)
        var changed = measure(shown.location..<min(msgs.count, shown.location + shown.length))
        let range = table.rows(in: visible.insetBy(dx: 0, dy: -visible.height))
        let mid = shown.location + shown.length / 2
        changed.formUnion(measure(Self.outwards(from: mid, range.location, min(msgs.count, range.location + range.length)),
                                  budget: 0.004))
        if heights.contains(where: { $0 == nil }) { scheduleIdleMeasure() }
        guard !changed.isEmpty else { return }
        let anchor = Anchor(self)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: changed)
        NSAnimationContext.endGrouping()
        anchor.restore()
        scheduleIdleMeasure()
    }

    /// After a chat opens or a scroll ends: the rows around the visible part (up to ten screens, and no more
    /// than the kept views) are built and measured in small steps while nothing else happens, nearest first,
    /// so that scrolling there only has to move them. Only the chat on screen does this (kept chats wait until
    /// opened).
    private func scheduleIdleMeasure() {
        guard !idleMeasureScheduled else { return }
        idleMeasureScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self else { return }
            idleMeasureScheduled = false
            guard let table, let scrollView, msgs.count > 0, key == model?.current else { return }
            if ScrollHold.shared.scrolling { scheduleIdleMeasure(); return } // after the scroll
            let visible = scrollView.contentView.bounds
            let mid = table.row(at: NSPoint(x: 1, y: max(0, min(table.frame.height - 1, visible.midY))))
            guard mid >= 0 else { return }
            let around = table.rows(in: visible.insetBy(dx: 0, dy: -visible.height * 10))
            let reach = Self.cellLimit / 2 - 10
            let lo = max(0, around.location, mid - reach)
            let hi = min(msgs.count, around.location + around.length, mid + reach)
            let todo = Self.outwards(from: mid, lo, hi).filter { self.heights[$0] == nil }
            guard !todo.isEmpty else { return }
            let changed = measure(todo, budget: 0.005) // one step stays well under a frame
            if !changed.isEmpty {
                let anchor = Anchor(self)
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
                NSAnimationContext.endGrouping()
                anchor.restore()
            }
            scheduleIdleMeasure()
        }
    }

    /// Keeps what is on screen in place across height changes: the end of the list if it was in view,
    /// otherwise the first visible row.
    private struct Anchor {
        let controller: MessageTableController
        let atBottom: Bool
        let row: Int
        let offset: CGFloat

        @MainActor init(_ c: MessageTableController) {
            controller = c
            guard let table = c.table, let sv = c.scrollView else { atBottom = false; row = -1; offset = 0; return }
            let visible = sv.contentView.bounds
            atBottom = visible.maxY >= table.frame.height + sv.contentInsets.bottom - 4
            row = table.row(at: NSPoint(x: 1, y: max(0, visible.minY + sv.contentInsets.top + 1)))
            offset = row >= 0 ? table.rect(ofRow: row).minY - visible.minY : 0
        }

        @MainActor func restore() {
            guard let table = controller.table, let sv = controller.scrollView else { return }
            if atBottom || !controller.didInitialScroll {
                controller.scrollToBottom(animated: false)
            } else if row >= 0, row < table.numberOfRows {
                let y = table.rect(ofRow: row).minY - offset
                if abs(y - sv.contentView.bounds.minY) > 0.5 {
                    sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.minX, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
        }
    }

    // MARK: Scrolling

    func attach(table: NSTableView, scrollView: NSScrollView) {
        self.table = table
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    /// Whether the end of the list was in view at the last scroll, and the visible height then.
    private var atBottom = true
    private var clipHeight: CGFloat = 0

    private func scrolled() {
        guard let table, let scrollView, !key.isEmpty else { return }
        let clip = scrollView.contentView
        if clip.bounds.height != clipHeight {
            // The list got shorter or taller (search bar, window resized): its end stays in view if it was.
            clipHeight = clip.bounds.height
            if atBottom && didInitialScroll {
                scrollToBottom(animated: false)
                return
            }
        }
        let visible = clip.bounds
        atBottom = visible.maxY >= table.frame.height + scrollView.contentInsets.bottom - 4
        let visibleMaxY = visible.maxY - scrollView.contentInsets.bottom
        ChatScrollState.of(key).scrolled(nearBottom: ScrollFollow.isNearBottom(contentHeight: table.frame.height,
                                                                                 visibleMaxY: visibleMaxY))
        measureAroundVisible()
    }

    var needsInitialScroll: Bool { !didInitialScroll }

    /// The first time the table has a size: its end in view.
    func laidOut() {
        guard !didInitialScroll, let table, table.bounds.width > 0, rowCount > 0 else { return }
        let last = IndexSet(integersIn: max(0, msgs.count - 40)..<msgs.count)
        let changed = measure(last)
        if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        scrollToBottom(animated: false)
        didInitialScroll = true
        measureAroundVisible()
    }

    func scrollToBottom(animated: Bool) {
        guard let table, let scrollView else { return }
        table.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = max(-scrollView.contentInsets.top, table.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
        scroll(to: y, animated: animated)
    }

    /// Scrolls message `id` into view (`center`: to the middle, else its bottom to the bottom).
    func scrollTo(id: String, center: Bool, animated: Bool) {
        guard let table, let scrollView, let i = msgs.lastIndex(where: { $0.id == id }) else { return }
        measure(IndexSet(integersIn: max(0, i - 30)..<min(msgs.count, i + 30)))
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: max(0, i - 30)..<min(msgs.count, i + 30)))
        let r = table.rect(ofRow: i), clip = scrollView.contentView
        let y = center ? r.midY - clip.bounds.height / 2 : r.maxY - clip.bounds.height + scrollView.contentInsets.bottom
        let maxY = table.frame.height + scrollView.contentInsets.bottom - clip.bounds.height
        scroll(to: min(max(-scrollView.contentInsets.top, y), max(-scrollView.contentInsets.top, maxY)), animated: animated)
    }

    private func scroll(to y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let target = NSPoint(x: clip.bounds.minX, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.scrollView?.reflectScrolledClipView(clip) }
            }
        } else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// A message's row view (kept by the controller while near the screen): the row's SwiftUI content in a
/// hosting view cut off from the window's layout machinery it does not need.
final class MessageCellView: NSHostingView<AnyView> {
    var rowID = ""
    var signature: MessageTableController.RowSignature?
    var lastUse = 0
    weak var controller: MessageTableController?
    /// The content's height when it was last laid out, and at which width.
    private(set) var fittedWidth: CGFloat = 0
    private(set) var fittedHeight: CGFloat = 0

    /// Development counters, logged by the scroll benchmark: layouts, rows given content, and [count, ms]
    /// of layouts per kind (new content, first after entering a window, after a size change, other).
    static var layouts = 0
    static var configured = 0
    static var stats = [[Double]](repeating: [0, 0], count: 4)
    private var configured = false
    private var entered = false
    private var lastSize = NSSize.zero

    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = [] // the table decides the height
        // Rows never sit under the toolbar's safe area as far as their content is concerned. Without this,
        // every scrolled frame moves each row relative to the titlebar, it re-reads its safe-area insets and
        // asks for a constraints pass, which travels up to the window's root SwiftUI view and makes it re-run
        // its layout and preferences on every frame.
        safeAreaRegions = []
    }

    @available(*, unavailable) required init(rootView: AnyView) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// New content: its height is not known until it is laid out.
    func setContent(_ view: AnyView) {
        fittedWidth = 0
        configured = true
        Self.configured += 1
        rootView = view
    }

    /// From the row's root layout, inside a layout pass.
    func fitted(_ height: CGFloat, width: CGFloat) {
        let h = max(1, height.rounded(.up))
        guard width != fittedWidth || h != fittedHeight else { return }
        fittedWidth = width
        fittedHeight = h
        if isShown { controller?.cellRefitted(self) }
    }

    /// In a row of the table (not waiting off screen).
    var isShown: Bool { superview is NSTableRowView && window != nil }

    /// The content's height at `width`, laying the row out at that width first if it was not.
    func fit(width: CGFloat) -> CGFloat {
        if fittedWidth == width && !needsLayout { return fittedHeight }
        if superview == nil { controller?.park(self) } // laid out in the window it will be shown in
        if frame.width != width || frame.height < 1 {
            setFrameSize(NSSize(width: width, height: max(frame.height, fittedHeight, 40)))
        }
        layoutSubtreeIfNeeded()
        guard fittedWidth == width else { return frame.height }
        // Already at the size the table will give it.
        if frame.height != fittedHeight {
            setFrameSize(NSSize(width: width, height: fittedHeight))
            layoutSubtreeIfNeeded()
        }
        return fittedHeight
    }

    /// Rows have nothing that takes keyboard focus (selectable text is an AppKit text view of its own). The
    /// default answer walks the row's focusable views, and the window asks every row that again on each
    /// scrolled frame (for the draggable area under the titlebar).
    override var acceptsFirstResponder: Bool { false }

    /// Asked of every view in the window on each scrolled frame (ordering the window's focus walk); the
    /// hosting view's own answer goes through its view graph.
    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        get { NSApp.userInterfaceLayoutDirection }
        set {}
    }

    /// SwiftUI asks for a constraints pass whenever the row's position in the window changes. The request
    /// travels up to the hosting view that holds the table, which then lays out the whole window on every
    /// scrolled frame. The row has no size constraints (the table sets its frame), so a layout pass of its
    /// own does the same work.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if newValue { needsLayout = true } else { super.needsUpdateConstraints = false }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { entered = true }
    }

    override func layout() {
        Self.layouts += 1
        let kind = configured ? 0 : entered ? 1 : bounds.size != lastSize ? 2 : 3
        configured = false
        entered = false
        lastSize = bounds.size
        let t = CACurrentMediaTime()
        super.layout()
        Self.stats[kind][0] += 1
        Self.stats[kind][1] += (CACurrentMediaTime() - t) * 1000
    }
}

/// A row's root: proposes the cell's width to the content, places it at the top at its own height, and
/// reports that height (the table makes the row that tall).
private struct RowFit: Layout {
    let report: (CGFloat, CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        let h = proposal.height ?? (subviews.first?.sizeThatFits(ProposedViewSize(width: w, height: nil)).height ?? 0)
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let h = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        report(h, bounds.width)
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h))
    }
}

/// No selection or hover look of its own: the rows draw their bubbles.
private final class PlainRowView: NSTableRowView {
    weak var controller: MessageTableController?

    /// Leaving the table: the row's view waits off screen, still in the window.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, let controller {
            for case let cell as MessageCellView in subviews { controller.park(cell) }
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

/// The table in its scroll view, for SwiftUI.
struct MessageTable: NSViewRepresentable {
    let controller: MessageTableController
    let key: String
    let msgs: [Message]
    let isGroup: Bool
    let divider: ChatScrollState.Divider?
    let pendingTs: Set<Int64>
    let typing: Bool
    let environment: MessageTableController.Environment
    let model: AppModel

    func makeCoordinator() -> MessageTableController { controller }

    /// Takes whatever room it is given: SwiftUI never measures the table (through Auto Layout, which it did
    /// on every frame in which a row height changed).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTableContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> MessageTableContainer {
        let table = MessageTableView()
        table.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("messages"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.controller = controller
        table.dataSource = controller
        table.delegate = controller

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        scroll.verticalScrollElasticity = .allowed
        controller.model = model
        controller.attach(table: table, scrollView: scroll)
        let container = MessageTableContainer()
        controller.staging = container.staging
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        apply()
        return container
    }

    func updateNSView(_ container: MessageTableContainer, context: Context) {
        controller.model = model
        apply()
    }

    private func apply() {
        controller.update(key: key, msgs: msgs, isGroup: isGroup, divider: divider, pendingTs: pendingTs,
                          typing: typing, environment: environment)
    }
}

/// Holds the scroll view, sized by autoresizing: what changes inside (the table's height) is not reported
/// to SwiftUI's layout.
final class MessageTableContainer: NSView {
    /// Where the table's row views wait off screen. It is inside the SwiftUI view the table is in (rows
    /// there get the same environment as on screen; elsewhere entering the table redoes their layout).
    let staging: NSView = {
        let v = NSView(frame: .zero)
        v.isHidden = true
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(staging)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}
}

/// Tells the controller when it has its size (the first scroll to the end needs it) and when it changes.
final class MessageTableView: NSTableView {
    weak var controller: MessageTableController?
    private var lastWidth: CGFloat = 0

    // Changes to the rows wait for the end of the table's own layout pass (AppKit warns about reentrancy).
    override func layout() {
        super.layout()
        if bounds.width != lastWidth {
            let first = lastWidth == 0
            lastWidth = bounds.width
            if !first {
                // Another width: heights are measured again, the end or the first visible row stays in place.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<numberOfRows))
                    controller?.measureAroundVisible()
                }
            }
        }
        if controller?.needsInitialScroll == true {
            DispatchQueue.main.async { [weak self] in self?.controller?.laidOut() }
        }
    }

    // Keyboard focus stays in the composer; the rows' own controls take clicks.
    override var acceptsFirstResponder: Bool { false }
}

