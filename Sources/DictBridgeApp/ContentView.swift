import DictBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private var mdxTypes: [UTType] {
        [UTType(filenameExtension: "mdx"), UTType(filenameExtension: "mdd"), .folder].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let job = model.job {
                JobView(job: job)
                    .padding(16)
                Divider()
            }
            if model.installed.isEmpty {
                DropZone()
                    .padding(24)
            } else {
                libraryList
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 460)
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handle(urls: urls)
            return true
        } isTargeted: { model.dropTargeted = $0 }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: mdxTypes) { result in
            if case .success(let url) = result { model.handle(urls: [url]) }
        }
        .sheet(item: $model.pendingImport) { pending in
            ImportSheet(request: pending)
        }
        .sheet(isPresented: $model.showDDKSetup) {
            DDKSetupView()
        }
        .alert(L.errorTitle, isPresented: Binding(get: { model.errorMessage != nil },
                                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button(L.close, role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(L.removeQuestion,
                            isPresented: Binding(get: { model.removeCandidate != nil },
                                                 set: { if !$0 { model.removeCandidate = nil } }),
                            presenting: model.removeCandidate) { d in
            Button(L.remove + " “\(d.name)”", role: .destructive) { model.remove(d) }
            Button(L.cancel, role: .cancel) {}
        } message: { _ in
            Text(L.removeDetail)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("DictBridge").font(.title2.weight(.semibold))
                Text(L.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showImporter = true
            } label: {
                Label(L.addDictionary, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.job?.isRunning == true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var libraryList: some View {
        List {
            Section(L.installedHeader) {
                ForEach(model.installed) { d in
                    DictionaryRow(dictionary: d, size: model.sizes[d.id])
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.revealLibraryFolder()
            } label: {
                Label(L.dictionariesFolder, systemImage: "folder")
            }
            .buttonStyle(.link)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label(L.refresh, systemImage: "arrow.clockwise")
            }
            Button {
                model.openDictionaryApp()
            } label: {
                Label(L.openDictionaryApp, systemImage: "book")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct DictionaryRow: View {
    @EnvironmentObject var model: AppModel
    let dictionary: InstalledDictionary
    let size: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: dictionary.isDictBridge ? "book.closed.fill" : "book.closed")
                .font(.title2)
                .foregroundStyle(dictionary.isDictBridge ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(dictionary.name).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                model.reveal(dictionary)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(L.showInFinder)
            Button(role: .destructive) {
                model.confirmRemove(dictionary)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L.remove)
            .disabled(model.job?.isRunning == true)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(L.showInFinder) { model.reveal(dictionary) }
            Button(L.remove, role: .destructive) { model.confirmRemove(dictionary) }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let source = dictionary.source { parts.append(source) }
        if let created = dictionary.created { parts.append(created.formatted(date: .abbreviated, time: .omitted)) }
        if !dictionary.isDictBridge { parts.append(L.otherDictionary) }
        parts.append(dictionary.url.lastPathComponent)
        return parts.joined(separator: " · ")
    }
}

struct DropZone: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text(L.dropTitle).font(.title3.weight(.medium))
            Text(L.dropHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(L.chooseFile) { model.showImporter = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
    }
}
