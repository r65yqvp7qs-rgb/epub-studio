
//  Core/ConverterTypes.swift
//  EPUB Studio

import Foundation
import CoreGraphics

/// JPEG 変換後の画像情報
struct ConvertedImage {
    /// 元画像の URL
    let originalURL: URL
    /// 変換後 JPEG の URL
    let jpegURL: URL
    /// ピクセルサイズ
    let pixelSize: CGSize
    /// ファイル名（ログ用）
    let fileName: String
    /// ファイル名から推定した見開き番号ペア (例: (2, 3))
    let spreadPair: (Int, Int)?
    /// 画像が横長（見開き想定）かどうか
    let isWide: Bool
}

/// 画像処理まわりのエラー
enum ImageConverterError: Error {
    /// 画像ファイルを読み込めなかった
    case cannotLoadImage(URL)
    /// JPEG を作成できなかった
    case cannotCreateJPEG(URL)
    /// ピクセルサイズを取得できなかった
    case cannotDetectSize(URL)
}
