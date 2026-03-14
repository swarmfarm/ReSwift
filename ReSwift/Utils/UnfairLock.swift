import os

final class UnfairLock: @unchecked Sendable {
    private let raw = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)

    init() {
        raw.initialize(to: os_unfair_lock())
    }

    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    func lock() {
        os_unfair_lock_lock(raw)
    }

    func unlock() {
        os_unfair_lock_unlock(raw)
    }

    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(raw)
        defer { os_unfair_lock_unlock(raw) }
        return try body()
    }
}
