import SwiftUI

/// What the name tag shows: the space's name, and where it sits among all spaces.
@MainActor
@Observable
public final class SpaceNameTagModel {
    public var name = ""
    public var index = 0
    public var count = 0

    public init() {}
}

/// The tag that flashes after a switch: the space's name over a row of dots, one per space, the
/// current one blue. Always the same size, whatever the name or the number of spaces, so it
/// doesn't jump about while you step through spaces.
public struct SpaceNameTag: View {
    let model: SpaceNameTagModel

    /// More than this many spaces and the dots give way to "3 of 12".
    static let maxDots = 12
    public static let size = CGSize(width: 340, height: 92)

    public init(model: SpaceNameTagModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text(model.name)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 24)
            Group {
                if model.count > Self.maxDots {
                    Text("\(model.index + 1) of \(model.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<max(1, model.count), id: \.self) { index in
                            Circle()
                                .fill(index == model.index ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.28))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }
            .frame(height: 16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }
}
