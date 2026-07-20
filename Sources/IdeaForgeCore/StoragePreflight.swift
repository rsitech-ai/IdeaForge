import Foundation

public protocol UserFacingIdeaForgeError: Error {
    var userFacingMessage: String { get }
}

public protocol StorageCapacityChecking: Sendable {
    func availableCapacityBytes(for url: URL) throws -> Int64
}

public enum StoragePreflightError: Error, Equatable, UserFacingIdeaForgeError {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case capacityUnavailable

    public var requiredBytes: Int64? {
        guard case .insufficientStorage(let requiredBytes, _) = self else { return nil }
        return requiredBytes
    }

    public var availableBytes: Int64? {
        guard case .insufficientStorage(_, let availableBytes) = self else { return nil }
        return availableBytes
    }

    public var userFacingMessage: String {
        switch self {
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let missingBytes = max(requiredBytes - availableBytes, 1)
            return "Not enough free storage. Free at least \(Self.formattedBytes(missingBytes)) and try again."
        case .capacityUnavailable:
            return "Storage capacity could not be verified. Free space and try again."
        }
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

public struct SystemStorageCapacityChecker: StorageCapacityChecking {
    public init() {}

    public func availableCapacityBytes(for url: URL) throws -> Int64 {
        let volumeURL = Self.nearestExistingAncestor(for: url)
        #if os(watchOS)
        let values = try volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        #else
        let values = try volumeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
            return importantCapacity
        }
        #endif
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        throw StoragePreflightError.capacityUnavailable
    }

    private static func nearestExistingAncestor(for url: URL) -> URL {
        var current = url.standardizedFileURL
        let fileManager = FileManager.default

        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return current }
            current = parent
        }
        return current
    }
}

public struct StoragePreflight: Sendable {
    public static let oneMiB: Int64 = 1_048_576

    public var minimumFreeBytes: Int64
    public var capacityChecker: any StorageCapacityChecking

    public init(
        minimumFreeBytes: Int64,
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) {
        self.minimumFreeBytes = minimumFreeBytes
        self.capacityChecker = capacityChecker
    }

    public func validateWritableVolume(
        for directory: URL,
        estimatedWriteBytes: Int64 = 0
    ) throws {
        let requiredBytes = max(minimumFreeBytes, 0) + max(estimatedWriteBytes, 0)
        let availableBytes = try capacityChecker.availableCapacityBytes(for: directory)
        guard availableBytes >= requiredBytes else {
            throw StoragePreflightError.insufficientStorage(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    public static func recording(
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) -> StoragePreflight {
        StoragePreflight(minimumFreeBytes: 100 * oneMiB, capacityChecker: capacityChecker)
    }

    public static func recordingImport(
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) -> StoragePreflight {
        StoragePreflight(minimumFreeBytes: 50 * oneMiB, capacityChecker: capacityChecker)
    }

    public static func ideaBriefExport(
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) -> StoragePreflight {
        StoragePreflight(minimumFreeBytes: 10 * oneMiB, capacityChecker: capacityChecker)
    }

    public static func codexPacketExport(
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) -> StoragePreflight {
        StoragePreflight(minimumFreeBytes: 25 * oneMiB, capacityChecker: capacityChecker)
    }

    public static func encryptedObjectStore(
        capacityChecker: any StorageCapacityChecking = SystemStorageCapacityChecker()
    ) -> StoragePreflight {
        StoragePreflight(minimumFreeBytes: 50 * oneMiB, capacityChecker: capacityChecker)
    }
}
