//
//  NetEaseMusicController.swift
//  boringNotch
//
//  NetEase Cloud Music (网易云音乐, com.netease.163music).
//
//  NetEase has no AppleScript dictionary, no local API and posts no distributed notifications.
//  It does publish to the system Now Playing center, so:
//  - Reading (title, artist, album, artwork, duration, position, playing) reuses NowPlayingController
//    (MediaRemote via mediaremote-adapter) and keeps only NetEase's own updates.
//  - Play/pause, next and previous go through MediaRemote while NetEase holds the system media focus.
//    MediaRemote commands always land on the focused app (even when "targeted" at a bundle), so when
//    another app holds focus they are sent by pressing NetEase's own menu items via the XPC helper.
//  - Like/unlike reads and presses its "喜欢歌曲 / 取消喜欢" menu item (⌘L) via the XPC helper.
//  - Volume, shuffle/repeat and seeking are not offered: the menu shows no shuffle/repeat state,
//    there is no volume readback, and NetEase rejects MediaRemote seek commands.
//  Menu control needs the Accessibility permission (the same one the HUD replacement uses).
//

import AppKit
import Combine
import Foundation

final class NetEaseMusicController: ObservableObject, MediaControllerProtocol {
    static let bundleIdentifier = "com.netease.163music"

    @Published private(set) var playbackState = PlaybackState(bundleIdentifier: NetEaseMusicController.bundleIdentifier)

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool { false }
    var supportsFavorite: Bool { true }

    private let nowPlaying: NowPlayingController
    private var cancellables = Set<AnyCancellable>()
    private var favoriteRefreshTask: Task<Void, Never>?
    private var appStateObserver: Task<Void, Never>?

    /// After a track change NetEase needs ~0.2s to update the Like menu item for the new track.
    private let favoriteSettleDelay: Duration = .seconds(1)

    /// Fails when MediaRemote is not usable on this system (same condition as NowPlayingController).
    init?() {
        guard let nowPlaying = NowPlayingController() else { return nil }
        self.nowPlaying = nowPlaying

        nowPlaying.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                // Delivered on the main queue by receive(on:) above.
                MainActor.assumeIsolated { self?.handleSystemNowPlaying(state) }
            }
            .store(in: &cancellables)

        appStateObserver = Task { [weak self] in
            let terminations = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification)
            for await note in terminations {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleIdentifier else { continue }
                await MainActor.run { self?.resetPlaybackState() }
            }
        }
    }

    deinit {
        favoriteRefreshTask?.cancel()
        appStateObserver?.cancel()
    }

    /// Whether NetEase currently owns the system Now Playing session (MediaRemote commands reach it).
    private var hasSystemMediaFocus: Bool {
        nowPlaying.playbackState.bundleIdentifier == Self.bundleIdentifier
    }

    // MARK: - State

    @MainActor
    private func handleSystemNowPlaying(_ state: PlaybackState) {
        guard state.bundleIdentifier == Self.bundleIdentifier else {
            // Another app took the Now Playing focus; keep NetEase's last track but stop treating it as playing.
            if playbackState.isPlaying {
                var paused = playbackState
                paused.isPlaying = false
                playbackState = paused
            }
            return
        }
        let trackChanged = state.title != playbackState.title || state.artist != playbackState.artist
        var updated = state
        updated.isFavorite = trackChanged ? false : playbackState.isFavorite
        updated.volume = playbackState.volume
        playbackState = updated
        if trackChanged {
            scheduleFavoriteRefresh(after: favoriteSettleDelay)
        }
    }

    @MainActor
    private func resetPlaybackState() {
        favoriteRefreshTask?.cancel()
        playbackState = PlaybackState(bundleIdentifier: Self.bundleIdentifier, isPlaying: false)
    }

    @MainActor
    private func scheduleFavoriteRefresh(after delay: Duration) {
        favoriteRefreshTask?.cancel()
        favoriteRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshFavorite()
        }
    }

    private func refreshFavorite() async {
        guard isActive(), let liked = await XPCHelperClient.shared.netEaseFavoriteState() else { return }
        await MainActor.run {
            guard playbackState.isFavorite != liked else { return }
            var updated = playbackState
            updated.isFavorite = liked
            playbackState = updated
        }
    }

    // MARK: - MediaControllerProtocol

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleIdentifier }
    }

    func updatePlaybackInfo() async {
        await refreshFavorite()
    }

    func play() async {
        if hasSystemMediaFocus { await nowPlaying.play() }
        else if !playbackState.isPlaying { await pressMenu("playPause") }
    }

    func pause() async {
        if hasSystemMediaFocus { await nowPlaying.pause() }
        else if playbackState.isPlaying { await pressMenu("playPause") }
    }

    func togglePlay() async {
        if hasSystemMediaFocus { await nowPlaying.togglePlay() }
        else { await pressMenu("playPause") }
    }

    func nextTrack() async {
        if hasSystemMediaFocus { await nowPlaying.nextTrack() }
        else { await pressMenu("nextTrack") }
    }

    func previousTrack() async {
        if hasSystemMediaFocus { await nowPlaying.previousTrack() }
        else { await pressMenu("previousTrack") }
    }

    /// NetEase rejects MediaRemote seek commands; sending it is harmless and keeps working if a
    /// future NetEase version accepts it.
    func seek(to time: Double) async {
        if hasSystemMediaFocus { await nowPlaying.seek(to: time) }
    }

    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {}

    func setFavorite(_ favorite: Bool) async {
        guard isActive() else { return }
        _ = await XPCHelperClient.shared.setNetEaseFavorite(favorite)
        await refreshFavorite()
    }

    private func pressMenu(_ command: String) async {
        guard isActive() else { return }
        _ = await XPCHelperClient.shared.pressNetEaseMenuCommand(command)
    }
}
