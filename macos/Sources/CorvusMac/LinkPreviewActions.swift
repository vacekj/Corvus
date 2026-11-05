import CorvusCore
import Foundation

extension AppModel {
    /// Called when the composer text, the edit state or the Settings switch changes.
    func refreshLinkPreview() {
        linkDraft.update(text: composerText, enabled: appearance.generateLinkPreviews, editing: !editKey.isEmpty)
    }

    /// `send` parameters for the preview of `text` (and the preview to show in the pending message).
    /// The image is written below `stageDir`, which the caller removes after sending.
    func linkPreviewForSend(text: String, stageDir: URL) -> (preview: LinkPreview, params: JSON)? {
        guard appearance.generateLinkPreviews, let lp = linkDraft.previewToSend(for: text) else { return nil }
        return (lp, LinkPreviews.sendParams(lp, imagePath: linkDraft.stageImage(in: stageDir)))
    }

    /// Return was pressed while the preview of the link is still loading: send as soon as it is ready.
    func deferSendForLinkPreview() {
        guard linkDraft.deferredSend == nil else { return }
        showFlash("Generating link preview …", seconds: 12)
        let text = composerText
        linkDraft.deferredSend = Task { [weak self] in
            await self?.linkDraft.waitUntilReady()
            guard let self else { return }
            self.linkDraft.deferredSend = nil
            self.clearFlash()
            if self.composerText == text {
                self.linkDraft.bypassWait = true
                self.sendMessage()
                self.linkDraft.bypassWait = false
            }
        }
    }

    /// Incoming previews bring only a reference to the sender's image; it is fetched from signal-cli (not from
    /// the linked site) and kept as a small thumbnail in the history, like the Qt app does.
    func fetchLinkPreviewThumbnail(_ key: String, ts: Int64, author: String, attempt: Int = 0) {
        guard let c = chats.convs[key], let mi = chats.findMessage(c, ts: ts, authors: [author]) else { return }
        let lp = c.msgs[mi].linkPreview
        guard lp.isValid, !lp.imageId.isEmpty, lp.imageThumb.isEmpty, lp.imageSize <= Media.maxThumbSource else { return }
        let token = "lp|\(key)|\(ts)|\(author)"
        guard !linkDraft.thumbPending.contains(token) else { return }
        linkDraft.thumbPending.insert(token)
        var p: JSON = ["id": lp.imageId]
        addRecipient(&p, c)
        Task { [p] in
            defer { linkDraft.thumbPending.remove(token) }
            let data: Data
            do {
                let res = try await cli.call("getAttachment", p)
                data = Data(base64Encoded: jsonString(jsonObject(res)["data"])) ?? Data()
            } catch {
                // signal-cli may still be downloading it: retry a few times
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
                    linkDraft.thumbPending.remove(token)
                    fetchLinkPreviewThumbnail(key, ts: ts, author: author, attempt: attempt + 1)
                }
                return
            }
            guard Media.pixelSize(data) != nil else { return }
            var thumb = Media.makeThumbnail(data)
            if thumb.isEmpty { thumb = data }
            guard let c2 = chats.convs[key], let i = chats.findMessage(c2, ts: ts, authors: [author]),
                  chats.convs[key]!.msgs[i].linkPreview.url == lp.url else { return }
            chats.convs[key]!.msgs[i].linkPreview.imageThumb = thumb
            persist(Records.linkPreviewUpdate(key, chats.convs[key]!.msgs[i]))
        }
    }
}
