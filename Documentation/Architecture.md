# Architecture – EPUB Studio（v1）

EPUB Studio は *画像フォルダ → EPUB3 固定レイアウト* への完全自動変換を目的とした  
モジュール型 macOS アプリ。

---

# 全体構造
UI (SwiftUI)
├─ ContentView
├─ AuthorInfoDialog
└─ LogView

State
└─ AppState

Core Pipeline
├─ Converter
├─ ImageConverter
├─ EPUBBuilder
├─ LogicalItem / PageInfo
├─ ConverterTypes
├─ NSImage+CGImage
└─ ImageLoader

Entry Point
└─ EPUB_StudioApp

---

# UI レイヤー

## ContentView.swift
- フォルダ選択（FileImporter + D&D）
- 進捗バー（step1/step2/step3/total）
- ログ（LogView）
- 作者 / 出版社入力ダイアログ（AuthorInfoDialog）
- `Converter.run()` の実行
- セキュリティスコープ付き URL 管理

## AuthorInfoDialog.swift
- 作者・出版社名入力
- OK / Cancel 処理

## LogView.swift
- `ScrollViewReader` による自動スクロール
- モノスペースフォント

---

# 状態管理：AppState.swift
- 入力フォルダの管理
- 進捗値・工程別ステップ
- 単巻 / 複数巻モード
- 動作中フラグ（isProcessing）
- ログ蓄積
- 進捗ヘルパー（setStepXProgress）
- 全体リセット

---

# Core Pipeline

## Converter.swift（中心モジュール）

### モード判定
- 親フォルダ直下に画像 → **単巻モード**
- サブフォルダ内に画像 → **複数巻モード**

### 画像収集
- 拡張子フィルタリング → ファイルソート
- 1階層のみ探索

---

## Step① JPEG 変換 / 情報取得
- `ImageConverter.convertToJPEG()` で統一 JPEG 化
- `pixelSize` 読み取り
- 横長 / 番号ペアから見開き推定
- 単ページサイズの頻度分析 → 標準ページサイズ決定

---

## Step② 見開き分割 / 論理ページ構築
- `splitSpreadImage`：CGImage 切り出し＋最適リサイズ
- LogicalItem（single/spread）生成
- `makePageSequence`
  - 表紙は single-right
  - 以降は spread ペアリング
  - 余りページは single-right

---

## Step③ EPUBBuilder 呼び出し
- ページ XHTML 生成
- JPEG コピー
- `nav.xhtml`
- `toc.ncx`
- `content.opf`（右開き設定）
- zip → `.epub`
- `open -a Books` による自動オープン

---

# EPUBBuilder.swift

### 固定レイアウト仕様
- pre-paginated
- `page-progression-direction = rtl`
- cover-image 指定
- iBooks display-options
- viewport = ページサイズ

### ファイル構造
mimetype
META-INF/container.xml
META-INF/com.apple.ibooks.display-options.xml
OEBPS/content.opf
OEBPS/nav.xhtml
OEBPS/toc.ncx
OEBPS/images/*.jpg
OEBPS/pages/page_0001.xhtml

---

# ユーティリティ

## ImageConverter
- NSImage → Bitmap → JPEG
- 圧縮率 0.92
- PNG/WebP/AVIF などをすべて JPEG 化

## NSImage+CGImage
- `toCGImage()` 拡張

## LogicalItem / PageInfo
- ページ論理構造
- spread（左右）・single

## ConverterTypes
- `ConvertedImage`（処理中の画像保持）
- ImageConverterError

---

# エントリポイント

## EPUB_StudioApp.swift
- `WindowGroup`
- `ContentView` を起動