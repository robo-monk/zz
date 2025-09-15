import Foundation
import LocalAuthentication

public func fingerprint() -> Bool {
    let context = LAContext()
    let reason = "Authenticate to unlock the secret"
    var error: NSError?

    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
        let sema = DispatchSemaphore(value: 0)
        var result = false

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            result = success
            sema.signal()
        }

        sema.wait()
        print("Authentication result: \(result)")
        return result
    } else {
        print("Authentication failed")
        return false
    }
}
