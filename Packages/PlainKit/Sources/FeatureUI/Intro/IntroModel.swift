#if os(iOS)
import BrowserCore
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
        case promise, inside, icon, blocking, browseForMe, defaultBrowser
    }

    /// The steps in order. Browse for Me only where Apple Intelligence can run (`IntroSetup`),
    /// decided once before the first step; the default-browser step only when its prompts are on.
    private(set) var steps: [Step]
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
    /// The safe area's height, set by the view controller: the steps leave room for the dawn
    /// from it (`IntroLayout`).
    var safeHeight: CGFloat = 0
    /// The window can be a foldable's (`IntroRules.showsUnfoldRow`), set by the view controller
    /// from its traits: only then does "What's inside" promise two pages side by side.
    var canUnfold = false
    /// The on-device model's last answer; nil until the first one.
    private(set) var aiAvailability: AIAvailability?
    /// Apple Intelligence became ready while the intro was up (turned on in Settings, or the
    /// model finished downloading): the step shows its check mark.
    private(set) var aiBecameReady = false
    /// The Browse for Me demo has run its one automatic play.
    var browseDemoPlayed = false

    /// Runs on every step change, for the view controller's mark, field and VoiceOver.
    @ObservationIgnored var onStepChange: ((Step?) -> Void)?
    /// Runs once when the user finishes or skips.
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var didFinish = false

    init(defaultBrowserStep: Bool, icon: AppIconChoice) {
        steps = Step.allCases.filter { $0 != .browseForMe && ($0 != .defaultBrowser || defaultBrowserStep) }
        self.icon = icon
    }

    /// What the Browse for Me step asks of the user now; nil when the step is left out.
    var browseForMe: IntroSetup.BrowseForMe? { aiAvailability.flatMap(IntroSetup.browseForMe) }

    /// A new answer from the model. Before the first step it decides whether the Browse for Me
    /// step is in the intro (after the blocking demo, before the default-browser step); later it
    /// only changes what the step shows, so the steps never change under the user.
    func setAIAvailability(_ answer: AIAvailability) {
        guard answer != aiAvailability else { return }
        let before = aiAvailability
        if step == nil, !didFinish {
            let wanted = IntroSetup.browseForMe(answer) != nil
            if wanted, !steps.contains(.browseForMe), let blocking = steps.firstIndex(of: .blocking) {
                steps.insert(.browseForMe, at: blocking + 1)
            } else if !wanted {
                steps.removeAll { $0 == .browseForMe }
            }
        }
        if answer == .available, let before, before != .available, steps.contains(.browseForMe), step != nil {
            withAnimation(Motion.prefersCrossfade ? IntroMotion.crossfade : IntroMotion.enter) {
                aiAvailability = answer
                aiBecameReady = true
            }
        } else {
            withAnimation(IntroMotion.crossfade) { aiAvailability = answer }
        }
    }

    var isLastStep: Bool { step == steps.last }

    /// The splash ended: show the first step.
    func start() {
        guard step == nil, !didFinish else { return }
        go(to: steps.first)
    }

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
    /// A step leaving: it lifts off like a sheet of paper, fading as it rises a little.
    static let exit = Animation.smooth(duration: 0.38)
    /// A step's parts arriving, one after another.
    static let enter = Animation.spring(duration: 0.52, bounce: 0)
    /// The first part starts after the old step is half gone, so the paper is never empty for long.
    static let enterDelay: Double = 0.16
    /// Between one part and the next.
    static let stagger: Double = 0.065
    /// When a step change has settled (for its signpost): the last part's arrival.
    static let stepSettle: Double = 0.85
    /// The Reduce Motion crossfade.
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// How far a part rises as it arrives, and how far a leaving step lifts.
    static let rise: CGFloat = 16
    static let lift: CGFloat = 10
    /// The dawn moving to a step's place (and the mark with it on the promise step).
    static let dawn = Animation.spring(duration: 0.85, bounce: 0)
    /// The window changing shape between steps: quicker, so it is out of the way before the next
    /// step's headline arrives under it.
    static let dawnStep = Animation.spring(duration: 0.5, bounce: 0)
    /// The blocking demo's page reflow.
    static let reflow = Animation.spring(duration: 0.55, bounce: 0)
    /// The longest the first step waits after the splash for the model's answer (it is usually in
    /// long before the splash ends).
    static let aiAnswerWait: Duration = .milliseconds(400)
    /// How often the Browse for Me step reads the answer again while the model is getting ready.
    static let aiRecheck: Duration = .seconds(2)
}
#endif
