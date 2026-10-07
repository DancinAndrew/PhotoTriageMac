import XCTest
@testable import PhotoTriageCore

final class LocalAlbumTests: XCTestCase {
    private var sources: [OrganizerAlbum] {
        [OrganizerAlbum(id: "photos:a", title: "Trip", assetIDs: ["one", "two"], origins: [AlbumOrigin(.photos, id: "a", title: "Trip")]),
         OrganizerAlbum(id: "photos:b", title: "Trip", assetIDs: ["two", "three"], origins: [AlbumOrigin(.photos, id: "b", title: "Trip")])]
    }
    func testSameNameSourcesStaySeparateAndRenameKeepsOrigin() throws {
        var document = LocalAlbumsDocument()
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: document).count, 2)
        try LocalAlbumEngine.rename(&document, id: "photos:a", title: "Weekend", sources: sources)
        let all = LocalAlbumEngine.catalog(sources: sources, document: document)
        XCTAssertEqual(all.first { $0.id == "photos:a" }?.origins, sources[0].origins)
        XCTAssertEqual(all.first { $0.id == "photos:b" }?.title, "Trip")
        XCTAssertEqual(sources[0].title, "Trip")
    }
    func testNamesValidateBeforeMutationAndNeverMerge() throws {
        var document = LocalAlbumsDocument()
        for title in ["", " \n ", "Name\nName", String(repeating: "x", count: 101), " TRIP "] {
            XCTAssertThrowsError(try LocalAlbumEngine.create(&document, title: title, sources: sources))
            XCTAssertTrue(document.edits.isEmpty); XCTAssertTrue(document.history.isEmpty)
        }
        let id = try LocalAlbumEngine.create(&document, title: "  Coffee  ", sources: sources)
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: document).first { $0.id == id }?.title, "Coffee")
        XCTAssertThrowsError(try LocalAlbumEngine.rename(&document, id: id, title: "trip", sources: sources))
        XCTAssertEqual(document.history.count, 1)
    }
    func testFullLifecycleUndoDoesNotDeleteAssetsOrChangeOtherAlbum() throws {
        var document = LocalAlbumsDocument()
        let id = try LocalAlbumEngine.create(&document, title: "Local", sources: sources, assetIDs: ["one"])
        try LocalAlbumEngine.changeMembers(&document, id: id, ids: ["two"], adding: true, sources: sources)
        try LocalAlbumEngine.changeMembers(&document, id: id, ids: ["one"], adding: false, sources: sources)
        try LocalAlbumEngine.rename(&document, id: id, title: "Renamed", sources: sources)
        try LocalAlbumEngine.delete(&document, id: id, sources: sources)
        XCTAssertFalse(LocalAlbumEngine.catalog(sources: sources, document: document).contains { $0.id == id })
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: document).first { $0.id == "photos:a" }?.assetIDs, sources[0].assetIDs)
        XCTAssertNotNil(LocalAlbumEngine.undo(&document))
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: document).first { $0.id == id }?.assetIDs, ["two"])
        for _ in 0..<4 { XCTAssertNotNil(LocalAlbumEngine.undo(&document)) }
        XCTAssertTrue(document.edits.isEmpty); XCTAssertTrue(document.hidden.isEmpty)
        XCTAssertEqual(Set(sources.flatMap { $0.assetIDs }), ["one", "two", "three"])
    }
    func testMembershipRemovalAndSourceDeletionAreOnlyLocalReferences() throws {
        var document = LocalAlbumsDocument()
        try LocalAlbumEngine.changeMembers(&document, id: "photos:a", ids: ["two"], adding: false, sources: sources)
        let all = LocalAlbumEngine.catalog(sources: sources, document: document)
        XCTAssertEqual(all.first { $0.id == "photos:a" }?.assetIDs, ["one"])
        XCTAssertEqual(all.first { $0.id == "photos:b" }?.assetIDs, ["two", "three"])
        try LocalAlbumEngine.delete(&document, id: "photos:a", sources: sources)
        XCTAssertTrue(document.hidden.contains("photos:a"))
        XCTAssertEqual(document.edits["photos:a"]?.origins, sources[0].origins)
        XCTAssertEqual(sources[0].assetIDs, ["one", "two"])
        _ = LocalAlbumEngine.undo(&document)
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: document).first { $0.id == "photos:a" }?.assetIDs, ["one"])
    }
    func testSourceChangesAndUnavailableMembersRemainRecoverable() throws {
        var document = LocalAlbumsDocument()
        try LocalAlbumEngine.rename(&document, id: "photos:a", title: "Local name", sources: sources)
        try LocalAlbumEngine.changeMembers(&document, id: "photos:a", ids: ["two"], adding: false, sources: sources)
        var updated = sources; updated[0].assetIDs.insert("new-iCloud-reference")
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: updated, document: document).first { $0.id == "photos:a" }?.assetIDs,
                       ["one", "new-iCloud-reference"])
        let absent = LocalAlbumEngine.catalog(sources: [], document: document).first { $0.id == "photos:a" }
        XCTAssertEqual(absent?.assetIDs, ["one"]); XCTAssertTrue(absent?.sourceUnavailable == true)
        XCTAssertEqual(absent?.origins, sources[0].origins)
    }
    func testNoOpRepeatsAndMissingTargetsDoNotAddUndoEntries() throws {
        var document = LocalAlbumsDocument()
        XCTAssertFalse(try LocalAlbumEngine.rename(&document, id: "photos:a", title: "Trip", sources: sources))
        XCTAssertFalse(try LocalAlbumEngine.changeMembers(&document, id: "photos:a", ids: ["one"], adding: true, sources: sources))
        XCTAssertFalse(try LocalAlbumEngine.changeMembers(&document, id: "photos:a", ids: ["unrelated"], adding: false, sources: sources))
        XCTAssertThrowsError(try LocalAlbumEngine.delete(&document, id: "missing", sources: sources))
        XCTAssertTrue(document.history.isEmpty)
    }
    func testPersistenceRestartAndUndoKeepExactReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local-albums.json")
        var document = LocalAlbumsDocument()
        try LocalAlbumEngine.rename(&document, id: "photos:a", title: "Rename", sources: sources)
        try LocalAlbumEngine.delete(&document, id: "photos:b", sources: sources)
        try LocalAlbumPersistence.save(document, to: url)
        var reopened = try LocalAlbumPersistence.load(from: url)
        XCTAssertEqual(reopened, document)
        _ = LocalAlbumEngine.undo(&reopened)
        try LocalAlbumPersistence.save(reopened, to: url)
        XCTAssertEqual(LocalAlbumEngine.catalog(sources: sources, document: try LocalAlbumPersistence.load(from: url)).count, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCorruptUnknownVersionAndFailedSavePreserveOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("bad.json")
        let bad = Data("broken".utf8); try bad.write(to: url)
        XCTAssertThrowsError(try LocalAlbumPersistence.load(from: url)); XCTAssertEqual(try Data(contentsOf: url), bad)
        var newer = LocalAlbumsDocument(); newer.schemaVersion = 99
        try JSONEncoder().encode(newer).write(to: url)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try LocalAlbumPersistence.load(from: url))
        XCTAssertThrowsError(try LocalAlbumPersistence.save(newer, to: url)); XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try LocalAlbumPersistence.save(LocalAlbumsDocument(), to: root))
    }
}
