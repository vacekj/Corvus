import CorvusCore
import Foundation

/// A preview generated for a link the user is about to send, with the image it came with.
struct FetchedLinkPreview {
    var preview: LinkPreview     // imageThumb holds the small stored image
    var imageData: Data?         // original image, attached to the message when sending
    var imageSuffix = "jpg"
}

/// Downloads one resource for a link preview: https only, no cookies, no cache, no credentials, redirects
/// followed manually (every hop must pass `LinkPreviews.isSafeToFetch`), hard size and time limits.
private final class PreviewLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var status: Int
        var contentType: String
        var location: String?
        var data: Data
    }

    private let limit: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var overflow = false
    private var continuation: CheckedContinuation<Result?, Never>?

    private init(limit: Int) { self.limit = limit }

    static func load(_ url: URL, accept: String, limit: Int, timeout: TimeInterval = 10) async -> Result? {
        let loader = PreviewLoader(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: loader, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Corvus (link preview)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Result?, Never>) in
                loader.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result?) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(limit) {
            overflow = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        if data.count > limit {
            overflow = true
            dataTask.cancel()
        }
    }

    /// Never follow redirects here: the caller checks the target first.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let http = response, !overflow else { return finish(nil) }
        if error != nil && !(300..<400).contains(http.statusCode) { return finish(nil) }
        finish(Result(status: http.statusCode,
                      contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                          .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "",
                      location: http.value(forHTTPHeaderField: "Location"),
                      data: data))
    }
}

/// Generates the preview of the first link of a message: OpenGraph title / description / image, like the Qt app.
enum LinkPreviewFetcher {
    /// GET with manual, validated redirects.
    private static func get(_ start: URL, accept: String, limit: Int) async -> (PreviewLoader.Result, URL)? {
        var url = start
        for _ in 0...LinkPreviews.maxRedirects {
            guard LinkPreviews.isSafeToFetch(url), !Task.isCancelled,
                  let r = await PreviewLoader.load(url, accept: accept, limit: limit) else { return nil }
            if (300..<400).contains(r.status) {
                guard let loc = r.location, let next = URL(string: loc, relativeTo: url)?.absoluteURL else { return nil }
                url = next
                continue
            }
            return (r, url)
        }
        return nil
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// nil when the page has no usable title, is not HTML, or cannot be loaded.
    static func fetch(link: String) async -> FetchedLinkPreview? {
        guard let start = URL(string: link), LinkPreviews.isSafeToFetch(start),
              let (page, finalURL) = await get(start, accept: "text/html,application/xhtml+xml", limit: LinkPreviews.maxPageBytes),
              (200..<300).contains(page.status), ["text/html", "application/xhtml+xml"].contains(page.contentType),
              !page.data.isEmpty else { return nil }
        let meta = LinkPreviews.parseMetadata(html: decode(page.data))
        guard !meta.title.isEmpty else { return nil }

        var result = FetchedLinkPreview(preview: LinkPreview())
        result.preview.url = link
        result.preview.title = meta.title
        result.preview.description = meta.description

        if !meta.imageURL.isEmpty, let imageURL = LinkPreviews.resolveImageURL(meta.imageURL, base: finalURL),
           let (img, _) = await get(imageURL, accept: "image/png,image/jpeg,image/webp,image/gif", limit: LinkPreviews.maxImageBytes),
           (200..<300).contains(img.status), let suffix = LinkPreviews.imageSuffix(forContentType: img.contentType),
           !img.data.isEmpty, Media.pixelSize(img.data) != nil {
            var thumb = Media.makeThumbnail(img.data)
            if thumb.isEmpty { thumb = img.data }
            result.preview.imageThumb = thumb
            result.preview.imageContentType = img.contentType
            result.preview.imageSize = Int64(img.data.count)
            result.imageData = img.data
            result.imageSuffix = suffix
        }
        return result.preview.isValid ? result : nil
    }
}
