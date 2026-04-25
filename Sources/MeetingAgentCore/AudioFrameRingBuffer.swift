import Foundation

public final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []
    private var droppedFrames = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func push(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        frames.append(frame)
        if frames.count > capacity {
            let overflow = frames.count - capacity
            frames.removeFirst(overflow)
            droppedFrames += overflow
        }
    }

    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
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
}
