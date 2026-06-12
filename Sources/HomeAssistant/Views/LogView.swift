import SwiftUI
import AppKit

/// A live, scrolling view of the captured server / installation output.
struct LogView: View {
    @EnvironmentObject var log: LogStore
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: log.lines.count) { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
            }
            Divider()
            HStack {
                statusBadge
                Spacer()
                Button("Dashboard öffnen") { NSWorkspace.shared.open(settings.dashboardURL) }
                    .disabled(server.status != .running)
                Button("Protokolldatei zeigen") { NSWorkspace.shared.activateFileViewerSelecting([log.logFileURL]) }
                Button("Leeren") { log.clear() }
            }
            .padding(8)
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .installing, .starting, .stopping: return .yellow
        case .crashed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusText: String {
        switch server.status {
        case .running: return "Läuft auf Port \(settings.port)"
        case .installing(let message): return message
        case .starting: return "Startet…"
        case .stopping: return "Stoppt…"
        case .stopped: return "Gestoppt"
        case .crashed(let r): return "Abgestürzt: \(r)"
        }
    }
}
