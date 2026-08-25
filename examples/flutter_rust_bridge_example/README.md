# Flutter Rust Bridge example

A Flutter counter app backed by Rust through `flutter_rust_bridge` native
assets. It exercises xcross's iOS build-hook and native-framework packaging.

## Run on iOS

Install the Rust toolchain declared in `rust/rust-toolchain.toml`, connect a
paired iPhone, then run:

```sh
flutter pub get
xcross flutter run -d <device>
```

The app initializes the Rust library before rendering and stores its counter in
Rust, so a working screen and increment button validate both startup and the FFI
bridge.
