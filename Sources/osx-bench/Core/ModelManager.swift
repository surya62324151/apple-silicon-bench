import Foundation
import CryptoKit

// MARK: - Model Manager

struct ModelManager {
    // Model configuration - download directly from Apple's ML assets
    static let modelVersion = "v1"
    static let modelSourceName = "MobileNetV2.mlmodel"
    static let modelCompiledName = "MobileNetV2.mlmodelc"

    // Apple's official CoreML model repository
    static let appleModelURL = "https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2.mlmodel"

    // Cache directory
    static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("osx-bench/models/\(modelVersion)")
    }

    static var cachedSourcePath: URL {
        cacheDirectory.appendingPathComponent(modelSourceName)
    }

    static var cachedCompiledPath: URL {
        cacheDirectory.appendingPathComponent(modelCompiledName)
    }

    let customModelPath: String?
    let offlineMode: Bool

    init(customModelPath: String? = nil, offlineMode: Bool = false) {
        self.customModelPath = customModelPath
        self.offlineMode = offlineMode
    }

    // MARK: - Public API

    /// Ensures the model is available and returns its path
    /// Returns nil if model is unavailable (offline mode without cache)
    func ensureModel() async throws -> URL? {
        // Priority 1: Custom model path
        if let customPath = customModelPath {
            let url = URL(fileURLWithPath: customPath)
            guard FileManager.default.fileExists(atPath: customPath) else {
                throw ModelError.customModelNotFound(path: customPath)
            }
            return url
        }

        // Priority 2: Cached compiled model
        if FileManager.default.fileExists(atPath: Self.cachedCompiledPath.path) {
            return Self.cachedCompiledPath
        }

        // Priority 3: Download and compile (if not offline)
        if offlineMode {
            print("  ⚠️  AI model not cached and --offline specified. Skipping AI benchmark.")
            return nil
        }

        // Download and compile the model
        return try await downloadAndCompileModel()
    }

    // MARK: - Download and Compile

    private func downloadAndCompileModel() async throws -> URL {
        print("  📥 Downloading AI model from Apple ML assets...")

        guard let url = URL(string: Self.appleModelURL) else {
            throw ModelError.invalidURL
        }

        // Create cache directory
        try FileManager.default.createDirectory(
            at: Self.cacheDirectory,
            withIntermediateDirectories: true
        )

        // Download
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Move to cache directory
        try? FileManager.default.removeItem(at: Self.cachedSourcePath)
        try FileManager.default.moveItem(at: tempURL, to: Self.cachedSourcePath)

        print("  ⚙️  Compiling model for your device...")

        // Compile the model using coremlcompiler
        try compileModel()

        // Clean up source .mlmodel (keep only compiled)
        try? FileManager.default.removeItem(at: Self.cachedSourcePath)

        // Verify compiled model exists
        guard FileManager.default.fileExists(atPath: Self.cachedCompiledPath.path) else {
            throw ModelError.compilationFailed
        }

        print("  ✓ Model ready")
        return Self.cachedCompiledPath
    }

    private func compileModel() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "coremlcompiler",
            "compile",
            Self.cachedSourcePath.path,
            Self.cacheDirectory.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelError.compilationFailed
        }
    }
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case customModelNotFound(path: String)
    case invalidURL
    case downloadFailed(statusCode: Int)
    case compilationFailed

    var errorDescription: String? {
        switch self {
        case .customModelNotFound(let path):
            return "Custom model not found at: \(path)"
        case .invalidURL:
            return "Invalid model URL"
        case .downloadFailed(let statusCode):
            return "Model download failed with status code: \(statusCode)"
        case .compilationFailed:
            return "Failed to compile CoreML model (requires Xcode Command Line Tools)"
        }
    }
}
