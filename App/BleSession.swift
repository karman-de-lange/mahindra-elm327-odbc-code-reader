import Combine
import CoreBluetooth
import Foundation

#if os(iOS)
import UIKit
#endif

struct FoundDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var likely: Bool
    var lastUsed: Bool
}

enum LinkPhase: Equatable {
    case idle
    case scanning
    case connecting
    case settingUp
    case ready
    case failed(String)
}

private enum LinkError: Error, Equatable, LocalizedError {
    case timeout
    case disconnected
    case notReady

    var errorDescription: String? {
        switch self {
        case .timeout: return "The dongle did not answer in time."
        case .disconnected: return "The dongle disconnected."
        case .notReady: return "The dongle is not ready."
        }
    }
}

/// BLE central for ELM327-style OBD dongles.
///
/// Scorpio S11 (mHawk) answers ISO 15765-4, 11-bit IDs, 500 kbit/s.
/// The app tries that protocol first, then lets the dongle search.
final class BleSession: NSObject, ObservableObject {
    @Published private(set) var phase: LinkPhase = .idle
    @Published private(set) var bluetoothReady = false
    @Published private(set) var bluetoothNote: String?
    @Published private(set) var devices: [FoundDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var protocolName: String?
    @Published private(set) var voltage: String?
    @Published private(set) var vin: String?
    @Published private(set) var milOn: Bool?
    @Published private(set) var reportedCount: Int?
    @Published private(set) var stored: [FaultCode] = []
    @Published private(set) var pending: [FaultCode] = []
    @Published private(set) var permanent: [FaultCode] = []
    @Published private(set) var history: [FaultCode] = []
    @Published private(set) var banner: String?
    @Published private(set) var bannerIsBad = false
    @Published private(set) var logText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isDemo = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastCommandResult = ""
    @Published var commandDraft = ""
    @Published var confirmClear = false

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var port: Port?
    private var waiter: Waiter?
    private var sessionGeneration = UUID()
    private var didStartSetup = false
    private var skipReset = false
    private var reconnects = 0
    private var userDisconnect = false
    private var ending = false
    private var pendingServices = 0
    private var didSelectPort = false
    private var usingAutoProtocol = false
    private var probeArmed = false
    private var probeScanStarted = false
    private var probeLoggedNames: Set<String> = []

    private let lastKey = "lastDongleUUID"
    private let probeFlagPath = "/tmp/scorpio-probe.on"
    private let probeLogPath = "/tmp/scorpio-probe.log"

    override init() {
        super.init()
        probeArmed = FileManager.default.fileExists(atPath: probeFlagPath)
        if probeArmed {
            try? Data().write(to: URL(fileURLWithPath: probeLogPath))
            noteProbe("probe armed")
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    init(startBluetooth: Bool) {
        super.init()
        if startBluetooth {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    static func preview() -> BleSession {
        let session = BleSession(startBluetooth: false)
        session.loadDemo()
        return session
    }

    func toggleScan() {
        if phase == .scanning {
            stopScan()
            phase = .idle
            return
        }
        startScan()
    }

    func startScan() {
        guard let central else {
            bluetoothNote = "Bluetooth is unavailable."
            return
        }
        guard central.state == .poweredOn else {
            applyBluetoothState(central.state)
            return
        }
        devices = []
        hasScanned = true
        phase = .scanning
        bluetoothNote = nil
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        central?.stopScan()
        if phase == .scanning {
            phase = .idle
        }
    }

    func connect(_ device: FoundDevice) {
        guard let central, let peripheral = peripherals[device.id] else { return }
        guard phase != .connecting, phase != .settingUp else { return }
        stopScan()
        sessionGeneration = UUID()
        ending = false
        userDisconnect = false
        didStartSetup = false
        didSelectPort = false
        skipReset = false
        reconnects = 0
        isDemo = false
        isBusy = true
        clearReadings()
        logText = ""
        banner = nil
        connectedName = device.name
        phase = .connecting
        connected = peripheral
        peripheral.delegate = self
        appendLog("Connecting to \(device.name)")
        central.connect(peripheral, options: nil)
        watchConnectTimeout()
    }

    private func watchConnectTimeout() {
        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.sessionGeneration == generation, self.phase == .connecting else { return }
            self.fail("The dongle did not connect. Move closer and try again.")
        }
    }

    func disconnect() {
        sessionGeneration = UUID()
        userDisconnect = true
        isBusy = false
        isDemo = false
        clearReadings()
        banner = nil
        connectedName = nil
        phase = .idle
        setIdleTimer(false)
        failWaiter(LinkError.disconnected)
        if let connected, let central {
            central.cancelPeripheralConnection(connected)
        }
        self.connected = nil
        port = nil
    }

    func readCodes() {
        if isDemo {
            loadDemo()
            return
        }
        guard phase == .ready, !isBusy else { return }
        isBusy = true
        let generation = sessionGeneration
        Task {
            defer { self.finishBusy(generation) }
            await self.readModes(generation: generation)
        }
    }

    func clearCodes() {
        guard !isBusy else { return }
        if isDemo {
            stored = []
            pending = []
            permanent = []
            history = []
            milOn = false
            reportedCount = 0
            banner = "Sample history cleared on screen only."
            bannerIsBad = false
            return
        }
        guard phase == .ready else { return }
        isBusy = true
        let generation = sessionGeneration
        Task {
            defer { self.finishBusy(generation) }
            await self.performClear(generation: generation)
        }
    }

    func sendManualCommand() {
        let command = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !command.isEmpty else { return }
        guard !isDemo else {
            banner = "Connect a dongle before sending a command."
            bannerIsBad = false
            return
        }
        guard phase == .ready, !isBusy else { return }
        if ["ATMA", "ATMT", "ATMR"].contains(where: { command.hasPrefix($0) }) {
            banner = "That command streams forever, so the app will not send it."
            bannerIsBad = true
            return
        }
        let compact = command.replacingOccurrences(of: " ", with: "")
        guard (1...40).contains(compact.count), compact.unicodeScalars.allSatisfy({ $0.isASCII && !Character($0).isNewline }) else {
            banner = "Send one short command, such as 03 or ATDP."
            bannerIsBad = true
            return
        }
        isBusy = true
        let generation = sessionGeneration
        Task {
            defer { self.finishBusy(generation) }
            let result = await self.sendResult(command, timeout: 8)
            guard await self.isCurrent(generation) else { return }
            await MainActor.run {
                switch result {
                case .success(let text):
                    self.lastCommandResult = text
                        .replacingOccurrences(of: "\r", with: "\n")
                        .replacingOccurrences(of: ">", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let error):
                    self.lastCommandResult = error.localizedDescription
                }
            }
        }
    }

    func loadDemo() {
        stopScan()
        isDemo = true
        phase = .ready
        connectedName = "Demo dongle"
        protocolName = "ISO 15765-4 CAN 11-bit 500 kbit/s"
        voltage = "12.4 V"
        vin = "TESTVIN0000000001"
        banner = "Sample readout. This did not come from a vehicle."
        bannerIsBad = false
        stored = ObdResponse.parseFaults(response: "7E8 07 43 00 87 04 01 02 34\n>", status: .stored).codes
        pending = []
        permanent = ObdResponse.parseFaults(response: "7E8 03 4A 00 87\n>", status: .permanent).codes
        history = ObdResponse.parseHistory(response: "7E8 07 59 02 FF 00 87 00 28\n>").codes
        milOn = true
        reportedCount = 3
        isBusy = false
    }

    private func performSetupAndRead(generation: UUID) async {
        guard await isCurrent(generation) else { return }
        await MainActor.run { self.phase = .settingUp }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard await isCurrent(generation) else { return }

        if !skipReset {
            let warm = await sendResult("ATWS", timeout: 4)
            if case .success(let text) = warm, text.contains("?") {
                _ = await sendResult("ATZ", timeout: 5)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard await isCurrent(generation) else { return }
        }

        for command in ["ATE0", "ATL0", "ATS1", "ATH1", "ATAT1", "ATCAF1", "ATAL", "ATSP6"] {
            _ = await sendResult(command, timeout: 2.5)
            if await lost(generation) { return }
        }

        if let voltage = await readVoltage() {
            await MainActor.run { self.voltage = voltage }
        }

        var linked = await probe()
        if await lost(generation) { return }
        if !linked {
            _ = await sendResult("ATSP0", timeout: 2.5)
            usingAutoProtocol = true
            linked = await probe()
            if await lost(generation) { return }
        }

        let described = await sendResult("ATDP", timeout: 3)
        let engineLinked = linked
        let auto = usingAutoProtocol
        let hint = await MainActor.run { self.ignitionHint() }
        await MainActor.run {
            if case .success(let text) = described, let name = self.cleanProtocol(text) {
                self.protocolName = name
            } else if auto {
                self.protocolName = "Auto-detected OBD protocol"
            } else {
                self.protocolName = "ISO 15765-4 CAN 11-bit 500 kbit/s"
            }
            self.phase = .ready
            self.setIdleTimer(true)
            if !engineLinked {
                self.banner = hint
                self.bannerIsBad = true
            } else {
                self.banner = nil
                self.bannerIsBad = false
            }
        }
        if linked {
            await readModes(generation: generation)
        }
        if probeArmed {
            await runCapabilityProbe(generation: generation, linked: linked)
        }
    }

    private func readModes(generation: UUID) async {
        guard await isCurrent(generation) else { return }
        await MainActor.run {
            self.stored = []
            self.pending = []
            self.permanent = []
            self.history = []
            self.banner = nil
            self.bannerIsBad = false
        }
        await readFaults(.stored, command: "03", generation: generation)
        await readFaults(.pending, command: "07", generation: generation)
        await readFaults(.permanent, command: "0A", generation: generation)
        if await lost(generation) { return }

        if case .success(let text) = await sendResult("0101", timeout: 6),
           let status = ObdResponse.parseMonitor(response: text) {
            await MainActor.run {
                self.milOn = status.milOn
                self.reportedCount = status.storedCodeCount
            }
        }
        if case .success(let text) = await sendResult("0902", timeout: 8),
           let vin = ObdResponse.parseVIN(text) {
            await MainActor.run { self.vin = vin }
        }
        await readHistory(generation: generation)
    }

    /// Mode 03 is empty once the lamp goes out. Mahindra keeps that lamp on UDS 19
    /// until a clear or until the controller ages the record out.
    private func readHistory(generation: UUID) async {
        if await lost(generation) { return }
        _ = await sendResult("ATSH7E0", timeout: 3)
        _ = await sendResult("ATCRA7E8", timeout: 3)
        _ = await sendResult("ATFCSH7E0", timeout: 3)
        _ = await sendResult("ATFCSD300000", timeout: 3)
        _ = await sendResult("ATFCSM1", timeout: 3)

        var chosen: FaultRead?
        var rejection: [String] = []
        var linkFailed = false

        if await isCurrent(generation) {
            switch await sendResult("1902FF", timeout: 12) {
            case .success(let text):
                let read = ObdResponse.parseHistory(response: text)
                if read.linkFailed {
                    linkFailed = true
                } else if !read.codes.isEmpty {
                    chosen = read
                } else {
                    rejection = read.rejected
                }
            case .failure:
                break
            }
        }

        if chosen == nil, !linkFailed, await isCurrent(generation) {
            var collected: [FaultCode] = []
            for command in ["190C", "190B", "190D", "190E"] {
                if await lost(generation) { break }
                guard case .success(let text) = await sendResult(command, timeout: 4) else { continue }
                let read = ObdResponse.parseHistory(response: text)
                if read.linkFailed {
                    linkFailed = true
                    break
                }
                collected.append(contentsOf: read.codes)
            }
            var unique: [FaultCode] = []
            for code in collected where !unique.contains(where: { $0.id == code.id }) {
                unique.append(code)
            }
            if !unique.isEmpty {
                chosen = FaultRead(codes: unique, noData: false, linkFailed: false, rejected: [])
                rejection = []
            }
        }

        if chosen == nil, !linkFailed, await isCurrent(generation) {
            switch await sendResult("1800FF00", timeout: 12) {
            case .success(let text):
                let read = ObdResponse.parseHistory(response: text)
                if read.linkFailed {
                    linkFailed = true
                } else if !read.codes.isEmpty {
                    chosen = read
                } else if !read.rejected.isEmpty {
                    rejection = read.rejected
                } else if read.noData {
                    rejection = []
                }
            case .failure:
                break
            }
        }

        if await isCurrent(generation) {
            _ = await sendResult("ATFCSM0", timeout: 2)
            _ = await sendResult("ATAR", timeout: 2)
            _ = await sendResult("ATSH7DF", timeout: 2)
        }

        guard await isCurrent(generation) else { return }
        let codes = chosen?.codes ?? []
        await MainActor.run {
            self.history = codes
            guard self.banner == nil else { return }
            let nothingCurrent = self.stored.isEmpty && self.pending.isEmpty && self.permanent.isEmpty
            if linkFailed {
                self.banner = "The dongle lost the engine while reading history."
                self.bannerIsBad = true
            } else if codes.isEmpty, !rejection.isEmpty, nothingCurrent {
                self.banner = rejection.joined(separator: " ")
                self.bannerIsBad = true
            } else if nothingCurrent && codes.isEmpty {
                self.banner = "The engine is not holding a current code or a since-last-clear code. The lamp going out means this controller has already dropped that record."
                self.bannerIsBad = false
            }
        }
    }

    private func performClear(generation: UUID) async {
        _ = await sendResult("ATSH7E0", timeout: 3)
        _ = await sendResult("ATCRA7E8", timeout: 3)
        _ = await sendResult("ATFCSH7E0", timeout: 3)
        _ = await sendResult("ATFCSD300000", timeout: 3)
        _ = await sendResult("ATFCSM1", timeout: 3)
        if await lost(generation) { return }
        _ = await sendResult("1003", timeout: 4)
        let factory = await sendResult("14FFFFFF", timeout: 8)
        _ = await sendResult("1001", timeout: 3)
        _ = await sendResult("ATFCSM0", timeout: 2)
        _ = await sendResult("ATAR", timeout: 2)
        _ = await sendResult("ATSH7DF", timeout: 2)
        let generic = await sendResult("04", timeout: 10)
        guard await isCurrent(generation) else { return }

        let factoryOk: Bool
        if case .success(let text) = factory {
            factoryOk = ObdResponse.didClearHistory(text)
        } else {
            factoryOk = false
        }
        let genericOk: Bool
        if case .success(let text) = generic {
            genericOk = ObdResponse.didClear(text)
        } else {
            genericOk = false
        }
        guard factoryOk || genericOk else {
            await MainActor.run {
                self.banner = "The engine did not accept the clear command. Ignition on, engine off, then try again."
                self.bannerIsBad = true
            }
            return
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        await readModes(generation: generation)
        guard await isCurrent(generation) else { return }
        await MainActor.run {
            let stillThere = !self.stored.isEmpty || !self.pending.isEmpty || !self.history.isEmpty
            if stillThere {
                self.banner = "The engine still reports a code after the clear."
                self.bannerIsBad = true
            } else if self.bannerIsBad {
                return
            } else if factoryOk {
                self.banner = "All history cleared. The list is what the engine reports now."
                self.bannerIsBad = false
            } else {
                self.banner = "Generic codes cleared. The factory list did not accept the erase."
                self.bannerIsBad = true
            }
        }
    }

    private func readFaults(_ status: FaultStatus, command: String, generation: UUID) async {
        if await lost(generation) { return }
        let result = await sendResult(command, timeout: 10)
        guard await isCurrent(generation) else { return }
        switch result {
        case .success(let text):
            let parsed = ObdResponse.parseFaults(response: text, status: status)
            await MainActor.run {
                switch status {
                case .stored: self.stored = parsed.codes
                case .pending: self.pending = parsed.codes
                case .permanent: self.permanent = parsed.codes
                case .history: break
                }
                if parsed.linkFailed {
                    self.banner = "The dongle lost the engine while reading \(status.title.lowercased()) codes."
                    self.bannerIsBad = true
                } else if !parsed.rejected.isEmpty {
                    self.banner = parsed.rejected.joined(separator: " ")
                    self.bannerIsBad = true
                }
            }
        case .failure(let error):
            await MainActor.run {
                self.banner = "Could not read \(status.title.lowercased()) codes. \(error.localizedDescription)"
                self.bannerIsBad = true
            }
        }
    }

    private func probe() async -> Bool {
        let result = await sendResult("0100", timeout: 15)
        guard case .success(let text) = result else { return false }
        return ObdResponse.answeredSupportedPIDs(text)
    }

    private func readVoltage() async -> String? {
        let result = await sendResult("ATRV", timeout: 3)
        guard case .success(let text) = result else { return nil }
        return ObdResponse.parseVoltage(text)
    }

    private func ignitionHint() -> String {
        if let voltage, let value = Double(voltage.replacingOccurrences(of: " V", with: "")), value < 8 {
            return "Port voltage is \(voltage). Turn the ignition to ON and leave the engine off, then tap Read codes."
        }
        return "No answer from the engine. Turn the ignition to ON, leave the engine off, and tap Read codes."
    }

    private func cleanProtocol(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let upper = line.uppercased()
                return !line.isEmpty && upper != "OK" && upper != "ATDP" && !upper.contains("SEARCHING")
            }
        let name = lines.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private func send(_ command: String, timeout: TimeInterval) async throws -> String {
        try await Task.sleep(nanoseconds: 60_000_000)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let waiter = Waiter()
                waiter.continuation = continuation
                self.waiter = waiter
                self.appendLog("› \(command)")
                guard self.write(command) else {
                    self.complete(id: waiter.id, result: .failure(LinkError.notReady))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.complete(id: waiter.id, result: .failure(LinkError.timeout))
                }
            }
        }
    }

    private func sendResult(_ command: String, timeout: TimeInterval) async -> Result<String, Error> {
        do {
            return .success(try await send(command, timeout: timeout))
        } catch {
            if let link = error as? LinkError, link == .timeout {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return .failure(error)
        }
    }

    private func write(_ command: String) -> Bool {
        guard let peripheral = connected, let port, peripheral.state == .connected else { return false }
        let payload = Data((command + "\r").utf8)
        let limit = max(peripheral.maximumWriteValueLength(for: port.writeType), 20)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + limit, payload.count)
            peripheral.writeValue(payload.subdata(in: offset..<end), for: port.write, type: port.writeType)
            offset = end
        }
        return true
    }

    private func complete(id: UUID, result: Result<String, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation?.resume(with: result)
        waiter.continuation = nil
    }

    private func failWaiter(_ error: LinkError) {
        guard let waiter else { return }
        complete(id: waiter.id, result: .failure(error))
    }

    private func isCurrent(_ generation: UUID) async -> Bool {
        await MainActor.run { self.sessionGeneration == generation }
    }

    private func lost(_ generation: UUID) async -> Bool {
        await MainActor.run {
            self.sessionGeneration != generation || self.connected?.state != .connected
        }
    }

    private func finishBusy(_ generation: UUID) {
        DispatchQueue.main.async {
            guard self.sessionGeneration == generation else { return }
            self.isBusy = false
        }
    }

    private func fail(_ message: String) {
        if probeArmed {
            noteProbe("DONE \(message)")
            finishProbe()
        }
        sessionGeneration = UUID()
        failWaiter(.disconnected)
        banner = message
        bannerIsBad = true
        phase = .failed(message)
        isBusy = false
        setIdleTimer(false)
        ending = true
        if let connected, let central {
            central.cancelPeripheralConnection(connected)
        }
    }

    private func clearReadings() {
        stored = []
        pending = []
        permanent = []
        history = []
        vin = nil
        voltage = nil
        milOn = nil
        reportedCount = nil
        protocolName = nil
        lastCommandResult = ""
    }

    private func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        logText += line + "\n"
        if logText.count > 16_000 {
            logText = String(logText.suffix(10_000))
        }
    }

    private func remember(_ peripheral: CBPeripheral, advertised name: String?, rssi: Int) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        let incoming = cleanedName(name ?? peripheral.name)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            var existing = devices[index]
            if incoming != "Unnamed device" {
                existing.name = incoming
                existing.likely = Self.isLikely(incoming)
            }
            existing.rssi = rssi
            existing.lastUsed = id == lastID
            devices[index] = existing
        } else {
            devices.append(FoundDevice(
                id: id,
                name: incoming,
                rssi: rssi,
                likely: Self.isLikely(incoming),
                lastUsed: id == lastID
            ))
        }
        if probeArmed, !probeLoggedNames.contains(incoming) {
            probeLoggedNames.insert(incoming)
            noteProbe("saw \(incoming) \(rssi)")
        }
        guard probeArmed, phase == .scanning, let match = devices.first(where: { $0.id == id }) else { return }
        let upper = match.name.uppercased()
        guard upper.contains("OBD") || match.id == lastID else { return }
        noteProbe("connecting \(match.name) rssi \(match.rssi)")
        connect(match)
    }

    private func beginProbeScanIfNeeded() {
        guard probeArmed, !probeScanStarted else { return }
        probeScanStarted = true
        noteProbe("scanning")
        startScan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.probeArmed, self.phase == .scanning else { return }
            let names = self.devices.map { "\($0.name) \($0.rssi)" }.joined(separator: ", ")
            self.noteProbe("DONE no dongle in range. nearby: \(names.isEmpty ? "none" : names)")
            self.finishProbe()
            self.stopScan()
        }
    }

    /// Read-only sweep. One shot, armed by /tmp/scorpio-probe.on, so a normal launch does not do this.
    private func runCapabilityProbe(generation: UUID, linked: Bool) async {
        var lines: [String] = []
        if !linked {
            lines.append("engine link: NO. Ignition is likely off, or the dongle is not seated.")
            lines.append("oil pressure: not read. The pump is still, and this ECU does not publish a pressure value.")
        } else {
            let checks: [(String, String)] = [
                ("010C", "rpm"),
                ("0105", "coolant °C"),
                ("010D", "speed km/h"),
                ("010B", "manifold kPa"),
                ("010F", "intake air °C"),
                ("0111", "throttle %"),
                ("0123", "fuel rail"),
                ("0142", "module volts"),
                ("015C", "oil temperature °C"),
                ("0100", "pid support 01-20"),
                ("0120", "pid support 21-40"),
                ("0140", "pid support 41-60"),
                ("0160", "pid support 61-80")
            ]
            var supported: [String] = []
            for check in checks {
                if await lost(generation) {
                    lines.append("link dropped during \(check.0)")
                    break
                }
                switch await sendResult(check.0, timeout: 4) {
                case .success(let text):
                    let flat = flatten(text)
                    let verdict = verdict(for: flat)
                    let meaning = meaning(of: check.0, response: text)
                    lines.append("\(check.0) \(check.1): \(verdict) \(meaning) | \(flat)")
                    if ["0100", "0120", "0140", "0160"].contains(check.0), verdict == "YES" {
                        supported.append(contentsOf: supportedPIDNames(request: check.0, response: text))
                    }
                case .failure(let error):
                    lines.append("\(check.0) \(check.1): FAIL \(error.localizedDescription)")
                }
            }
            lines.append("supported live PIDs: \(supported.isEmpty ? "none parsed" : supported.joined(separator: " "))")
            lines.append("oil pressure: NO PID. Nothing in the standard list is oil pressure, and 015C is oil temperature only.")
            let registry = await runRegistryProbe(generation: generation)
            lines.append(registry)
        }
        let snapshot = await MainActor.run { () -> String in
            let names = (self.stored + self.pending + self.permanent + self.history).map { "\($0.status.rawValue):\($0.code)" }
            return "codes: \(names.isEmpty ? "none" : names.joined(separator: " ")) | voltage \(self.voltage ?? "-") | mil \(String(describing: self.milOn)) | storedCount \(String(describing: self.reportedCount))"
        }
        lines.append(snapshot)
        lines.append("DONE")
        noteProbe(lines.joined(separator: "\n"))
        let headline = lines.first { $0.hasPrefix("010C") }
            ?? lines.first
            ?? "Probe finished."
        await MainActor.run {
            self.banner = headline
            self.bannerIsBad = false
        }
        finishProbe()
    }

    /// Read-only hunt for the factory fault list and any oil-pressure value.
    /// Session 10 03 only opens the diagnostic session. No clears, writes, or actuator tests.
    private func runRegistryProbe(generation: UUID) async -> String {
        noteProbe("confirm factory list")
        _ = await sendResult("ATSH7E0", timeout: 2)
        _ = await sendResult("ATCRA7E8", timeout: 2)
        _ = await sendResult("ATFCSH7E0", timeout: 2)
        _ = await sendResult("ATFCSD300000", timeout: 2)
        _ = await sendResult("ATFCSM1", timeout: 2)
        var notes: [String] = []
        for command in ["190C", "190B", "190D", "190E"] {
            if await lost(generation) { break }
            let flat = await logExchange(command, timeout: 4, label: "engine")
            if let found = storedCodes(in: flat), !found.isEmpty, !found.hasPrefix("none") {
                notes.append("\(command) \(found)")
            }
        }
        _ = await sendResult("ATFCSM0", timeout: 2)
        _ = await sendResult("ATAR", timeout: 2)
        _ = await sendResult("ATSH7DF", timeout: 2)
        if notes.isEmpty { return "registry: no confirmed factory code" }
        return "registry: " + notes.joined(separator: " | ")
    }

    @discardableResult
    private func logExchange(_ command: String, timeout: TimeInterval, label: String) async -> String {
        let start = Date()
        switch await sendResult(command, timeout: timeout) {
        case .success(let text):
            let flat = flatten(text)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let clip = flat.count > 700 ? String(flat.prefix(700)) + "…" : flat
            let extra = storedCodes(in: flat).map { " stored[\($0)]" } ?? ""
            noteProbe("\(label) \(command) \(ms)ms\(extra) \(clip)")
            return flat
        case .failure(let error):
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            noteProbe("\(label) \(command) \(ms)ms FAIL \(error.localizedDescription)")
            return ""
        }
    }

    /// Positive service 22 answers only. Stops if the ECU is slow or does not support the service.
    private func scanIdentifiers(generation: UUID) async -> [String] {
        var hits: [String] = []
        var slow = 0
        let ranges = [0xF180...0xF19F, 0x0000...0x00FF, 0x0100...0x01FF, 0x0200...0x021F, 0x1000...0x101F]
        for did in ranges.joined() {
            if await lost(generation) { break }
            let command = String(format: "22%04X", did)
            let start = Date()
            let result = await sendResult(command, timeout: 1.5)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.75 {
                slow += 1
                if slow >= 6 {
                    noteProbe("identifier scan stopped at \(command), responses are slow")
                    break
                }
            } else {
                slow = 0
            }
            guard case .success(let text) = result else { continue }
            let bytes = hexBytes(text)
            if let marker = bytes.firstIndex(of: 0x7F), marker + 2 < bytes.count, bytes[marker + 1] == 0x22 {
                let nrc = bytes[marker + 2]
                if nrc == 0x11 {
                    noteProbe("service 22 not supported")
                    break
                }
                if nrc != 0x31 && nrc != 0x13 {
                    noteProbe("NRC \(command) \(String(format: "%02X", nrc))")
                }
                continue
            }
            guard bytes.contains(0x62) else { continue }
            let flat = flatten(text)
            let clip = flat.count > 240 ? String(flat.prefix(240)) : flat
            noteProbe("HIT \(command) \(clip)")
            hits.append("\(command) \(clip)")
            if hits.count >= 40 { break }
        }
        if hits.isEmpty {
            noteProbe("identifier scan found no extra values")
        }
        return hits
    }

    /// Non-zero UDS status bytes from a 59 02 / 59 0A payload. Nil when the payload is not that service.
    private func storedCodes(in response: String) -> String? {
        let bytes = hexBytes(response)
        guard let index = bytes.firstIndex(of: 0x59), index + 2 < bytes.count else { return nil }
        let sub = bytes[index + 1]
        if sub == 0x01, index + 5 < bytes.count {
            let count = (Int(bytes[index + 4]) << 8) | Int(bytes[index + 5])
            return "count \(count)"
        }
        guard sub == 0x02 || sub == 0x0A || sub == 0x0C else { return nil }
        var cursor = index + 3
        var stored: [String] = []
        var total = 0
        while cursor + 3 < bytes.count {
            let status = bytes[cursor + 3]
            let code = saeCode(bytes[cursor], bytes[cursor + 1])
            let type = bytes[cursor + 2]
            cursor += 4
            total += 1
            if status != 0 {
                stored.append(String(format: "%@-%02X status %02X", code, type, status))
            }
        }
        if stored.isEmpty { return "none of \(total)" }
        return stored.joined(separator: ", ")
    }

    private func saeCode(_ hi: UInt8, _ lo: UInt8) -> String {
        let systems = ["P", "C", "B", "U"]
        let system = systems[Int(hi >> 6) & 0x3]
        let second = Int(hi >> 4) & 0x3
        let third = Int(hi) & 0x0F
        return String(format: "%@%d%X%02X", system, second, third, lo)
    }

    private func finishProbe() {
        probeArmed = false
        try? FileManager.default.removeItem(atPath: probeFlagPath)
    }

    private func noteProbe(_ line: String) {
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: probeLogPath)
        if FileManager.default.fileExists(atPath: probeLogPath),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func flatten(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verdict(for flat: String) -> String {
        let upper = flat.uppercased()
        if upper.contains("UNABLE") || upper.contains("CAN ERROR") || upper.contains("BUS ERROR") || upper.contains("BUS BUSY") {
            return "NO LINK"
        }
        if upper.contains("NO DATA") || upper.contains("STOPPED") || upper.contains("?") {
            return "NO"
        }
        if upper.contains("7F") { return "REJECTED" }
        return upper.isEmpty ? "NO" : "YES"
    }

    private func meaning(of command: String, response: String) -> String {
        let bytes = hexBytes(response)
        guard command.count == 4, command.hasPrefix("01"),
              let pid = UInt8(command.dropFirst(2), radix: 16),
              let index = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 0x41 && bytes[$0 + 1] == pid }) else {
            return ""
        }
        let payload = Array(bytes.dropFirst(index + 2))
        guard let a = payload.first else { return "" }
        let b = payload.count > 1 ? payload[1] : 0
        switch pid {
        case 0x0C: return String(format: "%.0f rpm", Double(Int(a) * 256 + Int(b)) / 4)
        case 0x05, 0x0F, 0x5C: return "\(Int(a) - 40) C"
        case 0x0D: return "\(a) km/h"
        case 0x0B: return "\(a) kPa"
        case 0x11: return "\(Int(a) * 100 / 255) %"
        case 0x23: return "\((Int(a) * 256 + Int(b)) * 10) kPa"
        case 0x42: return String(format: "%.2f V", Double(Int(a) * 256 + Int(b)) / 1000)
        default: return ""
        }
    }

    private func supportedPIDNames(request: String, response: String) -> [String] {
        guard request.count == 4, let base = UInt8(request.dropFirst(2), radix: 16) else { return [] }
        let bytes = hexBytes(response)
        guard let index = bytes.indices.first(where: { bytes[$0] == 0x41 && $0 + 5 < bytes.count && bytes[$0 + 1] == base }) else {
            return []
        }
        let mask = Array(bytes[(index + 2)...(index + 5)])
        var names: [String] = []
        for byteIndex in 0..<4 {
            for bit in 0..<8 {
                let pid = Int(base) + byteIndex * 8 + bit + 1
                if mask[byteIndex] & (0x80 >> bit) != 0, pid % 0x20 != 0 {
                    names.append(String(format: "%02X", pid))
                }
            }
        }
        return names
    }

    private func hexBytes(_ response: String) -> [UInt8] {
        let runs = response.uppercased().split(whereSeparator: { !$0.isHexDigit }).map(String.init)
        var bytes: [UInt8] = []
        for run in runs {
            var body = run
            if run.count == 3 { continue }
            if run.count % 2 == 1, run.count > 3 {
                let head = Int(run.prefix(3), radix: 16) ?? 0
                if (0x700...0x7FF).contains(head) {
                    body = String(run.dropFirst(3))
                }
            }
            guard body.count % 2 == 0 else { continue }
            var index = body.startIndex
            while index < body.endIndex {
                let next = body.index(index, offsetBy: 2)
                if let byte = UInt8(body[index..<next], radix: 16) {
                    bytes.append(byte)
                }
                index = next
            }
        }
        return bytes
    }

    private func markLast(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: lastKey)
    }

    private var lastID: UUID? {
        UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init(uuidString:))
    }

    private func cleanedName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed device" : trimmed
    }

    private static func isLikely(_ name: String) -> Bool {
        let value = name.lowercased()
        if value == "unnamed device" { return false }
        let keys = ["obd", "elm", "vlink", "v-link", "vgate", "veepeak", "icar", "carista", "obdlink", "konnwei", "viecar", "lelink", "scanner", "ios-vlink", "obdb"]
        return keys.contains { value.contains($0) }
    }

    private func applyBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothReady = true
            bluetoothNote = nil
            beginProbeScanIfNeeded()
        case .poweredOff:
            bluetoothReady = false
            bluetoothNote = "Bluetooth is off. Turn it on, then scan."
            if phase == .scanning {
                stopScan()
            }
        case .unauthorized:
            bluetoothReady = false
            bluetoothNote = "Bluetooth permission is off for Scorpio Codes. Enable it in Settings."
        case .unsupported:
            bluetoothReady = false
            bluetoothNote = "This device does not support Bluetooth Low Energy."
        default:
            bluetoothReady = false
            bluetoothNote = "Waiting for Bluetooth…"
        }
    }

    private func setIdleTimer(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    private func selectPort(on peripheral: CBPeripheral) -> Port? {
        let services = peripheral.services ?? []
        let profiles: [(String, String, String, String)] = [
            ("FFF0", "FFF2", "FFF1", "FFF0 / FFF2 write / FFF1 notify"),
            ("FFF0", "FFF1", "FFF1", "FFF0 / FFF1"),
            ("FFE0", "FFE1", "FFE1", "FFE0 / FFE1"),
            ("18F0", "2AF1", "2AF0", "18F0 / 2AF1 write / 2AF0 notify"),
            (
                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                "Nordic UART"
            )
        ]
        for profile in profiles {
            if let port = match(services, service: profile.0, write: profile.1, notify: profile.2, label: profile.3) {
                return port
            }
        }
        for service in services where !isStandard(service) {
            let characteristics = service.characteristics ?? []
            guard let write = characteristics.first(where: canWrite),
                  let notify = characteristics.first(where: canNotify),
                  let port = makePort(write: write, notify: notify, label: "Service \(service.uuid.uuidString)") else {
                continue
            }
            return port
        }
        return nil
    }

    private func match(_ services: [CBService], service: String, write: String, notify: String, label: String) -> Port? {
        guard let found = services.first(where: { $0.uuid == CBUUID(string: service) }),
              let writeChar = found.characteristics?.first(where: { $0.uuid == CBUUID(string: write) }),
              let notifyChar = found.characteristics?.first(where: { $0.uuid == CBUUID(string: notify) }) else {
            return nil
        }
        return makePort(write: writeChar, notify: notifyChar, label: label)
    }

    private func makePort(write: CBCharacteristic, notify: CBCharacteristic, label: String) -> Port? {
        let writeType: CBCharacteristicWriteType
        if write.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else if write.properties.contains(.write) {
            writeType = .withResponse
        } else {
            return nil
        }
        guard notify.properties.contains(.notify) || notify.properties.contains(.indicate) else { return nil }
        return Port(notify: notify, write: write, writeType: writeType, label: label)
    }

    private func canWrite(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
    }

    private func canNotify(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }

    private func isStandard(_ service: CBService) -> Bool {
        ["1800", "1801", "180A", "180F"].contains { service.uuid == CBUUID(string: $0) }
    }

    private func logServices(on peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] {
            appendLog("service \(service.uuid.uuidString)")
            for characteristic in service.characteristics ?? [] {
                appendLog("  \(characteristic.uuid.uuidString) \(describe(characteristic.properties))")
            }
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("write-without-response") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names.joined(separator: ", ")
    }

    private struct Port {
        var notify: CBCharacteristic
        var write: CBCharacteristic
        var writeType: CBCharacteristicWriteType
        var label: String
    }

    private final class Waiter {
        let id = UUID()
        var continuation: CheckedContinuation<String, Error>?
        var buffer = ""
    }
}

extension BleSession: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        applyBluetoothState(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        remember(peripheral, advertised: advertised, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = peripheral
        peripheral.delegate = self
        let name = cleanedName(peripheral.name ?? connectedName)
        connectedName = name
        markLast(peripheral.identifier)
        phase = .settingUp
        appendLog("Connected to \(name)")
        peripheral.discoverServices(nil)
        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.sessionGeneration == generation, self.phase == .settingUp, !self.didStartSetup else { return }
            self.fail("The dongle did not open its data channel.")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "Could not connect to the dongle.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failWaiter(.disconnected)
        if userDisconnect {
            userDisconnect = false
            return
        }
        if ending {
            ending = false
            return
        }
        if (phase == .settingUp || phase == .connecting) && reconnects < 1 {
            reconnects += 1
            skipReset = true
            didStartSetup = false
            didSelectPort = false
            sessionGeneration = UUID()
            appendLog("Dongle dropped. Connecting again.")
            isBusy = true
            phase = .connecting
            central.connect(peripheral, options: nil)
            watchConnectTimeout()
            return
        }
        fail(error?.localizedDescription ?? "The dongle disconnected.")
    }
}

extension BleSession: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(error.localizedDescription)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail("This device has no BLE services.")
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        guard pendingServices <= 0, !didSelectPort else { return }
        didSelectPort = true
        guard let port = selectPort(on: peripheral) else {
            logServices(on: peripheral)
            fail("This BLE device has no OBD data channel. A classic Bluetooth dongle will not work here.")
            return
        }
        self.port = port
        appendLog("Using \(port.label)")
        peripheral.setNotifyValue(true, for: port.notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail(error.localizedDescription)
            return
        }
        guard characteristic.isNotifying, !didStartSetup else { return }
        didStartSetup = true
        let generation = sessionGeneration
        Task {
            defer { self.finishBusy(generation) }
            await self.performSetupAndRead(generation: generation)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == port?.notify.uuid else { return }
        guard error == nil, let data = characteristic.value else { return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
        let chunk = text.replacingOccurrences(of: "\0", with: "")
        guard !chunk.isEmpty else { return }
        guard let waiter else {
            let line = chunk.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog("‹ \(line)")
            return
        }
        waiter.buffer += chunk
        if waiter.buffer.contains(">") {
            let response = waiter.buffer
            let line = response
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog("‹ \(line)")
            complete(id: waiter.id, result: .success(response))
        }
    }
}
