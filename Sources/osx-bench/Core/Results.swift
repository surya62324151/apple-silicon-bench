import Foundation

// MARK: - Benchmark Types

enum BenchmarkType: String, CaseIterable, Codable {
    case cpuSingleCore = "cpu-single"
    case cpuMultiCore = "cpu-multi"
    case memory = "memory"
    case disk = "disk"

    var displayName: String {
        switch self {
        case .cpuSingleCore: return "CPU Single-Core"
        case .cpuMultiCore: return "CPU Multi-Core"
        case .memory: return "Memory"
        case .disk: return "Disk"
        }
    }
}

// MARK: - Individual Test Results

struct TestResult: Codable {
    let name: String
    let value: Double
    let unit: String
    let higherIsBetter: Bool

    init(name: String, value: Double, unit: String, higherIsBetter: Bool = true) {
        self.name = name
        self.value = value
        self.unit = unit
        self.higherIsBetter = higherIsBetter
    }

    var formattedValue: String {
        if value >= 1_000_000 {
            return String(format: "%.2f M", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.2f K", value / 1_000)
        } else if value < 1 {
            return String(format: "%.4f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

// MARK: - Benchmark Category Results

struct BenchmarkResult: Codable {
    let type: BenchmarkType
    let tests: [TestResult]
    let duration: TimeInterval
    let thermalStart: ThermalMonitor.ThermalLevel
    let thermalEnd: ThermalMonitor.ThermalLevel

    init(type: BenchmarkType, tests: [TestResult], duration: TimeInterval,
         thermalStart: ThermalMonitor.ThermalLevel = .nominal,
         thermalEnd: ThermalMonitor.ThermalLevel = .nominal) {
        self.type = type
        self.tests = tests
        self.duration = duration
        self.thermalStart = thermalStart
        self.thermalEnd = thermalEnd
    }

    var hadThrottling: Bool {
        thermalStart == .serious || thermalStart == .critical ||
        thermalEnd == .serious || thermalEnd == .critical
    }

    var summary: String {
        let testSummaries = tests.map { "\($0.name): \($0.formattedValue) \($0.unit)" }
        return testSummaries.joined(separator: ", ")
    }
}

// MARK: - Complete Results

struct BenchmarkResults: Codable {
    let timestamp: Date
    let benchmarks: [BenchmarkResult]
    let thermalData: [ThermalSnapshot]

    init(benchmarks: [BenchmarkResult], thermalData: [ThermalSnapshot] = []) {
        self.timestamp = Date()
        self.benchmarks = benchmarks
        self.thermalData = thermalData
    }

    func result(for type: BenchmarkType) -> BenchmarkResult? {
        benchmarks.first { $0.type == type }
    }

    var hadAnyThrottling: Bool {
        benchmarks.contains { $0.hadThrottling } ||
        thermalData.contains { $0.level == .serious || $0.level == .critical }
    }
}

// MARK: - Scores

struct BenchmarkScores: Codable {
    let cpuSingleCore: Double
    let cpuMultiCore: Double
    let memory: Double
    let disk: Double
    let total: Double
    // Track which benchmarks were run (vs skipped via --only)
    let ranCpuSingle: Bool
    let ranCpuMulti: Bool
    let ranMemory: Bool
    let ranDisk: Bool

    init(cpuSingleCore: Double, cpuMultiCore: Double, memory: Double, disk: Double, total: Double,
         ranCpuSingle: Bool = false, ranCpuMulti: Bool = false, ranMemory: Bool = false, ranDisk: Bool = false) {
        self.cpuSingleCore = cpuSingleCore
        self.cpuMultiCore = cpuMultiCore
        self.memory = memory
        self.disk = disk
        self.total = total
        self.ranCpuSingle = ranCpuSingle
        self.ranCpuMulti = ranCpuMulti
        self.ranMemory = ranMemory
        self.ranDisk = ranDisk
    }

    func printSummary(quickMode: Bool = false, partialRun: Bool = false) {
        let line = String(repeating: "─", count: 44)
        print(line)
        print("  BENCHMARK SCORES")
        print(line)
        // Show score if benchmark ran (even if 0 = failed), hide if not run
        if ranCpuSingle { print(dotPad("CPU Single-Core", formatScore(cpuSingleCore))) }
        if ranCpuMulti { print(dotPad("CPU Multi-Core", formatScore(cpuMultiCore))) }
        if ranMemory { print(dotPad("Memory", formatScore(memory))) }
        if ranDisk { print(dotPad("Disk", formatScore(disk))) }
        print(line)
        print(dotPad("TOTAL SCORE", formatScore(total)))
        print(line)

        // Print notes about scoring accuracy
        if quickMode {
            print("  ⚠️  Quick mode: scores may be less accurate")
        }
        if partialRun {
            print("  ℹ️  Partial run: total based on selected tests")
        }
    }

    private func formatScore(_ score: Double) -> String {
        score > 0 ? String(Int(score)) : "Failed"
    }

    private func dotPad(_ label: String, _ value: String) -> String {
        let prefix = "  \(label) "
        let suffix = " \(value)"
        let dotsCount = max(2, 44 - prefix.count - suffix.count)
        return prefix + String(repeating: ".", count: dotsCount) + suffix
    }
}

// MARK: - Scorer

struct BenchmarkScorer {
    // Reference values (baseline = M1 base chip = 1000 points per category)
    // Units MUST match the benchmark output units exactly
    private let referenceValues: [String: Double] = [
        // CPU Single - units match benchmark output
        "integer": 500,               // 500 Mops/s
        "float": 200,                 // 200 Mops/s
        "simd": 50,                   // 50 GFLOPS
        "crypto": 2000,               // 2000 MB/s (~2 GB/s)
        "compression": 500,           // 500 MB/s

        // Memory (GB/s or ns)
        "mem_read": 60,               // 60 GB/s
        "mem_write": 50,              // 50 GB/s
        "mem_copy": 40,               // 40 GB/s
        "mem_latency": 100,           // 100 ns (lower is better)

        // Disk (MB/s or IOPS)
        "disk_seq_read": 3000,        // 3000 MB/s
        "disk_seq_write": 2500,       // 2500 MB/s
        "disk_rand_read": 300000,     // 300K IOPS
        "disk_rand_write": 250000,    // 250K IOPS
    ]

    func calculateScores(from results: BenchmarkResults, coreCount: Int = 8) -> BenchmarkScores {
        // Check which benchmarks were actually run (not skipped via --only)
        let ranCpuSingle = results.result(for: .cpuSingleCore) != nil
        let ranCpuMulti = results.result(for: .cpuMultiCore) != nil
        let ranMemory = results.result(for: .memory) != nil
        let ranDisk = results.result(for: .disk) != nil

        let cpuSingle = calculateCPUSingleScore(results)
        let cpuMulti = calculateCPUMultiScore(results, coreCount: coreCount)
        let memory = calculateMemoryScore(results)
        let disk = calculateDiskScore(results)

        // Weighted total - include categories that were run (even if score is 0 = failed)
        // This prevents partial runs (--only) from being unfairly penalized
        // but still penalizes failures appropriately
        var totalScore = 0.0
        var totalWeight = 0.0

        if ranCpuSingle {
            totalScore += cpuSingle * 0.3
            totalWeight += 0.3
        }
        if ranCpuMulti {
            totalScore += cpuMulti * 0.3
            totalWeight += 0.3
        }
        if ranMemory {
            totalScore += memory * 0.2
            totalWeight += 0.2
        }
        if ranDisk {
            totalScore += disk * 0.2
            totalWeight += 0.2
        }

        // Normalize to account for skipped categories (not failures)
        let total = totalWeight > 0 ? totalScore / totalWeight : 0

        return BenchmarkScores(
            cpuSingleCore: cpuSingle,
            cpuMultiCore: cpuMulti,
            memory: memory,
            disk: disk,
            total: total,
            ranCpuSingle: ranCpuSingle,
            ranCpuMulti: ranCpuMulti,
            ranMemory: ranMemory,
            ranDisk: ranDisk
        )
    }

    private func calculateCPUSingleScore(_ results: BenchmarkResults) -> Double {
        guard let result = results.result(for: .cpuSingleCore) else { return 0 }

        var score = 0.0
        var count = 0

        for test in result.tests {
            // Skip failed tests (value <= 0) to avoid dragging down the average
            guard test.value > 0 else { continue }
            if let reference = referenceValues[test.name.lowercased()] {
                score += (test.value / reference) * 1000
                count += 1
            }
        }

        return count > 0 ? score / Double(count) : 0
    }

    private func calculateCPUMultiScore(_ results: BenchmarkResults, coreCount: Int) -> Double {
        guard let result = results.result(for: .cpuMultiCore) else { return 0 }

        var score = 0.0
        var count = 0

        for test in result.tests {
            // Skip failed tests (value <= 0) to avoid dragging down the average
            guard test.value > 0 else { continue }
            let baseName = test.name.lowercased().replacingOccurrences(of: "_multi", with: "")
            if let reference = referenceValues[baseName] {
                // Multi-core reference scales with actual core count (baseline M1 = 8 cores)
                // This normalizes scores so different core counts are comparable
                let coreScaleFactor = Double(coreCount) / 8.0
                score += (test.value / (reference * 8 * coreScaleFactor)) * 1000
                count += 1
            }
        }

        return count > 0 ? score / Double(count) : 0
    }

    private func calculateMemoryScore(_ results: BenchmarkResults) -> Double {
        guard let result = results.result(for: .memory) else { return 0 }

        var score = 0.0
        var count = 0

        for test in result.tests {
            // Skip failed tests (value <= 0) to avoid dragging down the average
            guard test.value > 0 else { continue }
            let key = "mem_\(test.name.lowercased())"
            if let reference = referenceValues[key] {
                if test.higherIsBetter {
                    score += (test.value / reference) * 1000
                } else {
                    // Lower is better (latency)
                    score += (reference / test.value) * 1000
                }
                count += 1
            }
        }

        return count > 0 ? score / Double(count) : 0
    }

    private func calculateDiskScore(_ results: BenchmarkResults) -> Double {
        guard let result = results.result(for: .disk) else { return 0 }

        var score = 0.0
        var count = 0

        for test in result.tests {
            // Skip failed tests (value <= 0) to avoid dragging down the average
            guard test.value > 0 else { continue }
            let key = "disk_\(test.name.lowercased().replacingOccurrences(of: " ", with: "_"))"
            if let reference = referenceValues[key] {
                score += (test.value / reference) * 1000
                count += 1
            }
        }

        return count > 0 ? score / Double(count) : 0
    }
}

// MARK: - Results Exporter

struct ResultsExporter {
    /// Export results to JSON without machine ID for privacy
    static func exportJSON(results: BenchmarkResults, scores: BenchmarkScores, systemInfo: SystemInfo, to path: String) throws {
        struct ExportData: Codable {
            let systemInfo: SystemInfoExport  // Privacy-safe version without machine ID
            let results: BenchmarkResults
            let scores: BenchmarkScores
        }

        let data = ExportData(systemInfo: systemInfo.forExport(), results: results, scores: scores)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(data)
        try jsonData.write(to: URL(fileURLWithPath: path))
    }
}
