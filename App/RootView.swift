import SwiftUI

enum Theme {
    static let background = Color(red: 0.07, green: 0.065, blue: 0.055)
    static let card = Color(red: 0.14, green: 0.125, blue: 0.105)
    static let line = Color.white.opacity(0.08)
    static let amber = Color(red: 0.95, green: 0.66, blue: 0.16)
    static let text = Color(red: 0.96, green: 0.94, blue: 0.89)
    static let secondary = Color(red: 0.70, green: 0.65, blue: 0.56)
    static let danger = Color(red: 0.90, green: 0.38, blue: 0.30)
    static let ok = Color(red: 0.49, green: 0.76, blue: 0.48)
}

struct RootView: View {
    @StateObject private var session = BleSession()

    var body: some View {
        NavigationStack {
            Group {
                if session.phase == .ready {
                    CodesView(session: session)
                } else {
                    ScanView(session: session)
                }
            }
            .navigationTitle("Scorpio S11")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if session.phase == .ready {
                    Button("Disconnect") { session.disconnect() }
                        .foregroundStyle(Theme.amber)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
    }
}

struct ScanView: View {
    @ObservedObject var session: BleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let note = session.bluetoothNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text)
                        .card()
                }
                scanButton
                if session.phase == .connecting || session.phase == .settingUp {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(session.phase == .connecting ? "Connecting…" : "Waking the dongle and the engine…")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if case .failed(let message) = session.phase {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.danger)
                        .card()
                }
                deviceSection(title: "Dongles", devices: dongles)
                deviceSection(title: "Other nearby devices", devices: others)
                if session.hasScanned, session.devices.isEmpty, (session.phase == .scanning || session.phase == .idle) {
                    Text("Nothing yet. Stay near the dongle. A classic Bluetooth adapter pairs as a serial port and will not appear in this list.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                Text("Plug the dongle into the 16-pin socket under the dash. Turn the ignition on and leave the engine off. Scorpio S11 is read on CAN, 11-bit IDs, 500 kbit/s.\n\nThe dongle must be Bluetooth Low Energy, usually marked BLE or 4.0.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                Button("Demo readout") { session.loadDemo() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.amber)
                    .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fault codes")
                .font(.largeTitle.bold())
            Text("Mahindra Scorpio S11")
                .font(.title3)
                .foregroundStyle(Theme.secondary)
        }
    }

    private var scanButton: some View {
        Button(action: session.toggleScan) {
            Text(session.phase == .scanning ? "Stop scan" : "Scan for dongle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .disabled(!session.bluetoothReady && session.bluetoothNote != nil && session.phase != .scanning)
    }

    private var dongles: [FoundDevice] {
        session.devices.filter(\.likely).sorted { rank($0.rssi) > rank($1.rssi) }
    }

    private var others: [FoundDevice] {
        session.devices.filter { !$0.likely }.sorted { rank($0.rssi) > rank($1.rssi) }
    }

    private func rank(_ rssi: Int) -> Int {
        rssi == 127 ? -200 : rssi
    }

    @ViewBuilder
    private func deviceSection(title: String, devices: [FoundDevice]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(devices) { device in
                        deviceRow(device)
                        if device.id != devices.last?.id {
                            Divider().overlay(Theme.line)
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func deviceRow(_ device: FoundDevice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                Text(signal(device.rssi))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                if device.lastUsed {
                    Text("Last used")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
            Spacer(minLength: 8)
            Button {
                session.connect(device)
            } label: {
                Text("Connect")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .connecting || session.phase == .settingUp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func signal(_ rssi: Int) -> String {
        if rssi == 127 { return "Signal unknown" }
        let word: String
        if rssi >= -60 { word = "Strong" }
        else if rssi >= -80 { word = "Fair" }
        else { word = "Weak" }
        return "\(word) · \(rssi) dBm"
    }
}

struct CodesView: View {
    @ObservedObject var session: BleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.connectedName ?? "Dongle")
                        .font(.largeTitle.bold())
                    Text("Mahindra Scorpio S11")
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                }
                if let banner = session.banner {
                    Text(banner)
                        .font(.subheadline)
                        .foregroundStyle(session.bannerIsBad ? Theme.danger : Theme.text)
                        .card()
                }
                linkCard
                readButton
                codeSection(.stored, codes: session.stored)
                codeSection(.pending, codes: session.pending)
                codeSection(.permanent, codes: session.permanent)
                codeSection(.history, codes: session.history)
                Button(action: { session.confirmClear = true }) {
                    Text("Clear all history")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                .disabled(session.isBusy)
                Text(session.isDemo
                     ? "Demo mode only clears the sample list."
                     : "Clears the generic list and the factory history, including P1340. There is no date on that record. Permanent codes stay until the repair is confirmed. Ignition on, engine off.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                adapterSection
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .confirmationDialog("Clear all history?", isPresented: $session.confirmClear, titleVisibility: .visible) {
            Button("Clear all history", role: .destructive) { session.clearCodes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isDemo
                 ? "This removes the sample codes from the screen."
                 : "This erases the factory record as well as the generic codes. P1340 will be gone, and nothing will say when it happened. Ignition on, engine off.")
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let protocolName = session.protocolName {
                labeled("Protocol", protocolName)
            }
            if let voltage = session.voltage {
                labeled("OBD port", voltage)
            }
            if let vin = session.vin {
                labeled("VIN", vin)
            }
            if let milOn = session.milOn {
                HStack {
                    Circle()
                        .fill(milOn ? Theme.amber : Theme.ok)
                        .frame(width: 10, height: 10)
                    Text(milOn ? "Check engine lamp is on" : "Check engine lamp is off")
                        .font(.subheadline)
                }
            }
            if let count = session.reportedCount {
                Text(count == 1 ? "Engine reports 1 stored code." : "Engine reports \(count) stored codes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .card()
    }

    private var readButton: some View {
        Button(action: session.readCodes) {
            HStack(spacing: 8) {
                if session.isBusy {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(session.isBusy ? "Reading…" : "Read codes")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy)
    }

    private func codeSection(_ status: FaultStatus, codes: [FaultCode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.title)
                    .font(.headline)
                Spacer()
                Text("\(codes.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            if codes.isEmpty {
                Text("None")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .card()
            } else {
                VStack(spacing: 10) {
                    ForEach(codes) { code in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(code.code)
                                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                                .foregroundStyle(color(for: status))
                            Text(code.summary)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if !code.detail.isEmpty {
                                Text(code.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(code.moduleName)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                        .card()
                        .textSelection(.enabled)
                    }
                }
            }
            if status == .permanent {
                Text("Permanent codes clear themselves after the engine confirms the fault is gone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            if status == .history {
                Text("These stay after the lamp goes out, until the codes are cleared or the engine ages them out.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private var adapterSection: some View {
        DisclosureGroup("Adapter") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(session.logText.isEmpty ? "No traffic yet." : session.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 180)
                HStack {
                    TextField("03", text: $session.commandDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(session.sendManualCommand)
                    Button("Send", action: session.sendManualCommand)
                        .disabled(session.isBusy || session.isDemo)
                }
                if !session.lastCommandResult.isEmpty {
                    Text(session.lastCommandResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .tint(Theme.secondary)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    private func color(for status: FaultStatus) -> Color {
        switch status {
        case .stored, .history: return Theme.amber
        case .pending: return Theme.secondary
        case .permanent: return Theme.danger
        }
    }
}

private extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
