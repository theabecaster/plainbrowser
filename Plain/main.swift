import PerfSignposts
import UIKit

// The earliest point the app's own code runs. The `launch` interval starts here and ends when the
// search field becomes first responder (SceneDelegate). Time before `main` (dyld, static
// initializers) is outside it, and outside `launch.firstFrame` too.
let launchInterval = Signposts.signposter.beginInterval(Signposts.launch)
// Cold launch for the perf gate: ends at the first frame of the first window (SceneDelegate).
let launchFirstFrameInterval = Signposts.signposter.beginInterval(Signposts.launchFirstFrame)

_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
