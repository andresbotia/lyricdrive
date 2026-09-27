import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LyricDriveLiveActivityBundle: WidgetBundle {
    var body: some Widget { LyricDriveLiveActivity() }
}

struct LyricDriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricDriveActivityAttributes.self) { context in
            LyricActivityView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LyricActivityView(context: context)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.isStale ? "—" : (context.state.isPaused ? "Ⅱ" : "♪"))
            } minimal: {
                Image(systemName: context.isStale ? "clock" : "music.note")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LyricActivityView: View {
    let context: ActivityViewContext<LyricDriveActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.state.songTitle)
                .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            if context.isStale {
                Text("Open LyricDrive to refresh")
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
            } else {
                Text(context.state.currentLyric)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if !context.state.nextLyric.isEmpty && family != .small {
                    Text(context.state.nextLyric)
                        .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                if context.state.isPaused {
                    Text("Paused").font(.caption2)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(family == .small ? 8 : 12)
    }
}
