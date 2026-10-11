# webrtc-xcframework

`LiveKitWebRTC.xcframework` for iOS (arm64 device) and macOS (arm64), built
from [webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc) at the commit
behind LiveKit's published release 150.7871.02, with one patch:

- **No `RTCFileLogger`.** It is the only code in the framework that calls
  `stat`, which is in Apple's File Timestamp
  [required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
  category. Without it the framework imports no stat-family function, and
  its privacy manifest declares only System Boot Time.
- **The macOS privacy manifest is where Apple's tools look for it**
  (`Versions/A/Resources/PrivacyInfo.xcprivacy`, not
  `Versions/A/Versions/A/Resources`).

Everything else is unchanged: the same Objective-C API with the `LK` class
prefix, and the same build settings (no H.264, no FFmpeg, no protobuf).

## Use with Swift Package Manager

```swift
.binaryTarget(
    name: "LiveKitWebRTC",
    url: "https://github.com/gagehansberry/webrtc-xcframework/releases/download/150.7871.02-1/LiveKitWebRTC.xcframework.zip",
    checksum: "b7cfd712abde53ce1a38df744144c2c3df371c3994f811b354cf0e1938b11f2c"
)
```

## Build it yourself

```bash
./build.sh            # work directory defaults to ~/Builds
```

Needs Xcode (tested with 27.0) and about 30 GB of disk. The script fetches
depot_tools and the pinned source, applies `patches/`, builds each slice from
clean, refuses any slice that imports `stat`, `fstat`, `fstatat` or `lstat`,
checks where the privacy manifests are, and writes a deterministic zip, so
the checksum above can be reproduced.

| Input | Pinned at |
|---|---|
| Source: webrtc-sdk/webrtc | `ba469aa2093ba950066258ca0a59a6fbd1295582` (M150.7871@{#2}) |
| Recipe: webrtc-sdk/webrtc-build `build/apple/xcframework.sh` | `66ed9c7b07b2ad6ad624df0317e408dca562f91b` |
| `patches/apple_prefix.patch` | from webrtc-build at that commit, unchanged |
| `patches/no-file-timestamp.patch` | this repository |

On iOS the framework links with Apple's `ld` (`use_apple_linker = true`):
the `lld` at this commit cannot read the iOS 27 SDK's library stubs.

## Licence

The framework is WebRTC (BSD-3-Clause, with its patent grant; `LICENSE`
inside the xcframework) and the third-party libraries WebRTC builds in, as
listed by WebRTC's `tools_webrtc/libs/generate_licenses.py`. The build script
and patch in this repository are BSD-3-Clause (`LICENSE`).
