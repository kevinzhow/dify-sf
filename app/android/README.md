# Android client

Dify SF's Flutter app includes a native Android client. It connects to your own
Dify SF server; installing the app does not deploy a server.

## Connect

On first launch, enter the server origin, including `http://` or `https://` and
any port, for example `http://192.168.1.10:8080`. Do not append `/v1` or a console
path. HTTP and HTTPS are both supported; the deployment owner chooses which to use.
HTTPS uses normal Android certificate and hostname validation.
It trusts both system roots and certificates the device owner installs, including
in release builds. This is intentional for private deployments: the owner controls
which certificate authorities the device trusts.

Sign in with an account on that server. The server address is remembered across
restarts. The account menu has **Switch server**; the connection screen also has
an address action before sign-in. Switching closes open pages and stops the old
session. Each server keeps separate sign-in credentials and local edit journals;
switching back restores that server's saved sign-in if it is still valid.

A distributor can set a default origin with
`--dart-define=DIFYSF_SERVER_URL=https://dify.example.com`. Users can still switch
servers. Without that definition, Android opens the server picker. The web app
continues to connect to its own origin.

## Build

Use the Flutter version pinned by this repository and JDK 21. Install the Android
SDK components requested by Flutter (`flutter doctor -v` reports missing tools),
then accept the Android SDK licenses. From `app/`:

```sh
flutter pub get
flutter build apk --debug --split-per-abi
```

The debug application ID is `dev.difysf.dify_sf_app.dev`, so this test build can
coexist with the production package. Profile builds use the `.qa` suffix. Release
builds use `dev.difysf.dify_sf_app`. The minimum Android version is API 24
(Android 7.0).

Android HTTP uses the Dart team's `cronet_http` package and its embedded engine,
so the app does not require Google Play Services. The native canvas uses Flutter
GPU with the existing widget-renderer fallback.

To sign a release, the publisher supplies its own keystore through these
environment variables, without committing them:

- `DIFYSF_ANDROID_KEYSTORE_PATH`
- `DIFYSF_ANDROID_STORE_PASSWORD`
- `DIFYSF_ANDROID_KEY_ALIAS`
- `DIFYSF_ANDROID_KEY_PASSWORD`

Then run `flutter build apk --release --split-per-abi`. Without a publisher's
keystore, the release build remains unsigned; a debug key is never silently used
for the production package. Store publication is a separate release step.

## Validation

Run the server connection and account regression tests from `app/`:

```sh
flutter test test/server_address_test.dart test/server_connection_flow_test.dart \
  test/server_storage_test.dart test/native_connection_layout_test.dart \
  test/settings_server_test.dart test/auth_test.dart
```

Before distributing a build, also install it on an Android device or emulator
and verify first launch, login, restart, server switching, a workflow edit and a
workflow run against the self-hosted suite. Unit tests do not substitute for that
native check. This repository does not add an automatic CI pipeline.
