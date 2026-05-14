import Foundation

public final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []
    private var droppedFrames = 0
    private var waiters: [UUID: CheckedContinuation<[AudioFrame]?, Never>] = [:]
    private var isFinished = false

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func push(_ frame: AudioFrame) {
        let waitersToResume: [CheckedContinuation<[AudioFrame]?, Never>]
        let batchToResume: [AudioFrame]
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }

        frames.append(frame)
        if frames.count > capacity {
            let overflow = frames.count - capacity
            frames.removeFirst(overflow)
            droppedFrames += overflow
        }
        if waiters.isEmpty {
            waitersToResume = []
            batchToResume = []
        } else {
            waitersToResume = Array(waiters.values)
            waiters.removeAll()
            batchToResume = frames
            frames.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        for waiter in waitersToResume {
            waiter.resume(returning: batchToResume)
        }
    }

    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }

    public func finish() {
        let waitersToResume: [CheckedContinuation<[AudioFrame]?, Never>]
        let finalBatch: [AudioFrame]
        lock.lock()
        isFinished = true
        waitersToResume = Array(waiters.values)
        waiters.removeAll()
        finalBatch = frames
        frames.removeAll(keepingCapacity: true)
        lock.unlock()

        for waiter in waitersToResume {
            waiter.resume(returning: finalBatch.isEmpty ? nil : finalBatch)
        }
    }

    public var batches: AsyncStream<[AudioFrame]> {
        AsyncStream {
            await self.nextBatch()
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return frames.count
    }

    public var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }

        return droppedFrames
    }

    private func nextBatch() async -> [AudioFrame]? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult: [AudioFrame]?
                var shouldResumeImmediately = false

                lock.lock()
                if !frames.isEmpty {
                    immediateResult = frames
                    frames.removeAll(keepingCapacity: true)
                    shouldResumeImmediately = true
                } else if isFinished {
                    immediateResult = nil
                    shouldResumeImmediately = true
                } else {
                    immediateResult = nil
                    waiters[id] = continuation
                }
                lock.unlock()

                if shouldResumeImmediately {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter: CheckedContinuation<[AudioFrame]?, Never>?
        lock.lock()
        waiter = waiters.removeValue(forKey: id)
        lock.unlock()

        waiter?.resume(returning: nil)
    }
}
