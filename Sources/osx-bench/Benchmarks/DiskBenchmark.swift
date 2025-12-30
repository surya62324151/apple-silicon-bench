import Foundation

struct DiskBenchmark: Benchmark {
    let iterations: Int
    let quickMode: Bool

    private let testDir: URL
    private var sequentialSize: Int { quickMode ? 128 * 1024 * 1024 : 512 * 1024 * 1024 }  // 128MB quick, 512MB full
    private let randomBlockSize = 4096  // 4 KB
    private var randomOperations: Int { quickMode ? 1000 : 5000 }

    init(iterations: Int, quickMode: Bool = false) {
        self.iterations = iterations
        self.quickMode = quickMode
        self.testDir = FileManager.default.temporaryDirectory.appendingPathComponent("osx-bench-disk")
    }

    func run() async throws -> [TestResult] {
        // Setup test directory
        try? FileManager.default.removeItem(at: testDir)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        var results: [TestResult] = []

        // Sequential Write
        let seqWriteResult = try measureAverage(iterations: iterations) {
            try runSequentialWriteTest()
        }
        results.append(TestResult(name: "Seq_Write", value: seqWriteResult, unit: "MB/s"))

        // Sequential Read
        let seqReadResult = try measureAverage(iterations: iterations) {
            try runSequentialReadTest()
        }
        results.append(TestResult(name: "Seq_Read", value: seqReadResult, unit: "MB/s"))

        // Random Write IOPS
        let randWriteResult = try measureAverage(iterations: iterations) {
            try runRandomWriteTest()
        }
        results.append(TestResult(name: "Rand_Write", value: randWriteResult, unit: "IOPS"))

        // Random Read IOPS
        let randReadResult = try measureAverage(iterations: iterations) {
            try runRandomReadTest()
        }
        results.append(TestResult(name: "Rand_Read", value: randReadResult, unit: "IOPS"))

        return results
    }

    // MARK: - Sequential Write Test
    private func runSequentialWriteTest() throws -> Double {
        let filePath = testDir.appendingPathComponent("seq_write_test")
        defer { try? FileManager.default.removeItem(at: filePath) }

        let chunkSize = 4 * 1024 * 1024  // 4 MB chunks
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { ptr in
            arc4random_buf(ptr.baseAddress!, chunkSize)
        }

        let fd = open(filePath.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }
        defer { close(fd) }

        _ = fcntl(fd, F_NOCACHE, 1)

        let start = CFAbsoluteTimeGetCurrent()

        var bytesWritten = 0
        while bytesWritten < sequentialSize {
            let result = chunk.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, chunkSize)
            }
            if result < 0 { break }
            bytesWritten += result
        }

        _ = fcntl(fd, F_FULLFSYNC)

        let duration = CFAbsoluteTimeGetCurrent() - start

        return Double(bytesWritten) / duration / (1024 * 1024)
    }

    // MARK: - Sequential Read Test
    private func runSequentialReadTest() throws -> Double {
        let filePath = testDir.appendingPathComponent("seq_read_test")

        let chunkSize = 4 * 1024 * 1024
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { ptr in
            arc4random_buf(ptr.baseAddress!, chunkSize)
        }

        let writefd = open(filePath.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard writefd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }

        var written = 0
        while written < sequentialSize {
            let result = chunk.withUnsafeBytes { ptr in
                write(writefd, ptr.baseAddress!, chunkSize)
            }
            if result < 0 { break }
            written += result
        }
        close(writefd)

        defer { try? FileManager.default.removeItem(at: filePath) }

        let fd = open(filePath.path, O_RDONLY)
        guard fd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }
        defer { close(fd) }

        _ = fcntl(fd, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: chunkSize)

        let start = CFAbsoluteTimeGetCurrent()

        var bytesRead = 0
        while bytesRead < sequentialSize {
            let result = read(fd, &readBuffer, chunkSize)
            if result <= 0 { break }
            bytesRead += result
        }

        let duration = CFAbsoluteTimeGetCurrent() - start

        return Double(bytesRead) / duration / (1024 * 1024)
    }

    // MARK: - Random Write IOPS
    private func runRandomWriteTest() throws -> Double {
        let filePath = testDir.appendingPathComponent("rand_write_test")

        let fileSize = 256 * 1024 * 1024  // 256 MB sparse file
        let fd = open(filePath.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: filePath)
        }

        _ = ftruncate(fd, off_t(fileSize))
        _ = fcntl(fd, F_NOCACHE, 1)

        var block = [UInt8](repeating: 0, count: randomBlockSize)
        arc4random_buf(&block, randomBlockSize)

        let maxOffset = fileSize - randomBlockSize
        let blockAlignedMax = maxOffset / randomBlockSize

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<randomOperations {
            let blockIndex = Int(arc4random_uniform(UInt32(blockAlignedMax)))
            let offset = off_t(blockIndex * randomBlockSize)
            lseek(fd, offset, SEEK_SET)
            _ = write(fd, &block, randomBlockSize)
        }

        _ = fcntl(fd, F_FULLFSYNC)

        let duration = CFAbsoluteTimeGetCurrent() - start

        return Double(randomOperations) / duration
    }

    // MARK: - Random Read IOPS
    private func runRandomReadTest() throws -> Double {
        let filePath = testDir.appendingPathComponent("rand_read_test")

        let fileSize = 256 * 1024 * 1024  // 256 MB
        let chunkSize = 4 * 1024 * 1024

        let writefd = open(filePath.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard writefd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }

        var chunk = [UInt8](repeating: 0x5A, count: chunkSize)
        var written = 0
        while written < fileSize {
            let result = write(writefd, &chunk, chunkSize)
            if result < 0 { break }
            written += result
        }
        close(writefd)

        defer { try? FileManager.default.removeItem(at: filePath) }

        let fd = open(filePath.path, O_RDONLY)
        guard fd >= 0 else { throw DiskBenchmarkError.fileOpenFailed }
        defer { close(fd) }

        _ = fcntl(fd, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: randomBlockSize)
        let maxOffset = fileSize - randomBlockSize
        let blockAlignedMax = maxOffset / randomBlockSize

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<randomOperations {
            let blockIndex = Int(arc4random_uniform(UInt32(blockAlignedMax)))
            let offset = off_t(blockIndex * randomBlockSize)
            lseek(fd, offset, SEEK_SET)
            _ = read(fd, &readBuffer, randomBlockSize)
        }

        let duration = CFAbsoluteTimeGetCurrent() - start

        return Double(randomOperations) / duration
    }
}

enum DiskBenchmarkError: Error, LocalizedError {
    case fileOpenFailed
    case writeFailed
    case readFailed

    var errorDescription: String? {
        switch self {
        case .fileOpenFailed: return "Failed to open test file"
        case .writeFailed: return "Write operation failed"
        case .readFailed: return "Read operation failed"
        }
    }
}
