import Foundation

public enum FaultCatalog {
    public static func summary(for code: String) -> String {
        if let known = entries[code] {
            return known
        }
        guard code.count == 5, let system = code.first else {
            return "Diagnostic trouble code."
        }
        let kind = code.dropFirst().first
        switch system {
        case "P":
            if kind == "1" || kind == "3" {
                return "Mahindra-specific powertrain code. Match it in the Scorpio S11 EMS diagnostic manual."
            }
            return "Standard powertrain code. This app does not have a sentence for it yet."
        case "C":
            return "Chassis code. Check the Scorpio S11 brakes, ESC, or steering manual."
        case "B":
            return "Body code. Check the Scorpio S11 body or cluster manual."
        case "U":
            return "Network code. A control unit stopped answering on the vehicle CAN bus."
        default:
            return "Diagnostic trouble code."
        }
    }

    private static let entries: [String: String] = [
        "P0016": "Crankshaft and camshaft signals do not agree.",
        "P1340": "Camshaft and crankshaft position are out of step.",
        "P0030": "Oxygen sensor heater circuit fault, bank 1 sensor 1.",
        "P0031": "Oxygen sensor heater circuit low, bank 1 sensor 1.",
        "P0032": "Oxygen sensor heater circuit high, bank 1 sensor 1.",
        "P0087": "Fuel rail pressure too low.",
        "P0088": "Fuel rail pressure too high.",
        "P0090": "Fuel pressure regulator control circuit fault.",
        "P0091": "Fuel pressure regulator control circuit low.",
        "P0092": "Fuel pressure regulator control circuit high.",
        "P0100": "Mass air flow sensor circuit fault.",
        "P0101": "Mass air flow sensor signal out of range.",
        "P0102": "Mass air flow sensor signal low.",
        "P0103": "Mass air flow sensor signal high.",
        "P0105": "Manifold pressure sensor circuit fault.",
        "P0106": "Manifold pressure sensor signal out of range.",
        "P0107": "Manifold pressure sensor signal low.",
        "P0108": "Manifold pressure sensor signal high.",
        "P0110": "Intake air temperature sensor circuit fault.",
        "P0112": "Intake air temperature sensor signal low.",
        "P0113": "Intake air temperature sensor signal high.",
        "P0115": "Coolant temperature sensor circuit fault.",
        "P0116": "Coolant temperature sensor signal out of range.",
        "P0117": "Coolant temperature sensor signal low.",
        "P0118": "Coolant temperature sensor signal high.",
        "P0120": "Throttle position sensor circuit fault.",
        "P0121": "Throttle position sensor signal out of range.",
        "P0122": "Throttle position sensor signal low.",
        "P0123": "Throttle position sensor signal high.",
        "P0180": "Fuel temperature sensor circuit fault.",
        "P0182": "Fuel temperature sensor signal low.",
        "P0183": "Fuel temperature sensor signal high.",
        "P0190": "Fuel rail pressure sensor circuit fault.",
        "P0191": "Fuel rail pressure sensor signal out of range.",
        "P0192": "Fuel rail pressure sensor signal low.",
        "P0193": "Fuel rail pressure sensor signal high.",
        "P0200": "Injector circuit fault.",
        "P0201": "Injector 1 circuit open.",
        "P0202": "Injector 2 circuit open.",
        "P0203": "Injector 3 circuit open.",
        "P0204": "Injector 4 circuit open.",
        "P0216": "Injection timing control circuit fault.",
        "P0217": "Engine coolant temperature too high.",
        "P0219": "Engine speed above the limit.",
        "P0234": "Turbocharger overboost.",
        "P0235": "Turbo boost sensor circuit fault.",
        "P0236": "Turbo boost sensor signal out of range.",
        "P0237": "Turbo boost sensor signal low.",
        "P0238": "Turbo boost sensor signal high.",
        "P0261": "Injector 1 circuit low.",
        "P0262": "Injector 1 circuit high.",
        "P0264": "Injector 2 circuit low.",
        "P0265": "Injector 2 circuit high.",
        "P0267": "Injector 3 circuit low.",
        "P0268": "Injector 3 circuit high.",
        "P0270": "Injector 4 circuit low.",
        "P0271": "Injector 4 circuit high.",
        "P0299": "Turbocharger underboost.",
        "P0300": "Misfire on more than one cylinder.",
        "P0301": "Misfire on cylinder 1.",
        "P0302": "Misfire on cylinder 2.",
        "P0303": "Misfire on cylinder 3.",
        "P0304": "Misfire on cylinder 4.",
        "P0335": "Crankshaft position sensor circuit fault.",
        "P0336": "Crankshaft position sensor signal out of range.",
        "P0340": "Camshaft position sensor circuit fault.",
        "P0341": "Camshaft position sensor signal out of range.",
        "P0380": "Glow plug circuit fault.",
        "P0381": "Glow plug indicator circuit fault.",
        "P0400": "EGR flow fault.",
        "P0401": "EGR flow insufficient.",
        "P0402": "EGR flow excessive.",
        "P0403": "EGR control circuit fault.",
        "P0404": "EGR control signal out of range.",
        "P0405": "EGR position sensor signal low.",
        "P0406": "EGR position sensor signal high.",
        "P0470": "Exhaust pressure sensor circuit fault.",
        "P0471": "Exhaust pressure sensor signal out of range.",
        "P0472": "Exhaust pressure sensor signal low.",
        "P0473": "Exhaust pressure sensor signal high.",
        "P0480": "Cooling fan control circuit fault.",
        "P0500": "Vehicle speed sensor circuit fault.",
        "P0501": "Vehicle speed sensor signal out of range.",
        "P0544": "Exhaust temperature sensor circuit fault.",
        "P0545": "Exhaust temperature sensor signal low.",
        "P0546": "Exhaust temperature sensor signal high.",
        "P0560": "System voltage fault.",
        "P0562": "System voltage low.",
        "P0563": "System voltage high.",
        "P0600": "Serial communication link fault inside the powertrain controller.",
        "P0601": "Engine controller memory checksum fault.",
        "P0606": "Engine controller processor fault.",
        "P0627": "Fuel pump control circuit fault.",
        "P0628": "Fuel pump control circuit low.",
        "P0629": "Fuel pump control circuit high.",
        "P0641": "Sensor reference voltage A open.",
        "P0650": "Check engine lamp circuit fault.",
        "P0685": "Engine controller power relay circuit fault.",
        "P0697": "Sensor reference voltage C open.",
        "P0700": "Transmission controller requested the check engine lamp.",
        "P0720": "Transmission output speed sensor circuit fault.",
        "P2002": "Diesel particulate filter efficiency below the limit.",
        "P20EE": "SCR catalyst efficiency below the limit.",
        "P2122": "Accelerator pedal sensor D signal low.",
        "P2123": "Accelerator pedal sensor D signal high.",
        "P2127": "Accelerator pedal sensor E signal low.",
        "P2138": "Accelerator pedal sensors do not agree.",
        "P2200": "NOx sensor circuit fault.",
        "P2201": "NOx sensor signal out of range.",
        "P2263": "Turbo boost system performance fault.",
        "P2458": "Diesel particulate filter regeneration took too long.",
        "P2463": "Diesel particulate filter soot load too high.",
        "U0100": "Lost communication with the engine controller.",
        "U0101": "Lost communication with the transmission controller.",
        "U0121": "Lost communication with the ABS controller.",
        "U0140": "Lost communication with the body controller.",
        "U0155": "Lost communication with the instrument cluster."
    ]
}
