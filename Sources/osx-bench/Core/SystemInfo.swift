import Foundation

struct SystemInfo: Codable {
    let machineId: String
    let chip: String
    let coresPerformance: Int
    let coresEfficiency: Int
    let totalCores: Int
    let ramGB: Int
    let osVersion: String
    let modelIdentifier: String

    static func gather() throws -> SystemInfo {
        let machineId = getMachineId()
        let chip = getChipName()
        let (pCores, eCores) = getCoreCount()
        let ram = getRAMSize()
        let os = getOSVersion()
        let model = getModelIdentifier()

        return SystemInfo(
            machineId: machineId,
            chip: chip,
            coresPerformance: pCores,
            coresEfficiency: eCores,
            totalCores: pCores + eCores,
            ramGB: ram,
            osVersion: os,
            modelIdentifier: model
        )
    }

    func printSummary() {
        let thermal = ThermalMonitor.currentState()
        print("┌─────────────────────────────────────────────────────────────┐")
        print("│ System Information                                          │")
        print("├─────────────────────────────────────────────────────────────┤")
        print("│ Chip:        \(chip.padding(toLength: 45, withPad: " ", startingAt: 0)) │")
        print("│ Cores:       \(String("\(coresPerformance)P + \(coresEfficiency)E (\(totalCores) total)").padding(toLength: 45, withPad: " ", startingAt: 0)) │")
        print("│ RAM:         \(String("\(ramGB) GB").padding(toLength: 45, withPad: " ", startingAt: 0)) │")
        print("│ macOS:       \(osVersion.padding(toLength: 45, withPad: " ", startingAt: 0)) │")
        print("│ Thermal:     \(thermal.emoji) \(thermal.description.padding(toLength: 42, withPad: " ", startingAt: 0)) │")
        print("└─────────────────────────────────────────────────────────────┘")
    }

    func printDetailed() {
        print("""

        ┌─────────────────────────────────────────────────────────────┐
        │ System Information (Detailed)                               │
        ├─────────────────────────────────────────────────────────────┤
        │ Machine ID:    \(machineId.padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ Chip:          \(chip.padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ P-Cores:       \(String(coresPerformance).padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ E-Cores:       \(String(coresEfficiency).padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ Total Cores:   \(String(totalCores).padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ RAM:           \(String("\(ramGB) GB").padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ macOS:         \(osVersion.padding(toLength: 43, withPad: " ", startingAt: 0)) │
        │ Model:         \(modelIdentifier.padding(toLength: 43, withPad: " ", startingAt: 0)) │
        └─────────────────────────────────────────────────────────────┘

        """)
    }

    // MARK: - Private Helpers

    private static func getMachineId() -> String {
        // Get or create a persistent machine ID
        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".osx-bench")
        let idFile = configDir.appendingPathComponent("machine_id")

        if let existingId = try? String(contentsOf: idFile, encoding: .utf8) {
            return existingId.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Generate new ID
        let newId = UUID().uuidString
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? newId.write(to: idFile, atomically: true, encoding: .utf8)
        return newId
    }

    private static func getChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chipName = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chipName, &size, nil, 0)
        return String(cString: chipName)
    }

    private static func getCoreCount() -> (performance: Int, efficiency: Int) {
        // Try to get Apple Silicon specific core counts
        var pCores = 0
        var eCores = 0

        var size = MemoryLayout<Int32>.size
        var value: Int32 = 0

        // Performance cores
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0 {
            pCores = Int(value)
        }

        // Efficiency cores
        size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &value, &size, nil, 0) == 0 {
            eCores = Int(value)
        }

        // Fallback to total count if specific counts not available
        if pCores == 0 && eCores == 0 {
            size = MemoryLayout<Int32>.size
            sysctlbyname("hw.ncpu", &value, &size, nil, 0)
            pCores = Int(value)
            eCores = 0
        }

        return (pCores, eCores)
    }

    private static func getRAMSize() -> Int {
        var size = MemoryLayout<UInt64>.size
        var ram: UInt64 = 0
        sysctlbyname("hw.memsize", &ram, &size, nil, 0)
        return Int(ram / (1024 * 1024 * 1024))
    }

    private static func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func getModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
