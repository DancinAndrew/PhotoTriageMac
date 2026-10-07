import Foundation
import PhotoTriageCore

enum FilterChip: String, Identifiable {
    case album, review, screenshots, unclassified, temporary, rapidShots, media, date, unknownDate, group
    var id: String { rawValue }
}

extension AppModel {
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
        if let status = filter.reviewStatus { result.append((.review, "審閱：\(status.label)")) }
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
        case .review: filter.reviewStatus = nil
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
