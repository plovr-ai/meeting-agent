import AppKit
import AVFoundation
import Foundation

@MainActor
final class MeetingAudioReplayController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case playing(UUID)
        case paused(UUID)
    }

    @Published private(set) var state: State = .idle

    private var player: AVAudioPlayer?
    private var activeMeetingID: UUID?

    func toggleReplay(for meetingID: UUID, audioURL: URL) throws {
        switch state {
        case .playing(meetingID):
            pause()
        case .paused(meetingID):
            resume()
        default:
            try play(meetingID: meetingID, audioURL: audioURL)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        activeMeetingID = nil
        state = .idle
    }

    private func play(meetingID: UUID, audioURL: URL) throws {
        stop()
        let nextPlayer = try AVAudioPlayer(contentsOf: audioURL)
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()
        activeMeetingID = meetingID
        player = nextPlayer
        if nextPlayer.play() {
            state = .playing(meetingID)
        } else {
            stop()
            NSSound.beep()
        }
    }

    private func pause() {
        guard let activeMeetingID else { return }
        player?.pause()
        state = .paused(activeMeetingID)
    }

    private func resume() {
        guard let activeMeetingID else { return }
        if player?.play() == true {
            state = .playing(activeMeetingID)
        } else {
            stop()
            NSSound.beep()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.stop()
            NSSound.beep()
        }
    }
}
