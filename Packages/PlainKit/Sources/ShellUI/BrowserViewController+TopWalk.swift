#if canImport(UIKit) && DEBUG
import UIKit

// MARK: - The top bar walk (Debug builds)

extension BrowserViewController {
    /// Debug builds only (`-PlainTopWalk <steps>`, `-PlainTopWalkStep <seconds>`, default 2.5):
    /// walks the top bar through its states on the page on screen, one step per interval, so a
    /// recording of the Duo's inner screen (`simctl io recordVideo --display=<inner>`) gives frame
    /// strips of every collapse and reveal without XCUITest (which waits 60 s for the app to go
    /// idle before each step there). Steps, comma-separated:
    /// `mid` (the page 900 pt down, the bar as it is), `deeper` (700 pt more), `collapse` (the
    /// bar's spring to the slim band, as a release mid-page), `expand` (its spring back, as a move
    /// up), `tap` (a tap on the collapsed band), `top` (the page's top, the bar back, as a status
    /// bar tap), `find`, `reader`, `readerclose`, `back`, `forward`, `split`, `load:<url>`,
    /// `private:<url>` (a new private tab), `scroll` (4,000 pt in 2 s, frame by frame), `wait`.
    /// Each step is logged (`duo` category, notice level: `top walk: <n> <step>`), so a recording's
    /// frames can be matched to it. Not saved, not shipped.
    public func debugTopWalk(_ steps: String?, step: Double?) {
        guard let steps, !steps.isEmpty else { return }
        let list = steps.split(separator: ",").map(String.init)
        let interval = step ?? 2.5
        // `-PlainNoTopBand`: the band's glass off, for an A/B of its cost (`scroll`).
        if ProcessInfo.processInfo.arguments.contains("-PlainNoTopBand") { duo.top.band.glass.isHidden = true }
        Task { [weak self] in
            // After `debugSetUp` opened the pages (1.5 s) and they loaded.
            try? await Task.sleep(for: .seconds(8))
            for (index, name) in list.enumerated() {
                guard let self else { return }
                DuoUIState.logger.notice("top walk: \(index, privacy: .public) \(name, privacy: .public)")
                self.runTopWalkStep(name)
                try? await Task.sleep(for: .seconds(interval))
            }
            DuoUIState.logger.notice("top walk: done")
        }
    }

    private func runTopWalkStep(_ name: String) {
        let scrollView = isShowingReader ? engineUI.reader.webView?.scrollView : pageScrollView
        let top = -(scrollView?.adjustedContentInset.top ?? 0)
        switch name {
        case "mid":
            scrollView?.setContentOffset(CGPoint(x: 0, y: top + 900), animated: false)
        case "deeper":
            if let scrollView {
                scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
            }
        case "collapse":
            debugSettleCollapse(at: ChromeRest.pill.progress)
        case "expand":
            revealChrome(.scrollUp)
        case "tap":
            duo.top.band.onTap()
        case "top":
            scrollView?.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            revealChrome(.pageTop)
        case "find":
            findOnPage()
        case "reader":
            openReader()
        case "readerclose":
            closeReader(animated: true)
        case "back":
            performBack()
        case "forward":
            currentTab?.goForward()
        case "scroll":
            // 4,000 pt down in 2 s at the display's rate, as a long fling: the glass over a moving
            // page, frame by frame (the page's own frame counter reads the cost).
            if let scrollView { TopWalkScroller.run(scrollView, by: 4000, duration: 2) }
        case "split":
            if let current = currentTab { openInOtherPane(current) }
        case let load where load.hasPrefix("load:"):
            if let url = URL(string: String(load.dropFirst(5))) { currentTab?.load(url) }
        case let open where open.hasPrefix("private:"):
            if let url = URL(string: String(open.dropFirst(8))) {
                let tab = session.tabs.newTab(isPrivate: true)
                show(tab)
                tab.load(url)
            }
        default:
            break
        }
    }
}

/// Scrolls a scroll view by a distance over a duration, one display frame at a time.
@MainActor
private final class TopWalkScroller: NSObject {
    private static var running: TopWalkScroller?
    private let scrollView: UIScrollView
    private let start: CGFloat
    private let distance: CGFloat
    private let duration: CFTimeInterval
    private var began: CFTimeInterval = 0
    private var link: CADisplayLink?

    private init(_ scrollView: UIScrollView, distance: CGFloat, duration: CFTimeInterval) {
        self.scrollView = scrollView
        self.start = scrollView.contentOffset.y
        self.distance = distance
        self.duration = duration
    }

    static func run(_ scrollView: UIScrollView, by distance: CGFloat, duration: CFTimeInterval) {
        let scroller = TopWalkScroller(scrollView, distance: distance, duration: duration)
        running = scroller
        let link = CADisplayLink(target: scroller, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        scroller.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        if began == 0 { began = link.timestamp }
        let t = min((link.timestamp - began) / duration, 1)
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        scrollView.contentOffset.y = min(start + distance * CGFloat(t), maxY)
        guard t >= 1 else { return }
        link.invalidate()
        Self.running = nil
    }
}
#endif
