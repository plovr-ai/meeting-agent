import Foundation

public final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func push(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }
}
