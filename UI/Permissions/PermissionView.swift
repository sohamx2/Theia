import SwiftUI

struct PermissionView: View {
    let openSettings: () -> Void
    let restartInstalledApp: () -> Void
    let revealInstalledApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Recording access is off", systemImage: "lock.shield")
                .font(.headline)

            Text(
                "Theia needs Screen Recording access to capture the display. " +
                "No screenshot was taken and OCR was not started."
            )
            .foregroundStyle(.secondary)

            Text(
                "Enable the installed Theia.app in Privacy & Security -> Screen Recording, then quit and reopen Theia. For the permission to stay attached, keep using that same app copy, preferably from /Applications."
            )
            .font(.callout)

            HStack(spacing: 8) {
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)

                Button("Restart /Applications/Theia.app", action: restartInstalledApp)
                    .buttonStyle(.bordered)

                Button("Show in Finder", action: revealInstalledApp)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
