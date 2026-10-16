import HarborCore
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var session: ImportSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch session.phase {
            case .inspecting:
                progress("Checking \(session.url.lastPathComponent)…")
            case .ready(let report):
                ready(report)
            case .converting:
                progress(session.log.last ?? "Converting…")
            case .finished(let result):
                finished(result)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(session.isBusy)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func ready(_ report: InspectionReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Convert \(report.name)").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Version").foregroundStyle(.secondary); Text(report.version) }
                GridRow { Text("Bundle ID").foregroundStyle(.secondary); Text(report.bundleID).textSelection(.enabled) }
                GridRow {
                    Text("Made for").foregroundStyle(.secondary)
                    Text(report.deviceFamilies.map { $0 == 1 ? "iPhone" : $0 == 2 ? "iPad" : "Other" }.joined(separator: " and "))
                }
                GridRow { Text("Requires").foregroundStyle(.secondary); Text("iOS \(report.minimumOS)") }
            }
            if !report.missingLibraries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Some frameworks don't exist on macOS; features using them won't work:", systemImage: "exclamationmark.triangle")
                    ForEach(report.missingLibraries, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Form {
                TextField("Name", text: $session.name)
                Picker("Present as", selection: $session.deviceID) {
                    Text("Automatic").tag("automatic")
                    ForEach(DeviceProfile.all) { Text($0.name).tag($0.id) }
                }
                TextField("Bundle ID", text: $session.bundleID, prompt: Text(report.bundleID))
                    .help("Change it only if the official version of this app is also installed on this Mac.")
            }
            HStack {
                Text("Installs into /Applications").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Convert") { session.convert() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finished(_ result: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppIcon(app: result.app, size: 56)
                VStack(alignment: .leading) {
                    Text("\(result.app.name) is ready").font(.title2.weight(.semibold))
                    Text("Find it in Launchpad, Spotlight or /Applications.").foregroundStyle(.secondary)
                }
            }
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open \(result.app.name)") {
                    model.open(result.app)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Can't convert \(session.url.lastPathComponent)", systemImage: "xmark.octagon")
                .font(.title2.weight(.semibold))
            Text(message).textSelection(.enabled).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
