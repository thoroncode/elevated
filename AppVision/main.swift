#if os(visionOS)
import ElevatedVision

ElevatedApp.main()
#else
import UIKit
import ElevatedVision

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
#endif
