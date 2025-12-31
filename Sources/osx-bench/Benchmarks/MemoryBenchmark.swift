import Foundation

struct MemoryBenchmark: Benchmark {
    let iterations: Int = 1  // Kept for protocol conformance
    let duration: Int  // Duration in seconds

    // Buffer size: 256 MB (larger than L3 cache to measure actual RAM)
    private let bufferSize = 256 * 1024 * 1024

    init(duration: Int) {
        self.duration = duration
    }

    func run() async throws -> [TestResult] {
        var results: [TestResult] = []
        let testDuration = Double(duration) / 4.0  // Divide duration among 4 tests

        // Sequential Read
        let readResult = measureForDuration(seconds: testDuration) {
            runReadTest()
        }
        results.append(TestResult(name: "Read", value: readResult, unit: "GB/s"))

        // Sequential Write
        let writeResult = measureForDuration(seconds: testDuration) {
            runWriteTest()
        }
        results.append(TestResult(name: "Write", value: writeResult, unit: "GB/s"))

        // Copy
        let copyResult = measureForDuration(seconds: testDuration) {
            runCopyTest()
        }
        results.append(TestResult(name: "Copy", value: copyResult, unit: "GB/s"))

        // Latency
        let latencyResult = measureForDuration(seconds: testDuration) {
            runLatencyTest()
        }
        results.append(TestResult(name: "Latency", value: latencyResult, unit: "ns", higherIsBetter: false))

        return results
    }

    /// Run operation repeatedly for the specified duration, returning averaged result
    private func measureForDuration(seconds: Double, operation: () -> Double) -> Double {
        // Warmup run
        _ = operation()

        var total = 0.0
        var count = 0
        let endTime = CFAbsoluteTimeGetCurrent() + seconds

        while CFAbsoluteTimeGetCurrent() < endTime {
            total += operation()
            count += 1
        }

        return count > 0 ? total / Double(count) : 0
    }

    // MARK: - Read Test
    private func runReadTest() -> Double {
        let count = bufferSize / MemoryLayout<UInt64>.size

        // Allocate page-aligned memory using UnsafeMutableRawPointer
        var rawBuffer: UnsafeMutableRawPointer?
        posix_memalign(&rawBuffer, 16384, bufferSize)
        guard let raw = rawBuffer else { return 0 }
        defer { free(raw) }

        let ptr = raw.bindMemory(to: UInt64.self, capacity: count)

        // Initialize to avoid copy-on-write
        memset(raw, 0x5A, bufferSize)

        // Force memory to be resident
        _ = mlock(raw, bufferSize)
        defer { munlock(raw, bufferSize) }

        var sum: UInt64 = 0

        let start = CFAbsoluteTimeGetCurrent()

        // Sequential read with unrolling for better throughput
        for i in stride(from: 0, to: count, by: 8) {
            sum = sum &+ ptr[i]
            sum = sum &+ ptr[i + 1]
            sum = sum &+ ptr[i + 2]
            sum = sum &+ ptr[i + 3]
            sum = sum &+ ptr[i + 4]
            sum = sum &+ ptr[i + 5]
            sum = sum &+ ptr[i + 6]
            sum = sum &+ ptr[i + 7]
        }

        let duration = CFAbsoluteTimeGetCurrent() - start

        // Prevent optimization
        if sum == UInt64.max { print("") }

        // GB/s
        return Double(bufferSize) / duration / (1024 * 1024 * 1024)
    }

    // MARK: - Write Test
    private func runWriteTest() -> Double {
        let count = bufferSize / MemoryLayout<UInt64>.size

        var rawBuffer: UnsafeMutableRawPointer?
        posix_memalign(&rawBuffer, 16384, bufferSize)
        guard let raw = rawBuffer else { return 0 }
        defer { free(raw) }

        let ptr = raw.bindMemory(to: UInt64.self, capacity: count)

        _ = mlock(raw, bufferSize)
        defer { munlock(raw, bufferSize) }

        let start = CFAbsoluteTimeGetCurrent()

        // Sequential write with unrolling
        for i in stride(from: 0, to: count, by: 8) {
            ptr[i] = UInt64(i)
            ptr[i + 1] = UInt64(i + 1)
            ptr[i + 2] = UInt64(i + 2)
            ptr[i + 3] = UInt64(i + 3)
            ptr[i + 4] = UInt64(i + 4)
            ptr[i + 5] = UInt64(i + 5)
            ptr[i + 6] = UInt64(i + 6)
            ptr[i + 7] = UInt64(i + 7)
        }

        // Memory barrier to ensure writes complete
        OSMemoryBarrier()

        let duration = CFAbsoluteTimeGetCurrent() - start

        return Double(bufferSize) / duration / (1024 * 1024 * 1024)
    }

    // MARK: - Copy Test
    private func runCopyTest() -> Double {
        var srcBuffer: UnsafeMutableRawPointer?
        var dstBuffer: UnsafeMutableRawPointer?

        posix_memalign(&srcBuffer, 16384, bufferSize)
        posix_memalign(&dstBuffer, 16384, bufferSize)

        guard let src = srcBuffer, let dst = dstBuffer else { return 0 }
        defer {
            free(src)
            free(dst)
        }

        // Initialize source
        memset(src, 0x5A, bufferSize)

        _ = mlock(src, bufferSize)
        _ = mlock(dst, bufferSize)
        defer {
            munlock(src, bufferSize)
            munlock(dst, bufferSize)
        }

        let start = CFAbsoluteTimeGetCurrent()

        memcpy(dst, src, bufferSize)

        OSMemoryBarrier()

        let duration = CFAbsoluteTimeGetCurrent() - start

        // GB/s (counting both read and write)
        return Double(bufferSize) / duration / (1024 * 1024 * 1024)
    }

    // MARK: - Latency Test (Random Access)
    private func runLatencyTest() -> Double {
        // Use smaller buffer that fits in L3 cache for latency measurement
        let latencyBufferSize = 32 * 1024 * 1024  // 32 MB
        let count = latencyBufferSize / MemoryLayout<Int>.size
        let accessCount = 10_000_000

        var rawBuffer: UnsafeMutableRawPointer?
        posix_memalign(&rawBuffer, 16384, latencyBufferSize)
        guard let raw = rawBuffer else { return 0 }
        defer { free(raw) }

        let ptr = raw.bindMemory(to: Int.self, capacity: count)

        // Create pointer chase (each element points to random next element)
        var indices = Array(0..<count)
        indices.shuffle()

        // Build linked list
        for i in 0..<count - 1 {
            ptr[indices[i]] = indices[i + 1]
        }
        ptr[indices[count - 1]] = indices[0]

        _ = mlock(raw, latencyBufferSize)
        defer { munlock(raw, latencyBufferSize) }

        var index = 0

        let start = CFAbsoluteTimeGetCurrent()

        // Pointer chase to measure true memory latency
        for _ in 0..<accessCount {
            index = ptr[index]
        }

        let duration = CFAbsoluteTimeGetCurrent() - start

        // Prevent optimization
        if index == Int.max { print("") }

        // Nanoseconds per access
        return (duration / Double(accessCount)) * 1_000_000_000
    }
}
