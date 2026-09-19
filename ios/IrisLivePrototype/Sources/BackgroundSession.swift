//
//  BackgroundSession.swift
//  IrisLivePrototype
//
//  Keeps a live conversation usable with the app backgrounded or the phone
//  locked. The `audio` background mode (Info.plist) is what actually keeps the
//  process running while the .playAndRecord session is active; this file adds
//  the lock-screen / Control Center presence and a way to end the session from
//  there, so a live microphone is never invisible or unstoppable.
//

#if os(iOS)
import MediaPlayer

@MainActor
enum BackgroundSession {
    private static var stopTarget: Any?

    /// Call when a session starts. `onStop` ends the session.
    static func begin(onStop: @escaping @MainActor () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.stopCommand, center.togglePlayPauseCommand] {
            command.removeTarget(nil)
            command.isEnabled = true
        }
        let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            Task { @MainActor in onStop() }
            return .success
        }
        stopTarget = [
            center.pauseCommand.addTarget(handler: handler),
            center.stopCommand.addTarget(handler: handler),
            center.togglePlayPauseCommand.addTarget(handler: handler),
        ]
        center.playCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Iris — live conversation",
            MPMediaItemPropertyArtist: "Microphone is on. Pause to end the session.",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    /// Call when the session ends by any path.
    static func end() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.stopCommand, center.togglePlayPauseCommand] {
            command.removeTarget(nil)
        }
        stopTarget = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
#endif
