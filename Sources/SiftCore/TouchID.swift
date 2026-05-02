import Foundation
import LocalAuthentication

/// Touch ID gate. Returns true on biometric success or when biometrics
/// aren't available on this Mac (so CI runners and older hardware
/// without TouchID don't brick on every vault unlock).
public enum TouchID {
    public static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public static func confirm(reason: String) -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"

        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return true
        }

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            ok = success
            sem.signal()
        }
        sem.wait()
        return ok
    }
}
