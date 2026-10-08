# Agents

Scorpio Codes is a macOS 14 SwiftUI app for a Mahindra Scorpio S11 mHawk. It talks to a BLE ELM327-style dongle and reads both the generic OBD fault list and the Bosch factory list. Phone apps miss the factory list. P1340 was stored there while mode 03 reported nothing.

Stay on macOS. Do not add an iOS target, Android, or a classic Bluetooth serial path.

## Layout

- `App/` is the SwiftUI app and the BLE session. It compiles `Sources/OBDCore` into the same target. Do not `import OBDCore` from app files.
- `Sources/OBDCore` is the parser, models, and fault sentences. `Package.swift` exists so `swift test` can build that library. The app does not use the package.
- `project.yml` is the source of the Xcode project. Run `xcodegen generate` after changing it. That command rewrites `App/Info.plist` from `info.properties`. Bluetooth usage strings must stay in `project.yml` or the app aborts on launch with a TCC crash. Launch the `.app` bundle with `open`, not the raw binary.
- Scheme name is `ScorpioCodes`. Local builds are unsigned: `CODE_SIGNING_ALLOWED` is already `NO`.

## Checks

```sh
swift test
xcodegen generate
xcodebuild -project MahindraODBCBle.xcodeproj -scheme ScorpioCodes -destination 'platform=macOS' build
```

Add a parser fixture in `Tests/OBDCoreTests` when you change response parsing. Do not invent a P1 or P3 description. Unknown manufacturer powertrain codes keep the sentence that points at the Scorpio S11 EMS manual. `P1340` is already catalogued.

## Vehicle facts

The live dongle advertises as `OBDBLE`. The engine answers ISO 15765-4 CAN, 11-bit, 500 kbit/s. Engine request is `7E0`, response `7E8`. Functional request is `7DF`. VIN prefix `MA1` is Mahindra.

Supported mode 01 PIDs seen on this car: `01 04 05 0B 0C 0D 0F 10 21 23 33`. There is no oil-pressure PID and no oil-temperature PID. Do not add a fake oil-pressure gauge. The oil lamp is a switch.

`P1340` means the camshaft and crankshaft are out of step. Status `0x28` means confirmed and failed since last clear, not failing now. `P0340` is no cam signal. `P0335` is no crank signal. A missing no-signal code does not prove the sensor is healthy. Mode 03 can stay empty while service 19 still holds the factory code. That record has no timestamp.

## Session rules

Setup order is `ATWS` (use `ATZ` only when the clone answers `?`), then `ATE0 ATL0 ATS1 ATH1 ATAT1 ATCAF1 ATAL ATSP6`, then `0100`. If that probe fails, `ATSP0` and `0100` again. CoreBluetooth callbacks stay on the main queue. One reconnect if the dongle drops during setup, then skip the reset.

Read `03`, `07`, `0A`, `0101`, and `0902` on functional addressing before any physical header change. Factory history then sets `ATSH7E0`, `ATCRA7E8`, flow control, and sends `1902FF`, then `190C`, `190B`, `190D`, `190E`, then `1800FF00` if still empty. Always restore `ATFCSM0`, `ATAR`, and `ATSH7DF` before returning.

Clear all history only from the clear button, ignition on and engine off. Order is diagnostic session `1003`, `14FFFFFF`, `1001`, restore functional addressing, then mode `04`, then read again. A factory clear is accepted only when the payload starts with `54`. Mode `04` alone can succeed and still leave P1340.

Do not send programming session `1002`, security access, writes, actuator tests, routine control, or a bus monitor (`ATMA`, `ATMT`, `ATMR`). A file named `/tmp/scorpio-probe.on` makes the next launch auto-connect and log to `/tmp/scorpio-probe.log`. That is a one-shot debug hook. Do not arm it during normal work, and do not turn it into a user feature.

`FaultStatus` switches must stay exhaustive. `FaultCode.detail` is required. New history rows use status `.history` and look up the catalog on the five-character code, ignoring a failure-type suffix.

## Do not commit

Derived data, `xcuserdata`, `.build`, or `.grok-desktop`.
