# Amp Workbench

A community-built SwiftUI editor for Yamaha THR II guitar amplifiers. It offers a local sound library, tone editing and history, USB-MIDI control, and an iPhone sound designer. This project is independent of Yamaha and is not endorsed by Yamaha or the artists named in example sounds.

This is a **source snapshot**, separate from the maintainer's private working repository. It deliberately excludes the maintainer's Git history, third-party preset catalogue, downloaded THR Remote files, app artwork, device captures, and credentials. The included example sounds are original approximations created for this app, not artist presets. An empty system app icon is intentional; bring artwork you have rights to before distributing a build.

## What works

- macOS: browse and edit local presets, import/export THR Remote `.thrl6p` and JSON sounds, connect automatically to a THR II over USB MIDI, apply a temporary tone, read it back, and revisit tone history.
- iPhone: browse/edit sounds, share and import validated sound links, create/refine sounds using Apple Intelligence on supported devices, local rules, or a user-supplied OpenAI API key, and connect to an amp over USB-C MIDI.
- A verified THR10II Wireless running firmware 1.50.0b has passed the macOS USB read/write/readback flow. iPhone USB identity and firmware reads have passed on a physical device; full iPhone preset application still needs a physical acceptance test. Other THR II models and firmware are not yet verified. Bluetooth tone control is experimental.

The app writes the **current temporary tone**, not the amp's onboard memory slots. Set the physical listening volume to a comfortable level before applying a sound.

## Build

Requires macOS with Xcode and Swift installed. For a local Mac build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-app.sh
open 'dist/Amp Workbench.app'
```

The iPhone Xcode project is `iOSPrototype/AmpWorkbenchPhone.xcodeproj`. Open it in Xcode and choose your own signing team and bundle identifier for a device build. Simulator builds do not exercise the amp's USB path. `iOSPrototype/project.yml` is the XcodeGen source; both it and the checked-in project use example bundle identifiers and no developer team.

No account or API key is needed to edit bundled sounds. The Mac app can optionally download third-party community sounds from their original sources on demand; those files are not distributed in this repository. Check their own terms before further redistribution.

## AI and optional network services

On iPhone, **Apple Intelligence** creates and refines sounds with Apple's on-device Foundation Models and a local THR renderer. It does not use web search or a cloud AI service. **Local rules** is a separate offline fallback. **My OpenAI key** sends a request directly to OpenAI when selected; the key remains in the device Keychain and OpenAI bills that account. The app never bundles a shared provider key.

The public source build has no hosted catalogue or cloud AI endpoint configured. A separate service can be supplied by setting the HTTPS `AmpWorkbenchServiceBaseURL` Info.plist key to an implementation of the `v1/catalog.json`, `v1/design`, `v1/refine`, and `v1/research` endpoints. Only then is the hosted AI choice shown. Do not put private service tokens into source or build settings.

See [PRIVACY.md](PRIVACY.md) for what the app stores and sends. Source code and app-authored example presets are available under the [MIT license](LICENSE). Yamaha names and marks belong to their owners. External preset archives and assets are not included in that license.
