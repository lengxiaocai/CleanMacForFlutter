//
//  DirectoryWatcher.swift
//  CleanMacForFlutters
//
//  基于 FSEvents 的目录变动监控器
//  用于自动检测新增的 Flutter 项目
//

import Foundation
import CoreServices

/// 使用 macOS FSEventStream API 递归监控目录变化
/// 当检测到文件系统变动时，通过回调通知调用方
final class DirectoryWatcher {

    // MARK: - 属性

    /// FSEventStream 引用
    private var stream: FSEventStreamRef?

    /// 文件变动时的回调闭包
    private let callback: () -> Void

    /// 防抖延迟（秒）
    /// 文件系统操作通常会短时间内触发大量事件（如 flutter create），
    /// 通过防抖机制合并为一次回调，避免重复扫描
    private let debounceInterval: TimeInterval = 2.0

    /// 防抖工作项
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - 生命周期

    /// 初始化监控器
    /// - Parameter callback: 文件变动后的回调（在主线程触发）
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    deinit {
        stop()
    }

    // MARK: - 监控控制

    /// 开始监控指定的目录列表
    /// - Parameter paths: 要监控的目录路径列表（会递归监控所有子目录）
    func start(watching paths: [String]) {
        // 先停止之前的监控
        stop()

        guard !paths.isEmpty else { return }

        let pathsToWatch = paths as CFArray

        // 创建 FSEventStream 上下文，传入 self 指针
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        // 创建 FSEventStream
        guard let stream = FSEventStreamCreate(
            nil,                                    // 使用默认分配器
            DirectoryWatcher.eventCallback,         // C 函数回调
            &context,                               // 上下文（包含 self 指针）
            pathsToWatch,                           // 要监控的路径列表
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), // 只关注启动后的事件
            1.0,                                    // 延迟 1 秒批量合并事件
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        self.stream = stream
        // 在后台队列上处理文件事件
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// 停止监控并释放资源
    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    // MARK: - FSEventStream 回调

    /// FSEventStream 的 C 函数回调
    /// 从上下文中恢复 DirectoryWatcher 实例并调用实例方法
    private static let eventCallback: FSEventStreamCallback = {
        (_, clientCallbackInfo, _, _, _, _) in
        guard let info = clientCallbackInfo else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleEvents()
    }

    /// 处理文件事件：使用防抖机制延迟触发回调
    private func handleEvents() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.callback()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
