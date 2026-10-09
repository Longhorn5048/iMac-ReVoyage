import AppKit
import SystemExtensions
import Observation

@MainActor @Observable
final class TBVirtualDevices: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    static let shared = TBVirtualDevices()
    static let cameraIdentifier = "com.targetbridge.sender.camera"
    private(set) var state = "not_installed"
    private(set) var busy = false
    @ObservationIgnored private var completion: ((Result<Void, Error>) -> Void)?
    @ObservationIgnored private var activeRequest: OSSystemExtensionRequest?
    @ObservationIgnored private var installer: Process?

    var signingConfigured: Bool {
        let team = Bundle.main.object(forInfoDictionaryKey: "ReVoyageSigningTeam") as? String ?? ""
        return team.count == 10 && team.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }
    func installCamera() {
        guard !busy else { return }
        guard signingConfigured else { state = "signing_required"; return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { state = "move_to_applications"; return }
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.cameraIdentifier, queue: .main))
    }
    func deactivateCamera(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy else {
            completion(.failure(NSError(domain: "ReVoyageVirtualDevices", code: 1, userInfo: [NSLocalizedDescriptionKey:"A device operation is still in progress."]))); return
        }
        // An unsigned build cannot have activated this extension. The native
        // uninstaller independently checks registration before deleting apps.
        guard signingConfigured else { completion(.success(())); return }
        self.completion = completion
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.cameraIdentifier, queue: .main))
    }
    private func submit(_ request: OSSystemExtensionRequest) {
        busy = true; state = "installing"; activeRequest = request
        request.delegate = self; OSSystemExtensionManager.shared.submitRequest(request)
    }
    func installSpeaker() {
        guard !busy else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ReVoyageSpeakerInstaller")
        let process = Process(); process.executableURL = helper
        process.arguments = ["--app", Bundle.main.bundleURL.path]
        process.terminationHandler = { [weak self] task in
            Task { @MainActor [weak self] in
                self?.busy = false; self?.installer = nil
                self?.state = task.terminationStatus == 0 ? "speaker_restart_required" : "install_failed"
            }
        }
        do { busy = true; state = "installing"; installer = process; try process.run() }
        catch { busy = false; installer = nil; state = "install_failed" }
    }
    func installMicrophone() {
        guard !busy else { return }
        guard signingConfigured else { state = "signing_required"; return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ReVoyageDeviceInstaller")
        let process = Process(); process.executableURL = helper
        process.arguments = ["--app", Bundle.main.bundleURL.path]
        process.terminationHandler = { [weak self] task in
            Task { @MainActor [weak self] in
                self?.busy = false; self?.installer = nil
                self?.state = task.terminationStatus == 0 ? "restart_required" : "install_failed"
            }
        }
        do { busy = true; state = "installing"; installer = process; try process.run() }
        catch { busy = false; installer = nil; state = "install_failed" }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { state = "approval_required" }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        busy = false; activeRequest = nil
        state = result == .completed ? "installed" : "restart_required"
        let done = completion; completion = nil
        if result == .completed { done?(.success(())) }
        else { done?(.failure(NSError(domain:"ReVoyageVirtualDevices", code:2, userInfo:[NSLocalizedDescriptionKey:
            "Restart macOS to finish removing the camera extension, then retry uninstall. / 请重启以完成摄像头扩展移除，再重试卸载。"]))) }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        busy = false; activeRequest = nil; state = "install_failed"
        let done = completion; completion = nil
        // Nothing registered: the rest of the role can still be uninstalled.
        if (error as NSError).domain == OSSystemExtensionErrorDomain,
           (error as NSError).code == OSSystemExtensionError.extensionNotFound.rawValue { done?(.success(())) }
        else { done?(.failure(error)) }
    }
}
