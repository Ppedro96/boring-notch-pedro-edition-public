//
//  PlaybackState.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

struct PlaybackState {
    var bundleIdentifier: String
    var isPlaying: Bool = false
    var title: String = "I'm Handsome"
    var artist: String = "Me"
    var album: String = "Self Love"
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.isPlaying == rhs.isPlaying
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
            && lhs.volume == rhs.volume
            && lhs.playbackRate == rhs.playbackRate
    }
}

extension PlaybackState {
    func hasSameTrack(as other: PlaybackState) -> Bool {
        bundleIdentifier == other.bundleIdentifier && title == other.title &&
            artist == other.artist && album == other.album
    }
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}


extension NowPlayingUpdate {
    func applying(to previous: PlaybackState, now: Date = Date()) -> PlaybackState {
        let incremental = diff ?? false
        var state = incremental ? previous : PlaybackState(bundleIdentifier: "")
        state.bundleIdentifier = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? state.bundleIdentifier
        state.title = payload.title ?? (incremental ? previous.title : "")
        state.artist = payload.artist ?? (incremental ? previous.artist : "")
        state.album = payload.album ?? (incremental ? previous.album : "")
        state.duration = payload.duration ?? (incremental ? previous.duration : 0)
        let sameTrack = state.hasSameTrack(as: previous)
        if !sameTrack {
            state.artwork = nil
            state.isFavorite = false
            state.currentTime = 0
        }
        if let artwork = payload.artworkData {
            state.artwork = Data(base64Encoded: artwork.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let elapsed = payload.elapsedTime {
            state.currentTime = elapsed
        } else if incremental, sameTrack, payload.playing == false, previous.isPlaying,
                  previous.lastUpdated != .distantPast {
            state.currentTime += max(0, now.timeIntervalSince(previous.lastUpdated)) * previous.playbackRate
            state.currentTime = min(max(0, state.currentTime), max(state.duration, 0))
        }
        state.isPlaying = payload.playing ?? (incremental ? previous.isPlaying : false)
        state.playbackRate = payload.playbackRate ?? (incremental ? previous.playbackRate : 1)
        state.volume = payload.volume ?? (incremental ? previous.volume : 0.5)
        if let shuffle = payload.shuffleMode { state.isShuffled = shuffle != 1 }
        if let repeatMode = payload.repeatMode { state.repeatMode = RepeatMode(rawValue: repeatMode) ?? .off }
        if let timestamp = payload.timestamp, let date = ISO8601DateFormatter().date(from: timestamp) {
            state.lastUpdated = date
        } else if !incremental || !sameTrack || payload.elapsedTime != nil || payload.playing != nil {
            state.lastUpdated = now
        }
        return state
    }
}
