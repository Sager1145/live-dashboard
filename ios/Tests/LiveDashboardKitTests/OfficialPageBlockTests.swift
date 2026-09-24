import XCTest
import LiveIngestionCore
@testable import LiveDashboardKit

final class OfficialPageBlockTests: XCTestCase {
    func testSourceBlocksKeepHeadingPathHiddenPaneTableLinksAndImages() throws {
        let html = """
        <div data-target="ticket" style="display:none">
          <h2>チケット</h2>
          <h3>東京公演</h3>
          <h4>プレイガイド先行</h4>
          <p>受付期間：2026年9月22日(火)21:00～10月18日(日)23:59</p>
          <a href="/jp">日本国内受付</a>
          <a href="https://example.com/overseas">海外受付</a>
          <table>
            <tr><th>Day1</th><td>S席</td></tr>
            <tr><th>Day2</th><td>A席</td></tr>
          </table>
          <img alt="物販" data-src="/goods/main.jpg" src="data:image/gif;base64,AAAA">
        </div>
        """
        let base = URL(string: "https://www.lovelive-anime.jp/live/")!
        let blocks = OfficialPageBlocks.sourceBlocks(html: html, baseURL: base, snapshotID: "snap-1")
        let ticket = blocks.first { $0.headingPath == ["チケット", "東京公演", "プレイガイド先行"] }
        let block = try XCTUnwrap(ticket)
        XCTAssertEqual(block.snapshotID, "snap-1")
        XCTAssertEqual(block.pane, "ticket")
        XCTAssertNotNil(block.parentBlockID)
        XCTAssertTrue(block.rawLines.contains { $0.contains("受付期間") })
        XCTAssertEqual(block.links.map(\.label), ["日本国内受付", "海外受付"])
        XCTAssertEqual(block.links.map(\.resolvedURL), [
            "https://www.lovelive-anime.jp/jp",
            "https://example.com/overseas"
        ])
        XCTAssertEqual(block.tableRows, [["Day1", "S席"], ["Day2", "A席"]])
        XCTAssertTrue(block.images.contains { $0.source == "data-src" && $0.resolvedURL == "https://www.lovelive-anime.jp/goods/main.jpg" })
        XCTAssertFalse(block.blockID.contains("lovelive"))
    }
}
