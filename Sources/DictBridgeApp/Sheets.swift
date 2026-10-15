import AppKit
import DictBridgeCore
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var request: PendingImport
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.importTitle).font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L.nameLabel).font(.headline)
                TextField("", text: $request.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L.filesLabel).font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    fileLine(request.source.mdx, symbol: "doc.text")
                    ForEach(request.source.mdds, id: \.self) { fileLine($0, symbol: "shippingbox") }
                    ForEach(request.source.stylesheets, id: \.self) { fileLine($0, symbol: "paintbrush") }
                    ForEach(request.source.scripts, id: \.self) { fileLine($0, symbol: "curlybraces") }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            // Audio comes from the .mdd files; without them there is nothing to choose.
            if !request.source.mdds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L.includeAudio, isOn: $request.includeAudio)
                    Text(L.includeAudioHint).font(.caption).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(L.advanced, isExpanded: $showAdvanced) {
                Toggle(L.chineseVariants, isOn: $request.chineseVariants)
                    .padding(.top, 6)
                Picker(L.headwordLabel, selection: $request.headwordMode) {
                    Text(L.headwordAuto).tag(HeadwordMode.auto)
                    Text(L.headwordAlways).tag(HeadwordMode.always)
                    Text(L.headwordNever).tag(HeadwordMode.never)
                }
                .pickerStyle(.menu)
                .padding(.top, 6)
            }

            if let old = request.replaces {
                Label(L.replaces(old.name), systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.convert) {
                    let r = request
                    dismiss()
                    model.startConversion(r)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func fileLine(_ url: URL, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(fileSize(url)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }

    private func fileSize(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

struct JobView: View {
    @EnvironmentObject var model: AppModel
    let job: ConversionJob
    @State private var showLog = false

    private let stages: [ConversionStage] = [.indexing, .resources, .converting, .compiling, .installing]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                statusIcon
                Text(title).font(.headline)
                Spacer()
                actions
            }

            switch job.status {
            case .running:
                ProgressView(value: job.fraction)
                HStack(spacing: 14) {
                    ForEach(stages, id: \.self) { stage in
                        stageLabel(stage)
                    }
                    Spacer()
                    if !job.detail.isEmpty {
                        Text(job.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            case .succeeded(let report):
                Text(L.summary(entries: report.entries, keys: report.searchKeys, seconds: report.seconds))
                    .font(.callout)
                Text(L.enableHint).font(.caption).foregroundStyle(.secondary)
                ForEach(report.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                EmptyView()
            }

            DisclosureGroup(L.log, isExpanded: $showLog) {
                ScrollView {
                    Text(job.log.suffix(400).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 140)
            }
            .font(.callout)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private var title: String {
        switch job.status {
        case .running: return L.converting(job.name)
        case .succeeded: return L.finished(job.name)
        case .failed: return L.failed(job.name)
        case .cancelled: return L.cancel + " — " + job.name
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.status {
        case .running:
            Button(L.cancel) { model.cancelConversion() }
        case .succeeded:
            Button(L.openDictionaryApp) { model.openDictionaryApp() }
            Button(L.done) { model.dismissJob() }.buttonStyle(.borderedProminent)
        case .failed, .cancelled:
            Button(L.copyLog) { model.copyLog() }
            Button(L.close) { model.dismissJob() }
        }
    }

    private func stageLabel(_ stage: ConversionStage) -> some View {
        let current = stages.firstIndex(of: job.stage) ?? 0
        let index = stages.firstIndex(of: stage) ?? 0
        let symbol = index < current ? "checkmark.circle.fill" : (index == current ? "circle.dotted" : "circle")
        return Label(L.stage(stage.rawValue), systemImage: symbol)
            .font(.caption)
            .foregroundStyle(index <= current ? Color.primary : Color.secondary)
    }
}

struct DDKSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L.ddkTitle, systemImage: "hammer").font(.title2.weight(.semibold))
            Text(L.ddkBody).fixedSize(horizontal: false, vertical: true)

            if model.ddkDownloading {
                ProgressView(value: model.ddkProgress)
            }

            HStack {
                Button(L.ddkDownload) { model.downloadDDK() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.ddkDownloading)
                Button(L.ddkChoose) { choosingFolder = true }
                    .disabled(model.ddkDownloading)
            }
            Text(L.ddkChooseHint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Link(L.applePage, destination: DDKToolkit.applePage).font(.caption)
                Text("·").foregroundStyle(.secondary)
                Link("nanoskript/dictionary-development-kit", destination: DDKToolkit.mirrorPage).font(.caption)
                Spacer()
                Button(L.cancel) { model.cancelDDKSetup() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.useDDKFolder(url) }
        }
    }
}
