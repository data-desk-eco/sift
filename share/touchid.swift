// touchid — prompt the user for biometric (Touch ID) confirmation.
// Exit 0 on success or when biometrics aren't available; exit 1 on cancel/fail.
//
// Build:   swiftc -O -o touchid touchid.swift
// Run:     ./touchid "Unlock the vault"
//
// First arg, if present, is the localized reason shown next to the prompt.

import Foundation
import LocalAuthentication

let reason: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Confirm to continue"

let ctx = LAContext()
ctx.localizedCancelTitle = "Cancel"

var err: NSError?
guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
    // No biometrics on this Mac — let the caller proceed (mirrors Aileph behaviour).
    exit(0)
}

let sem = DispatchSemaphore(value: 0)
var ok = false
ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                   localizedReason: reason) { success, _ in
    ok = success
    sem.signal()
}
sem.wait()
exit(ok ? 0 : 1)
