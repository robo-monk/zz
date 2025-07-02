import Foundation

@_cdecl("hello")
public func hello() -> Int {

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
