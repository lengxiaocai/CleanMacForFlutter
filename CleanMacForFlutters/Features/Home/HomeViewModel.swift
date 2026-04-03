//
//  HomeViewModel.swift
//  CleanMacForFlutters
//
//  主界面的 ViewModel，管理 Flutter 项目列表、清理操作、目录监控等核心逻辑。
//  使用 @Observable 宏实现响应式数据绑定。
//

import Foundation
import AppKit
import SwiftUI

// MARK: - 持久化存储键

/// UserDefaults 中使用的存储键常量
enum PersistenceKey {
    /// 已选择的 Flutter 项目文件夹书签数据
    static let bookmarks = "selectedFoldersBookmarks"
    /// 被监控目录的书签数据
    static let watchedBookmarks = "watchedDirectoriesBookmarks"
    /// 文件监控开关状态
    static let watchEnabled = "fileWatchEnabled"
}

// MARK: - HomeViewModel

@Observable
class HomeViewModel {

    // MARK: - Flutter 项目状态

    /// 已添加的 Flutter 项目列表
    var selectedFolders: [DocModel] = []
    /// 是否正在执行清理命令
    var isRunningCommands = false
    /// 当前正在处理的文件夹名称（用于进度显示）
    var currentProcessingFolder: String = ""
    /// 错误提示信息
    var errorMessage: String?
    /// 成功提示信息
    var successMessage: String?
    /// 是否已加载持久化的文件夹（防止重复加载）
    var hasLoadedPersistedFolders = false
    /// 是否正在扫描目录
    var isScanning = false
    /// 扫描过程中已发现的项目数量
    var scanFoundCount = 0

    // MARK: - 文件监控状态

    /// 被监控的目录列表
    var watchedDirectories: [WatchedDirectory] = []

    /// 是否启用文件监控（持久化到 UserDefaults）
    var isWatchEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isWatchEnabled, forKey: PersistenceKey.watchEnabled)
            if isWatchEnabled {
                startWatching()
            } else {
                stopWatching()
            }
        }
    }

    /// FSEvents 文件监控器实例
    private var directoryWatcher: DirectoryWatcher?

    // MARK: - 手动选择文件夹

    /// 打开文件选择面板，让用户手动选择 Flutter 项目文件夹
    func requestFolderPermission() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = NSLocalizedString("scan.select.confirm", comment: "")
        panel.message = NSLocalizedString("home.select_folders_message", comment: "")

        if panel.runModal() == .OK {
            addFolders(panel.urls)
        }
    }

    // MARK: - 扫描目录

    /// 打开文件选择面板，选择一个父目录后递归扫描其中所有 Flutter 项目
    /// 通过检测 pubspec.yaml 文件来识别 Flutter 项目
    func scanForFlutterProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("scan.select.confirm", comment: "")
        panel.message = NSLocalizedString("scan.select.message", comment: "")

        guard panel.runModal() == .OK, let rootURL = panel.url else { return }

        isScanning = true
        scanFoundCount = 0

        // 在后台线程执行扫描，避免阻塞 UI
        Task.detached {
            let found = Self.findFlutterProjects(in: rootURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanFoundCount = found.count
                self.addFolders(found)
                self.isScanning = false
                if found.isEmpty {
                    self.successMessage = NSLocalizedString("scan.nothing.found", comment: "")
                } else {
                    self.successMessage = String(
                        format: NSLocalizedString("scan.completed", comment: ""),
                        found.count
                    )
                }
            }
        }
    }

    /// 递归查找指定目录下包含 pubspec.yaml 的目录（即 Flutter 项目）
    /// - Parameter rootURL: 要搜索的根目录
    /// - Returns: 找到的所有 Flutter 项目目录 URL 列表
    /// - Note: 找到 Flutter 项目后不再深入其子目录，避免添加嵌套的子包
    private nonisolated static func findFlutterProjects(in rootURL: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return results }

        // 已找到的 Flutter 项目路径，用于跳过其子目录
        var flutterProjectPaths: [String] = []

        while let itemURL = enumerator.nextObject() as? URL {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            let currentPath = itemURL.path

            // 跳过已找到的 Flutter 项目的子目录
            if flutterProjectPaths.contains(where: { currentPath.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }

            // 跳过常见的大型无关目录以提高扫描速度
            let dirName = itemURL.lastPathComponent
            if ["node_modules", ".git", "build", ".dart_tool", "Pods", ".symlinks"].contains(dirName) {
                enumerator.skipDescendants()
                continue
            }

            // 检查目录中是否包含 pubspec.yaml（Flutter 项目标识）
            let pubspec = itemURL.appendingPathComponent("pubspec.yaml")
            if fm.fileExists(atPath: pubspec.path) {
                results.append(itemURL)
                flutterProjectPaths.append(currentPath)
                enumerator.skipDescendants()
            }
        }

        return results
    }

    // MARK: - 文件夹管理

    /// 将一组 URL 添加到项目列表中（自动去重并按名称排序）
    /// - Parameter urls: 要添加的文件夹 URL 列表
    func addFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var merged = selectedFolders

        for url in urls {
            let pathString = url.path
            // 检查是否已存在，避免重复添加
            if !merged.contains(where: { $0.path == pathString }) {
                let docModel = DocModel(path: pathString, activated: true)
                merged.append(docModel)
            }
        }

        // 按文件夹名称字母排序
        selectedFolders = merged.sorted {
            URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() <
            URL(fileURLWithPath: $1.path).lastPathComponent.lowercased()
        }
        persistFolders()
    }

    /// 通过索引集删除文件夹（用于 List 的 onDelete）
    func deleteFolders(at offsets: IndexSet) {
        selectedFolders.remove(atOffsets: offsets)
        persistFolders()
    }

    /// 删除指定的文件夹
    func removeFolder(_ folder: DocModel) {
        selectedFolders.removeAll { $0.id == folder.id }
        persistFolders()
    }

    /// 切换文件夹的激活/停用状态
    func toggleFolderActivation(_ folder: DocModel) {
        if let index = selectedFolders.firstIndex(where: { $0.id == folder.id }) {
            selectedFolders[index].activated.toggle()
            persistFolders()
        }
    }

    /// 全选或取消全选所有文件夹
    func toggleAllFolders() {
        let allActive = selectedFolders.allSatisfy(\.activated)
        for index in selectedFolders.indices {
            selectedFolders[index].activated = !allActive
        }
        persistFolders()
    }

    // MARK: - 持久化（Flutter 项目书签）

    /// 从 UserDefaults 加载之前保存的文件夹书签（仅在首次调用时执行）
    func loadPersistedFoldersIfNeeded() {
        guard !hasLoadedPersistedFolders else { return }
        hasLoadedPersistedFolders = true

        guard let stored = UserDefaults.standard.array(forKey: PersistenceKey.bookmarks) as? [Data] else { return }

        var resolved: [DocModel] = []
        for data in stored {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                // 激活安全作用域访问权限
                _ = url.startAccessingSecurityScopedResource()
                resolved.append(DocModel(path: url.path, activated: true))
            }
        }

        selectedFolders = resolved.sorted {
            URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() <
            URL(fileURLWithPath: $1.path).lastPathComponent.lowercased()
        }
    }

    /// 将当前文件夹列表序列化为安全作用域书签并保存到 UserDefaults
    private func persistFolders() {
        let bookmarks: [Data] = selectedFolders.compactMap { docModel in
            let url = URL(fileURLWithPath: docModel.path)
            return try? url.bookmarkData(options: [.withSecurityScope],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: PersistenceKey.bookmarks)
    }

    // MARK: - 监控目录管理

    /// 打开文件选择面板添加一个要监控的目录
    func addWatchedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("watch.select.confirm", comment: "")
        panel.message = NSLocalizedString("watch.select.message", comment: "")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 检查是否已存在
        let pathString = url.path
        guard !watchedDirectories.contains(where: { $0.path == pathString }) else { return }

        watchedDirectories.append(WatchedDirectory(path: pathString))
        persistWatchedDirectories()

        // 添加后立即扫描一次该目录
        scanWatchedDirectoryOnce(url)

        // 如果监控已开启，重新启动以包含新目录
        if isWatchEnabled {
            startWatching()
        }
    }

    /// 移除一个监控目录
    func removeWatchedDirectory(_ dir: WatchedDirectory) {
        watchedDirectories.removeAll { $0.id == dir.id }
        persistWatchedDirectories()

        // 重新启动监控（更新监控列表）
        if isWatchEnabled {
            startWatching()
        }
    }

    /// 从 UserDefaults 加载监控目录书签和开关状态
    func loadWatchedDirectories() {
        isWatchEnabled = UserDefaults.standard.bool(forKey: PersistenceKey.watchEnabled)

        guard let stored = UserDefaults.standard.array(forKey: PersistenceKey.watchedBookmarks) as? [Data] else { return }

        var resolved: [WatchedDirectory] = []
        for data in stored {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                resolved.append(WatchedDirectory(path: url.path))
            }
        }
        watchedDirectories = resolved

        // 如果开关已开启且有监控目录，自动启动监控
        if isWatchEnabled && !watchedDirectories.isEmpty {
            startWatching()
        }
    }

    /// 保存监控目录书签到 UserDefaults
    private func persistWatchedDirectories() {
        let bookmarks: [Data] = watchedDirectories.compactMap { dir in
            let url = URL(fileURLWithPath: dir.path)
            return try? url.bookmarkData(options: [.withSecurityScope],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: PersistenceKey.watchedBookmarks)
    }

    /// 启动 FSEvents 文件系统监控
    private func startWatching() {
        stopWatching()
        let paths = watchedDirectories.map { $0.path }
        guard !paths.isEmpty else { return }

        let watcher = DirectoryWatcher { [weak self] in
            self?.onFileSystemChange()
        }
        watcher.start(watching: paths)
        directoryWatcher = watcher
    }

    /// 停止文件系统监控
    private func stopWatching() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }

    /// FSEvents 文件变动回调处理
    /// 重新扫描所有监控目录，将新发现的 Flutter 项目自动添加到列表中
    private func onFileSystemChange() {
        let dirs = watchedDirectories
        Task.detached {
            var allFound: [URL] = []
            for dir in dirs {
                let url = URL(fileURLWithPath: dir.path)
                let projects = Self.findFlutterProjects(in: url)
                allFound.append(contentsOf: projects)
            }
            let found = allFound
            await MainActor.run { [weak self] in
                guard let self else { return }
                let beforeCount = self.selectedFolders.count
                self.addFolders(found)
                let newCount = self.selectedFolders.count - beforeCount
                if newCount > 0 {
                    self.successMessage = String(
                        format: NSLocalizedString("watch.new_projects_found", comment: ""),
                        newCount
                    )
                }
            }
        }
    }

    /// 立即扫描单个目录并将找到的项目添加到列表
    private func scanWatchedDirectoryOnce(_ url: URL) {
        Task.detached { [weak self] in
            let found = Self.findFlutterProjects(in: url)
            await MainActor.run {
                self?.addFolders(found)
            }
        }
    }

    // MARK: - Xcode 构建缓存清理

    /// Xcode 目录的安全作用域书签（持久化到 UserDefaults）
    var xcodeDirectoryBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "xcodeDirectoryBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "xcodeDirectoryBookmark") }
    }

    /// 是否显示清理确认弹窗
    var showBuildIndexConfirmation = false
    /// 待清理的 Xcode 缓存大小描述文本
    var buildIndexSizeDescription: String = ""
    /// 已解析的 Xcode 目录 URL（用于确认后执行清理）
    private var resolvedXcodeURL: URL?

    /// 从保存的书签数据中解析出带安全作用域的 URL
    private func resolveXcodeBookmark() -> URL? {
        guard let data = xcodeDirectoryBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        // 如果书签已过期，重新保存
        if isStale {
            if let newData = try? url.bookmarkData(options: [.withSecurityScope],
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
                xcodeDirectoryBookmark = newData
            }
        }
        return url
    }

    /// 打开文件选择面板让用户选择 Xcode 目录并保存书签
    func selectXcodeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xcodeDevDir = home.appendingPathComponent("Library/Developer/Xcode")

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = xcodeDevDir
        panel.prompt = NSLocalizedString("build.index.select.confirm", comment: "")
        panel.message = NSLocalizedString("build.index.select.message", comment: "")

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        if let data = try? selectedURL.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
            xcodeDirectoryBookmark = data
        }
    }

    /// Xcode 清理按钮点击处理：
    /// 如果已有保存的目录则计算大小并显示确认弹窗，否则先让用户选择目录
    func cleanBuildAndIndexCommand() {
        guard let url = resolveXcodeBookmark() else {
            selectXcodeDirectory()
            return
        }

        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        // 计算 DerivedData 和 Index 的总大小
        var totalSize: Int64 = 0
        for targetName in ["DerivedData", "Index"] {
            let target = url.appendingPathComponent(targetName)
            if FileManager.default.fileExists(atPath: target.path),
               let size = try? FileManager.default.allocatedSizeOfDirectory(at: target) {
                totalSize += size
            }
        }

        buildIndexSizeDescription = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        resolvedXcodeURL = url
        showBuildIndexConfirmation = true
    }

    /// 用户确认后执行 Xcode 缓存清理（删除 DerivedData 和 Index 目录内容）
    func confirmCleanBuildAndIndex() {
        guard let selectedURL = resolvedXcodeURL else { return }

        let hasAccess = selectedURL.startAccessingSecurityScopedResource()

        Task {
            await MainActor.run {
                self.isRunningCommands = true
                self.errorMessage = nil
                self.successMessage = nil
                self.currentProcessingFolder = NSLocalizedString("build.index.processing", comment: "")
            }

            var deletedCount = 0
            var failedCount = 0
            var totalSize: Int64 = 0

            for targetName in ["DerivedData", "Index"] {
                let target = selectedURL.appendingPathComponent(targetName)

                guard FileManager.default.fileExists(atPath: target.path) else { continue }

                if let size = try? FileManager.default.allocatedSizeOfDirectory(at: target) {
                    totalSize += size
                }

                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                    for item in contents {
                        try FileManager.default.removeItem(at: item)
                        deletedCount += 1
                    }
                } catch {
                    failedCount += 1
                }
            }

            if hasAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }

            await MainActor.run {
                self.isRunningCommands = false
                self.currentProcessingFolder = ""

                if deletedCount > 0 {
                    let sizeString = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                    let title = NSLocalizedString("build.index.completed.title", comment: "")
                    let space = String(format: NSLocalizedString("clean.completed.space", comment: ""), sizeString)
                    var message = "\(title)\n\n\(space)"
                    if failedCount > 0 {
                        let warnings = String(format: NSLocalizedString("clean.completed.warnings", comment: ""), failedCount)
                        message += "\n\(warnings)"
                    }
                    self.successMessage = message
                } else if failedCount > 0 {
                    self.errorMessage = String(format: NSLocalizedString("clean.none.deleted.errors", comment: ""), failedCount)
                } else {
                    self.successMessage = NSLocalizedString("build.index.nothing.found", comment: "")
                }
            }
        }
    }

    // MARK: - Flutter 项目清理

    /// 执行 Flutter 项目清理：删除所有已激活项目中的构建缓存和依赖文件
    /// 包括 build/、.dart_tool/、pubspec.lock、ios/Pods 等
    func cleanCommand() {
        let activatedFolders = selectedFolders.filter(\.activated)

        guard !activatedFolders.isEmpty else {
            errorMessage = NSLocalizedString("clean.no.activated", comment: "")
            return
        }

        Task {
            await MainActor.run {
                self.isRunningCommands = true
                self.errorMessage = nil
                self.successMessage = nil
            }

            var deletedCount = 0
            var failedCount = 0
            var totalSize: Int64 = 0

            // 每个 Flutter 项目中需要删除的目标文件/文件夹
            let targets = [
                "build",            // Flutter 构建输出
                ".dart_tool",       // Dart 工具缓存
                "pubspec.lock",     // 依赖锁定文件
                "ios/Pods",         // CocoaPods 依赖
                "ios/Podfile.lock", // CocoaPods 锁定文件
                "ios/Gemfile.lock"  // Ruby Gem 锁定文件
            ]

            for folder in activatedFolders {
                let folderURL = URL(fileURLWithPath: folder.path)

                await MainActor.run {
                    self.currentProcessingFolder = folderURL.lastPathComponent
                }

                for target in targets {
                    let targetPath = folderURL.appendingPathComponent(target)

                    if FileManager.default.fileExists(atPath: targetPath.path) {
                        do {
                            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: targetPath) {
                                totalSize += size
                            }
                            try FileManager.default.removeItem(at: targetPath)
                            deletedCount += 1
                        } catch {
                            failedCount += 1
                        }
                    }
                }
            }

            await MainActor.run {
                self.isRunningCommands = false
                self.currentProcessingFolder = ""

                if deletedCount > 0 {
                    let sizeString = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                    let title = NSLocalizedString("clean.completed.title", comment: "")
                    let summary = String(format: NSLocalizedString("clean.completed.summary", comment: ""), deletedCount)
                    let space = String(format: NSLocalizedString("clean.completed.space", comment: ""), sizeString)
                    var message = "\(title)\n\n\(summary)\n\n\(space)"
                    if failedCount > 0 {
                        let warnings = String(format: NSLocalizedString("clean.completed.warnings", comment: ""), failedCount)
                        message += "\n\(warnings)"
                    }
                    self.successMessage = message
                } else if failedCount > 0 {
                    self.errorMessage = String(format: NSLocalizedString("clean.none.deleted.errors", comment: ""), failedCount)
                } else {
                    self.successMessage = NSLocalizedString("clean.nothing.found", comment: "")
                }
            }
        }
    }
}

// MARK: - FileManager 扩展

extension FileManager {
    /// 递归计算指定目录的磁盘占用大小（字节）
    /// - Parameter url: 目录路径
    /// - Returns: 目录总大小（字节）
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = self.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }

        var totalSize: Int64 = 0

        while let item = enumerator.nextObject() as? URL {
            let resourceValues = try item.resourceValues(forKeys: keys)

            // 只统计普通文件的大小
            if let isRegular = resourceValues.isRegularFile, isRegular {
                if let total = resourceValues.totalFileAllocatedSize {
                    totalSize += Int64(total)
                } else if let file = resourceValues.fileAllocatedSize {
                    totalSize += Int64(file)
                }
            }
        }

        return totalSize
    }
}
