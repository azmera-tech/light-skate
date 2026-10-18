/// Single switch for demo (no-backend) mode. When true, `ApiClient` never makes a real HTTP
/// call — every request is answered by `MockBackend` instead, and login accepts anything.
///
/// Defaults to false (real backend) for production builds. Override at build time with
/// `--dart-define=DEMO_MODE=true` for a no-backend demo APK — every screen talks to `ApiClient`
/// the same way either way, so no screen code needs to change when this flips. See
/// mobile/README.md "Demo mode" for details.
const bool kDemoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);
