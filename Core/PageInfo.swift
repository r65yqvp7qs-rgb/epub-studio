//
//  PageInfo.swift
//  EPUB Studio
//

import Foundation

/// ページの左右（単ページも含む）
enum PageSide {
    /// 単ページ（表紙・裏表紙など）
    case single
    /// 見開きの右ページ
    case right
    /// 見開きの左ページ
    case left
}

/// Converter で組み立てた最終ページ情報
struct PageInfo {
    /// JPEG 画像ファイル（EPUB に入る最終的な画像）
    let imageFile: URL

    /// ページが単ページ / 見開きの左右か
    let side: PageSide
}
