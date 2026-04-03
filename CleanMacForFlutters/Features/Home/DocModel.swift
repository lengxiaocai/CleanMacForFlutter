//
//  DocModel.swift
//  CleanMacForFlutters
//
//  数据模型定义
//

import Foundation

/// Flutter 项目文件夹模型
/// 代表一个已添加到清理列表中的 Flutter 项目
struct DocModel: Identifiable, Hashable {
    /// 唯一标识符
    let id = UUID()
    /// 项目文件夹的完整路径
    let path: String
    /// 是否已激活（激活的项目会被包含在清理操作中）
    var activated: Bool
}

/// 监控目录模型
/// 代表一个被 FSEvents 文件监控器跟踪的父目录
struct WatchedDirectory: Identifiable, Hashable {
    /// 唯一标识符
    let id = UUID()
    /// 被监控目录的完整路径
    let path: String
}
