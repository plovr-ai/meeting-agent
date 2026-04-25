import Foundation

final class AudioFrameRingBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [AudioFrame] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func push(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }
}
