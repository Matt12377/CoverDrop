import Foundation
import UniformTypeIdentifiers

enum CoverSearchResultDragItemProvider {
    static func provider(for result: CoverSearchResult) -> NSItemProvider {
        let provider = NSItemProvider()
        CoverDropDebugLog.write(
            "封面拖拽：创建聚合搜索 URL-only 拖拽 provider，source=\(result.sourceName)，imageURL=\(result.imageURL.absoluteString)"
        )
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.url.identifier,
            visibility: .all
        ) { completion in
            completion(result.imageURL.absoluteString.data(using: .utf8), nil)
            return Progress(totalUnitCount: 1)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier,
            visibility: .all
        ) { completion in
            completion(result.imageURL.absoluteString.data(using: .utf8), nil)
            return Progress(totalUnitCount: 1)
        }
        return provider
    }
}
