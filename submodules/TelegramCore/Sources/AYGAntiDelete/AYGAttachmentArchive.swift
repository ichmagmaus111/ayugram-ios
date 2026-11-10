import Foundation
import Postbox
import SwiftSignalKit
import Reachability

// AYG: The attachments half of "Save Deleted Messages".
//
// The source fork had an `archiveMedia` flag and nothing behind it — the archive
// there is text only. AyuGram for Android does copy the file out, into
// `Downloads/AyuGram/Saved Attachments`, bounded by a folder-size cap and by
// per-connection size limits, and the Spy screen's "Attachments Folder" and
// "MAX FOLDER SIZE" rows are that store's settings. So this file is new: it is
// the store those rows configure.
//
// What it can and cannot do. A deletion is the last moment the bytes exist
// locally; there is no way to fetch them afterwards. So this copies the file
// only when Telegram has *already* downloaded it — `MediaBox.completedResourcePath`
// returns nil otherwise and the message is archived as text alone. That is the
// honest ceiling of the feature on iOS.
public final class AttachmentArchive {
    public static let shared = AttachmentArchive()

    public static let settingsChangedNotification = Notification.Name("AYG.attachmentArchiveSettingsChanged")

    private let defaults = AYGSharedDefaults.store

    private let folderBookmarkKey = "AYG.attachments.folderBookmark"
    private let maxFolderSizeKey = "AYG.attachments.maxFolderSize"
    private let cellularLimitKey = "AYG.attachments.cellularLimit"
    private let wifiLimitKey = "AYG.attachments.wifiLimit"
    private let scopePrivateChatsKey = "AYG.attachments.scope.privateChats"
    private let scopePublicChannelsKey = "AYG.attachments.scope.publicChannels"
    private let scopePrivateChannelsKey = "AYG.attachments.scope.privateChannels"
    private let scopePublicGroupsKey = "AYG.attachments.scope.publicGroups"
    private let scopePrivateGroupsKey = "AYG.attachments.scope.privateGroups"

    /// `Int64.max` means "no limit", matching the slider's last stop.
    public static let noFolderSizeLimit: Int64 = Int64.max

    /// AyuConfig's own defaults: 16 MB on cellular, 64 MB on WiFi.
    public static let defaultCellularLimit: Int64 = 16 * 1024 * 1024
    public static let defaultWiFiLimit: Int64 = 64 * 1024 * 1024

    private let lock = NSLock()
    private var cachedNetworkType: Reachability.NetworkType = .wifi
    private var networkTypeDisposable: Disposable?

    private init() {
        // One subscription for the lifetime of the process. The archive runs on
        // the postbox queue and cannot wait on a signal there, so the last known
        // value is cached instead.
        self.networkTypeDisposable = (Reachability.networkType
        |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { [weak self] value in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.cachedNetworkType = value
            self.lock.unlock()
        })
    }

    deinit {
        self.networkTypeDisposable?.dispose()
    }

    // MARK: - Folder

    /// Default location: inside the app's own Documents. AyuGram for Android
    /// writes to shared storage; iOS has no equivalent a sandboxed app may use
    /// without the user picking it, which is exactly what the "Attachments
    /// Folder" row does.
    private static var defaultFolderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("AyuGram/Saved Attachments", isDirectory: true)
    }

    /// Remember a folder the user picked in the document picker. Stored as a
    /// bookmark, not a path: the picked URL is security-scoped and its path is
    /// meaningless to us on the next launch.
    public func setFolder(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            self.defaults.set(bookmark, forKey: self.folderBookmarkKey)
        } else {
            self.defaults.removeObject(forKey: self.folderBookmarkKey)
        }
        NotificationCenter.default.post(name: AttachmentArchive.settingsChangedNotification, object: nil)
    }

    public func resetFolder() {
        self.defaults.removeObject(forKey: self.folderBookmarkKey)
        NotificationCenter.default.post(name: AttachmentArchive.settingsChangedNotification, object: nil)
    }

    /// The resolved destination, plus whether the caller has to balance a
    /// `startAccessingSecurityScopedResource`. A stale or unresolvable bookmark
    /// silently falls back to the in-sandbox default — losing an attachment is
    /// worse than writing it somewhere less convenient.
    private func resolvedFolder() -> (url: URL, isSecurityScoped: Bool) {
        guard let bookmark = self.defaults.data(forKey: self.folderBookmarkKey) else {
            return (AttachmentArchive.defaultFolderURL, false)
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale), !isStale else {
            return (AttachmentArchive.defaultFolderURL, false)
        }
        return (url, true)
    }

    /// Name shown on the "Attachments Folder" row.
    public var folderName: String {
        let resolved = self.resolvedFolder()
        let name = resolved.url.lastPathComponent
        return name.isEmpty ? aygString("AYGSavedAttachmentsFolder") : name
    }

    // MARK: - Limits

    public var maxFolderSize: Int64 {
        get {
            guard let value = self.defaults.object(forKey: self.maxFolderSizeKey) as? NSNumber else {
                return AttachmentArchive.noFolderSizeLimit
            }
            return value.int64Value
        }
        set {
            self.defaults.set(NSNumber(value: newValue), forKey: self.maxFolderSizeKey)
            NotificationCenter.default.post(name: AttachmentArchive.settingsChangedNotification, object: nil)
        }
    }

    public var cellularLimit: Int64 {
        get {
            guard let value = self.defaults.object(forKey: self.cellularLimitKey) as? NSNumber else {
                return AttachmentArchive.defaultCellularLimit
            }
            return value.int64Value
        }
        set { self.defaults.set(NSNumber(value: newValue), forKey: self.cellularLimitKey) }
    }

    public var wifiLimit: Int64 {
        get {
            guard let value = self.defaults.object(forKey: self.wifiLimitKey) as? NSNumber else {
                return AttachmentArchive.defaultWiFiLimit
            }
            return value.int64Value
        }
        set { self.defaults.set(NSNumber(value: newValue), forKey: self.wifiLimitKey) }
    }

    /// Largest file we will copy right now. On an unknown/absent connection we
    /// use the WiFi ceiling: nothing is being downloaded here — the bytes are
    /// already on disk — so the stricter cellular budget has nothing to protect.
    private var currentFileSizeLimit: Int64 {
        self.lock.lock()
        let networkType = self.cachedNetworkType
        self.lock.unlock()
        switch networkType {
        case .cellular:
            return self.cellularLimit
        case .wifi, .none:
            return self.wifiLimit
        }
    }

    // MARK: - Scopes

    private func scope(_ key: String, default defaultValue: Bool) -> Bool {
        if self.defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return self.defaults.bool(forKey: key)
    }

    // Defaults are AyuConfig's: private chats/channels/groups on, public off.
    public var saveInPrivateChats: Bool {
        get { return self.scope(self.scopePrivateChatsKey, default: true) }
        set { self.defaults.set(newValue, forKey: self.scopePrivateChatsKey) }
    }

    public var saveInPublicChannels: Bool {
        get { return self.scope(self.scopePublicChannelsKey, default: false) }
        set { self.defaults.set(newValue, forKey: self.scopePublicChannelsKey) }
    }

    public var saveInPrivateChannels: Bool {
        get { return self.scope(self.scopePrivateChannelsKey, default: true) }
        set { self.defaults.set(newValue, forKey: self.scopePrivateChannelsKey) }
    }

    public var saveInPublicGroups: Bool {
        get { return self.scope(self.scopePublicGroupsKey, default: false) }
        set { self.defaults.set(newValue, forKey: self.scopePublicGroupsKey) }
    }

    public var saveInPrivateGroups: Bool {
        get { return self.scope(self.scopePrivateGroupsKey, default: true) }
        set { self.defaults.set(newValue, forKey: self.scopePrivateGroupsKey) }
    }

    private func isScopeEnabled(for peer: Peer?) -> Bool {
        if let channel = peer as? TelegramChannel {
            let isPublic = channel.addressName != nil && !(channel.addressName ?? "").isEmpty
            switch channel.info {
            case .broadcast:
                return isPublic ? self.saveInPublicChannels : self.saveInPrivateChannels
            case .group:
                return isPublic ? self.saveInPublicGroups : self.saveInPrivateGroups
            }
        }
        if peer is TelegramGroup {
            // A basic group has no username, so it is a private group.
            return self.saveInPrivateGroups
        }
        // Users, bots and secret chats all count as private chats.
        return self.saveInPrivateChats
    }

    // MARK: - Capture

    /// Serialises every write to the attachments folder, and keeps them off the
    /// caller's thread. `archiveMedia` is called from inside a postbox
    /// transaction: a "delete for everyone" of thirty photos would otherwise
    /// copy thirty files, and re-walk the folder thirty times to trim it, on the
    /// postbox queue while the rest of the app waits on it.
    private let writeQueue = DispatchQueue(label: "org.ayugram.AttachmentArchive.write", qos: .utility)

    /// Copy the message's already-downloaded media into the attachments folder.
    /// Returns the name the file will have, or nil when there is nothing to
    /// copy. Only path resolution happens on the caller's thread; the copy
    /// itself is queued. A queued copy that later fails leaves an archive entry
    /// naming a file that is not there, which readers must tolerate anyway —
    /// the folder is user-visible and its contents can be deleted at any time.
    public func archiveMedia(for message: Message, mediaBox: MediaBox) -> String? {
        guard AntiDeleteManager.shared.archiveMedia else {
            return nil
        }
        guard self.isScopeEnabled(for: message.peers[message.id.peerId]) else {
            return nil
        }
        guard let source = AttachmentArchive.sourceFile(for: message, mediaBox: mediaBox) else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0, fileSize <= self.currentFileSizeLimit else {
            return nil
        }

        let fileName = "\(message.id.peerId.toInt64())_\(message.id.id)_\(source.suggestedName)"
        let sourcePath = source.path
        self.writeQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            let resolved = self.resolvedFolder()
            let didStart = resolved.isSecurityScoped ? resolved.url.startAccessingSecurityScopedResource() : false
            defer {
                if didStart {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
            }

            let destination = resolved.url.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: resolved.url, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    return
                }
                try FileManager.default.copyItem(atPath: sourcePath, toPath: destination.path)
            } catch {
                Logger.shared.log("AYGAttachments", "copy failed: \(error)")
                return
            }
            self.trimToLimit(folder: resolved.url)
        }
        return fileName
    }

    private struct SourceFile {
        let path: String
        let suggestedName: String
    }

    /// The single most interesting downloaded file on the message. Photos
    /// resolve to their largest representation; documents/videos/voice to the
    /// file itself. Thumbnails are deliberately not archived on their own.
    private static func sourceFile(for message: Message, mediaBox: MediaBox) -> SourceFile? {
        for media in message.media {
            if let file = media as? TelegramMediaFile {
                if let path = mediaBox.completedResourcePath(file.resource) {
                    let name = file.fileName ?? "file-\(file.fileId.id)\(AttachmentArchive.pathExtension(for: file))"
                    return SourceFile(path: path, suggestedName: name)
                }
            } else if let image = media as? TelegramMediaImage {
                if let representation = image.representations.last, let path = mediaBox.completedResourcePath(representation.resource) {
                    return SourceFile(path: path, suggestedName: "photo-\(image.imageId.id).jpg")
                }
            }
        }
        return nil
    }

    private static func pathExtension(for file: TelegramMediaFile) -> String {
        if file.isVideo {
            return ".mp4"
        } else if file.isVoice {
            return ".ogg"
        } else if file.isSticker {
            return ".webp"
        }
        return ""
    }

    // MARK: - Housekeeping

    /// Total bytes in the attachments folder, for the "Clear" sheet's label.
    public func folderSize() -> Int64 {
        let resolved = self.resolvedFolder()
        let didStart = resolved.isSecurityScoped ? resolved.url.startAccessingSecurityScopedResource() : false
        defer {
            if didStart {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        return AttachmentArchive.contents(of: resolved.url).reduce(Int64(0)) { $0 + $1.size }
    }

    /// Runs on the same queue as the copies, so a clear can never interleave
    /// with an attachment still being written. `completion` lands on the main
    /// queue, for a screen that wants to re-measure the folder afterwards.
    public func clear(completion: (() -> Void)? = nil) {
        self.writeQueue.async {
            let resolved = self.resolvedFolder()
            let didStart = resolved.isSecurityScoped ? resolved.url.startAccessingSecurityScopedResource() : false
            for entry in AttachmentArchive.contents(of: resolved.url) {
                try? FileManager.default.removeItem(at: entry.url)
            }
            if didStart {
                resolved.url.stopAccessingSecurityScopedResource()
            }
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    /// Drop the oldest files until the folder fits under `maxFolderSize` — the
    /// behaviour the "MAX FOLDER SIZE" footer describes.
    private func trimToLimit(folder: URL) {
        let limit = self.maxFolderSize
        guard limit != AttachmentArchive.noFolderSizeLimit, limit > 0 else {
            return
        }
        var entries = AttachmentArchive.contents(of: folder)
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else {
            return
        }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            if total <= limit {
                break
            }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    private struct FolderEntry {
        let url: URL
        let size: Int64
        let date: Date
    }

    private static func contents(of folder: URL) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [FolderEntry] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            result.append(FolderEntry(url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? Date.distantPast))
        }
        return result
    }
}
