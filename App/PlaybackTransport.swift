import PianobarCore

@MainActor
extension PlaybackState {
    /// Drive a play/pause transition through a single, race-free path.
    ///
    /// pianobar's `p` is a blind toggle and it emits no play/pause events, so
    /// the UI's `isPlaying` is our only estimate of pianobar's real state. The
    /// transport entry points used to read `isPlaying` *after* awaiting the
    /// FIFO write and then flip it (`try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying)`),
    /// which races with event-driven state changes and desyncs the UI when the
    /// write fails. This computes against an explicit `target` up front, only
    /// sends a command when a change is actually needed, and only updates the
    /// published state once the command has gone through.
    func setPlayback(_ target: Bool, via ctrl: PianobarCtrl) async {
        guard isPlaying != target else { return }
        do {
            try await ctrl.togglePlay()
            setPlaying(target)
        } catch {
            // The FIFO write didn't reach pianobar; leave the UI reflecting the
            // last known good state rather than claiming a transition that
            // never happened.
        }
    }
}
