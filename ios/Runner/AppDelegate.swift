import AVFoundation
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpeechProbe") {
      SpeechProbe.register(messenger: registrar.messenger())
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

/// Reads test sentences with the system voice, optionally with pronunciations
/// attached to single characters, to find out what the voice misreads and
/// whether a pronunciation attribute can correct it.
enum SpeechProbe {
  private static let synthesizer = AVSpeechSynthesizer()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "anx_reader/speech_probe", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "speak":
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty else {
          result(nil)
          return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)

        let attributed = NSMutableAttributedString(string: text)
        let key = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
        let length = (text as NSString).length
        for mark in args["marks"] as? [[String: Any]] ?? [] {
          guard let start = mark["start"] as? Int, let count = mark["length"] as? Int,
                let notation = mark["notation"] as? String,
                start >= 0, count > 0, start + count <= length else { continue }
          attributed.addAttribute(key, value: notation, range: NSRange(location: start, length: count))
        }
        let utterance = AVSpeechUtterance(attributedString: attributed)
        let voice = pickVoice(named: args["voice"] as? String)
        utterance.voice = voice
        if let rate = args["rate"] as? Double {
          utterance.rate = Float(rate)
        }
        synthesizer.speak(utterance)
        result([
          "name": voice?.name ?? "",
          "identifier": voice?.identifier ?? "",
          "language": voice?.language ?? "",
          "quality": voice?.quality.rawValue ?? 0,
        ])
      case "stop":
        synthesizer.stopSpeaking(at: .immediate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The voice chosen in narration settings, or the best Mandarin voice.
  private static func pickVoice(named name: String?) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    if let name = name, !name.isEmpty {
      let named = voices.filter { $0.name == name }
      if let voice = named.first(where: { $0.language.hasPrefix("zh") }) ?? named.first {
        return voice
      }
    }
    return voices
      .filter { $0.language == "zh-CN" }
      .max { $0.quality.rawValue < $1.quality.rawValue }
      ?? AVSpeechSynthesisVoice(language: "zh-CN")
  }
}
