import AppKit
import SwiftUI
import PulseCore
import PulseMac

@MainActor
final class FolderModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var root: FolderNode?
    @Published private(set) var scanning = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var note: String?
    /// Identifiers of the folders opened below the root.
    @Published var path: [Int] = []
    @Published var selection: Int?
    private var task: Task<Void, Never>?
    private var generation = 0

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to measure"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    func scan(_ url: URL) {
        task?.cancel()
        generation += 1
        let run = generation
        rootURL = url
        root = nil
        path = []
        selection = nil
        note = nil
        progress = nil
        scanning = true
        task = Task.detached(priority: .utility) { [weak self] in
            let result = Result {
                try FolderScan.scan(url) { update in
                    guard let model = self else { return }
                    Task { @MainActor in
                        if model.generation == run { model.progress = update }
                    }
                }
            }
            await self?.finish(result, run: run)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Result<FolderNode, Error>, run: Int) {
        guard run == generation else { return }
        scanning = false
        switch result {
        case .success(let node):
            root = node
            if node.kind == .unreadable {
                note = "This folder could not be read. Check its permissions or the privacy settings for Makarov Pulse."
            }
        case .failure(let error):
            note = error is CancellationError ? "Scan cancelled." : "The folder could not be scanned."
        }
    }

    /// Nodes from the root to the folder currently shown.
    var trail: [FolderNode] { root?.trail(path) ?? [] }

    func url(of child: FolderNode?) -> URL? {
        guard var url = rootURL else { return nil }
        for node in trail.dropFirst() { url.appendPathComponent(node.name) }
        if let child, child.kind != .smallerFiles { url.appendPathComponent(child.name) }
        return url
    }

    func open(_ child: FolderNode) {
        guard child.isContainer else { return }
        path = trail.dropFirst().map(\.id) + [child.id]
        selection = nil
    }

    func show(depth: Int) {
        path = Array(trail.dropFirst().prefix(depth).map(\.id))
        selection = nil
    }
}

struct FolderPane: View {
    @ObservedObject var model: FolderModel
    @State private var byAllocation = true
    @State private var order = [KeyPathComparator(\FolderNode.allocatedBytes, order: .reverse)]

    private var current: FolderNode? { model.trail.last }

    private var children: [FolderNode] {
        (current?.children ?? []).sorted(using: order + [KeyPathComparator(\FolderNode.name)])
    }

    private var selected: FolderNode? {
        current?.children.first { $0.id == model.selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar
            if let current, model.root != nil {
                breadcrumb(current)
                HSplitView {
                    TreemapView(nodes: current.children, byAllocation: byAllocation,
                                selection: $model.selection, open: { model.open($0) })
                        .frame(minWidth: 300, minHeight: 200)
                    table.frame(minWidth: 380)
                }
            } else {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var bar: some View {
        HStack {
            Button("Choose Folder…") { model.choose() }
            if model.scanning {
                Button("Cancel") { model.cancel() }
                ProgressView().controlSize(.small)
            } else if let url = model.rootURL {
                Button("Scan Again") { model.scan(url) }
            }
            Spacer()
            if model.root != nil {
                Picker("Size by", selection: $byAllocation) {
                    Text("On disk").tag(true)
                    Text("File length").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                .help("On disk counts allocated blocks. File length counts logical bytes.")
                Button("Open") { if let selected { model.open(selected) } }
                    .disabled(selected?.isContainer != true)
                Button("Reveal in Finder") {
                    if let url = model.url(of: selected) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.scanning {
            VStack(spacing: 6) {
                Text("Scanning \(model.rootURL?.lastPathComponent ?? "folder")…").font(.headline)
                if let progress = model.progress {
                    Text("\(progress.items) items · \(Display.bytes(progress.allocatedBytes)) on disk").monospacedDigit()
                    Text(progress.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } else {
            VStack(spacing: 6) {
                Text(model.note ?? "Choose a folder to see where its space went.")
                Text("Files are measured from metadata. Nothing is opened, downloaded or changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func breadcrumb(_ current: FolderNode) -> some View {
        HStack(spacing: 4) {
            Button { model.show(depth: model.path.count - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(model.path.isEmpty).help("Enclosing folder").accessibilityLabel("Enclosing folder")
            ForEach(Array(model.trail.enumerated()), id: \.element.id) { depth, node in
                if depth > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                Button(node.name) { model.show(depth: depth) }.buttonStyle(.link).lineLimit(1)
            }
            Spacer()
            Text("\(Display.bytes(current.allocatedBytes)) on disk · \(Display.bytes(current.logicalBytes)) file length · \(current.items) items")
                .font(.callout).monospacedDigit()
            if current.isPartial {
                Label("Partial: \(current.unreadable) unreadable", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .help("Some locations could not be read. The totals leave them out.")
            }
        }
    }

    private var table: some View {
        Table(children, selection: $model.selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { node in
                Label(node.name, systemImage: FolderPane.symbol(node)).lineLimit(1).help(node.name)
            }
            .width(min: 150, ideal: 240)
            TableColumn("On disk", value: \.allocatedBytes) { Text(Display.bytes($0.allocatedBytes)) }
            TableColumn("File length", value: \.logicalBytes) { Text(Display.bytes($0.logicalBytes)) }
            TableColumn("Items", value: \.items) { Text(String($0.items)) }
            TableColumn("Note") { (node: FolderNode) in Text(FolderPane.remark(node)).foregroundStyle(.secondary) }
        }
    }

    static func symbol(_ node: FolderNode) -> String {
        switch node.kind {
        case .folder: return "folder"
        case .file: return "doc"
        case .symlink: return "arrow.up.right"
        case .smallerFiles: return "doc.on.doc"
        case .otherVolume: return "externaldrive"
        case .cloudOnly: return "icloud"
        case .unreadable: return "lock"
        }
    }

    static func remark(_ node: FolderNode) -> String {
        switch node.kind {
        case .symlink: return "Link, not followed"
        case .otherVolume: return "Other volume, not entered"
        case .cloudOnly: return "In the cloud, not entered"
        case .unreadable: return "No permission"
        default:
            if node.linkedElsewhere { return "Hard link, counted elsewhere" }
            return node.isPartial ? "Partial: \(node.unreadable) unreadable" : ""
        }
    }
}

/// Area is proportional to size. Click selects an entry. Double-click opens a folder.
private struct TreemapView: View {
    let nodes: [FolderNode]
    let byAllocation: Bool
    @Binding var selection: Int?
    let open: (FolderNode) -> Void

    private func weight(_ node: FolderNode) -> Double {
        Double(byAllocation ? node.allocatedBytes : node.logicalBytes)
    }

    private func frames(_ size: CGSize) -> [CGRect] {
        Treemap.layout(nodes.map(weight), width: Double(size.width), height: Double(size.height))
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func node(at point: CGPoint, in size: CGSize) -> FolderNode? {
        zip(nodes, frames(size)).first { $0.1.contains(point) }?.0
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for (index, frame) in frames(size).enumerated() where frame.width > 0.5 && frame.height > 0.5 {
                    let node = nodes[index]
                    let tile = Path(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3)
                    let hue = Double((node.id &* 37) % 100) / 100
                    let fill = node.kind == .folder ? Color(hue: hue, saturation: 0.45, brightness: 0.75)
                        : Color.gray.opacity(0.45)
                    context.fill(tile, with: .color(fill))
                    if node.id == selection {
                        context.stroke(tile, with: .color(.primary), lineWidth: 2)
                    }
                    if frame.width > 54, frame.height > 20 {
                        context.draw(Text(node.name).font(.caption).foregroundColor(.white),
                                     in: frame.insetBy(dx: 5, dy: 3))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                if let hit = node(at: tap.location, in: geometry.size) { open(hit) }
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                selection = node(at: tap.location, in: geometry.size)?.id
            })
        }
        .accessibilityLabel("Treemap of folder sizes. The table lists the same entries.")
    }
}
