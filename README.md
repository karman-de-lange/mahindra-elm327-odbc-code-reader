# Scorpio Codes

Mac app that reads fault codes from a Mahindra Scorpio S11 (mHawk) through a Bluetooth Low Energy OBD-II dongle.

Generic phone apps only ask for the emissions list. On this Bosch engine computer, a code such as P1340 can sit on the factory list and never show up there. Scorpio Codes reads both.

## What it does

- Finds a BLE dongle and connects. Classic Bluetooth serial dongles will not appear.
- Talks ISO 15765-4 CAN, 11-bit IDs, 500 kbit/s.
- Shows stored, pending, and permanent codes, plus factory history kept since the last clear.
- Shows whether the check-engine lamp is on, the port voltage, the protocol, and the VIN.
- **Clear all history** erases the generic list and the factory record. Ignition on, engine off. Permanent codes stay until the engine confirms the repair. The factory record has no date.
- Includes a demo readout and a one-line adapter command.

## Use it

1. Plug the dongle into the 16-pin socket under the dash.
2. Turn the ignition on. Leave the engine off to read or clear codes.
3. Open Scorpio Codes, scan, and connect to the dongle.
4. Read the **Since last clear** section for factory history.

The dongle must be Bluetooth Low Energy, usually marked BLE or 4.0.

## Build

Requires macOS 14 and Xcode. The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project MahindraODBCBle.xcodeproj -scheme ScorpioCodes -destination 'platform=macOS' build
```

Parser tests:

```sh
swift test
```
