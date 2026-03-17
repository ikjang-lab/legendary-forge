import Cocoa
import FlutterMacOS
import ApplicationServices

@main
class AppDelegate: FlutterAppDelegate {
    let automation = ForgeAutomationService()

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)

        guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }

        let channel = FlutterMethodChannel(
            name: "com.ikjang.legendary_forge/forge",
            binaryMessenger: controller.engine.binaryMessenger
        )

        let saved = UserDefaults.standard.integer(forKey: "target_level")
        automation.targetLevel = saved == 0 ? 10 : saved

        automation.onStatusUpdate = { status in
            DispatchQueue.main.async {
                channel.invokeMethod("onStatus", arguments: status)
            }
        }

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            let args = call.arguments as? [String: Any]

            switch call.method {
            case "isAccessibilityEnabled":
                result(AXIsProcessTrusted())
            case "openAccessibilitySettings":
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
                result(nil)
            case "saveTargetLevel":
                let level = args?["level"] as? Int ?? 10
                self.automation.targetLevel = level
                UserDefaults.standard.set(level, forKey: "target_level")
                result(nil)
            case "getTargetLevel":
                let v = UserDefaults.standard.integer(forKey: "target_level")
                result(v == 0 ? 10 : v)
            case "startAutomation":
                if let lvl = args?["targetLevel"] as? Int { self.automation.targetLevel = lvl }
                self.automation.start()
                result(nil)
            case "stopAutomation":
                self.automation.stop()
                result(nil)
            case "getIsRunning":
                result(self.automation.isRunning)
            case "setCurrentLevel":
                self.automation.currentLevel = args?["level"] as? Int ?? 0
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
