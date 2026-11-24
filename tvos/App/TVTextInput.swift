//
//  TVTextInput.swift
//  MeloNX tvOS
//
//  The core's "show_text_input" / "show_alert" callbacks (AlertHelper.cs), as the
//  iOS app has them in AlertHandlers.swift. The Switch software keyboard (character
//  names in Diablo II, Animal Crossing, ...) asks for text through show_text_input;
//  with no handler registered the game waited forever at the name screen.
//
//  tvOS shows the text field of an alert with its full-screen keyboard. While the
//  alert is up the emulation screen hands the remote/pad to UIKit, then takes it
//  back for the game.
//

import GameController
import UIKit

enum TVTextInput {
    private struct TextInputRequest: Decodable {
        let title: String?
        let message: String?
        let placeholder: String?
        let callbackId: String

        enum CodingKeys: String, CodingKey {
            case title = "Title", message = "Message", placeholder = "Placeholder", callbackId = "CallbackId"
        }
    }

    private struct AlertRequest: Decodable {
        let title: String?
        let message: String?
        let cancel: Bool?

        enum CodingKeys: String, CodingKey {
            case title = "Title", message = "Message", cancel = "Cancel"
        }
    }

    /// Called once at launch, after the core is initialised.
    static func register() {
        "show_text_input".withCString { name in
            RegisterCallback(name, { raw, _ in
                guard let request: TextInputRequest = TVTextInput.decode(raw) else { return }
                DispatchQueue.main.async { TVTextInput.presentTextInput(request) }
            }, nil)
        }
        "show_alert".withCString { name in
            RegisterCallback(name, { raw, _ in
                guard let request: AlertRequest = TVTextInput.decode(raw) else { return }
                DispatchQueue.main.async { TVTextInput.presentAlert(request) }
            }, nil)
        }
        TVLog.write("text input / alert callbacks registered")
    }

    private static func decode<T: Decodable>(_ raw: UnsafeRawPointer?) -> T? {
        guard let raw else { return nil }
        let data = raw.load(as: CallbackData.self)
        guard let ptr = data.ptr, data.len > 0 else { return nil }
        let bytes = Data(bytes: ptr, count: Int(data.len))     // copy: the buffer is the caller's
        return try? JSONDecoder().decode(T.self, from: bytes)
    }

    private static func presentTextInput(_ request: TextInputRequest) {
        let resultName = "show_text_input_result_\(request.callbackId)"
        TVLog.write("software keyboard: \(request.title ?? "")")

        guard let host = topViewController() else {
            TVLog.write("software keyboard: nothing to present on, returning empty text")
            reply(resultName, text: nil)
            return
        }

        let alert = UIAlertController(title: request.title?.nilIfEmpty ?? "텍스트 입력",
                                      message: request.message?.nilIfEmpty,
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = request.placeholder?.nilIfEmpty
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }

        let gameScreen = host as? GCEventViewController
        let previousInteraction = gameScreen?.controllerUserInteractionEnabled
        gameScreen?.controllerUserInteractionEnabled = true

        func finish(_ text: String?) {
            if let previousInteraction { gameScreen?.controllerUserInteractionEnabled = previousInteraction }
            reply(resultName, text: text)
        }

        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in
            finish(alert.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
            finish(nil)
        })
        host.present(alert, animated: true)
    }

    private static func presentAlert(_ request: AlertRequest) {
        guard let host = topViewController() else { return }
        let alert = UIAlertController(title: request.title, message: request.message, preferredStyle: .alert)
        let gameScreen = host as? GCEventViewController
        let previousInteraction = gameScreen?.controllerUserInteractionEnabled
        gameScreen?.controllerUserInteractionEnabled = true
        let restore: (UIAlertAction) -> Void = { _ in
            if let previousInteraction { gameScreen?.controllerUserInteractionEnabled = previousInteraction }
        }
        alert.addAction(UIAlertAction(title: "확인", style: .default, handler: restore))
        if request.cancel == true {
            alert.addAction(UIAlertAction(title: "취소", style: .cancel, handler: restore))
        }
        host.present(alert, animated: true)
    }

    /// Text back to the waiting core thread; nil/empty = cancelled.
    private static func reply(_ name: String, text: String?) {
        name.withCString { cName in
            if let bytes = text?.data(using: .utf8), !bytes.isEmpty {
                bytes.withUnsafeBytes { buffer in
                    _ = InvokeCallback(cName, buffer.baseAddress, Int32(bytes.count))
                }
            } else {
                _ = InvokeCallback(cName, nil, 0)
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first ?? UIApplication.shared.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
