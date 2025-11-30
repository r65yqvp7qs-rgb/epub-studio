//
//  EPUBBuilder.swift
//  EPUB Studio
//

import Foundation

/// EPUB3 固定レイアウト (Fixed Layout) で EPUB を生成するビルダー
///
/// - 仕様は「見開きがきれいにくっついて見える」ことが確認できていた
///   旧版 EPUBBuilder をベースに、
///   - publisher メタデータの追加
///   - nav.xhtml の epub 名前空間追加（エラー対策）
///   を行ったものです。
struct EPUBBuilder {

    /// タイトル（フォルダ名）
    let title: String
    /// 作者名（ダイアログの入力値）
    let author: String
    /// 出版社名（ダイアログの入力値）
    let publisher: String

    /// 出力先 .epub ファイル URL
    let outputURL: URL

    /// Converter で組み立てたページ情報
    let pages: [PageInfo]

    /// 単ページのピクセルサイズ（Converter で決めた baseSize）
    let pageSize: CGSize

    /// ログ出力クロージャ
    let log: (String) -> Void

    // MARK: - Public

    /// EPUB を実際に作成するメイン処理
    func build() throws {
        log("=== EPUB Builder 開始 (EPUB3 FXL) ===")

        let fm = FileManager.default

        // ------------------------------------------------
        // 作業フォルダ構成
        //
        // workDir/
        //   mimetype
        //   META-INF/
        //   OEBPS/
        //     images/
        //     pages/
        // ------------------------------------------------
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_work_\(UUID().uuidString)")

        let oebps      = workDir.appendingPathComponent("OEBPS")
        let metaInf    = workDir.appendingPathComponent("META-INF")
        let imagesDir  = oebps.appendingPathComponent("images")
        let pagesDir   = oebps.appendingPathComponent("pages")

        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir,   withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps,     withIntermediateDirectories: true)
        try fm.createDirectory(at: metaInf,   withIntermediateDirectories: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pagesDir,  withIntermediateDirectories: true)

        log("✓ EPUBフォルダ構造を準備完了")

        // ------------------------------------------------
        // mimetype（必ず ZIP の先頭 & 無圧縮）
        // ------------------------------------------------
        let mimeURL = workDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(
            to: mimeURL,
            atomically: true,
            encoding: .utf8
        )
        log("✓ mimetype 作成")

        // ------------------------------------------------
        // META-INF/container.xml
        // ------------------------------------------------
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true,
            encoding: .utf8
        )

        // ------------------------------------------------
        // com.apple.ibooks.display-options.xml
        //   → iBooks / Apple Books に固定レイアウトであることを明示
        // ------------------------------------------------
        let ibooksDisplayOptions = """
        <?xml version="1.0" encoding="UTF-8"?>
        <display_options>
          <platform name="*">
            <option name="fixed-layout">true</option>
            <option name="orientation-lock">none</option>
            <option name="open-to-spread">auto</option>
          </platform>
        </display_options>
        """
        try ibooksDisplayOptions.write(
            to: metaInf.appendingPathComponent("com.apple.ibooks.display-options.xml"),
            atomically: true,
            encoding: .utf8
        )
        log("✓ com.apple.ibooks.display-options.xml 作成 (固定レイアウト)")

        // ------------------------------------------------
        // 画像コピー & ページ XHTML 作成
        // ------------------------------------------------
        var xhtmlFileNames: [String] = []
        var imageManifestItems: [String] = []
        var xhtmlManifestItems: [String] = []
        var spineItems: [String] = []

        let iso8601Now = currentISO8601()
        let uuid = UUID().uuidString

        // 1ページ目の画像を cover にする
        let coverImageName = pages.first?.imageFile.lastPathComponent

        for (i, page) in pages.enumerated() {
            let pageIndex = i + 1

            // ---- 画像コピー ----
            let imgName = page.imageFile.lastPathComponent
            let imgDst  = imagesDir.appendingPathComponent(imgName)
            try fm.copyItem(at: page.imageFile, to: imgDst)

            let media = mediaType(for: page.imageFile)

            let isCover = (imgName == coverImageName)
            let coverProp = isCover ? #" properties="cover-image""# : ""

            imageManifestItems.append(
                """
                <item id="img\(pageIndex)" href="images/\(imgName)" media-type="\(media)"\(coverProp)/>
                """
            )

            // ---- XHTML 1ページ分 ----
            let xhtmlName = String(format: "page_%04d.xhtml", pageIndex)
            let xhtmlPath = pagesDir.appendingPathComponent(xhtmlName)

            let xhtml = makePageXHTML(
                pageNumber: pageIndex,
                imageFileName: imgName
            )
            try xhtml.write(
                to: xhtmlPath,
                atomically: true,
                encoding: .utf8
            )

            xhtmlFileNames.append(xhtmlName)

            xhtmlManifestItems.append(
                """
                <item id="page\(pageIndex)" href="pages/\(xhtmlName)" media-type="application/xhtml+xml"/>
                """
            )

            // ---- spine item（見開き左右の指定）----
            let spreadProp: String
            switch page.side {
            case .single:
                // 単ページ → 属性なし
                spreadProp = ""
            case .right:
                spreadProp = #" properties="page-spread-right""#
            case .left:
                spreadProp = #" properties="page-spread-left""#
            }

            spineItems.append(
                "<itemref idref=\"page\(pageIndex)\"\(spreadProp)/>"
            )
        }

        log("✓ 画像 & ページ XHTML 作成完了")

        // ------------------------------------------------
        // nav.xhtml (EPUB3 TOC)
        //   ※ 旧版 + epub 名前空間を追加
        // ------------------------------------------------
        let navXHTML = makeNavXHTML(xhtmlFileNames: xhtmlFileNames)
        try navXHTML.write(
            to: oebps.appendingPathComponent("nav.xhtml"),
            atomically: true,
            encoding: .utf8
        )
        log("✓ nav.xhtml 作成")

        // ------------------------------------------------
        // toc.ncx（互換用・簡易）
        // ------------------------------------------------
        let tocNCX = makeTOCNCX(xhtmlFileNames: xhtmlFileNames)
        try tocNCX.write(
            to: oebps.appendingPathComponent("toc.ncx"),
            atomically: true,
            encoding: .utf8
        )
        log("✓ toc.ncx 作成")

        // ------------------------------------------------
        // content.opf (EPUB3 FXL)
        //   → pre-paginated / spread=auto など、
        //     以前 “見開きがぴったりくっついていた” 時と同じ設定
        // ------------------------------------------------

        // manifest
        let manifest =
        """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        """ +
        "\n" + imageManifestItems.joined(separator: "\n") +
        "\n" + xhtmlManifestItems.joined(separator: "\n")

        // spine
        let spine = spineItems.joined(separator: "\n            ")

        let contentOPF = """
        <?xml version="1.0" encoding="utf-8"?>
        <package version="3.0"
                 xmlns="http://www.idpf.org/2007/opf"
                 unique-identifier="bookid">

          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(uuid)</dc:identifier>
            <dc:title>\(escapeXML(title))</dc:title>
            <dc:creator>\(escapeXML(author))</dc:creator>
            <dc:publisher>\(escapeXML(publisher))</dc:publisher>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">\(iso8601Now)</meta>

            <!-- 固定レイアウト指定 (EPUB3 FXL) -->
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:orientation">auto</meta>
            <meta property="rendition:spread">auto</meta>

            <!-- iBooks 拡張 -->
            <meta property="ibooks:reader-optimized">true</meta>
          </metadata>

          <manifest>
        \(manifest)
          </manifest>

          <!-- 右開き -->
          <spine page-progression-direction="rtl">
            \(spine)
          </spine>

        </package>
        """

        try contentOPF.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true,
            encoding: .utf8
        )
        log("✓ content.opf 作成 (EPUB3 固定レイアウト, 右開き)")

        // ------------------------------------------------
        // ZIP → EPUB
        //   /usr/bin/zip は iCloud 直下などで権限エラーを出すので
        //   いったん一時ファイルに .epub を作成してから move する
        // ------------------------------------------------
        try zipEpub(workDir: workDir, dest: outputURL)
        log("✓ EPUB パッケージング完了: \(outputURL.path)")

        log("=== EPUB Builder 完了 ===")
    }

    // MARK: - XHTML (1ページぶん)

    /// 1ページ分の XHTML を生成
    /// 画像サイズ = viewport = pageSize に揃え、
    /// Apple Books 側で余計なスケーリングが入らないようにする。
    private func makePageXHTML(pageNumber: Int, imageFileName: String) -> String {
        let w = Int(pageSize.width)
        let h = Int(pageSize.height)

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
          "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>Page \(pageNumber)</title>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
            <meta name="viewport" content="width=\(w), height=\(h)"/>
            <style type="text/css">
              html, body {
                margin: 0;
                padding: 0;
                width: \(w)px;
                height: \(h)px;
                background-color: #000000;
              }
              img {
                position: absolute;
                top: 0;
                left: 0;
                width: \(w)px;
                height: \(h)px;
                object-fit: fill;
              }
            </style>
          </head>
          <body>
            <img src="../images/\(imageFileName)" alt="" />
          </body>
        </html>
        """
    }

    // MARK: - nav.xhtml (EPUB3 TOC)

    /// nav.xhtml を生成
    /// 旧版 + epub 名前空間 (xmlns:epub) を追加して
    /// 「epub 名前空間がない」エラーを防いでいる。
    private func makeNavXHTML(xhtmlFileNames: [String]) -> String {
        let items = xhtmlFileNames.enumerated().map { (index, name) in
            """
                <li><a href="pages/\(name)">\(index + 1)</a></li>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"
              xml:lang="ja">
          <head>
            <title>Navigation</title>
            <meta charset="utf-8" />
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <ol>
        \(items)
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    // MARK: - toc.ncx（互換用・簡易）

    private func makeTOCNCX(xhtmlFileNames: [String]) -> String {
        let navPoints = xhtmlFileNames.enumerated().map { (index, name) in
            """
            <navPoint id="navPoint-\(index + 1)" playOrder="\(index + 1)">
              <navLabel>
                <text>Page \(index + 1)</text>
              </navLabel>
              <content src="pages/\(name)"/>
            </navPoint>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="bookid"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle>
            <text>\(escapeXML(title))</text>
          </docTitle>
          <navMap>
        \(navPoints)
          </navMap>
        </ncx>
        """
    }

    // MARK: - Utility

    /// 拡張子から media-type を決定
    private func mediaType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        default:            return "application/octet-stream"
        }
    }

    /// ZIP で EPUB を作成
    ///
    /// - /usr/bin/zip は iCloud / デスクトップ直下などで
    ///   「Operation not permitted」を出すことがあるので、
    ///   いったん **一時ファイルに .epub を作成 → moveItem で移動**
    private func zipEpub(workDir: URL, dest: URL) throws {
        let fm = FileManager.default

        // 一時ファイルに書き出し
        let tempDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_tmp_\(UUID().uuidString).epub")

        try? fm.removeItem(at: tempDest)

        // mimetype 無圧縮
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p1.arguments = ["-X0", tempDest.path, "mimetype"]
        p1.currentDirectoryURL = workDir
        try p1.run()
        p1.waitUntilExit()

        // META-INF と OEBPS を圧縮
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p2.arguments = ["-r", tempDest.path, "META-INF", "OEBPS"]
        p2.currentDirectoryURL = workDir
        try p2.run()
        p2.waitUntilExit()

        // 既に出力先があれば削除してから移動
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: tempDest, to: dest)
    }

    /// ISO8601 形式の現在時刻
    private func currentISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// XML 用に最低限のエスケープ
    private func escapeXML(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'", with: "&apos;")
        return s
    }
}
