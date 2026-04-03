//
//  HomeView.swift
//  CleanMacForFlutters
//
//  主界面视图，采用侧边栏 + 详情区域的布局（参考 CleanMyMac 风格）
//

import SwiftUI
import AppKit

// MARK: - 侧边栏导航项

/// 侧边栏可选择的功能页面
enum SidebarItem: String, CaseIterable, Identifiable {
    case flutterClean   // Flutter 项目清理
    case xcodeClean     // Xcode 构建缓存清理
    case autoDetect     // 自动检测 Flutter 项目

    var id: String { rawValue }

    /// 侧边栏显示的本地化标题
    var title: String {
        switch self {
        case .flutterClean: return NSLocalizedString("sidebar.flutter_clean", comment: "")
        case .xcodeClean:   return NSLocalizedString("sidebar.xcode_clean", comment: "")
        case .autoDetect:   return NSLocalizedString("sidebar.auto_detect", comment: "")
        }
    }

    /// 侧边栏图标名称
    var icon: String {
        switch self {
        case .flutterClean: return "leaf.fill"
        case .xcodeClean:   return "hammer.fill"
        case .autoDetect:   return "eye.fill"
        }
    }

    /// 侧边栏图标颜色
    var color: Color {
        switch self {
        case .flutterClean: return .cyan
        case .xcodeClean:   return .orange
        case .autoDetect:   return .green
        }
    }
}

// MARK: - 主入口视图

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var selectedItem: SidebarItem = .flutterClean

    // Full Disk Access 权限状态
    @State private var hasFullDiskAccess: Bool? = nil
    @State private var fdaCheckInProgress = false

    var body: some View {
        Group {
            if let hasFDA = hasFullDiskAccess {
                if hasFDA {
                    mainContent
                } else {
                    fullDiskAccessView
                }
            } else {
                // 正在检查权限
                permissionCheckingView
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            viewModel.loadPersistedFoldersIfNeeded()
            viewModel.loadWatchedDirectories()
            checkFullDiskAccess()
        }
        // 加载/扫描遮罩
        .overlay { processingOverlay }
        // 弹窗
        .alert(NSLocalizedString("alert.error", comment: ""),
               isPresented: .constant(viewModel.errorMessage != nil),
               presenting: viewModel.errorMessage) { _ in
            Button(NSLocalizedString("alert.ok", comment: "")) { viewModel.errorMessage = nil }
        } message: { Text($0) }
        .alert(NSLocalizedString("alert.success", comment: ""),
               isPresented: .constant(viewModel.successMessage != nil),
               presenting: viewModel.successMessage) { _ in
            Button(NSLocalizedString("alert.ok", comment: "")) { viewModel.successMessage = nil }
        } message: { Text($0) }
        .alert(NSLocalizedString("build.index.confirm.title", comment: ""),
               isPresented: $viewModel.showBuildIndexConfirmation) {
            Button(NSLocalizedString("build.index.confirm.cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("build.index.confirm.delete", comment: ""), role: .destructive) {
                viewModel.confirmCleanBuildAndIndex()
            }
        } message: {
            Text(String(format: NSLocalizedString("build.index.confirm.message", comment: ""),
                        viewModel.buildIndexSizeDescription))
        }
    }

    // MARK: - 主内容（侧边栏 + 详情区域）

    private var mainContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: $selectedItem) { item in
            Label {
                Text(item.title)
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: item.icon)
                    .foregroundStyle(item.color)
                    .font(.body)
            }
            .padding(.vertical, 4)
            .tag(item)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) {
            // 底部 GitHub 链接
            Button {
                if let url = URL(string: "https://github.com/andrelucassvt/CleanMacForFlutter") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("GitHub", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 详情区域路由

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .flutterClean: flutterCleanView
        case .xcodeClean:   xcodeCleanView
        case .autoDetect:   autoDetectView
        }
    }

    // MARK: - Flutter 清理页面

    private var flutterCleanView: some View {
        VStack(spacing: 0) {
            // 顶部统计信息
            flutterStatsHeader
                .padding(.horizontal, 28)
                .padding(.top, 20)

            Divider().padding(.horizontal, 28).padding(.vertical, 12)

            // 工具栏按钮
            flutterToolbar
                .padding(.horizontal, 28)

            // 项目列表
            if viewModel.selectedFolders.isEmpty {
                emptyStateView
            } else {
                flutterProjectList
            }

            Divider().padding(.horizontal, 28)

            // 底部清理按钮
            flutterCleanButton
                .padding(.vertical, 20)
        }
    }

    /// 顶部统计卡片：项目数 / 已激活数
    private var flutterStatsHeader: some View {
        HStack(spacing: 16) {
            StatCardView(
                icon: "folder.fill",
                color: .cyan,
                value: "\(viewModel.selectedFolders.count)",
                label: NSLocalizedString("stats.total_projects", comment: "")
            )
            StatCardView(
                icon: "checkmark.circle.fill",
                color: .green,
                value: "\(viewModel.selectedFolders.filter(\.activated).count)",
                label: NSLocalizedString("stats.activated", comment: "")
            )
            StatCardView(
                icon: "xmark.circle.fill",
                color: .secondary,
                value: "\(viewModel.selectedFolders.filter { !$0.activated }.count)",
                label: NSLocalizedString("stats.deactivated", comment: "")
            )
        }
    }

    /// 工具栏：选择文件夹 / 扫描目录
    private var flutterToolbar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.requestFolderPermission()
            } label: {
                Label(NSLocalizedString("home.select_folders", comment: ""), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.scanForFlutterProjects()
            } label: {
                Label(NSLocalizedString("home.scan_directory", comment: ""), systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isScanning)

            Spacer()

            // 全选/取消全选
            if !viewModel.selectedFolders.isEmpty {
                Button {
                    viewModel.toggleAllFolders()
                } label: {
                    let allActive = viewModel.selectedFolders.allSatisfy(\.activated)
                    Label(
                        allActive
                            ? NSLocalizedString("toolbar.deselect_all", comment: "")
                            : NSLocalizedString("toolbar.select_all", comment: ""),
                        systemImage: allActive ? "square" : "checkmark.square.fill"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.bottom, 12)
    }

    /// 空状态提示
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("home.empty_folders_message", comment: ""))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Flutter 项目列表
    private var flutterProjectList: some View {
        List {
            ForEach(viewModel.selectedFolders) { folder in
                ProjectRowView(
                    folder: folder,
                    onToggle: { viewModel.toggleFolderActivation(folder) },
                    onRemove: { viewModel.removeFolder(folder) }
                )
            }
            .onDelete(perform: viewModel.deleteFolders)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .padding(.horizontal, 12)
    }

    /// 底部大清理按钮
    private var flutterCleanButton: some View {
        Button {
            viewModel.cleanCommand()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                Text(NSLocalizedString("home.run_clean", comment: ""))
                    .fontWeight(.semibold)
            }
            .frame(width: 200, height: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .controlSize(.large)
        .disabled(viewModel.isRunningCommands || viewModel.selectedFolders.filter(\.activated).isEmpty)
    }

    // MARK: - Xcode 清理页面

    private var xcodeCleanView: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(systemName: "hammer.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange.gradient)

            Text(NSLocalizedString("xcode.title", comment: ""))
                .font(.title2.bold())

            Text(NSLocalizedString("xcode.description", comment: ""))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            // Xcode 目录选择提示
            if viewModel.xcodeDirectoryBookmark != nil {
                Label(NSLocalizedString("xcode.folder_configured", comment: ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            // 操作按钮
            VStack(spacing: 12) {
                Button {
                    viewModel.cleanBuildAndIndexCommand()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash.fill")
                        Text(NSLocalizedString("home.clean_build_index", comment: ""))
                            .fontWeight(.semibold)
                    }
                    .frame(width: 260, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(viewModel.isRunningCommands)

                Button {
                    viewModel.selectXcodeDirectory()
                } label: {
                    Text(NSLocalizedString("xcode.change_folder", comment: ""))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - 自动检测页面

    private var autoDetectView: some View {
        VStack(spacing: 0) {
            // 顶部说明
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "eye.fill")
                        .font(.title2)
                        .foregroundStyle(.green.gradient)
                    Text(NSLocalizedString("watch.page_title", comment: ""))
                        .font(.title2.bold())
                }
                Text(NSLocalizedString("watch.page_description", comment: ""))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Divider().padding(.horizontal, 28).padding(.vertical, 12)

            // 开关
            Toggle(isOn: Binding(
                get: { viewModel.isWatchEnabled },
                set: { viewModel.isWatchEnabled = $0 }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isWatchEnabled ? "eye.fill" : "eye.slash")
                        .foregroundStyle(viewModel.isWatchEnabled ? .green : .secondary)
                    Text(NSLocalizedString("watch.enable", comment: ""))
                        .fontWeight(.medium)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 28)

            Divider().padding(.horizontal, 28).padding(.vertical, 12)

            // 监控目录列表
            List {
                Section {
                    Button {
                        viewModel.addWatchedDirectory()
                    } label: {
                        Label(NSLocalizedString("watch.add_directory", comment: ""),
                              systemImage: "folder.badge.gearshape")
                    }

                    if viewModel.watchedDirectories.isEmpty {
                        Text(NSLocalizedString("watch.empty_message", comment: ""))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(viewModel.watchedDirectories) { dir in
                            WatchedDirectoryRow(
                                directory: dir,
                                isEnabled: viewModel.isWatchEnabled,
                                onRemove: { viewModel.removeWatchedDirectory(dir) }
                            )
                        }
                    }
                } header: {
                    Text(NSLocalizedString("watch.section_header", comment: ""))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .padding(.horizontal, 12)
        }
    }

    // MARK: - 进度遮罩

    @ViewBuilder
    private var processingOverlay: some View {
        if viewModel.isScanning || viewModel.isRunningCommands {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text(viewModel.isScanning
                         ? NSLocalizedString("scan.in_progress", comment: "")
                         : NSLocalizedString("commands.executing", comment: ""))
                        .font(.headline)

                    if viewModel.isScanning {
                        Text(String(format: NSLocalizedString("scan.found_count", comment: ""),
                                    viewModel.scanFoundCount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.currentProcessingFolder.isEmpty {
                        Text(viewModel.currentProcessingFolder)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Full Disk Access 相关视图

    /// 需要 Full Disk Access 权限的提示页面
    private var fullDiskAccessView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.yellow)

            Text(NSLocalizedString("fda.required_title", comment: ""))
                .font(.title2)
                .multilineTextAlignment(.center)

            Text(NSLocalizedString("fda.required_description", comment: ""))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            VStack(spacing: 12) {
                Button {
                    openFullDiskAccessPreferences()
                } label: {
                    Text(NSLocalizedString("fda.open_settings", comment: ""))
                        .frame(maxWidth: 340)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    checkFullDiskAccess()
                } label: {
                    HStack(spacing: 8) {
                        if fdaCheckInProgress { ProgressView().controlSize(.small) }
                        Text(NSLocalizedString("fda.try_again", comment: ""))
                    }
                    .frame(maxWidth: 340)
                }
                .disabled(fdaCheckInProgress)
            }
            .padding(.top, 8)

            Text(NSLocalizedString("fda.instructions", comment: ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 正在检查权限的加载页面
    private var permissionCheckingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(NSLocalizedString("fda.checking_permissions", comment: ""))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Full Disk Access 检查

    /// 检查是否拥有 Full Disk Access 权限
    private func checkFullDiskAccess() {
        fdaCheckInProgress = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 尝试访问受保护的 TCC 目录来判断是否有 FDA 权限
            let protectedURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC")
            let hasAccess: Bool
            do {
                _ = try FileManager.default.contentsOfDirectory(at: protectedURL, includingPropertiesForKeys: nil)
                hasAccess = true
            } catch {
                // 回退方案：尝试读取 TimeMachine 配置文件
                let tmPlist = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")
                hasAccess = (try? Data(contentsOf: tmPlist)) != nil
            }
            DispatchQueue.main.async {
                self.hasFullDiskAccess = hasAccess
                self.fdaCheckInProgress = false
            }
        }
    }

    /// 打开系统偏好设置中的 Full Disk Access 页面
    private func openFullDiskAccessPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 统计卡片组件

/// 顶部统计信息卡片（项目数、已激活数等）
struct StatCardView: View {
    let icon: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 项目行组件

/// Flutter 项目列表中每一行的视图
struct ProjectRowView: View {
    let folder: DocModel
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 开关
            Toggle("", isOn: Binding(
                get: { folder.activated },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            // 文件夹图标（根据激活状态显示不同颜色）
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.activated ? .cyan : .secondary)
                .font(.title3)

            // 项目名称和路径
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(folder.path)
            }

            Spacer()

            // 删除按钮
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 监控目录行组件

/// 自动检测页面中每个监控目录的行视图
struct WatchedDirectoryRow: View {
    let directory: WatchedDirectory
    let isEnabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isEnabled ? "eye.fill" : "eye.slash")
                .foregroundStyle(isEnabled ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: directory.path).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 预览

#Preview {
    HomeView()
}
