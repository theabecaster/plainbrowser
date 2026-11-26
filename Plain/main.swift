import PerfSignposts
import UIKit

// The earliest point the app's own code runs. The `launch` interval starts here and ends when the
// search field becomes first responder (SceneDelegate). Time before `main` (dyld, static
// initializers) is outside it; XCTApplicationLaunchMetric covers the whole launch.
let launchInterval = Signposts.signposter.beginInterval(Signposts.launch)

_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
