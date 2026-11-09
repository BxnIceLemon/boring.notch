//
//  MusicControlButton.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-16.
//

import Defaults

enum MusicControlButton: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case shuffle
    case previous
    case playPause
    case next
    case repeatMode
    case volume
    case favorite
    case goBackward
    case goForward
    case none

    var id: String { rawValue }

    static let defaultLayout: [MusicControlButton] = [
        .none,
        .previous,
        .playPause,
        .next,
        .none
    ]

    static let minSlotCount: Int = 3
    static let maxSlotCount: Int = 5

    static let pickerOptions: [MusicControlButton] = [
        .shuffle,
        .previous,
        .playPause,
        .next,
        .repeatMode,
        .favorite,
        .volume,
        .goBackward,
        .goForward
    ]

    var label: String {
        switch self {
        case .shuffle:
            return String(localized: "Shuffle", comment: "Music control button")
        case .previous:
            return String(localized: "Previous", comment: "Music control button")
        case .playPause:
            return String(localized: "Play/Pause", comment: "Music control button")
        case .next:
            return String(localized: "Next", comment: "Music control button")
        case .repeatMode:
            return String(localized: "Repeat", comment: "Music control button")
        case .volume:
            return String(localized: "Volume", comment: "Music control button")
        case .favorite:
            return String(localized: "Favorite", comment: "Music control button")
        case .goBackward:
            return String(localized: "Backward 15s", comment: "Music control button")
        case .goForward:
            return String(localized: "Forward 15s", comment: "Music control button")
        case .none:
            return String(localized: "Empty slot", comment: "Music control button")
        }
    }

    var iconName: String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .previous:
            return "backward.fill"
        case .playPause:
            return "playpause"
        case .next:
            return "forward.fill"
        case .repeatMode:
            return "repeat"
        case .volume:
            return "speaker.wave.2.fill"
        case .favorite:
            return "heart"
        case .goBackward:
            return "gobackward.15"
        case .goForward:
            return "goforward.15"
        case .none:
            return ""
        }
    }

    var prefersLargeScale: Bool {
        self == .playPause
    }
}
