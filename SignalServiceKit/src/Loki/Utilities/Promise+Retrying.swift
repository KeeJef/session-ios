import PromiseKit

/// Retry the promise constructed in `body` up to `maxRetryCount` times.
internal func attempt<T>(maxRetryCount: UInt, recoveringOn queue: DispatchQueue = .global(qos: .userInitiated), body: @escaping () -> Promise<T>) -> Promise<T> {
    var retryCount = 0
    func attempt() -> Promise<T> {
        return body().recover(on: queue) { error -> Promise<T> in
            guard retryCount < maxRetryCount else { throw error }
            retryCount += 1
            return attempt()
        }
    }
    return attempt()
}
