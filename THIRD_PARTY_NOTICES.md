# Third-party notices

Reach's source code is MIT-licensed (see `LICENSE`). Builds of the apps also contain:

## WebRTC

Google's WebRTC (M154), as the prebuilt `WebRTC.xcframework` from
[stasel/WebRTC](https://github.com/stasel/WebRTC) (release 154.0.0). It is downloaded by Swift Package
Manager when you build (`Packages/ReachKit/Package.swift`, checksum-pinned) and is not stored in this
repository.

WebRTC is distributed under a BSD-style license with an additional patent grant, and includes
third-party components under their own licenses. The full texts ship inside the framework
(`WebRTC.xcframework/LICENSE`) and are published at
<https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE>. If you distribute builds of Reach,
include those notices with them.
