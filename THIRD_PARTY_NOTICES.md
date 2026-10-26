# Third-party notices

Reach's source code is MIT-licensed (see `LICENSE`). Builds of the apps also contain:

## WebRTC

Google's WebRTC (M154), as the prebuilt `WebRTC.xcframework` from
[stasel/WebRTC](https://github.com/stasel/WebRTC) (release 154.0.0). It is downloaded by Swift Package
Manager when you build (`Packages/ReachKit/Package.swift`, checksum-pinned) and is not stored in this
repository.

WebRTC is distributed under a BSD-style license (included in the framework as
`WebRTC.xcframework/LICENSE`, and at <https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE>)
with an additional patent grant (<https://webrtc.googlesource.com/src/+/refs/heads/main/PATENTS>).
It also contains third-party components under their own licenses, which are listed in the WebRTC
source tree rather than in the framework. If you distribute builds of Reach, include all of these
notices with them.
