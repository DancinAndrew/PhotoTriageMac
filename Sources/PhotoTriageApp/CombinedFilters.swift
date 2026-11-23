import Foundation
import PhotoTriageCore

enum ReviewFilterOption: String, CaseIterable {
    case all, unreviewed, reviewed, kept, temporary, deleteCandidate, legacy, custom
    var label: String {
        switch self {
        case .all: return "全部審閱與決策"
        case .unreviewed: return "未審閱"
        case .reviewed: return "已審閱"
        case .kept: return "保留 K"
        case .temporary: return "暫時用途 T"
        case .deleteCandidate: return "待刪候選 D"
        case .legacy: return "舊版已審閱"
        case .custom: return "自訂審閱組合"
        }
    }
}

enum FilterChip: String, Identifiable {
    case album, review, decision, screenshots, unclassified, temporary, rapidShots, media, date, unknownDate, group
    var id: String { rawValue }
}

extension AppModel {
    var reviewFilterOption: ReviewFilterOption {
        get {
            if filter.temporaryOnly {
                return filter.reviewStatus == nil && filter.reviewedOnly == nil ? .temporary : .custom
            }
            if filter.reviewedOnly != nil && filter.reviewStatus != nil { return .custom }
            if let reviewed = filter.reviewedOnly { return reviewed ? .reviewed : .unreviewed }
            switch filter.reviewStatus {
            case nil: return .all
            case .unreviewed: return .unreviewed
            case .kept: return .kept
            case .deleteCandidate: return .deleteCandidate
            case .organized: return .legacy
            }
        }
        set {
            guard newValue != .custom else { return }
            filter.reviewStatus = nil; filter.reviewedOnly = nil; filter.temporaryOnly = false
            switch newValue {
            case .unreviewed: filter.reviewStatus = .unreviewed
            case .reviewed: filter.reviewedOnly = true
            case .kept: filter.reviewStatus = .kept
            case .temporary: filter.temporaryOnly = true
            case .deleteCandidate: filter.reviewStatus = .deleteCandidate
            case .legacy: filter.reviewStatus = .organized
            case .all, .custom: break
            }
            filterChanged()
        }
    }
    func clearAlbumFilter() {
        selectedOrganizerAlbumID = nil; filter.albumID = nil; filter.groupID = nil; travelTripID = nil
        invalidateAlbumFilter()
    }
    func scopeIsActive(_ scope: ReviewScope) -> Bool {
        switch scope {
        case .all: return selectedOrganizerAlbumID == nil && filter.albumID == nil && filter.groupID == nil
        case .screenshots: return filter.screenshotsOnly
        case .unclassified: return filter.unclassifiedOnly
        case .temporary: return filter.temporaryOnly
        case .rapidShots: return filter.rapidShotsOnly
        case .unreviewed: return filter.reviewStatus == .unreviewed
        case .kept: return filter.reviewStatus == .kept
        case .organized: return filter.reviewStatus == .organized
        case .deleteQueue: return filter.reviewStatus == .deleteCandidate
        }
    }
    var activeFilterChips: [(kind: FilterChip, title: String)] {
        var result: [(FilterChip, String)] = []
        if let album = currentOrganizerAlbum { result.append((.album, "相簿：\(album.title)")) }
        else if let id = filter.albumID { result.append((.album, "相簿：\(albums.first { $0.id == id }?.title ?? "來源不可見")")) }
        if filter.groupID != nil || travelTripID != nil { result.append((.group, "事件篩選")) }
        if let reviewed = filter.reviewedOnly { result.append((.review, reviewed ? "已審閱" : "未審閱")) }
        if let status = filter.reviewStatus { result.append((filter.reviewedOnly == nil ? .review : .decision, "審閱：\(status == .organized ? "舊版已審閱" : status.label)")) }
        if filter.screenshotsOnly { result.append((.screenshots, "螢幕截圖")) }
        if filter.unclassifiedOnly { result.append((.unclassified, "尚無分類歸屬")) }
        if filter.temporaryOnly { result.append((.temporary, "暫時用途")) }
        if filter.rapidShotsOnly { result.append((.rapidShots, "密集拍攝")) }
        if let media = filter.media { result.append((.media, media == .video ? "影片" : "照片")) }
        if useDateRange { result.append((.date, "\(rangeStart.formatted(.dateTime.year().month().day()))–\(rangeEnd.formatted(.dateTime.year().month().day()))")) }
        if filter.unknownDateOnly { result.append((.unknownDate, "時間未知")) }
        return result
    }
    func removeFilterChip(_ chip: FilterChip) {
        switch chip {
        case .album: clearAlbumFilter()
        case .review: filter.reviewStatus = nil; filter.reviewedOnly = nil
        case .decision: filter.reviewStatus = nil
        case .screenshots: filter.screenshotsOnly = false
        case .unclassified: filter.unclassifiedOnly = false
        case .temporary: filter.temporaryOnly = false
        case .rapidShots: filter.rapidShotsOnly = false
        case .media: filter.media = nil
        case .date: useDateRange = false
        case .unknownDate: filter.unknownDateOnly = false
        case .group: filter.groupID = nil; travelTripID = nil
        }
        filterChanged()
    }
    func setDateRangeEnabled(_ enabled: Bool) {
        useDateRange = enabled
        if enabled { filter.unknownDateOnly = false }
        filterChanged()
    }
    func setUnknownDateOnly(_ enabled: Bool) {
        filter.unknownDateOnly = enabled
        if enabled { useDateRange = false }
        filterChanged()
    }
    func classificationLabel(for id: String) -> String {
        locallyClassifiedIDs.contains(id) ? "已有分類歸屬" : "尚無分類歸屬"
    }
}
