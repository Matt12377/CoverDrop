import Foundation
import Testing
@testable import CoverDrop

struct AlbumScanDisplayIndexTests {
    @Test("五万张专辑下索引查找统计筛选和无命中搜索均低于 100ms")
    func fiftyThousandAlbumReadsStayUnderInteractionBudget() {
        let result = LibraryScanResult(
            albums: (0..<50_000).map { index in
                makeAlbum(
                    index: index,
                    hasCover: index.isMultiple(of: 2),
                    issues: index.isMultiple(of: 5) ? [.singleFileNeedsConfirmation(hasCue: true)] : []
                )
            },
            looseAudioPaths: []
        )
        let index = AlbumScanDisplayIndex(
            result: result,
            failedAlbumIDs: Set(result.albums[0..<1_000].map(\.id)),
            displayNames: { album in
                (artistName: album.artistName, albumName: album.albumName)
            }
        )
        let lastAlbumID = result.albums[49_999].id

        let lookup = measured {
            #expect(index.album(id: lastAlbumID)?.albumName == "专辑 49999")
        }
        let stats = measured {
            #expect(index.stats.albumsWithCover == 25_000)
            #expect(index.stats.albumsNeedingAttention == 10_000)
        }
        let filterAll = measured {
            #expect(index.albums(filter: .all, query: "").count == 50_000)
        }
        let filterWithCover = measured {
            #expect(index.albums(filter: .withCover, query: "").count == 25_000)
        }
        let noHitSearch = measured {
            #expect(index.albums(filter: .all, query: "不会命中的搜索词").isEmpty)
        }
        let failed = measured {
            #expect(index.failedAlbumIDs.count == 1_000)
        }

        #expect(lookup < 0.1, "albumID 查找耗时 \(lookup) 秒")
        #expect(stats < 0.1, "统计读取耗时 \(stats) 秒")
        #expect(filterAll < 0.1, "全部筛选耗时 \(filterAll) 秒")
        #expect(filterWithCover < 0.1, "已有封面筛选耗时 \(filterWithCover) 秒")
        #expect(noHitSearch < 0.1, "无命中搜索耗时 \(noHitSearch) 秒")
        #expect(failed < 0.1, "失败集合读取耗时 \(failed) 秒")
    }

    @Test("局部替换专辑会同步更新查找统计和筛选桶")
    func replacingOneAlbumUpdatesLookupStatsAndBuckets() {
        let oldAlbum = makeAlbum(index: 1, hasCover: false, issues: [])
        let keptAlbum = makeAlbum(index: 2, hasCover: true, issues: [])
        let newAlbum = makeAlbum(index: 1, hasCover: true, issues: [.singleFileNeedsConfirmation(hasCue: true)])
        let index = AlbumScanDisplayIndex(
            result: LibraryScanResult(albums: [oldAlbum, keptAlbum], looseAudioPaths: []),
            failedAlbumIDs: []
        )

        let updated = index.replacingAlbums([newAlbum])

        #expect(updated.album(id: oldAlbum.id)?.displayedCover != nil)
        #expect(updated.stats.albumsWithCover == 2)
        #expect(updated.stats.albumsNeedingAttention == 1)
        #expect(updated.albums(filter: .missingCover, query: "").isEmpty)
        #expect(updated.albums(filter: .singleFileUnsplit, query: "").map(\.id) == [newAlbum.id])
    }

    @Test("五万张专辑下局部替换索引低于 100ms")
    func replacingOneAlbumInLargeIndexStaysUnderInteractionBudget() {
        let result = LibraryScanResult(
            albums: (0..<50_000).map { index in
                makeAlbum(index: index, hasCover: index.isMultiple(of: 2), issues: [])
            },
            looseAudioPaths: []
        )
        let index = AlbumScanDisplayIndex(result: result)
        let refreshedAlbum = makeAlbum(
            index: 49_999,
            hasCover: true,
            issues: [.singleFileNeedsConfirmation(hasCue: true)]
        )

        var updated: AlbumScanDisplayIndex?
        let elapsed = measured {
            updated = index.replacingAlbums([refreshedAlbum])
        }

        #expect(elapsed < 0.1, "局部替换索引耗时 \(elapsed) 秒")
        #expect(updated?.album(id: refreshedAlbum.id)?.displayedCover != nil)
        #expect(updated?.stats.albumsWithCover == 25_001)
        #expect(updated?.albums(filter: .singleFileUnsplit, query: "").map(\.id) == [refreshedAlbum.id])
    }

    @Test("五万张专辑下单张名称增强索引更新低于 100ms")
    func updatingOneNameEnhancementInLargeIndexStaysUnderInteractionBudget() {
        let result = LibraryScanResult(
            albums: (0..<50_000).map { index in
                makeAlbum(index: index, hasCover: false, issues: [])
            },
            looseAudioPaths: []
        )
        let index = AlbumScanDisplayIndex(result: result)
        let targetAlbum = result.albums[49_999]

        let elapsed = measured {
            _ = index.updatingNameEnhancement(
                for: targetAlbum.id,
                failedAlbumIDs: [targetAlbum.id],
                displayNames: { album in
                    if album.id == targetAlbum.id {
                        return (artistName: "增强歌手", albumName: "增强专辑")
                    }
                    return (artistName: album.artistName, albumName: album.albumName)
                }
            )
        }

        #expect(elapsed < 0.1, "单张名称增强索引更新耗时 \(elapsed) 秒")
        #expect(index.albums(filter: .nameEnhancementFailed, query: "").map(\.id) == [targetAlbum.id])
        #expect(index.albums(filter: .all, query: "增强专辑").map(\.id) == [targetAlbum.id])
    }

    private func measured(_ block: () -> Void) -> TimeInterval {
        let startedAt = Date()
        block()
        return Date().timeIntervalSince(startedAt)
    }

    private func makeAlbum(
        index: Int,
        hasCover: Bool,
        issues: [AlbumScanIssue]
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: "/tmp/歌手 \(index % 500)/专辑 \(index)", isDirectory: true)
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: "歌手 \(index % 500)",
            albumName: "专辑 \(index)",
            audioFiles: [
                AudioFileRecord(
                    url: folderURL.appendingPathComponent("01.flac"),
                    relativePath: "01.flac",
                    format: "flac",
                    metadata: nil,
                    readError: nil
                )
            ],
            cueSheets: issues.contains(.singleFileNeedsConfirmation(hasCue: true)) ? [
                CueSheetRecord(
                    url: folderURL.appendingPathComponent("album.cue"),
                    relativePath: "album.cue"
                )
            ] : [],
            displayedCover: hasCover ? CoverCandidate(
                url: folderURL.appendingPathComponent("cover.jpg"),
                relativePath: "cover.jpg",
                namePriority: 0,
                depth: 0
            ) : nil,
            issues: issues
        )
    }
}
