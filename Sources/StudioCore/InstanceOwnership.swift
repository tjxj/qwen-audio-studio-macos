import Foundation
import Darwin

public enum InstanceOwnershipError: Error, Equatable, Sendable, LocalizedError {
    case alreadyOwned, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .alreadyOwned: "另一应用实例正在使用此原生资料库，请先退出该实例。"
        case .system(let code): "无法锁定原生资料库（系统错误 \(code)）。"
        }
    }
}

/// Hold this object for the entire database lifetime. The fixed lock inode is NEVER unlinked.
public final class InstanceOwnership: Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    public static func acquire(dataRoot: URL) throws -> InstanceOwnership {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let descriptor = open(dataRoot.appendingPathComponent("instance.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstanceOwnershipError.system(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw InstanceOwnershipError.alreadyOwned }
            throw InstanceOwnershipError.system(code)
        }
        return InstanceOwnership(descriptor: descriptor)
    }
    deinit { Darwin.close(descriptor) }
}
