import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CoverDrop

@MainActor
struct CoverDropReceiverTests {
    @Test("拖入项同时提供 URL 和图片数据时优先暂存 URL")
    func receiverPrefersURLOverImageRepresentation() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropReceiver-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.validPNGData().write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let provider = NSItemProvider(object: sourceURL as NSURL)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(Self.validPNGData(), nil)
            return Progress(totalUnitCount: 1)
        }

        let appModel = AppModel()
        let albumID = "album-\(UUID().uuidString)"

        let didReceive = CoverDropReceiver.receive(
            [provider],
            albumID: albumID,
            appModel: appModel
        )

        #expect(didReceive)

        await waitUntil {
            appModel.pendingCoverURL(for: albumID) != nil
        }

        #expect(appModel.pendingCoverURL(for: albumID) == sourceURL)
    }

    @Test("封面拖入成功暂存后才触发接受回调")
    func receiverCallsAcceptedAfterImageDataIsStaged() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion(Self.validPNGData(), nil)
            }
            return Progress(totalUnitCount: 1)
        }

        let appModel = AppModel()
        let albumID = "album-\(UUID().uuidString)"
        var didAccept = false

        let didReceive = CoverDropReceiver.receive(
            [provider],
            albumID: albumID,
            appModel: appModel
        ) {
            didAccept = true
        }

        #expect(didReceive)
        #expect(!didAccept)

        await waitUntil {
            appModel.pendingCoverURL(for: albumID) != nil
        }

        #expect(didAccept)
    }

    @Test("URL 可用时不会触发失败的 JPEG representation")
    func receiverDoesNotLoadFailingJPEGWhenURLIsAvailable() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropReceiver-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.validPNGData().write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        var didRequestJPEG = false
        let provider = NSItemProvider(object: sourceURL as NSURL)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            didRequestJPEG = true
            let error = NSError(
                domain: NSItemProvider.errorDomain,
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Cannot load representation of type public.jpeg"
                ]
            )
            completion(nil, error)
            return Progress(totalUnitCount: 1)
        }

        let appModel = AppModel()
        let albumID = "album-\(UUID().uuidString)"

        let didReceive = CoverDropReceiver.receive(
            [provider],
            albumID: albumID,
            appModel: appModel
        )

        #expect(didReceive)

        await waitUntil {
            appModel.pendingCoverURL(for: albumID) != nil
        }

        #expect(appModel.pendingCoverURL(for: albumID) == sourceURL)
        #expect(!didRequestJPEG)
        #expect(appModel.errorMessage == nil)
    }

    nonisolated private static func validPNGData() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
