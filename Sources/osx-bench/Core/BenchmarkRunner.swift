import Foundation

actor BenchmarkRunner {
    private let systemInfo: SystemInfo
    private let quickMode: Bool
    private let selectedBenchmarks: Set<BenchmarkType>?
    private let thermalCollector = ThermalCollector()

    init(systemInfo: SystemInfo, quickMode: Bool, selectedBenchmarks: Set<BenchmarkType>?) {
        self.systemInfo = systemInfo
        self.quickMode = quickMode
        self.selectedBenchmarks = selectedBenchmarks
    }

    func runAll() async throws -> BenchmarkResults {
        var results: [BenchmarkResult] = []

        // Record thermal state at start
        thermalCollector.record(phase: "start")

        // Check for throttling before starting
        if ThermalMonitor.isThrottling {
            print("\n⚠️  Warning: System is already throttling. Consider waiting for cooldown.")
        }

        let benchmarksToRun = selectedBenchmarks ?? Set(BenchmarkType.allCases)

        for benchmarkType in BenchmarkType.allCases where benchmarksToRun.contains(benchmarkType) {
            // Record thermal before each benchmark
            thermalCollector.record(phase: "before_\(benchmarkType.rawValue)")

            let thermalState = ThermalMonitor.currentState()
            print("\n▶ Running \(benchmarkType.displayName) benchmark... \(thermalState.emoji)")

            let result = try await runBenchmark(type: benchmarkType)
            results.append(result)

            // Record thermal after each benchmark
            thermalCollector.record(phase: "after_\(benchmarkType.rawValue)")

            printResult(result)
        }

        // Record final thermal state
        thermalCollector.record(phase: "end")

        // Print thermal summary
        printThermalSummary()

        return BenchmarkResults(benchmarks: results, thermalData: thermalCollector.allSnapshots)
    }

    private func runBenchmark(type: BenchmarkType) async throws -> BenchmarkResult {
        let iterations = quickMode ? 1 : 3
        let startTime = CFAbsoluteTimeGetCurrent()
        let startThermal = ThermalMonitor.currentState()

        let benchmark: any Benchmark
        switch type {
        case .cpuSingleCore:
            benchmark = CPUSingleCoreBenchmark(iterations: iterations, quickMode: quickMode)
        case .cpuMultiCore:
            benchmark = CPUMultiCoreBenchmark(iterations: iterations, coreCount: systemInfo.totalCores, quickMode: quickMode)
        case .memory:
            benchmark = MemoryBenchmark(iterations: iterations)
        case .disk:
            benchmark = DiskBenchmark(iterations: iterations, quickMode: quickMode)
        }

        let tests = try await benchmark.run()
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let endThermal = ThermalMonitor.currentState()

        return BenchmarkResult(
            type: type,
            tests: tests,
            duration: duration,
            thermalStart: startThermal,
            thermalEnd: endThermal
        )
    }

    private func printResult(_ result: BenchmarkResult) {
        let thermalChange = result.thermalStart.emoji != result.thermalEnd.emoji
            ? " \(result.thermalStart.emoji)→\(result.thermalEnd.emoji)"
            : ""

        print("  ✓ Completed in \(String(format: "%.2f", result.duration))s\(thermalChange)")
        for test in result.tests {
            let indicator = test.higherIsBetter ? "↑" : "↓"
            print("    • \(test.name): \(test.formattedValue) \(test.unit) \(indicator)")
        }
    }

    private func printThermalSummary() {
        print("\n┌─────────────────────────────────────────────────────────────┐")
        print("│ Thermal Summary                                             │")
        print("├─────────────────────────────────────────────────────────────┤")
        print("│ Progression: \(thermalCollector.summary().padding(toLength: 45, withPad: " ", startingAt: 0)) │")

        if thermalCollector.hadThrottling {
            print("│ ⚠️  Throttling was detected during benchmark!               │")
            print("│    Results may be lower than optimal performance.          │")
        }
        print("└─────────────────────────────────────────────────────────────┘")
    }
}

// MARK: - Benchmark Protocol

protocol Benchmark {
    var iterations: Int { get }
    func run() async throws -> [TestResult]
}

extension Benchmark {
    func measureAverage(iterations: Int, warmup: Int = 1, operation: () throws -> Double) rethrows -> Double {
        // Warmup runs
        for _ in 0..<warmup {
            _ = try operation()
        }

        // Measured runs
        var total = 0.0
        for _ in 0..<iterations {
            total += try operation()
        }

        return total / Double(iterations)
    }

    func measureTime(operation: () throws -> Void) rethrows -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try operation()
        return CFAbsoluteTimeGetCurrent() - start
    }
}
