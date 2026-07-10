import Foundation
import UniformTypeIdentifiers

enum CoverSearchResultDragItemProvider {
    static func provider(for result: CoverSearchResult) -> NSItemProvider {
        let provider = NSItemProvider(object: result.imageURL as NSURL)
        CoverDropDebugLog.write(
            "封面拖拽：创建聚合搜索拖拽 provider，source=\(result.sourceName)，imageURL=\(result.imageURL.absoluteString)"
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
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            let task = URLSession.shared.dataTask(with: RemoteCoverPreviewLoader.remoteImageRequest(for: result.imageURL)) { data, response, error in
                if let error {
                    completion(nil, error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ..< 400).contains(httpResponse.statusCode),
                      let data else {
                    completion(nil, CoverSearchResultDragFailure.invalidImageResponse)
                    return
                }

                completion(data, nil)
            }
            task.resume()
            return Progress(totalUnitCount: 1)
        }
        return provider
    }
}

private enum CoverSearchResultDragFailure: LocalizedError {
    case invalidImageResponse

    var errorDescription: String? {
        switch self {
        case .invalidImageResponse:
            "无法下载聚合搜索结果封面。"
        }
    }
}
