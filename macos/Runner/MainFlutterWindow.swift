import Cocoa
import FlutterMacOS
import window_manager
import LaunchAtLogin
import Security
import SystemConfiguration

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        FlutterMethodChannel(
            name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any] {
                    LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        FlutterMethodChannel(name: "fluxora/system-proxy", binaryMessenger: flutterViewController.engine.binaryMessenger)
            .setMethodCallHandler { [weak self] call, result in
                self?.handleSystemProxy(call, result: result)
            }

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }


    private var proxyAuthorization: AuthorizationRef?

    private func handleSystemProxy(_ call: FlutterMethodCall, result: FlutterResult) {
        let writing = call.method == "write"
        var prefs: SCPreferences?
        if writing {
            if proxyAuthorization == nil {
                guard AuthorizationCreate(nil, nil, [], &proxyAuthorization) == errAuthorizationSuccess else {
                    result(FlutterError(code: "auth", message: "Could not authorize network preferences", details: nil))
                    return
                }
            }
            prefs = SCPreferencesCreateWithAuthorization(nil, "Fluxora" as CFString, nil, proxyAuthorization)
        } else {
            prefs = SCPreferencesCreate(nil, "Fluxora" as CFString, nil)
        }
        guard let prefs = prefs else {
            result(FlutterError(code: "preferences", message: "Could not open network preferences", details: nil))
            return
        }
        if writing && !SCPreferencesLock(prefs, true) {
            result(FlutterError(code: "lock", message: "Could not lock network preferences", details: nil))
            return
        }
        defer { if writing { SCPreferencesUnlock(prefs) } }
        if call.method == "services" {
            guard let set = SCNetworkSetCopyCurrent(prefs),
                  let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
                result(FlutterError(code: "services", message: "Could not enumerate network services", details: nil))
                return
            }
            result(services.filter {
                SCNetworkServiceGetEnabled($0) && SCNetworkServiceCopyProtocol($0, kSCNetworkProtocolTypeProxies) != nil
            }.compactMap { SCNetworkServiceGetServiceID($0) as String? })
            return
        }
        guard let args = call.arguments as? [String: Any], let id = args["service"] as? String,
              let service = SCNetworkServiceCopy(prefs, id as CFString),
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            result(FlutterError(code: "service", message: "Network service is unavailable", details: nil))
            return
        }
        var configuration = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
        if call.method == "read", let keys = args["keys"] as? [String] {
            result(configuration.filter { keys.contains($0.key) })
        } else if writing, let values = args["values"] as? [String: Any],
                  let expected = args["expected"] as? [String: Any] {
            // Compare under the preferences lock so another application's recent
            // change survives even if it arrives between the Dart read and write.
            for key in values.keys {
                let actual = configuration[key] ?? NSNull()
                guard let previous = expected[key],
                      (actual as? NSObject)?.isEqual(previous) == true else {
                    result(FlutterError(code: "changed", message: "System proxy changed during update", details: nil))
                    return
                }
            }
            for (key, value) in values {
                if value is NSNull { configuration.removeValue(forKey: key) }
                else { configuration[key] = value }
            }
            guard SCNetworkProtocolSetConfiguration(proto, configuration as CFDictionary),
                  SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
                result(FlutterError(code: "write", message: "Could not apply system proxy settings", details: nil))
                return
            }
            result(nil)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    deinit {
        if let reference = proxyAuthorization { AuthorizationFree(reference, []) }
    }

    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}
