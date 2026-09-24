import AppKit
import SwiftUI
import StudioCore

@MainActor
protocol OutputFolderChoosing {
    func chooseDirectory() async -> URL?
}

@MainActor
struct OutputFolderPicker: OutputFolderChoosing {
    var makePanel: () -> NSOpenPanel = { NSOpenPanel() }
    static func configure(_ panel: NSOpenPanel) {
        panel.title = "选择音频输出文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
    }
    func chooseDirectory() async -> URL? {
        let panel = makePanel()
        Self.configure(panel)
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

@MainActor @Observable
final class OutputFolderController {
    private(set) var defaultID: String?
    private(set) var defaultName = "尚未选择"
    private(set) var errorMessage: String?
    private(set) var isChoosing = false
    let directories: OutputDirectoryStore?
    private let picker: any OutputFolderChoosing
    init(directories: OutputDirectoryStore?, picker: any OutputFolderChoosing = OutputFolderPicker()) {
        self.directories = directories; self.picker = picker
    }
    static func live() -> OutputFolderController {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("QwenAudioStudioNative", isDirectory: true)
            return OutputFolderController(directories: OutputDirectoryStore(store: try StudioStore(dataRoot: root)))
        } catch {
            let controller = OutputFolderController(directories: nil)
            controller.errorMessage = "本地作品库暂不可用。请关闭其他应用实例后重试。"
            return controller
        }
    }
    func loadDefault() async {
        guard let directories else { return }
        do {
            defaultID = try await directories.defaultDirectoryID()
            if let defaultID { defaultName = try await name(for: defaultID) }
        } catch { defaultName = "需重新授权或连接磁盘"; errorMessage = Self.message(error) }
    }
    func name(for id: String) async throws -> String {
        guard let directories else { throw OutputDirectoryError.unavailable }
        let lease = try await directories.resolve(id); defer { lease.close() }
        return lease.rootURL.lastPathComponent
    }
    func choose(currentID: String?) async -> String? {
        guard let directories, !isChoosing else { return currentID }
        isChoosing = true; defer { isChoosing = false }
        guard let selected = await picker.chooseDirectory() else { return currentID }
        do {
            let id = try await directories.register(selectedURL: selected)
            errorMessage = nil
            return id
        } catch { errorMessage = Self.message(error); return currentID }
    }
    func chooseDefault() async {
        let previous = defaultID
        guard let id = await choose(currentID: previous), id != previous, let directories else { return }
        do {
            try await directories.setDefault(id)
            defaultID = id; defaultName = try await name(for: id)
        } catch { errorMessage = Self.message(error) }
    }
    func reauthorize(_ id: String) async -> Bool {
        guard let directories, !isChoosing else { return false }
        isChoosing = true; defer { isChoosing = false }
        guard let selected = await picker.chooseDirectory() else { return false }
        do {
            try await directories.reauthorize(directoryID: id, selectedURL: selected)
            if defaultID == id { defaultName = try await name(for: id) }
            errorMessage = nil
            return true
        } catch { errorMessage = Self.message(error); return false }
    }
    func revealDirectory(_ id: String) async {
        guard let directories else { return }
        do {
            let lease = try await directories.resolve(id); defer { lease.close() }
            NSWorkspace.shared.activateFileViewerSelecting([lease.rootURL])
        } catch { errorMessage = Self.message(error) }
    }
    func revealAsset(_ id: String, assets: GeneratedAssetStore) async {
        do {
            let (lease, url) = try await assets.resolveRegisteredAsset(id); defer { lease.close() }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { errorMessage = Self.message(error) }
    }
    private static func message(_ error: Error) -> String {
        if error as? OutputDirectoryError == .reauthorizationRequired { return "文件夹授权已失效，请使用“重新授权”选择原输出文件夹。" }
        if error as? OutputDirectoryError == .directoryMismatch { return "无法确认所选文件夹为原输出目录，原授权记录保持不变。" }
        return "无法访问输出文件夹。请检查磁盘连接与写入权限，或重新选择。"
    }
}
