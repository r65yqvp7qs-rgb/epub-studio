//
//  EPUBBuilder.swift
//  EPUB Studio
//

import Foundation
import AppKit

/// EPUB 1冊分をパッケージングするクラス
struct EPUBBuilder {

    let title: String
    let author: String
    let publisher: String

    let outputURL: URL
    let pages: [PageInfo]
    let pageSize: CGSize

    let log: (String) -> Void

    // ================================================
    // 初期化
    // ================================================
    init(
        title: String,
        author: String,
        publisher: String,
        outputURL: URL,
        pages: [PageInfo],
        pageSize: CGSize,
        log: @escaping (String) -> Void
    ) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.outputURL = outputURL
        self.pages = pages
        self.pageSize = pageSize
        self.log = log
    }

    // ================================================
    // EPUB 作成メイン処理
    // ================================================
    func build() throws {

        let fm = FileManager.default
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_work_\(UUID().uuidString)")

        // 作業フォルダ作成
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let metaInf = work.appendingPathComponent("META-INF")
        let oebps = work.appendingPathComponent("OEBPS")

        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)

        // mimetype は必ず最初・無圧縮で保存
        let mimetypeURL = work.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypeURL, atomically: true, encoding: .utf8)

        // container.xml
        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0"
            xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true,
            encoding: .utf8
        )

        // XHTML ページ生成
        let imagesDir = oebps.appendingPathComponent("Images")
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let xhtmlDir = oebps.appendingPathComponent("Text")
        try fm.createDirectory(at: xhtmlDir, withIntermediateDirectories: true)

        var manifestItems: [String] = []
        var spineItems: [String] = []

        for (index, page) in pages.enumerated() {

            let imgName = String(format: "img_%04d.jpg", index + 1)
            let imgURL = imagesDir.appendingPathComponent(imgName)

            try fm.copyItem(at: page.imageFile, to: imgURL)

            let xhtmlName = String(format: "page_%04d.xhtml", index + 1)
            let xhtmlURL = xhtmlDir.appendingPathComponent(xhtmlName)

            let xhtml = makeXHTML(
                imageName: imgName,
                pageWidth: Int(pageSize.width),
                pageHeight: Int(pageSize.height),
                side: page.side
            )

            try xhtml.write(to: xhtmlURL, atomically: true, encoding: .utf8)

            manifestItems.append("""
                <item id="img\(index+1)" href="Images/\(imgName)" media-type="image/jpeg"/>
                <item id="p\(index+1)" href="Text/\(xhtmlName)" media-type="application/xhtml+xml"/>
            """)

            spineItems.append("""
                <itemref idref="p\(index+1)" linear="yes"/>
            """)
        }

        // content.opf 生成（作者・出版社がここ！）
        let opf = makeOPF(
            manifestItems: manifestItems.joined(separator: "\n"),
            spineItems: spineItems.joined(separator: "\n")
        )

        try opf.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true,
            encoding: .utf8
        )

        // toc.xhtml（必要最小限）
        let toc = makeTOC()
        try toc.write(
            to: oebps.appendingPathComponent("toc.xhtml"),
            atomically: true,
            encoding: .utf8
        )

        // ZIP → EPUB
        try createEPUBZIP(workDir: work, epubURL: outputURL)

        log("✓ EPUB パッケージング完了")
    }

    // ================================================
    // XHTML ページ生成
    // ================================================
    private func makeXHTML(
        imageName: String,
        pageWidth: Int,
        pageHeight: Int,
        side: PageSide
    ) -> String {

        let rendition = (side == .right)
            ? #"  <meta property="rendition:page-spread">right</meta>"#
            : #"  <meta property="rendition:page-spread">left</meta>"#

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title></title>
          <meta charset="utf-8" />
        \(rendition)
          <style>
            body, html {
              margin: 0; padding: 0;
              width: \(pageWidth)px;
              height: \(pageHeight)px;
              overflow: hidden;
            }
            img {
              width: 100%;
              height: 100%;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <img src="../Images/\(imageName)" />
        </body>
        </html>
        """
    }

    // ================================================
    // content.opf 生成（作者/出版社記述）
    // ================================================
    private func makeOPF(manifestItems: String, spineItems: String) -> String {

        let uuid = UUID().uuidString

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package version="3.0"
                 xmlns="http://www.idpf.org/2007/opf"
                 unique-identifier="BookID">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmlns:opf="http://www.idpf.org/2007/opf">

            <dc:identifier id="BookID">urn:uuid:\(uuid)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:publisher>\(publisher)</dc:publisher>
            <dc:language>ja</dc:language>

            <meta property="dcterms:modified">\(iso8601Date())</meta>
          </metadata>

          <manifest>
            <item id="toc" properties="nav"
                  href="toc.xhtml"
                  media-type="application/xhtml+xml"/>
            \(manifestItems)
          </manifest>

          <spine>
            <itemref idref="toc"/>
            \(spineItems)
          </spine>
        </package>
        """
    }

    // ================================================
    // toc.xhtml 最小実装
    // ================================================
    private func makeTOC() -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>TOC</title></head>
        <body>
          <nav epub:type="toc">
            <ol></ol>
          </nav>
        </body>
        </html>
        """
    }

    // ================================================
    // EPUB zip 作成
    // ================================================
    private func createEPUBZIP(workDir: URL, epubURL: URL) throws {

        let fm = FileManager.default
        if fm.fileExists(atPath: epubURL.path) {
            try fm.removeItem(at: epubURL)
        }

        let cwd = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(cwd) }

        fm.changeCurrentDirectoryPath(workDir.path)

        let task = Process()
        task.launchPath = "/usr/bin/zip"
        task.arguments = ["-X0", epubURL.path, "mimetype"]
        try task.run()
        task.waitUntilExit()

        let task2 = Process()
        task2.launchPath = "/usr/bin/zip"
        task2.arguments = [
            "-Xr9D", epubURL.path,
            "META-INF",
            "OEBPS"
        ]
        try task2.run()
        task2.waitUntilExit()
    }

    // ================================================
    // ISO8601
    // ================================================
    private func iso8601Date() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        return df.string(from: Date())
    }
}
