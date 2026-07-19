# AirPlay Receiver Dependency and License Review

Status: production dependency selection blocked on licensing and physical-device validation.

Last reviewed: 20 July 2026.

This review is an engineering assessment, not legal advice.

## Recommendation

Use a two-step decision:

1. Build the advertisement layer independently in Swift and prove that `Lumina – <Mac name>` appears on the real iPhone. This code can remain MIT-compatible and does not require a receiver library.
2. For local interoperability testing only, evaluate pinned UxPlay v1.73.6 as the protocol core. Do not copy, link, distribute, or production-integrate it until Lumina's license strategy is explicit.

UxPlay is the only reviewed implementation with the maintenance level, legacy-protocol coverage, macOS support, and compressed-video callback needed for a serious proof. It is also GPLv3, which is incompatible with distributing a combined work as MIT-only.

The best technical prototype candidate is UxPlay. There is no reviewed candidate that is both the best technical fit and compatible with distributing Lumina as MIT-only, and there is no maintained, permissively licensed native macOS receiver core that can simply be added to Lumina.

## Candidate evidence and maintenance

Dates below are the reviewed commit or release dates, not repository-page “updated” timestamps.

| Candidate | Exact reviewed revision | Maintenance evidence | macOS / Apple silicon evidence | Initial decision |
| --- | --- | --- | --- | --- |
| [UxPlay](https://github.com/FDH2/UxPlay) | v1.73.6, published 4 Apr 2026; master `3ca7526`, 25 Jun 2026 | Active releases and protocol issue activity | Upstream documents Intel and Apple-silicon builds and reports testing on an M2 Mac | Best technical proof; blocked for MIT-only distribution |
| [AirCapture](https://github.com/libardoram/AirCapture) | `2dc06c8`, 22 Feb 2026 | Very young repository; three commits at review time | Project requires macOS 15+ and Apple silicon; not independently run by Lumina | Architecture evidence only; not a dependency |
| [RPiPlay](https://github.com/FD-/RPiPlay) | `64d0341`, committed 14 Mar 2022 | Effectively inactive | Raspberry Pi/desktop-Linux focus; no supported current macOS/arm64 validation | Superseded by UxPlay; reject |
| [air-screen](https://github.com/yaojunluo/air-screen) | `63f1bc0`, 16 Apr 2026 | Very young repository; three commits at review time | Source targets native macOS, VideoToolbox, and Metal; claims were not independently validated | No usable license grant; reject |
| [SteeBono/airplayreceiver](https://github.com/SteeBono/airplayreceiver) | `806fd39`, 7 Feb 2023 | Stale | Upstream reports .NET Core testing on macOS with an iPhone 12 Pro/iOS 14; no current Apple-silicon proof | Stale runtime and unresolved FairPlay provenance; reject |
| [java-airplay-lib](https://github.com/serezhka/java-airplay-lib) | `0269ad0`, 14 Dec 2022 | Stale | JVM library with no current native-macOS or Apple-silicon validation | Stale, poor native fit, and unresolved FairPlay provenance; reject |
| [apsdk-public](https://github.com/air-display/apsdk-public) | `e7aba62`, 18 Jul 2024 | Limited activity | Claims cross-platform macOS support; not validated on current Apple silicon | Missing FairPlay implementation and inconsistent license notices; reject |
| [Shairport Sync](https://github.com/mikebrady/shairport-sync) | `d6ac53b`, 2 Jul 2026 | Active | Linux, FreeBSD, and OpenBSD are documented targets; macOS is not a supported primary target | Audio only; not a screen-mirroring receiver |

## Per-candidate protocol, media, pairing, and distribution checklist

“Reported” means the upstream project or source states the capability. It is not a Lumina real-device result.

| Candidate | AirPlay behavior and current-iOS evidence | Mirroring / H.264 path | Audio | Pairing, FairPlay, and DRM limits | License and redistribution impact |
| --- | --- | --- | --- | --- | --- |
| UxPlay | Advertises compatibility with AirPlay 2 senders while receiving the legacy mirroring protocol, not the newer encrypted control mode. One upstream report used UxPlay 1.72.2 with iPadOS 26.1 through WSL/Linux; Lumina has no authenticated current-iPhone result for this core. | Yes. The core callback supplies decrypted buffers containing Annex-B H.264 or H.265 NAL units; GStreamer is the default renderer but is replaceable. | Mirror AAC and AirPlay/RAOP formats including ALAC are reported. | Implements legacy pair setup/verify, optional PIN/password, and PlayFair-based SAP handling. Protected Apple TV/DRM content is unsupported; the project questions PlayFair's legal status. | Receiver distribution is GPL-3.0; bundled PlayFair is GPL-3.0. A linked Lumina distribution cannot remain MIT-only. |
| AirCapture | Inherits the vendored UxPlay legacy protocol. The repository claims sender support but supplies no independent current-iOS validation relevant to Lumina. | Yes in source: UxPlay callback → VideoToolbox H.264/H.265 decode → `CVPixelBuffer` → AppKit/SwiftUI presentation. Lumina has not run it. | The callback is wired, but application audio handling is explicitly not implemented. | Inherits UxPlay pairing/FairPlay behavior and limitations; adds an application-level optional PIN flow. | GPL-3.0 because it statically links vendored UxPlay. Architecture evidence only. |
| RPiPlay | Legacy AirPlay mirroring; upstream broadly claims iOS 9+ but has no current-iOS evidence. | Yes. Encrypted mirror transport to H.264 with Raspberry Pi/OpenMAX or desktop GStreamer renderers. | Mirror AAC is supported. | Implements legacy pairing and bundled PlayFair. Protected DRM is unsupported; upstream calls PlayFair's legal status unclear. | GPL-3.0 combined application; unsuitable for MIT-only Lumina and effectively superseded. |
| air-screen | Claims a native AirPlay receiver, but no current-iOS result was independently verified. Some protocol code resembles a conventional RTP/ANNOUNCE flow rather than proving current Apple mirroring interoperability. | Source claims H.264/HEVC depacketization, VideoToolbox, and Metal; no real-device result was verified. | Source claims RTP audio playback. | Source includes PlayFair code identified as ported from RPiPlay, logs sensitive key material in places, and has no demonstrated current pairing result. | No repository license grant. Some copied PlayFair material has GPL provenance. Do not copy, redistribute, or treat it as open source without written permission and a provenance review. |
| SteeBono/airplayreceiver | Calls itself an AirPlay 2 receiver and reports testing only with iOS 14. | Emits decrypted H.264 buffers from a .NET Core receiver; no native VideoToolbox path. | Emits PCM/AAC/ALAC through codec dependencies. | Contains OmgHax/PlayFair-derived FairPlay code. Pair/FairPlay behavior is old and its provenance is not resolved by the repository-level MIT file. | Repository says MIT, but that does not establish clean permission for derived FairPlay material. Do not use pending provenance/legal review. |
| java-airplay-lib | AirPlay 2 server library tested upstream only with iOS 14.0.1. | Exposes decrypted media callbacks; no native renderer or current macOS proof. | Exposes decrypted audio data. | Contains OmgHax/PlayFair-derived code and logs a decrypted AES key in source. Pairing/current-iOS behavior is stale. | Repository says MIT, but that does not establish clean permission for derived FairPlay material. Do not use pending provenance/legal review. |
| apsdk-public | Claims a cross-platform AirPlay receiver; current-iOS behavior is unproven. | Public source has a mirroring SDK shape, but a working encrypted stream cannot be established from the public checkout. | Claims audio support. | The required FairPlay submodule is private/missing; the documented empty fallback does not work. Pairing and DRM compatibility therefore cannot be validated. | Licensing is internally inconsistent: root GPLv2 text, many files GPL-3.0-or-later, and some GPL-2.0-or-later notices. Treat as copyleft and unusable until clarified. |
| Shairport Sync | AirPlay/RAOP audio receiver, including current AirPlay 2 audio work; it is not an AirPlay screen-mirroring implementation. | None. | Yes; this is its purpose. | Audio authentication/timing is outside Lumina's video requirement; it supplies no mirroring FairPlay path. | The project directs distributors to the license notice in each source file; the reviewed components are permissive but require their notices. Capability mismatch rejects it before integration. |

## UxPlay technical fit

Strengths:

- Maintained releases and active protocol issue tracking.
- Documents macOS and Apple-silicon operation.
- Implements Bonjour, RTSP/HTTP, binary plist handling, pairing, FairPlay setup, mirror transport, timing, and reconnect behavior.
- Exposes compressed video after decryption, so Lumina can replace GStreamer with a native VideoToolbox renderer.
- Provides the most complete reviewed legacy-protocol mirroring path. The cited iPadOS 26.1 result used UxPlay 1.72.2 through WSL/Linux and is upstream evidence only, not a Lumina or macOS validation.

Risks and limitations:

- Lumina has not validated it with the actual iPhone 15 Plus on iOS 26.1.
- UxPlay calls this the legacy protocol and warns that future clients may stop supporting it.
- A live iOS 27 beta report documents a newer control setup that fails with the legacy implementation.
- Protected Apple TV/DRM video is unsupported.
- UxPlay's own disclaimer says the legal status of the bundled FairPlay implementation is unclear.
- The default renderer introduces GStreamer, which Lumina neither needs nor should ship. A custom build would still link the receiver core and inherit its license obligations.
- A network-facing C parser requires hardening and fuzzing before production use.

## License analysis

### Lumina

Lumina is distributed under the MIT License.

### UxPlay and AirCapture

UxPlay's repository is GPL-3.0. Its receiver incorporates components with several licenses, but the combined receiver is distributed as GPLv3; the PlayFair component is also GPLv3. AirCapture publishes its UxPlay-based macOS application under GPLv3.

Consequences for Lumina:

- A distributed binary that links UxPlay into Lumina cannot be presented as MIT-only.
- Compliance would normally require a GPLv3-compatible license for the combined work, complete corresponding source, notices, build scripts, and the other GPL conditions.
- Merely running a tightly coupled receiver as a subprocess is not a reliable way to avoid a combined-work analysis.
- The project should not copy implementation code from GPL repositories into an MIT codebase.

Acceptable paths to evaluate with qualified counsel:

1. Relicense the relevant Lumina distribution under GPLv3-compatible terms and comply fully.
2. Obtain a separate commercial license from all necessary copyright holders.
3. Use Apple's authorized MFi/licensed implementation materials where available and commercially appropriate.
4. Build a clean-room implementation using authorized specifications and independently recorded interoperability behavior, with no copied expression.

### `air-screen`

The reviewed repository has no license file or general source-level permission grant. Publicly visible source is not automatically open source. Its PlayFair directory says it was ported from RPiPlay, adding a separate GPL-provenance concern. Do not copy, redistribute, or build on it without written permission and a complete provenance audit.

### MIT-labelled legacy ports

The repository-level MIT files in `SteeBono/airplayreceiver` and `java-airplay-lib` do not by themselves establish clean provenance for the OmgHax/PlayFair-derived FairPlay implementations they contain. Neither is approved for copying or integration until the relevant authorship and license chain is resolved.

### `apsdk-public`

The reviewed checkout is not accurately described by a single GPL version: its root contains the GPLv2 license text, many current source files say GPL-3.0-or-later, and other inherited files say GPL-2.0-or-later. Its required FairPlay submodule is private and missing. Treat it as an unresolved copyleft dependency and do not use it without clarification from the rights holders.

### Apple specifications and MFi

Apple's public [MFi program page](https://mfi.apple.com/en/how-it-works.html) says the program provides technical specifications, components, certification tools, and licensed technologies; its public list includes AirPlay audio. Public materials do not grant a general license to reverse-engineer or distribute AirPlay receiver technology. Product counsel should confirm whether a software video receiver can use an Apple program/SDK and what certification or distribution terms apply.

The advertisement-only proof uses public Bonjour APIs and publishes observed interoperability metadata. It does not implement protected authentication, decrypt media, or claim AirPlay certification.

## Recommended native dependency surface

Regardless of the selected protocol core, the macOS side should prefer system frameworks:

| Framework | Purpose | Distribution impact |
| --- | --- | --- |
| Network | TCP/UDP listeners and Bonjour publication | Apple system framework |
| CryptoKit / Security | Experimental identity generation and Keychain persistence | Apple system frameworks |
| CoreMedia | Format descriptions, timestamps, and sample buffers | Apple system framework |
| VideoToolbox | Hardware H.264 decode | Apple system framework |
| AVFoundation / QuartzCore | Low-latency sample-buffer presentation | Apple system frameworks |
| MetalKit | Optional advanced renderer and privacy effects | Apple system framework |
| OSLog | Redacted diagnostics and signposts | Apple system framework |

Do not add GStreamer to the Lumina app. It is unnecessary for a single native macOS renderer, expands the binary and license surface, and makes notarization and crash diagnosis more complex.

If UxPlay is approved, its likely non-system build dependencies are:

| Dependency | Purpose | License concern |
| --- | --- | --- |
| UxPlay core | AirPlay receiver protocol | GPL-3.0 |
| PlayFair | FairPlay SAP handling | GPL-3.0; project notes legal uncertainty |
| OpenSSL 3 | Pairing and stream cryptography in UxPlay | Apache-2.0, compatible with GPLv3; preserve Apache notices |
| libplist | Binary property lists | LGPL-2.1-or-later; dynamic/static-link obligations differ |
| llhttp | HTTP parsing | MIT |
| Bonjour / DNS-SD | Service discovery | macOS system service |

## Bluetooth keyboard dependency note

Keyboard input is independent of AirPlay and is not part of this receiver proof.

The strongest current feasibility example is [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote), reviewed at `db6c820` from 27 Jun 2026. Its source and published application report a sandboxed Mac App Store implementation using CoreBluetooth HID-over-GATT; Lumina has not independently validated pairing or input delivery. Its source is AGPL-3.0-only with a commercial-license option, so Lumina must not copy it into an MIT build.

| Bluetooth review item | Finding at `db6c820` |
| --- | --- |
| Supported systems | Upstream reports iOS 15+ and macOS 13+; the Xcode project includes macOS and iOS builds. |
| Apple silicon | Native Swift/CoreBluetooth code and a current macOS target; Lumina has not independently run the binary. |
| iPhone target support | Upstream reports iOS/iPadOS as HID hosts for keyboard, consumer, system-control, and relative-mouse reports. |
| Public API path | BLE HOGP is built with public `CBPeripheralManager` APIs and a manually constructed HID service. |
| Private/deprecated path | The separate macOS Bluetooth Classic backend uses deprecated IOBluetooth APIs and a private Boolean getter through KVC. |
| Root or SIP changes | None reported for the BLE path. |
| Sandbox/distribution evidence | The repository carries App Sandbox and Bluetooth entitlements and links to a Mac App Store listing; this is evidence, not Lumina notarization proof. |
| License | AGPL-3.0-only; a commercial license is offered by the project. |

A later clean-room `BluetoothKeyboardPOC` should use:

- Apple's public `CBPeripheralManager` API;
- the Bluetooth SIG [HID over GATT profile](https://www.bluetooth.com/specifications/specs/hid-over-gatt-profile/);
- full 128-bit SIG UUID strings, because current macOS rejects the short HID service UUID form;
- encryption-required characteristics for pairing/bonding;
- App Sandbox plus the Bluetooth entitlement;
- real pairing, relaunch, reboot, sleep/wake, and notarization tests.

This route remains experimental because Apple documents peripheral mode but does not document macOS acting as a HOGP keyboard or the full-UUID compatibility behavior. BLE keyboard can complement WDA; BLE mouse cannot replace absolute WDA touch.

Bluetooth Classic does not supply the normal inbound, host-initiated HID-peripheral flow on macOS because `bluetoothd` owns the HID L2CAP ports. Experimental code can make outbound HIDP connections to a limited set of target stacks, but its deprecated/private-API surface makes it a poor release candidate. That is narrower than saying Classic HID is impossible on macOS.

## Decision record

| Decision | Result |
| --- | --- |
| Replace the native macOS AirPlay receiver immediately | No |
| Add Bonjour advertisement in an isolated target | Yes |
| Copy protocol code from a GPL or unlicensed repository | No |
| Use UxPlay for a private local compatibility experiment | Conditionally, pinned to v1.73.6 and kept outside production/distribution |
| Merge UxPlay into MIT Lumina | Blocked pending an explicit license decision |
| Promise iOS 26.1 or 60 FPS support | No; measure on the real device |
| Add GStreamer | No |
| Keep XCTest/WDA as the touch channel | Yes |
| Add Bluetooth to this AirPlay proof | No |

## Proof acceptance gates

The advertisement milestone passes only when:

- the standalone target builds without changing the production target;
- it advertises a stable `Lumina – <Mac name>` identity under `_airplay._tcp` and `_raop._tcp`;
- `dns-sd` on another process resolves the expected port and TXT record;
- the real iPhone shows a distinct Lumina receiver in Screen Mirroring;
- selecting it reaches the proof listener and produces a bounded, redacted request trace;
- stopping the proof removes both services;
- no native macOS AirPlay Receiver or Screen Recording permission is involved.

Result: passed on 20 July 2026 with the physical iPhone 15 Plus running iOS 26.1. The separate Lumina destination appeared, selection reached the proof listener, and the expected `501 Not Implemented` response ended negotiation. This is not receiver-core or video validation.

The receiver-core milestone passes only after actual authenticated H.264 delivery, VideoToolbox presentation in a normal window, working WDA controls, and the reliability/measurement runs in the architecture document.

## Primary sources

- [UxPlay repository and GPL-3.0 license](https://github.com/FDH2/UxPlay)
- [UxPlay v1.73.6](https://github.com/FDH2/UxPlay/releases/tag/v1.73.6)
- [UxPlay iPadOS 26.1 report](https://github.com/FDH2/UxPlay/issues/480)
- [UxPlay iOS 27 beta incompatibility report](https://github.com/FDH2/UxPlay/issues/535)
- [RPiPlay](https://github.com/FD-/RPiPlay)
- [AirCapture](https://github.com/libardoram/AirCapture)
- [AirScreen source without a license grant](https://github.com/yaojunluo/air-screen)
- [SteeBono/airplayreceiver](https://github.com/SteeBono/airplayreceiver)
- [java-airplay-lib](https://github.com/serezhka/java-airplay-lib)
- [apsdk-public](https://github.com/air-display/apsdk-public)
- [Shairport Sync](https://github.com/mikebrady/shairport-sync)
- [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote)
- [OpenSSL license](https://www.openssl.org/source/license.html)
- [GNU GPL version 3](https://www.gnu.org/licenses/gpl-3.0.html)
- [Apple Bonjour](https://developer.apple.com/bonjour/)
- [Apple TN3179: local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple MFi program](https://mfi.apple.com/en/how-it-works.html)
- [Apple Core Bluetooth peripheral role](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonPeripheralRoleTasks/PerformingCommonPeripheralRoleTasks.html)
- [Bluetooth SIG HID over GATT](https://www.bluetooth.com/specifications/specs/hid-over-gatt-profile/)
