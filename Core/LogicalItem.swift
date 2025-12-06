//  Core/LogicalItem.swift
//  EPUB Studio

import Foundation

/// 見開き or 単ページを表すデータ構造
enum LogicalItem {
    case spread(right: URL, left: URL)  // 見開き（右ページ + 左ページ）
    case single(URL)                    // 単ページ（1枚）
}
