# Third-Party Notices

KhmerInstaller incorporates or depends on the following third-party
components. Their respective license terms continue to apply.

## Zsign

Used for IPA signing.

License: MIT
Copyright (c) 2026 zhlynn

Full license: `Vendor/Zsign/LICENSE`

## SRP

Used by the RemotePairing authentication implementation.

License: MIT
Copyright (C) 2016 Bouke Haarsma

Full license: `ThirdPartyNotices/SRP-LICENSE`

## Swift Crypto

Used by the RemotePairing cryptographic implementation.

License: Apache License 2.0

Full license: `ThirdPartyNotices/swift-crypto-LICENSE.txt`
Additional notice: `ThirdPartyNotices/swift-crypto-NOTICE.txt`

## BigInt

Present in the resolved Swift package dependencies.

License: MIT
Copyright (c) 2016-2017 Károly Lőrentey

Full license: `ThirdPartyNotices/BigInt-LICENSE.md`

## OpenSSL Swift package

Dependency used by Zsign.

License: Apache License 2.0

Full license: `ThirdPartyNotices/OpenSSL-LICENSE.txt`

## MiniZip

KhmerInstaller includes MiniZip source code through the vendored Zsign dependency.

Original contributors include:

- Gilles Vollant (1998-2010)
- Even Rouault (2007-2008, ZIP64 modifications)
- Mathias Svensson (2009-2010, ZIP64 modifications)

MiniZip uses zlib-style licensing. Original copyright and attribution notices are preserved in the vendored source files.

Some MiniZip code incorporates components from Info-ZIP, which are acknowledged separately below.

## zlib

The vendored Zsign source tree includes zlib source code.

- **Version:** 1.3.1
- **License:** zlib License
- **Copyright:** (C) 1995-2024 Jean-loup Gailly and Mark Adler
- **Source:** `Vendor/Zsign/src/third-party/zlib/`
- **License terms:** `Vendor/Zsign/src/third-party/zlib/zlib.h`

The original copyright and license notices are preserved in the vendored source files.

## Info-ZIP code in MiniZip

The vendored MiniZip `unzip.c` source identifies its reduced
encryption/decryption component as originating from Info-ZIP and
references the Info-ZIP license.

License text included: Info-ZIP license, version 2009-Jan-02.

Full license: `ThirdPartyNotices/Info-ZIP-LICENSE.txt`

The original attribution and license comments remain in the vendored
MiniZip source files.

## Project license

KhmerInstaller's project license is provided in the root `LICENSE` file.
Third-party components remain subject to their respective licenses.

## pymobiledevice3 (development reference)

The pymobiledevice3 project was consulted as a technical reference during development of KhmerInstaller's Apple TV pairing and RemoteXPC behavior. KhmerInstaller does not bundle the pymobiledevice3 Python package as a runtime dependency.
