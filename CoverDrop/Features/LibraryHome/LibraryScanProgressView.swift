import SwiftUI

struct LibraryScanProgressView: View {
    let progress: LibraryScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.phase.displayName)
                    .font(.callout.weight(.medium))
            }

            Text(progress.targetPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(progress.targetPath)

            ScanProgressBar(
                fraction: progress.albumProgressFraction,
                isSlowIndeterminate: progress.phase == .discoveringAlbums
            )
            .frame(height: 6)

            Text(progress.completedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
