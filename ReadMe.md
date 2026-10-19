<div align="center">
  <img src="Screenshots/Icon.png" width="100" height="100" alt="KhmerInstaller Logo">

  <h1>KhmerInstaller</h1>

  <p>
    An iOS app for signing tvOS IPA packages and installing them wirelessly on a compatible Apple TV.
  </p>

  <p>
    <img src="https://img.shields.io/badge/Platform-iOS-blue" alt="iOS">
    <img src="https://img.shields.io/badge/Target-tvOS-blue" alt="tvOS">
    <img src="https://img.shields.io/badge/iOS-18%2B-green" alt="iOS 18+">
    <img src="https://img.shields.io/badge/Installation-Wireless-brightgreen" alt="Wireless Installation">
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/License-GPL--3.0-orange" alt="GPL-3.0">
    </a>
    <a href="https://ko-fi.com/thedevilz">
      <img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white" alt="Support on Ko-fi">
    </a>
  </p>
</div>

## What It Does

- Runs directly on an iPhone and performs the Apple TV workflow wirelessly.
- Does not require a PC, Mac, or Linux computer for normal signing and installation use after KhmerInstaller is installed on the iPhone.
- Pairs with a compatible Apple TV.
- Imports a tvOS IPA selected by the user.
- Manages signing certificates and provisioning profiles used for IPA signing.
- Validates signing credentials and relevant IPA information before signing.
- Re-signs and packages the selected tvOS IPA.
- Prepares the signed IPA for installation on the paired Apple TV.
- Starts installation and displays installation status and results.
- Includes safeguards for failed or cancelled workflows and cleanup of temporary signing workspaces.
  <h2>Screenshots</h2>

<h3>Setup & Signing</h3>
<p align="center">
  <img src="Screenshots/Setup.png" width="850" alt="KhmerInstaller Setup and Signing">
</p>

<h3>Wireless Apple TV Installation</h3>
<p align="center">
  <img src="Screenshots/Installation.png" width="850" alt="KhmerInstaller Wireless Installation">
</p>

## Tested Devices & Compatibility

KhmerInstaller has been tested on the following devices:

| Device | Operating System | Status |
|---|---|---|
| iPhone 15 Pro Max | iOS 18+ | ✅ Tested |
| Apple TV 4K | tvOS 27.0 | ✅ Tested |
| Apple TV HD | tvOS 26.6 | ✅ Tested |

**Note:** Other iPhone and Apple TV models may work but have not been officially tested.

## Build from Source

KhmerInstaller is a native Swift iOS application built with Xcode.

### Requirements

- Mac with Xcode
- iPhone running iOS 18.0 or later
- Apple Developer account with the required signing capabilities
- Compatible Apple TV

### Build Instructions

1. Clone the repository:
   ```bash
   git clone https://github.com/konrepo/KhmerInstaller.git
   cd KhmerInstaller
   ```
2. Open `KunInstaller.xcodeproj` in Xcode.
3. Select the `KunInstaller` scheme and your iPhone.
4. Under **Signing & Capabilities**, select your Apple Developer Team for both `KunInstaller` and `KunInstallerTunnel`.
5. Configure your own identifiers in **Build Settings** for both targets:
   - `APP_BUNDLE_ID` — Your unique application Bundle ID.
   - `APP_GROUP_ID` — Your registered App Group identifier.
6. Enable **Network Extensions (Packet Tunnel)** and **App Groups** for both targets.
7. Ensure your provisioning profiles support the required entitlements.
8. Build and run KhmerInstaller on your iPhone.
The Packet Tunnel Bundle ID is automatically derived from `APP_BUNDLE_ID`. Both targets share the configured App Group.

### Wireless Installation

1. Connect your iPhone and Apple TV to the same local network.
2. Pair KhmerInstaller with your Apple TV.
3. Import your signing certificate and provisioning profile.
4. Select and sign a compatible tvOS IPA.
5. Install the signed IPA wirelessly on Apple TV.

**Note:** A Mac with Xcode is required to build KhmerInstaller from source. Once installed, signing and wireless installation work directly from your iPhone without a computer.

## Project Scope

- KhmerInstaller is an iPhone app designed to sign and install tvOS IPAs wirelessly, directly from the phone to a compatible Apple TV.
- A separate PC, Mac, or Linux computer is not required for the app's normal operating workflow; a Mac with Xcode is still needed to build the iOS app from source.
- KhmerInstaller is intended for tvOS IPA signing and Apple TV installation.
- The app implements its pairing and RemoteXPC-related functionality natively in Swift.
- The pymobiledevice3 Python package is a development reference and is not bundled as a runtime dependency.
- An Apple Developer signing identity, appropriate provisioning profile, and compatible entitlements may be required to sign and install an IPA. Requirements depend on the app being signed and the target device.

## Third-Party Components

The project includes Zsign and uses Swift packages and other third-party code.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the accompanying license files for attributions and applicable license terms.

## License

KhmerInstaller is distributed under the **GNU General Public License, version 3 (GPL-3.0)**.

See [LICENSE](LICENSE) for the full license text. Third-party components remain subject to their respective license terms.

## Support KhmerInstaller

KhmerInstaller is a free and open-source project.

If you enjoy using KhmerInstaller and would like to support future development, consider buying me a coffee.

☕ [Support TheDevilz on Ko-fi](https://ko-fi.com/thedevilz)

## Disclaimer

KhmerInstaller is an independent community project and is not affiliated with, endorsed by, or sponsored by Apple Inc.

Use only IPA files and signing credentials that you are authorized to use.
