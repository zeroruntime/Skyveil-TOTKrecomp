# Skyveil

<p align="center"><b>Tears of the Kingdom for iPhone and iPad, built from your own game files.</b><br>
A native ARM64 compatibility runtime for Apple devices. This is not a CPU emulator.</p>

Skyveil is an iOS-focused fork of [MacNativeGames](https://github.com/ly05010419/MacNativeGames). The game’s ARM64 code runs on the Apple chip in the iPhone or iPad, with platform patches and a Metal graphics layer. An Intel Mac can build the iOS app, but it is only the build host: it does not run the game. The app built here targets ARM64 iOS/iPadOS devices.

The current iOS menu and settings are on the `codex/totk-main-menu` branch. Use that branch for the features described here.

## iOS features

- A main menu with **Play** and **Settings**.
- An optional looping menu video. A local `game_essentials/totk_menu_video.mp4` is not included in Git; if it is absent, the menu uses a dark background.
- **Display** settings: show or hide a compact measured-FPS badge, choose one of the four screen corners, and select a 30 FPS cap or an up-to-60 FPS cap. The 60 FPS option is a cap, not a performance guarantee.
- **Audio** settings: master volume from 0–100. Game audio is mixed with other app audio, so music from Spotify can continue.
- **Controls** settings: enable or disable the phone gyro and vibration.

The menu and settings were tested on an iPhone 14 Pro Max. The iOS deployment target is iOS/iPadOS 26.0. All settings, including FPS and master volume, persist on the device between launches.

## Build on an Intel Mac

### Requirements

- Intel Mac running **macOS 15.6 or later**.
- Use the full **Xcode 26.3** app with the **iOS 26.2 SDK** and Metal tools. The iOS deployment target is 26.0. See [Apple’s Xcode 26.3 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes).
- Xcode command-line tools, Homebrew, Python 3.14, CMake, Ninja and XcodeGen.
- Network access for source and package downloads.
- An iPhone or iPad running iOS/iPadOS 26, an Apple ID configured in Xcode for signing, and Developer Mode enabled on the device.
- Your own uncompressed Tears of the Kingdom base game **1.0.0** as an XCI or NSP, your own `prod.keys`, and optionally your own **1.4.3** update NSP. An NSP base also needs the six shared fonts, which you can extract from your own firmware.

The project’s iOS settings were built on an Intel Mac running macOS 15.7.5 with Xcode 26.3 and the iOS 26.2 SDK. A complete build from a clean clone has not been confirmed.

### 1. Clone this branch

```sh
git clone --branch codex/totk-main-menu https://github.com/zeroruntime/Skyveil-TOTKrecomp.git
cd Skyveil-TOTKrecomp
```

### 2. Install the build tools

```sh
xcode-select --install
brew install xcodegen cmake ninja python@3.14
```

Install the full Xcode app, select it in Xcode’s settings, and install its iOS platform and Metal toolchain. If the Metal tools are missing, run:

```sh
xcodebuild -downloadComponent MetalToolchain
```

### 3. Build the Intel shader translator

A clean checkout of this branch does not include the Intel host translator under `games/totk/prebuilt/macos-x86_64`. The normal build checks for this host tool and its SHA-256 file, then stops if either is missing. Build it locally with the repository script. It requires the **.NET 10 SDK** and network access on its first run. The existing local Intel helper build notes record SDK 10.0.403; that is a record of the local build, not a version enforced by the project. [Download a .NET 10 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/10.0):

```sh
games/totk/tools/totk_xlate/publish_native.sh
```

Install a .NET 10 SDK and make `dotnet` available on your PATH before running the script. It builds for the current Mac architecture and writes both `totk_xlate` and `totk_xlate.sha256`; the app builder verifies the hash automatically. This prepares the host shader tool; you still need to run the normal app build below.

### 4. Build the IPA

For an XCI base and 1.4.3 update:

```sh
python3.14 build_app.py "<base 1.0.0.xci>" -k "<prod.keys>" \
  --update "<1.4.3 update.nsp>" \
  --platform ios --ios-game-data documents \
  -o "<output folder>/TOTK.ipa"
```

For an NSP base, add `--firmware "<your firmware folder>"` to provide shared fonts. Without `--update`, the build uses the base game version 1.0.0. The work folder defaults to `TOTK_build` beside the base game; keep it on an APFS volume with enough space. With `--ios-game-data documents`, the large game image stays outside the IPA.

### 5. Install on the device

Connect and unlock the device, enable Developer Mode, then run:

```sh
python3.14 games/totk/ios/tools/install_device.py "<output folder>/TOTK.ipa" \
  --device "<device name>" \
  --game-data "<work folder>/totk/extracted/v143/romfs/romfs.bin"
```

For a build without an update, use the extracted `v0` folder instead of `v143`. The first installation copies the game image to the app’s Documents container. After installation, open **TOTK** and choose **Play**.

See the [iPhone and iPad install notes](docs/install.md#iphone-and-ipad), [controls](docs/controls.md), and [how it works](docs/how-it-works.md) for more detail.

## Legal

Use only a game you bought and keys or system files dumped from your own Nintendo Switch. This is an independent, non-commercial project and is not affiliated with, endorsed by, or sponsored by Nintendo. The repository contains no game files, keys or firmware. The app you build contains your game data; keep it for your own use and do not share it. Dumping games, keys and system files is subject to local law; follow the laws where you live. Issues or pull requests containing, requesting or linking to game files, keys or firmware will be removed.

The Legend of Zelda, Nintendo and Nintendo Switch are trademarks of Nintendo. Apple, Mac, iPhone, iPad, Apple Vision Pro and Metal are trademarks of Apple Inc. Skyveil is not affiliated with Apple. Other names and trademarks belong to their respective owners.

## Acknowledgements

Skyveil builds on work credited by the upstream project:

- [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) (MIT): the NSO rewriter, Horizon host and NVN-on-Metal layer began with its generic Switch game support.
- [nxnative](https://github.com/seedds/nxnative): the one-script packaging and NSP common-ticket import approach.
- [Ryujinx](https://github.com/Ryujinx/Ryujinx) (MIT): shader translation and system-service reference code.
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache-2.0): translates SPIR-V into Metal Shading Language.
- deko3d (zlib) for texture-layout sizing; bcdec for BC texture decoding; libopus and libvpx (BSD) for audio and pre-rendered video.

## License

This project is licensed under the [MIT License](LICENSE). Third-party code retains its own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
