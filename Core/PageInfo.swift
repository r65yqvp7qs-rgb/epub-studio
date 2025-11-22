import Foundation

/// ページの左右・単ページ種別
enum PageSide {
    /// 単ページ（表紙・裏表紙など）
    case single

    /// 見開きの右ページ
    case right

    /// 見開きの左ページ
    case left
}

/// Converter で組み立てた最終ページ列
struct PageInfo {
    /// 実体画像ファイル（JPEG / PNG）
    let imageFile: URL

    /// ページが単ページか / 見開きの左右か
    let side: PageSide
}
