import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle
import MergeLists
import UndoUI

// AYG: Spy. A one-for-one port of AyuGram for Android's
// `SpyPreferencesActivity.fillItems` — same rows, same order, same copy, same
// icons. Every Android shadow (`UItem.asShadow()`) becomes a new iOS section, so
// the eight blocks below match the eight blocks Android draws.
//
// The screen holds no state of its own. Every row reads and writes the real
// managers in TelegramCore — `AntiDeleteManager` (capture), `EditHistoryManager`
// (pre-edit text), `AttachmentArchive` (the attachments folder and its limits)
// and `SpyDataStore` (read dates and last-seen) — so a toggle here changes what
// the client actually does with the next deletion, and survives the screen.

// MARK: - Copy
//
// Strings are AyuGram for Android's own English text (docs/AYGAndroidStrings.xml);
// the Android key is named next to each one. Three of them (`Clear`, `NoLimit`,
// `AutodownloadSizeLimitUpTo`) are Telegram-Android strings rather than AyuGram
// ones — the last has an exact iOS counterpart and is read from `strings`.

private var aygSpyEssentialsHeader: String { aygString("SpyEssentialsHeader") }
private var aygSpySaveDeletedMessages: String { aygString("SaveDeletedMessages") }
private var aygSpySaveMessagesHistory: String { aygString("SaveMessagesHistory") }
private var aygSpySaveForBots: String { aygString("MessageSavingSaveForBots") }
private var aygSpySaveReadMarks: String { aygString("SpySaveReadMarks") }
private var aygSpySaveReadMarksDescription: String { aygString("SpySaveReadMarksDescription") }
private var aygSpySaveLocalOnline: String { aygString("SpySaveLocalOnline") }
private var aygSpySaveLocalOnlineDescription: String { aygString("SpySaveLocalOnlineDescription") }
private var aygSpySaveMedia: String { aygString("MessageSavingSaveMedia") }
private var aygSpySaveMediaHint: String { aygString("MessageSavingSaveMediaHint") }
private var aygSpySavePath: String { aygString("MessageSavingSavePath") }
private var aygSpySavePathTitle: String { aygString("MessageSavingSavePathTitle") }
private var aygSpyMaxSizeHeader: String { aygString("AttachmentsFolderMaxSizeHeader") }
private var aygSpyMaxSizeDescription: String { aygString("AttachmentsFolderMaxSizeDescription") }
private var aygSpyExportDatabase: String { aygString("ExportDatabaseButton") }
private var aygSpyImportDatabase: String { aygString("ImportDatabaseButton") }
private var aygSpyClear: String { aygString("AYGSpyClearButton") }
private var aygSpyNoLimit: String { aygString("AYGSpyNoLimit") }

// The five chat kinds in the Save Attachments sheet.
// Computed, not a stored `let`: a global `let` is evaluated once and cached, so it
// would keep the language the app happened to launch in.
private var aygSpyMediaScopeTitles: [String] {
    return [
        aygString("MessageSavingSaveMediaInPrivateChats"),
        aygString("MessageSavingSaveMediaInPublicChannels"),
        aygString("MessageSavingSaveMediaInPrivateChannels"),
        aygString("MessageSavingSaveMediaInPublicGroups"),
        aygString("MessageSavingSaveMediaInPrivateGroups")
    ]
}

private var aygSpyMaximumMediaSizeCellular: String { aygString("MaximumMediaSizeCellular") }
private var aygSpyMaximumMediaSizeWiFi: String { aygString("MaximumMediaSizeWiFi") }

private var aygSpyExportDataTitle: String { aygString("ExportDataTitle") }
// AyuGram's own ExportDataDescription is "Pick a compatibility version, then
// choose where to save the exported database." The compatibility picker is
// gone — see `openExportDatabase` — so the sentence describing it is too.
private var aygSpyExportDataDescription: String { aygString("AYGSpyExportDescription") }
private var aygSpyExportDataConfirm: String { aygString("ExportDataConfirm") }
private var aygSpyExportDataCancel: String { aygString("ExportDataCancel") }
private var aygSpyExportDataSuccess: String { aygString("ExportDataSuccess") }
private var aygSpyExportDataFailure: String { aygString("ExportDataFailure") }
private var aygSpyImportDataTitle: String { aygString("ImportDataTitle") }
private var aygSpyImportDataDescription: String { aygString("ImportDataDescription") }
private var aygSpyImportDataConfirm: String { aygString("ImportDataConfirm") }
private var aygSpyImportDataCancel: String { aygString("ImportDataCancel") }
private var aygSpyImportDataFailure: String { aygString("ImportDataFailure") }
private var aygSpyImportModeReplace: String { aygString("ImportModeReplace") }
private var aygSpyImportModeMerge: String { aygString("ImportModeMerge") }

private var aygSpyClearAttachments: String { aygString("AyuAttachments") }
private var aygSpyClearDatabase: String { aygString("AyuDatabase") }
private var aygSpyClearTelegramDatabase: String { aygString("TelegramCacheDatabase") }
private var aygSpyClearDone: String { aygString("AyuForwardStatusFinished") }

// The two files an export writes. Import recognises which is which by the
// script id embedded in the HTML, so the names are cosmetic.
private let aygSpyExportArchiveFileName = "AyuGram Deleted Messages.html"
private let aygSpyExportHistoryFileName = "AyuGram Edit History.html"
private let aygSpyEditHistoryMarker = "ayugram-edit-history"

// MARK: - Max folder size

// `SpyPreferencesActivity.getOptions()`: 300 MB, 1 GB and 2 GB always, then 5 GB
// and 16 GB only on devices big enough for them, then "no limit". Android draws
// them as a `SlideChooseView` (`UItem.asSlideView`) — one stop per option, the
// label under each stop — which is what `AYGSlideChooseItem` is.
private enum AYGSpyMaxFolderSize: Equatable {
    case megabytes300
    case gigabytes(Int)
    case noLimit

    var title: String {
        switch self {
        case .megabytes300:
            return aygString("AYGSizeMegabytes", 300)
        case let .gigabytes(value):
            return aygString("AYGSizeGigabytes", value)
        case .noLimit:
            return aygSpyNoLimit
        }
    }

    /// What `AttachmentArchive` stores. Android keeps an opaque int here; a byte
    /// count is what the store actually needs to trim against.
    var byteValue: Int64 {
        switch self {
        case .megabytes300:
            return 300 * 1024 * 1024
        case let .gigabytes(value):
            return Int64(value) * 1024 * 1024 * 1024
        case .noLimit:
            return AttachmentArchive.noFolderSizeLimit
        }
    }

    static func from(byteValue: Int64) -> AYGSpyMaxFolderSize {
        if byteValue >= AttachmentArchive.noFolderSizeLimit {
            return .noLimit
        }
        if byteValue == 300 * 1024 * 1024 {
            return .megabytes300
        }
        return .gigabytes(Int(byteValue / (1024 * 1024 * 1024)))
    }
}

// Android reads the storage volume with StatFs and divides down to "GB":
// `((int) ((total / 1024) / 1024)) / 1000f`. Mirrored exactly, including the
// megabytes-over-1000 definition of a gigabyte.
private func aygSpyMaxFolderSizeOptions() -> [AYGSpyMaxFolderSize] {
    var totalGigabytes: Double = 0.0
    if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey]), let totalBytes = values.volumeTotalCapacity {
        totalGigabytes = Double(Int64(totalBytes) / 1024 / 1024) / 1000.0
    }
    var options: [AYGSpyMaxFolderSize] = [.megabytes300, .gigabytes(1), .gigabytes(2)]
    if totalGigabytes > 5.0 {
        options.append(.gigabytes(5))
    }
    if totalGigabytes > 16.0 {
        options.append(.gigabytes(16))
    }
    options.append(.noLimit)
    return options
}

// The per-connection media limits are a continuous SeekBar on Android
// (`MaxFileSizeCell`, 500 KB … 2 GB). `AYGMaxFileSizeItem` is that seekbar, with
// the same four-quarter byte curve; see its own file for the anchors.

// MARK: - State

// A read-through snapshot of the managers, not a source of truth: every mutation
// goes to the manager first and the snapshot is rebuilt from it afterwards, so
// the screen can never drift from what the capture engine will actually do.
private struct AYGSpyState: Equatable {
    var saveDeletedMessages: Bool
    var saveMessagesHistory: Bool
    var saveForBots: Bool
    var saveReadDate: Bool
    var saveLocalOnline: Bool
    var saveMedia: Bool

    var savePathFolder: String
    var maxFolderSize: AYGSpyMaxFolderSize

    // The Save Attachments sheet.
    var saveMediaInPrivateChats: Bool
    var saveMediaInPublicChannels: Bool
    var saveMediaInPrivateChannels: Bool
    var saveMediaInPublicGroups: Bool
    var saveMediaInPrivateGroups: Bool
    var cellularLimit: Int64
    var wifiLimit: Int64

    // The Clear sheet. Android persists the checkbox states as `clearToggled_N`,
    // so unlike the export/import choices they survive the sheet being closed.
    var clearAttachments: Bool
    var clearDatabase: Bool
    var clearTelegramDatabase: Bool

    /// nil while the folder is still being measured — Android shows an ellipsis
    /// for exactly this window.
    var attachmentsSize: Int64?
    var databaseSize: Int64

    var mediaScopes: [Bool] {
        return [
            self.saveMediaInPrivateChats,
            self.saveMediaInPublicChannels,
            self.saveMediaInPrivateChannels,
            self.saveMediaInPublicGroups,
            self.saveMediaInPrivateGroups
        ]
    }

    mutating func setMediaScope(_ index: Int, _ value: Bool) {
        switch index {
        case 0: self.saveMediaInPrivateChats = value
        case 1: self.saveMediaInPublicChannels = value
        case 2: self.saveMediaInPrivateChannels = value
        case 3: self.saveMediaInPublicGroups = value
        default: self.saveMediaInPrivateGroups = value
        }
    }

    var clearSelections: [Bool] {
        return [self.clearAttachments, self.clearDatabase, self.clearTelegramDatabase]
    }

    mutating func setClearSelection(_ index: Int, _ value: Bool) {
        switch index {
        case 0: self.clearAttachments = value
        case 1: self.clearDatabase = value
        default: self.clearTelegramDatabase = value
        }
    }
}

// The Clear checkboxes are the only rows Android persists on its own; nothing in
// TelegramCore has an opinion about them, so they stay in UserDefaults here.
private let aygSpyClearSelectionKeys = [
    "AYG.spy.clearToggled.attachments",
    "AYG.spy.clearToggled.database",
    "AYG.spy.clearToggled.telegramDatabase"
]

private func aygSpyReadState(attachmentsSize: Int64?) -> AYGSpyState {
    let antiDelete = AntiDeleteManager.shared
    let attachments = AttachmentArchive.shared
    let spyData = SpyDataStore.shared
    let defaults = AYGSharedDefaults.store
    return AYGSpyState(
        saveDeletedMessages: antiDelete.isEnabled,
        saveMessagesHistory: antiDelete.displayEditedMessages,
        saveForBots: antiDelete.saveInBotDialogs,
        saveReadDate: spyData.saveReadDate,
        saveLocalOnline: spyData.saveLastSeenDate,
        saveMedia: antiDelete.archiveMedia,
        savePathFolder: attachments.folderName,
        maxFolderSize: AYGSpyMaxFolderSize.from(byteValue: attachments.maxFolderSize),
        saveMediaInPrivateChats: attachments.saveInPrivateChats,
        saveMediaInPublicChannels: attachments.saveInPublicChannels,
        saveMediaInPrivateChannels: attachments.saveInPrivateChannels,
        saveMediaInPublicGroups: attachments.saveInPublicGroups,
        saveMediaInPrivateGroups: attachments.saveInPrivateGroups,
        cellularLimit: attachments.cellularLimit,
        wifiLimit: attachments.wifiLimit,
        clearAttachments: defaults.bool(forKey: aygSpyClearSelectionKeys[0]),
        clearDatabase: defaults.bool(forKey: aygSpyClearSelectionKeys[1]),
        clearTelegramDatabase: defaults.bool(forKey: aygSpyClearSelectionKeys[2]),
        attachmentsSize: attachmentsSize,
        databaseSize: AntiDeleteManager.databaseStorageSize()
    )
}

// MARK: - Sections

private enum AYGSpySection: Int32 {
    case essentials
    case bots
    case readDate
    case lastSeen
    case attachments
    case maxSize
    case database
    case clear
}

// MARK: - Arguments

private final class AYGSpyArguments {
    let toggleSaveDeletedMessages: (Bool) -> Void
    let toggleSaveMessagesHistory: (Bool) -> Void
    let toggleSaveForBots: (Bool) -> Void
    let toggleSaveReadDate: (Bool) -> Void
    let toggleSaveLocalOnline: (Bool) -> Void
    let toggleSaveMedia: (Bool) -> Void
    let openMediaSaving: () -> Void
    let openSavePath: () -> Void
    let selectMaxFolderSize: (Int) -> Void
    let openExportDatabase: () -> Void
    let openImportDatabase: () -> Void
    let openClear: () -> Void

    init(
        toggleSaveDeletedMessages: @escaping (Bool) -> Void,
        toggleSaveMessagesHistory: @escaping (Bool) -> Void,
        toggleSaveForBots: @escaping (Bool) -> Void,
        toggleSaveReadDate: @escaping (Bool) -> Void,
        toggleSaveLocalOnline: @escaping (Bool) -> Void,
        toggleSaveMedia: @escaping (Bool) -> Void,
        openMediaSaving: @escaping () -> Void,
        openSavePath: @escaping () -> Void,
        selectMaxFolderSize: @escaping (Int) -> Void,
        openExportDatabase: @escaping () -> Void,
        openImportDatabase: @escaping () -> Void,
        openClear: @escaping () -> Void
    ) {
        self.toggleSaveDeletedMessages = toggleSaveDeletedMessages
        self.toggleSaveMessagesHistory = toggleSaveMessagesHistory
        self.toggleSaveForBots = toggleSaveForBots
        self.toggleSaveReadDate = toggleSaveReadDate
        self.toggleSaveLocalOnline = toggleSaveLocalOnline
        self.toggleSaveMedia = toggleSaveMedia
        self.openMediaSaving = openMediaSaving
        self.openSavePath = openSavePath
        self.selectMaxFolderSize = selectMaxFolderSize
        self.openExportDatabase = openExportDatabase
        self.openImportDatabase = openImportDatabase
        self.openClear = openClear
    }
}

// AYG: the three drawables pulled out of the APK for this screen —
// msg_unarchive, msg_archive and msg_clear. Tinted the way Android tints them.
private func aygSpyIcon(_ name: String, theme: PresentationTheme) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: "AyuGram/\(name)"), color: theme.list.itemSecondaryTextColor)
}

private func aygSpySizeString(_ size: Int64, presentationData: PresentationData) -> String {
    let strings = presentationData.strings
    let formatting = DataSizeStringFormatting(decimalSeparator: presentationData.dateTimeFormat.decimalSeparator, byte: strings.FileSize_B(_:), kilobyte: strings.FileSize_KB(_:), megabyte: strings.FileSize_MB(_:), gigabyte: strings.FileSize_GB(_:))
    return dataSizeString(size, formatting: formatting)
}

// MARK: - Entries

private enum AYGSpyEntry: ItemListNodeEntry {
    case essentialsHeader(String)
    case saveDeleted(Bool)
    case saveHistory(Bool)
    case saveForBots(Bool)
    case saveReadDate(Bool)
    case saveReadDateFooter(String)
    case saveLocalOnline(Bool)
    case saveLocalOnlineFooter(String)
    case saveMedia(Bool)
    case savePath(String)
    case maxSizeHeader(String)
    case maxSizeSlider([String], Int)
    case maxSizeFooter(String)
    case exportDatabase
    case importDatabase
    case clear

    var section: ItemListSectionId {
        switch self {
        case .essentialsHeader, .saveDeleted, .saveHistory:
            return AYGSpySection.essentials.rawValue
        case .saveForBots:
            return AYGSpySection.bots.rawValue
        case .saveReadDate, .saveReadDateFooter:
            return AYGSpySection.readDate.rawValue
        case .saveLocalOnline, .saveLocalOnlineFooter:
            return AYGSpySection.lastSeen.rawValue
        case .saveMedia, .savePath:
            return AYGSpySection.attachments.rawValue
        case .maxSizeHeader, .maxSizeSlider, .maxSizeFooter:
            return AYGSpySection.maxSize.rawValue
        case .exportDatabase, .importDatabase:
            return AYGSpySection.database.rawValue
        case .clear:
            return AYGSpySection.clear.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .essentialsHeader: return 0
        case .saveDeleted: return 1
        case .saveHistory: return 2
        case .saveForBots: return 3
        case .saveReadDate: return 4
        case .saveReadDateFooter: return 5
        case .saveLocalOnline: return 6
        case .saveLocalOnlineFooter: return 7
        case .saveMedia: return 8
        case .savePath: return 9
        case .maxSizeHeader: return 10
        case .maxSizeSlider: return 11
        case .maxSizeFooter: return 12
        case .exportDatabase: return 13
        case .importDatabase: return 14
        case .clear: return 15
        }
    }

    static func <(lhs: AYGSpyEntry, rhs: AYGSpyEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGSpyArguments
        switch self {
        case let .essentialsHeader(text), let .maxSizeHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .saveDeleted(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveDeletedMessages, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveDeletedMessages(value)
            })
        case let .saveHistory(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveMessagesHistory, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveMessagesHistory(value)
            })
        case let .saveForBots(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveForBots, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveForBots(value)
            })
        case let .saveReadDate(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveReadMarks, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveReadDate(value)
            })
        case let .saveLocalOnline(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveLocalOnline, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveLocalOnline(value)
            })
        case let .saveMedia(value):
            // Android splits this row: the right 76dp toggles the switch, the rest
            // opens the sheet — and only while the switch is on.
            var openSheet: (() -> Void)?
            if value {
                openSheet = {
                    arguments.openMediaSaving()
                }
            }
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySaveMedia, text: aygSpySaveMediaHint, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSaveMedia(value)
            }, action: openSheet)
        case let .savePath(folder):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: aygSpySavePath, label: folder, labelStyle: .coloredText(presentationData.theme.list.itemAccentColor), sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openSavePath()
            })
        case let .maxSizeSlider(titles, index):
            return AYGSlideChooseItem(theme: presentationData.theme, systemStyle: .glass, titles: titles, value: index, sectionId: self.section, updated: { index in
                arguments.selectMaxFolderSize(index)
            })
        case let .saveReadDateFooter(text), let .maxSizeFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .saveLocalOnlineFooter(text):
            // Android runs this one through AndroidUtilities.replaceTags, which is
            // what makes "very approximately" bold.
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .exportDatabase:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: aygSpyIcon("AYGSpyExport", theme: presentationData.theme), title: aygSpyExportDatabase, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openExportDatabase()
            })
        case .importDatabase:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: aygSpyIcon("AYGSpyImport", theme: presentationData.theme), title: aygSpyImportDatabase, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openImportDatabase()
            })
        case .clear:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: aygSpyIcon("AYGSpyClear", theme: presentationData.theme), title: aygSpyClear, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openClear()
            })
        }
    }
}

private func aygSpyEntries(state: AYGSpyState, maxFolderSizeOptions: [AYGSpyMaxFolderSize]) -> [AYGSpyEntry] {
    var entries: [AYGSpyEntry] = []
    entries.append(.essentialsHeader(aygSpyEssentialsHeader))
    entries.append(.saveDeleted(state.saveDeletedMessages))
    entries.append(.saveHistory(state.saveMessagesHistory))
    entries.append(.saveForBots(state.saveForBots))
    entries.append(.saveReadDate(state.saveReadDate))
    entries.append(.saveReadDateFooter(aygSpySaveReadMarksDescription))
    entries.append(.saveLocalOnline(state.saveLocalOnline))
    entries.append(.saveLocalOnlineFooter(aygSpySaveLocalOnlineDescription))
    entries.append(.saveMedia(state.saveMedia))
    entries.append(.savePath(state.savePathFolder))
    entries.append(.maxSizeHeader(aygSpyMaxSizeHeader))
    // `getInitialMaxSizeIndex()`: a value that is not one of the stops falls back
    // to the last one, which is "no limit".
    let selectedIndex = maxFolderSizeOptions.firstIndex(of: state.maxFolderSize) ?? max(0, maxFolderSizeOptions.count - 1)
    entries.append(.maxSizeSlider(maxFolderSizeOptions.map { $0.title }, selectedIndex))
    entries.append(.maxSizeFooter(aygSpyMaxSizeDescription))
    entries.append(.exportDatabase)
    entries.append(.importDatabase)
    entries.append(.clear)
    return entries
}

// MARK: - Document pickers

// The picker holds its delegate weakly, so the delegate keeps itself alive until
// one of the two callbacks fires.
private final class AYGSpyDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var lifetime: AYGSpyDocumentPickerDelegate?

    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
        super.init()
        self.lifetime = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completion(urls)
        self.lifetime = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.lifetime = nil
    }
}

// MARK: - Controller

// AYG: the Spy category screen.
public func aygSpyController(context: AccountContext) -> ViewController {
    // Computed once: Android reads the volume size in onFragmentCreate.
    let maxFolderSizeOptions = aygSpyMaxFolderSizeOptions()

    let statePromise = ValuePromise(aygSpyReadState(attachmentsSize: nil), ignoreRepeated: true)
    let attachmentsSizeValue = Atomic<Int64?>(value: nil)
    let refreshState: () -> Void = {
        statePromise.set(aygSpyReadState(attachmentsSize: attachmentsSizeValue.with { $0 }))
    }
    // `calculateAttachmentsSize()` — Android walks the folder off the main thread
    // and refreshes the Clear sheet's label when it lands.
    let measureAttachments: () -> Void = {
        Queue.concurrentDefaultQueue().async {
            let size = AttachmentArchive.shared.folderSize()
            Queue.mainQueue().async {
                let _ = attachmentsSizeValue.swap(size)
                refreshState()
            }
        }
    }
    measureAttachments()

    var presentControllerImpl: ((ViewController) -> Void)?
    var presentNativeControllerImpl: ((UIViewController) -> Void)?
    var presentBulletinImpl: ((UndoOverlayContent) -> Void)?

    let clearDisposable = MetaDisposable()

    let arguments = AYGSpyArguments(toggleSaveDeletedMessages: { value in
        AntiDeleteManager.shared.isEnabled = value
        refreshState()
    }, toggleSaveMessagesHistory: { value in
        AntiDeleteManager.shared.displayEditedMessages = value
        refreshState()
    }, toggleSaveForBots: { value in
        AntiDeleteManager.shared.saveInBotDialogs = value
        refreshState()
    }, toggleSaveReadDate: { value in
        SpyDataStore.shared.saveReadDate = value
        refreshState()
    }, toggleSaveLocalOnline: { value in
        SpyDataStore.shared.saveLastSeenDate = value
        refreshState()
    }, toggleSaveMedia: { value in
        AntiDeleteManager.shared.archiveMedia = value
        refreshState()
    }, openMediaSaving: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)

        // Android's bottom sheet edits a draft and only writes it back on Save.
        var draft = aygSpyReadState(attachmentsSize: attachmentsSizeValue.with { $0 })

        // A row that rebuilds itself on tap has to reach its own builder, so the
        // builder is a local the closure captures. `dismissed` clears it —
        // without that the mutual capture keeps the whole graph alive forever.
        var makeScopeItem: ((Int) -> ActionSheetItem)?
        actionSheet.dismissed = { _ in
            makeScopeItem = nil
        }

        // Group 0 is: header, five scopes, two limits, Save.
        let scopeOffset = 1

        makeScopeItem = { [weak actionSheet] index in
            return ActionSheetCheckboxItem(title: aygSpyMediaScopeTitles[index], label: "", value: draft.mediaScopes[index], action: { [weak actionSheet] _ in
                draft.setMediaScope(index, !draft.mediaScopes[index])
                if let item = makeScopeItem?(index) {
                    actionSheet?.updateItem(groupIndex: 0, itemIndex: scopeOffset + index, { _ in item })
                }
            })
        }
        // Android's two MaxFileSizeCells. The slider redraws its own "up to"
        // label while it is being dragged, so unlike the checkbox rows above it
        // never needs the sheet to rebuild it.
        let makeLimitItem: (Int) -> ActionSheetItem = { index in
            let title = index == 0 ? aygSpyMaximumMediaSizeCellular : aygSpyMaximumMediaSizeWiFi
            let value = index == 0 ? draft.cellularLimit : draft.wifiLimit
            return AYGMaxFileSizeItem(theme: presentationData.theme, strings: presentationData.strings, decimalSeparator: presentationData.dateTimeFormat.decimalSeparator, title: title, value: value, updated: { value in
                if index == 0 {
                    draft.cellularLimit = value
                } else {
                    draft.wifiLimit = value
                }
            })
        }

        var items: [ActionSheetItem] = [ActionSheetTextItem(title: aygSpySaveMedia)]
        for index in 0 ..< aygSpyMediaScopeTitles.count {
            if let item = makeScopeItem?(index) {
                items.append(item)
            }
        }
        items.append(makeLimitItem(0))
        items.append(makeLimitItem(1))
        items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Save, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let committed = draft
            let attachments = AttachmentArchive.shared
            attachments.saveInPrivateChats = committed.saveMediaInPrivateChats
            attachments.saveInPublicChannels = committed.saveMediaInPublicChannels
            attachments.saveInPrivateChannels = committed.saveMediaInPrivateChannels
            attachments.saveInPublicGroups = committed.saveMediaInPublicGroups
            attachments.saveInPrivateGroups = committed.saveMediaInPrivateGroups
            attachments.cellularLimit = committed.cellularLimit
            attachments.wifiLimit = committed.wifiLimit
            refreshState()
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, openSavePath: {
        // Android opens ACTION_OPEN_DOCUMENT_TREE. The iOS counterpart is a
        // folder-scoped picker; the chosen folder is kept as a security-scoped
        // bookmark by AttachmentArchive, which is what makes writing there
        // possible on the next launch.
        if #available(iOS 14.0, *) {
            let delegate = AYGSpyDocumentPickerDelegate(completion: { urls in
                guard let url = urls.first else {
                    return
                }
                AttachmentArchive.shared.setFolder(url)
                refreshState()
                measureAttachments()
            })
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
            picker.delegate = delegate
            picker.allowsMultipleSelection = false
            picker.title = aygSpySavePathTitle
            presentNativeControllerImpl?(picker)
        } else {
            presentBulletinImpl?(.info(title: nil, text: aygString("AYGSpyFolderPickerUnavailable"), timeout: nil, customUndoText: nil))
        }
    }, selectMaxFolderSize: { index in
        guard index >= 0 && index < maxFolderSizeOptions.count else {
            return
        }
        AttachmentArchive.shared.maxFolderSize = maxFolderSizeOptions[index].byteValue
        refreshState()
    }, openExportDatabase: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)

        // AyuGram's sheet offers a compatibility version here, which selects the
        // SQLite schema `AyuData.exportToTemp` writes so older AyuGram builds can
        // read the file. This fork's archive is not that database — it is JSON
        // wrapped in a readable HTML page, with one format and no older readers —
        // so there is nothing for a version list to choose between, and offering
        // one would be a control that does nothing.
        let archiveCount = AntiDeleteManager.shared.archivedCount
        let historyCount = EditHistoryManager.shared.archivedCount
        let summary = aygString("AYGSpyExportSummary", aygPluralString("AYGDeletedMessagesCount", archiveCount), aygPluralString("AYGEditedMessagesCount", historyCount))

        let items: [ActionSheetItem] = [
            ActionSheetTextItem(title: "**\(aygSpyExportDataTitle)**\n\(aygSpyExportDataDescription)"),
            ActionSheetTextItem(title: summary),
            ActionSheetButtonItem(title: aygSpyExportDataConfirm, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()

                guard let archiveData = AntiDeleteManager.shared.exportArchiveData(), let historyData = EditHistoryManager.shared.exportHistoryData() else {
                    presentBulletinImpl?(.info(title: nil, text: aygSpyExportDataFailure, timeout: nil, customUndoText: nil))
                    return
                }
                // The picker needs files on disk. They land in a per-export temp
                // directory so two exports cannot collide.
                let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AYGSpyExport-\(UUID().uuidString)", isDirectory: true)
                let archiveURL = directory.appendingPathComponent(aygSpyExportArchiveFileName)
                let historyURL = directory.appendingPathComponent(aygSpyExportHistoryFileName)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try archiveData.write(to: archiveURL, options: .atomic)
                    try historyData.write(to: historyURL, options: .atomic)
                } catch {
                    presentBulletinImpl?(.info(title: nil, text: aygSpyExportDataFailure, timeout: nil, customUndoText: nil))
                    return
                }

                // A share sheet rather than a document picker: the picker's
                // `forExporting:` initialiser is iOS 14+, and its iOS 13
                // predecessor is deprecated — which `-warnings-as-errors` will
                // not have. The share sheet offers Save to Files (Android's
                // "choose location") plus everything else, on every version.
                let activityController = UIActivityViewController(activityItems: [archiveURL, historyURL], applicationActivities: nil)
                activityController.completionWithItemsHandler = { _, completed, _, _ in
                    try? FileManager.default.removeItem(at: directory)
                    if completed {
                        presentBulletinImpl?(.succeed(text: aygSpyExportDataSuccess, timeout: nil, customUndoText: nil))
                    }
                }
                presentNativeControllerImpl?(activityController)
            })
        ]

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: aygSpyExportDataCancel, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, openImportDatabase: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)

        // Replace vs merge maps exactly onto `importArchiveData(_:merge:)` and
        // `importHistoryData(_:merge:)`. Android resets the choice every time the
        // sheet opens, so it is sheet-local.
        var mergeMode = false
        let modeOffset = 1

        var makeModeItem: ((Int) -> ActionSheetItem)?
        actionSheet.dismissed = { _ in
            makeModeItem = nil
        }
        makeModeItem = { [weak actionSheet] index in
            let title = index == 0 ? aygSpyImportModeReplace : aygSpyImportModeMerge
            return ActionSheetCheckboxItem(title: title, label: "", value: mergeMode == (index == 1), action: { [weak actionSheet] _ in
                mergeMode = index == 1
                for refreshed in 0 ..< 2 {
                    if let item = makeModeItem?(refreshed) {
                        actionSheet?.updateItem(groupIndex: 0, itemIndex: modeOffset + refreshed, { _ in item })
                    }
                }
            })
        }

        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: "**\(aygSpyImportDataTitle)**\n\(aygSpyImportDataDescription)")
        ]
        if let item = makeModeItem?(0) {
            items.append(item)
        }
        if let item = makeModeItem?(1) {
            items.append(item)
        }
        items.append(ActionSheetButtonItem(title: aygSpyImportDataConfirm, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let merge = mergeMode
            if #available(iOS 14.0, *) {
                let delegate = AYGSpyDocumentPickerDelegate(completion: { urls in
                    var importedMessages = 0
                    var importedEdits = 0
                    var didFail = false
                    for url in urls {
                        guard let data = try? Data(contentsOf: url) else {
                            didFail = true
                            continue
                        }
                        // One export writes two files. Which is which is settled
                        // by the script id the exporter embedded, not by name.
                        let text = String(data: data, encoding: .utf8) ?? ""
                        if text.contains(aygSpyEditHistoryMarker) {
                            let result = EditHistoryManager.shared.importHistoryData(data, merge: merge)
                            importedEdits += result.addedMessages
                        } else {
                            let result = AntiDeleteManager.shared.importArchiveData(data, merge: merge)
                            importedMessages += result.added
                        }
                    }
                    refreshState()
                    if didFail && importedMessages == 0 && importedEdits == 0 {
                        presentBulletinImpl?(.info(title: nil, text: aygSpyImportDataFailure, timeout: nil, customUndoText: nil))
                    } else {
                        presentBulletinImpl?(.succeed(text: aygString("AYGSpyImportSummary", aygPluralString("AYGDeletedMessagesCount", importedMessages), aygPluralString("AYGEditedMessagesCount", importedEdits)), timeout: nil, customUndoText: nil))
                    }
                })
                // `asCopy` hands back a temp copy, so the file can be read
                // without juggling a security scope.
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.html, UTType.json, UTType.data], asCopy: true)
                picker.delegate = delegate
                picker.allowsMultipleSelection = true
                presentNativeControllerImpl?(picker)
            } else {
                presentBulletinImpl?(.info(title: nil, text: aygString("AYGSpyFilePickerUnavailable"), timeout: nil, customUndoText: nil))
            }
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: aygSpyImportDataCancel, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, openClear: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)

        var draft = aygSpyReadState(attachmentsSize: attachmentsSizeValue.with { $0 })
        let targetTitles = [aygSpyClearAttachments, aygSpyClearDatabase, aygSpyClearTelegramDatabase]
        // Android shows a computed size next to the first two and an ellipsis
        // while it is still counting. The third has no size: on Android it wipes
        // Telegram's own message tables, and there is no size to quote for what
        // this maps onto here.
        let targetLabels = [
            draft.attachmentsSize.flatMap { aygSpySizeString($0, presentationData: presentationData) } ?? "…",
            aygSpySizeString(draft.databaseSize, presentationData: presentationData),
            ""
        ]
        let targetOffset = 1
        let buttonIndex = targetOffset + targetTitles.count

        var makeTargetItem: ((Int) -> ActionSheetItem)?
        var makeButtonItem: (() -> ActionSheetItem)?
        actionSheet.dismissed = { _ in
            makeTargetItem = nil
            makeButtonItem = nil
        }

        makeTargetItem = { [weak actionSheet] index in
            return ActionSheetCheckboxItem(title: targetTitles[index], label: targetLabels[index], value: draft.clearSelections[index], action: { [weak actionSheet] _ in
                draft.setClearSelection(index, !draft.clearSelections[index])
                if let item = makeTargetItem?(index) {
                    actionSheet?.updateItem(groupIndex: 0, itemIndex: targetOffset + index, { _ in item })
                }
                if let item = makeButtonItem?() {
                    actionSheet?.updateItem(groupIndex: 0, itemIndex: buttonIndex, { _ in item })
                }
            })
        }
        makeButtonItem = { [weak actionSheet] in
            // Android disables the button while nothing would be cleared.
            let enabled = draft.clearSelections.contains(true)
            return ActionSheetButtonItem(title: aygSpyClear, color: .accent, font: .bold, enabled: enabled, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                let committed = draft
                let defaults = AYGSharedDefaults.store
                for (index, value) in committed.clearSelections.enumerated() {
                    defaults.set(value, forKey: aygSpyClearSelectionKeys[index])
                }

                if committed.clearAttachments {
                    AttachmentArchive.shared.clear(completion: {
                        measureAttachments()
                    })
                }
                if committed.clearDatabase {
                    AntiDeleteManager.shared.clearArchive()
                    EditHistoryManager.shared.clearAllHistory()
                    LocalEditManager.shared.clearAllEdits()
                    SpyDataStore.shared.clear()
                }
                if committed.clearTelegramDatabase {
                    // Android deletes rows out of Telegram's own messages tables
                    // and restarts the app. iOS exposes no equivalent — the
                    // postbox has no "drop the message cache" entry point — so
                    // this maps onto Telegram's own Clear Cache across every
                    // category, which is the nearest thing the engine offers.
                    clearDisposable.set((context.engine.resources.clearStorage(
                        peerId: nil,
                        categories: [.photos, .videos, .files, .music, .stickers, .avatars, .misc, .stories],
                        includeMessages: [],
                        excludeMessages: []
                    )
                    |> deliverOnMainQueue).start(completed: {
                        presentBulletinImpl?(.succeed(text: aygSpyClearDone, timeout: nil, customUndoText: nil))
                    }))
                } else {
                    presentBulletinImpl?(.succeed(text: aygSpyClearDone, timeout: nil, customUndoText: nil))
                }

                refreshState()
                measureAttachments()
            })
        }

        var items: [ActionSheetItem] = [ActionSheetTextItem(title: aygSpyClear)]
        for index in 0 ..< targetTitles.count {
            if let item = makeTargetItem?(index) {
                items.append(item)
            }
        }
        if let item = makeButtonItem?() {
            items.append(item)
        }

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGSettingsCategory.spy.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygSpyEntries(state: state, maxFolderSizeOptions: maxFolderSizeOptions),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        clearDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentNativeControllerImpl = { [weak controller] c in
        guard let root = controller?.view.window?.rootViewController else {
            return
        }
        // The share sheet is a popover on iPad and crashes without a source, so
        // anchor it to the middle of the screen the way a sheet would sit.
        if let popover = c.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0.0, height: 0.0)
            popover.permittedArrowDirections = []
        }
        root.present(c, animated: true)
    }
    presentBulletinImpl = { [weak controller] content in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
    }
    return controller
}
