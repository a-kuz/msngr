import LiveKit
import SwiftUI

/// A participant's camera in a room call, filling its tile.
public struct RoomVideoView: View {
    private let track: VideoTrack

    public init(track: VideoTrack) {
        self.track = track
    }

    public var body: some View {
        SwiftUIVideoView(track, layoutMode: .fill)
    }
}
