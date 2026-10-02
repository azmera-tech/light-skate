/// Single switch for demo (no-backend) mode. When true, `ApiClient` never makes a real HTTP
/// call — every request is answered by `MockBackend` instead, and login accepts anything.
///
/// This is intentionally a plain constant, not a runtime setting: flipping it back to `false`
/// (and nothing else) restores the exact real-backend behavior the app had before — every
/// screen talks to `ApiClient` the same way either way, so no screen code needs to change
/// when this flips. See mobile/README.md "Demo mode" for details.
const bool kDemoMode = true;
