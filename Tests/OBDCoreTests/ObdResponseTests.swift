import XCTest
@testable import OBDCore

final class ObdResponseTests: XCTestCase {
    func testStoredCodesWithHeaderAndLength() {
        let read = ObdResponse.parseFaults(
            response: "7E8 07 43 00 87 04 01 02 34\r>",
            status: .stored
        )
        XCTAssertEqual(read.codes.map(\.code), ["P0087", "P0401", "P0234"])
        XCTAssertEqual(read.codes.map(\.moduleName), ["Engine", "Engine", "Engine"])
        XCTAssertEqual(read.codes[0].summary, "Fuel rail pressure too low.")
        XCTAssertFalse(read.noData)
        XCTAssertFalse(read.linkFailed)
    }

    func testHeaderlessPairsSkipPadding() {
        let read = ObdResponse.parseFaults(response: "43 01 33 00 00 00 00\n>", status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0133"])
        XCTAssertEqual(read.codes[0].moduleName, "ECU")
    }

    func testPendingAndPermanentServiceBytes() {
        let pending = ObdResponse.parseFaults(response: "47 02 34 00 00\n>", status: .pending)
        XCTAssertEqual(pending.codes.map(\.code), ["P0234"])
        let permanent = ObdResponse.parseFaults(response: "7E8 03 4A 00 87\n>", status: .permanent)
        XCTAssertEqual(permanent.codes.map(\.code), ["P0087"])
        XCTAssertEqual(permanent.codes[0].status, .permanent)
    }

    func testTwoModules() {
        let response = """
        7E8 05 43 00 87 04 01
        7E9 03 43 07 00
        >
        """
        let read = ObdResponse.parseFaults(response: response, status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0087", "P0401", "P0700"])
        XCTAssertEqual(read.codes.map(\.moduleName), ["Engine", "Engine", "Transmission"])
    }

    func testCompactHeader() {
        let read = ObdResponse.parseFaults(response: "7E80743008704010234\r>", status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0087", "P0401", "P0234"])
    }

    func testElmMultilineCount() {
        let response = """
        008
        0: 43 01 33 01 34 02
        1: 56 00 00 00 00 00
        >
        """
        let read = ObdResponse.parseFaults(response: response, status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0133", "P0134", "P0256"])
    }

    func testIsoTpReassembly() {
        let response = """
        7E8 10 0A 43 01 33 04 20 00
        7E8 21 00 00 00 00 00 00 00
        >
        """
        let read = ObdResponse.parseFaults(response: response, status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0133", "P0420"])
    }

    func testZeroPaddingIsNotACodeAndP0300IsKept() {
        let read = ObdResponse.parseFaults(response: "43 03 00 00 00 00\n>", status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0300"])
    }

    func testSystemLetters() {
        XCTAssertEqual(ObdResponse.parseFaults(response: "43 41 23\n>", status: .stored).codes.map(\.code), ["C0123"])
        XCTAssertEqual(ObdResponse.parseFaults(response: "43 92 34\n>", status: .stored).codes.map(\.code), ["B1234"])
        XCTAssertEqual(ObdResponse.parseFaults(response: "43 C1 00\n>", status: .stored).codes.map(\.code), ["U0100"])
    }

    func testSearchingAndNoData() {
        let read = ObdResponse.parseFaults(response: "SEARCHING...\rNO DATA\r>", status: .pending)
        XCTAssertTrue(read.codes.isEmpty)
        XCTAssertTrue(read.noData)
        XCTAssertFalse(read.linkFailed)
    }

    func testUnableToConnect() {
        let read = ObdResponse.parseFaults(response: "SEARCHING...\rUNABLE TO CONNECT\r>", status: .stored)
        XCTAssertTrue(read.codes.isEmpty)
        XCTAssertTrue(read.linkFailed)
        XCTAssertFalse(read.noData)
    }

    func testBusInitOkIsNotAFailure() {
        let read = ObdResponse.parseFaults(response: "BUS INIT: OK\r43 00 87\r>", status: .stored)
        XCTAssertEqual(read.codes.map(\.code), ["P0087"])
        XCTAssertFalse(read.linkFailed)
    }

    func testNegativeResponse() {
        let read = ObdResponse.parseFaults(response: "7E8 03 7F 03 11\r>", status: .stored)
        XCTAssertTrue(read.codes.isEmpty)
        XCTAssertEqual(read.rejected, ["Engine rejected the request (service not supported)."])
    }

    func testLiveDataIsNotAFault() {
        let read = ObdResponse.parseFaults(response: "7E8 04 41 0C 0C 84\r>", status: .stored)
        XCTAssertTrue(read.codes.isEmpty)
    }

    func testMonitorStatus() {
        let status = ObdResponse.parseMonitor(response: "7E8 06 41 01 82 07 65 00\r>")
        XCTAssertEqual(status, MonitorStatus(milOn: true, storedCodeCount: 2))
    }

    func testSupportedPidProbe() {
        XCTAssertTrue(ObdResponse.answeredSupportedPIDs("7E8 06 41 00 BE 1F A8 13\r>"))
        XCTAssertFalse(ObdResponse.answeredSupportedPIDs("SEARCHING...\rUNABLE TO CONNECT\r>"))
    }

    func testClearAccepted() {
        XCTAssertTrue(ObdResponse.didClear("44\r>"))
        XCTAssertTrue(ObdResponse.didClear("7E8 01 44\r>"))
        XCTAssertFalse(ObdResponse.didClear("NO DATA\r>"))
        XCTAssertTrue(ObdResponse.didClearHistory("7E8 01 54\r>"))
        XCTAssertFalse(ObdResponse.didClearHistory("7E8 03 7F 14 22\r>"))
    }

    func testVINFromIsoTp() {
        let response = """
        7E8 10 14 49 02 01 4D 41 48 4E
        7E8 21 44 52 41 31 32 33 34 35
        7E8 22 36 37 38 39 30 00 00 00
        >
        """
        XCTAssertEqual(ObdResponse.parseVIN(response), "MAHNDRA1234567890")
    }

    func testVINFromNumberedLines() {
        let response = """
        49 02 01 4D 41 48 4E
        49 02 02 44 52 41 31
        49 02 03 32 33 34 35
        49 02 04 36 37 38 39
        49 02 05 30
        >
        """
        XCTAssertEqual(ObdResponse.parseVIN(response), "MAHNDRA1234567890")
    }

    func testVoltage() {
        XCTAssertEqual(ObdResponse.parseVoltage("ATRV\r12.6 V\r>"), "12.6 V")
        XCTAssertEqual(ObdResponse.parseVoltage("12.4V\r>"), "12.4 V")
        XCTAssertNil(ObdResponse.parseVoltage("?\r>"))
    }

    func testCatalogFallsBackByFamily() {
        XCTAssertEqual(
            FaultCatalog.summary(for: "P1110"),
            "Mahindra-specific powertrain code. Match it in the Scorpio S11 EMS diagnostic manual."
        )
        XCTAssertEqual(
            FaultCatalog.summary(for: "P0999"),
            "Standard powertrain code. This app does not have a sentence for it yet."
        )
        XCTAssertTrue(FaultCatalog.summary(for: "U0100").contains("engine controller"))
    }

    func testHistoryStatusMaskAndConfirmedBits() {
        let read = ObdResponse.parseHistory(response: "7E8 0B 59 02 FF 00 87 00 28 04 01 00 2C\r>")
        XCTAssertEqual(read.codes.map(\.code), ["P0087", "P0401"])
        XCTAssertEqual(read.codes.map(\.status), [.history, .history])
        XCTAssertEqual(read.codes.map(\.moduleName), ["Engine", "Engine"])
        XCTAssertTrue(read.codes[0].detail.contains("Failed since last clear"))
        XCTAssertTrue(read.codes[0].detail.contains("Confirmed"))
        XCTAssertTrue(read.codes[1].detail.contains("Pending"))
        XCTAssertEqual(read.codes[0].summary, "Fuel rail pressure too low.")
        XCTAssertFalse(read.noData)
    }

    func testHistoryFaultTypeSuffix() {
        let read = ObdResponse.parseHistory(response: "59 02 FF 00 87 11 28\r>")
        XCTAssertEqual(read.codes.map(\.code), ["P0087-11"])
        XCTAssertTrue(read.codes[0].detail.contains("Fault type 11"))
        XCTAssertEqual(read.codes[0].summary, "Fuel rail pressure too low.")
    }

    func testHistoryIsoTpReassembly() {
        let response = """
        7E8 10 0B 59 02 FF 00 87 00
        7E8 21 28 04 01 00 2C 00 00
        >
        """
        let read = ObdResponse.parseHistory(response: response)
        XCTAssertEqual(read.codes.map(\.code), ["P0087", "P0401"])
    }

    func testHistoryKwpCount() {
        let read = ObdResponse.parseHistory(response: "58 01 02 34 28\r>")
        XCTAssertEqual(read.codes.map(\.code), ["P0234"])
        XCTAssertEqual(read.codes[0].status, .history)
        XCTAssertTrue(read.codes[0].detail.contains("Confirmed"))
    }

    func testFactoryConfirmedCodeHiddenFromMode03() {
        let read = ObdResponse.parseHistory(response: "7E8 07 59 0C FF 13 40 00 28\r>")
        XCTAssertEqual(read.codes.map(\.code), ["P1340"])
        XCTAssertEqual(read.codes[0].summary, "Camshaft and crankshaft position are out of step.")
        XCTAssertTrue(read.codes[0].detail.contains("Confirmed"))
        XCTAssertTrue(read.codes[0].detail.contains("Failed since last clear"))
        XCTAssertFalse(read.codes[0].detail.contains("Failing now"))
    }

    func testHistoryNegativeResponse() {
        let read = ObdResponse.parseHistory(response: "7F 19 11\r>")
        XCTAssertTrue(read.codes.isEmpty)
        XCTAssertEqual(read.rejected, ["ECU rejected the request (service not supported)."])
        XCTAssertFalse(read.noData)
    }
}
