import CallKit
import AVFoundation
import Combine
import UIKit

/// Makes real phone calls through the iPhone's native dialer via CallKit.
/// No Twilio, no VoIP — the user's actual phone number shows on caller ID.
class VeraCallManager: NSObject, ObservableObject, CXProviderDelegate {

    @Published var isCallActive = false
    @Published var callContactName: String?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var currentCallUUID: UUID?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber]
        config.iconTemplateImageData = UIImage(systemName: "person.fill")?.pngData()

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Initiate a real phone call through the iPhone's native dialer.
    func makeCall(phone: String, name: String) {
        let uuid = UUID()
        currentCallUUID = uuid
        callContactName = name

        let handle = CXHandle(type: .phoneNumber, value: phone)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        action.contactIdentifier = name

        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error = error {
                print("[CallManager] Call failed: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self?.isCallActive = true
            }
        }
    }

    func endCall() {
        guard let uuid = currentCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { _ in }
        DispatchQueue.main.async {
            self.isCallActive = false
            self.callContactName = nil
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        DispatchQueue.main.async { self.isCallActive = false }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
}
