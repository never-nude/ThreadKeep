import AppKit
import SwiftUI

/// Avatar representation of one or more participants. Shows a contact photo when
/// available, otherwise a colored monogram. For group conversations, composes a
/// compact cluster that stays inside the avatar slot.
struct AvatarView: View {
    struct Participant: Hashable {
        /// Display name the caller already resolved (for initials).
        let displayName: String
        /// Raw handle (phone/email) used as the palette + image lookup key. Falls back to
        /// `displayName` when the caller only has a name.
        let handle: String
    }

    let participants: [Participant]
    let size: CGFloat
    @ObservedObject var resolver: ContactDisplayResolver

    var body: some View {
        Group {
            if participants.isEmpty {
                MonogramView(displayName: "?", paletteKey: "?", size: size)
            } else if participants.count == 1 {
                single(participants[0], size: size)
            } else {
                groupCluster
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func single(_ participant: Participant, size: CGFloat) -> some View {
        if let data = resolver.imageData(for: participant.handle),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            MonogramView(
                displayName: participant.displayName,
                paletteKey: participant.handle.isEmpty ? participant.displayName : participant.handle,
                size: size
            )
        }
    }

    private var groupCluster: some View {
        let items = clusterItems
        let tileSize = clusterTileSize(for: items.count)

        return clusterGrid(items: items, tileSize: tileSize)
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func clusterGrid(items: [ClusterItem], tileSize: CGFloat) -> some View {
        switch items.count {
        case 2:
            HStack(spacing: 2) {
                clusterTile(items[0], tileSize: tileSize)
                clusterTile(items[1], tileSize: tileSize)
            }
        case 3:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    clusterTile(items[0], tileSize: tileSize)
                    clusterTile(items[1], tileSize: tileSize)
                }
                clusterTile(items[2], tileSize: tileSize)
            }
        default:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    clusterTile(items[0], tileSize: tileSize)
                    clusterTile(items[1], tileSize: tileSize)
                }
                HStack(spacing: 2) {
                    clusterTile(items[2], tileSize: tileSize)
                    clusterTile(items[3], tileSize: tileSize)
                }
            }
        }
    }

    @ViewBuilder
    private func clusterTile(_ item: ClusterItem, tileSize: CGFloat) -> some View {
        switch item {
        case .participant(let participant):
            single(participant, size: tileSize)
        case .overflow(let count):
            overflowBubble(extraCount: count, tileSize: tileSize)
        }
    }

    private enum ClusterItem {
        case participant(Participant)
        case overflow(Int)
    }

    private var clusterItems: [ClusterItem] {
        if participants.count <= 4 {
            return participants.prefix(4).map(ClusterItem.participant)
        }

        return participants.prefix(3).map(ClusterItem.participant) + [.overflow(participants.count - 3)]
    }

    private func clusterTileSize(for visibleItemCount: Int) -> CGFloat {
        switch visibleItemCount {
        case 2:
            return size * 0.46
        case 3:
            return size * 0.40
        default:
            return size * 0.43
        }
    }

    private func overflowBubble(extraCount: Int, tileSize: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.35))
            Text("+\(extraCount)")
                .font(.system(size: tileSize * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }
}
