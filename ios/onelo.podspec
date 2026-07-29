#
# Native iOS plugin layer for the Onelo Flutter SDK.
# Bridges Apple App Attest (DCAppAttestService) to Dart over the
# `onelo/attest` MethodChannel so the SDK can send an X-Attest-Token header.
#
# Autolinked: `flutter pub get` in the host app writes this pod into the
# generated Podfile; `pod install` compiles OneloPlugin into the app. No manual
# Podfile edit is required.
#
Pod::Spec.new do |s|
  s.name             = 'onelo'
  s.version          = '1.26.0'
  s.summary          = 'Onelo Flutter SDK — iOS App Attest bridge.'
  s.description      = <<-DESC
Native iOS plugin for the Onelo Flutter SDK. Bridges Apple App Attest
(DCAppAttestService) to Dart so the SDK can attest the device and send an
X-Attest-Token header on every transport. No-op on unsupported devices.
                       DESC
  s.homepage         = 'https://github.com/onelo-tools/onelo-flutter'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Onelo' => 'support@onelo.tools' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  # Flutter's minimum; the App Attest calls are individually gated with
  # `@available(iOS 14.0, *)` and a runtime `isSupported` check.
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
  # DeviceCheck (DCAppAttestService) + CryptoKit ship with the SDK; no extra
  # linker flags are needed — they are weak-linked and gated at runtime.
end
