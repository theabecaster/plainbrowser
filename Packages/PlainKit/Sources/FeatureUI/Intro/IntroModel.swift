#if os(iOS)
import DesignSystem
import Observation
import os
import PerfSignposts
import SwiftUI
import UIKit

/// The intro's state: which step is up, the demo toggle and the picked icon. The view controller
/// owns it; the SwiftUI steps read and change it.
@Observable
final class IntroModel {
    enum Step: String, CaseIterable {
        case promise, inside, icon, blocking, defaultBrowser
    }

    /// The steps in order. The default-browser step only when its prompts are on.
    let steps: [Step]
    /// The step on screen; nil during the splash and after the intro ends.
    private(set) var step: Step?
    /// The blocking demo: on is the clean page.
    var blockingOn = false
    /// The demo has run its one automatic flip (it never plays again after the user flips it).
    var blockingDemoPlayed = false
    /// The icon picked on the icon step (the current Home Screen icon to start).
    var icon: AppIconChoice
    /// The previews, decoded off the main thread when the intro starts.
    var iconPreviews: [AppIconChoice: UIImage] = [:]

    /// Runs on every step change, for the view controller's mark, field and VoiceOver.
    @ObservationIgnored var onStepChange: ((Step?) -> Void)?
    /// Runs once when the user finishes or skips.
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var didFinish = false

    init(defaultBrowserStep: Bool, icon: AppIconChoice) {
        steps = Step.allCases.filter { $0 != .defaultBrowser || defaultBrowserStep }
        self.icon = icon
    }

    var isLastStep: Bool { step == steps.last }

    /// The splash ended: show the first step.
    func start() { go(to: steps.first) }

    func next() {
        guard let step, let index = steps.firstIndex(of: step) else { return }
        if index + 1 < steps.count {
            go(to: steps[index + 1])
        } else {
            finish()
        }
    }

    func skip() {
        Signposts.signposter.emitEvent(Signposts.introSkip, "\(self.step?.rawValue ?? "splash", privacy: .public)")
        finish()
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        go(to: nil)
        onFinish?()
    }

    private func go(to next: Step?) {
        withAnimation(Motion.prefersCrossfade ? IntroMotion.crossfade : IntroMotion.exit) { step = next }
        onStepChange?(next)
        guard let next else { return }
        let interval = Signposts.signposter.beginAnimationInterval(Signposts.introStep, "\(next.rawValue, privacy: .public)")
        Task {
            try? await Task.sleep(for: .seconds(IntroMotion.stepSettle))
            Signposts.signposter.endInterval(Signposts.introStep, interval)
        }
    }

    /// An icon change is in flight; picks wait for it (the system takes one at a time).
    private(set) var isChangingIcon = false

    /// Shows the pick at once, then asks the system; a refusal puts the old choice back, so the
    /// same tile can be tried again.
    func pick(_ choice: AppIconChoice) {
        guard choice != icon, !isChangingIcon else { return }
        let previous = icon
        icon = choice
        isChangingIcon = true
        Task {
            let changed = await AppIcons.set(choice)
            isChangingIcon = false
            if !changed { icon = previous }
        }
    }

    func loadPreviews() async {
        for choice in AppIconChoice.allCases where iconPreviews[choice] == nil {
            iconPreviews[choice] = await AppIcons.preview(choice)
        }
    }
}

/// The intro's motion, in one place (docs/research/intro.md has the reasoning).
enum IntroMotion {
    /// A step leaving: blur, fade and a slight shrink.
    static let exit = Animation.smooth(duration: 0.38)
    /// A step's parts arriving, one after another.
    static let enter = Animation.spring(duration: 0.52, bounce: 0)
    /// The first part starts after the old step is half gone, so the field is never empty for long.
    static let enterDelay: Double = 0.16
    /// Between one part and the next.
    static let stagger: Double = 0.065
    /// When a step change has settled (for its signpost): the last part's arrival.
    static let stepSettle: Double = 0.85
    /// The Reduce Motion crossfade.
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// How far a part rises as it arrives, and how blurred it starts.
    static let rise: CGFloat = 18
    static let blur: CGFloat = 12
    /// The blocking demo's page reflow.
    static let reflow = Animation.spring(duration: 0.55, bounce: 0)
}
#endif
