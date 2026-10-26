# Security

Reach lets one device control another, so security reports are very welcome.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on this repository
(private vulnerability reporting). Don't open a public issue for anything exploitable.

Include what you found, how to reproduce it, and what an attacker gains. Fixes land on `main`;
there are no maintained release branches.

## What Reach relies on

- Each app keeps its X25519 identity key in the Keychain. The exceptions: if Reach Host can't use
  the Keychain, it runs with a temporary identity that isn't saved; a Simulator build of the iPhone
  app falls back to a file when the Keychain isn't available; and `reach-probe`, the command-line
  test tool, keeps its identities in files.
- Pairing requires a single-use, 128-bit secret shown as a QR code on the Mac (valid 10 minutes).
- Signaling is end-to-end encrypted and authenticated (ChaCha20-Poly1305 with a key from both
  devices' static keys) and carries the WebRTC DTLS fingerprints, so the media and input channels
  are authenticated end to end even though signaling passes through public relays.
- The Mac only accepts sessions, and input, from devices it has paired with. Removing a device ends
  its session at once and refuses it afterwards. If the change can't be saved, Reach Host says so,
  and the device is trusted again the next time Reach Host starts.

See [docs/DESIGN.md](docs/DESIGN.md#networking-works-anywhere) for details, and the README's
*Known limitations* for what Reach does not protect against.
