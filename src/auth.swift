import Foundation
import LocalAuthentication


@_cdecl("hello")
public func hello() -> Int {
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
        // return result
    } else {
        print("Authentication failed")
        // return false
    }
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short

    print("Current date and time: \(formatter.string(from: now))")

    // print hello world
    let randomInt = Int.random(in: 0..<8)
    print("Hello there from swift?!")
    return randomInt;
}
