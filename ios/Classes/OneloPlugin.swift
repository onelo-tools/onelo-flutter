import Flutter
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Native iOS bridge for the Onelo Flutter SDK's App Attest support.
///
/// Dart (`lib/src/attest.dart`) owns the token lifecycle (challenge fetch, HTTP
/// exchange, caching). This plugin exposes ONLY the pieces that must run in
/// native Swift because they call Apple's `DCAppAttestService`:
///
///   • `isSupported`                        → Bool
///   • `generateKey`                        → String  (a fresh key id)
///   • `attestKey(keyId, challenge)`        → { keyId, attestation(base64) }
///   • `getBundleId`                        → String? (Bundle.main.bundleIdentifier)
///
/// The `clientDataHash` passed to `attestKey` is `SHA256(challenge)` — computed
/// here so it exactly matches what the backend recomputes and verifies (parity
/// with the Swift SDK's `OneloAppAttest`).
///
/// This class is registered ONLY on iOS (see `pubspec.yaml` `plugin.platforms`).
/// On Android / other platforms the channel does not exist; the Dart side guards
/// every call with a platform check and never invokes it there.
public class OneloPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "onelo/attest",
            binaryMessenger: registrar.messenger()
        )
        let instance = OneloPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(Self.isSupported)

        case "getBundleId":
            result(Bundle.main.bundleIdentifier)

        case "generateKey":
            generateKey(result: result)

        case "attestKey":
            guard let args = call.arguments as? [String: Any],
                  let keyId = args["keyId"] as? String,
                  let challenge = args["challenge"] as? String
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "attestKey requires 'keyId' and 'challenge'",
                    details: nil
                ))
                return
            }
            attestKey(keyId: keyId, challenge: challenge, result: result)

        case "generateAssertion":
            guard let args = call.arguments as? [String: Any],
                  let keyId = args["keyId"] as? String,
                  let clientData = args["clientData"] as? String
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "generateAssertion requires 'keyId' and 'clientData'",
                    details: nil
                ))
                return
            }
            generateAssertion(keyId: keyId, clientData: clientData, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - App Attest

    private static var isSupported: Bool {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) {
            return DCAppAttestService.shared.isSupported
        }
        #endif
        return false
    }

    /// Mint a FRESH App Attest key. An App Attest key can be attested exactly
    /// once, so Dart calls this each time it needs a new attestation.
    private func generateKey(result: @escaping FlutterResult) {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) {
            DCAppAttestService.shared.generateKey { keyId, error in
                if let error = error {
                    result(FlutterError(
                        code: "generate_key_failed",
                        message: error.localizedDescription,
                        details: nil
                    ))
                    return
                }
                result(keyId)
            }
            return
        }
        #endif
        result(FlutterError(
            code: "unsupported",
            message: "App Attest requires iOS 14+",
            details: nil
        ))
    }

    /// Attest `keyId` against `SHA256(challenge)` and return the base64 attestation.
    private func attestKey(keyId: String, challenge: String, result: @escaping FlutterResult) {
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        if #available(iOS 14.0, *) {
            let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
            DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                if let error = error {
                    result(FlutterError(
                        code: "attest_key_failed",
                        message: error.localizedDescription,
                        details: nil
                    ))
                    return
                }
                guard let attestation = attestation else {
                    result(FlutterError(
                        code: "attest_key_failed",
                        message: "attestKey returned no attestation",
                        details: nil
                    ))
                    return
                }
                result([
                    "keyId": keyId,
                    "attestation": attestation.base64EncodedString(),
                ])
            }
            return
        }
        #endif
        result(FlutterError(
            code: "unsupported",
            message: "App Attest requires iOS 14+",
            details: nil
        ))
    }

    /// FAZA 3 (assertion model) — per-request assertion. `clientData` is the FULL
    /// preimage Dart built: `"{METHOD}\n{path?query}\n{challenge}\n{body}"`. We
    /// SHA-256 it HERE (native, like attestKey) so the bytes Apple signs match the
    /// backend's `compute_client_data_hash` exactly. Returns the base64 CBOR assertion.
    private func generateAssertion(keyId: String, clientData: String, result: @escaping FlutterResult) {
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        if #available(iOS 14.0, *) {
            let clientDataHash = Data(SHA256.hash(data: Data(clientData.utf8)))
            DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
                if let error = error {
                    result(FlutterError(
                        code: "generate_assertion_failed",
                        message: error.localizedDescription,
                        details: nil
                    ))
                    return
                }
                guard let assertion = assertion else {
                    result(FlutterError(
                        code: "generate_assertion_failed",
                        message: "generateAssertion returned no data",
                        details: nil
                    ))
                    return
                }
                result(assertion.base64EncodedString())
            }
            return
        }
        #endif
        result(FlutterError(
            code: "unsupported",
            message: "App Attest requires iOS 14+",
            details: nil
        ))
    }
}
