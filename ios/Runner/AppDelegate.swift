import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SystemDictionary") {
      SystemDictionary.register(messenger: registrar.messenger())
    }
  }
}

/// The dictionaries enabled in iOS Settings (Chinese, English and others Apple
/// licenses), shown in Apple's own look-up panel. Their text is not available
/// to apps, only the panel.
enum SystemDictionary {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "anx_reader/system_dictionary", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let term = ((call.arguments as? [String: Any])?["term"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      switch call.method {
      case "hasDefinition":
        result(!term.isEmpty && UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term))
      case "show":
        guard !term.isEmpty, let presenter = topViewController() else {
          result(false)
          return
        }
        let panel = UIReferenceLibraryViewController(term: term)
        if let popover = panel.popoverPresentationController {
          // iPad presents it as a popover, which needs an anchor.
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        presenter.present(panel, animated: true)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
