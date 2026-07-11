import Foundation
import SQLite3
import Testing
@testable import ThreadKeep

/// Launch-blocker probes for the import path: corrupted input, empty-but-valid
/// input, and unreadable input must all surface as thrown errors — never a
/// crash, hang, or silent empty library. These tests document the observed
/// behavior; fixes (if any) get their own regression assertions.
struct ImportResilienceTests {
    private func makeMessagesFolder(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadKeepResilience-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test
    func corruptedGarbageDatabaseThrowsInsteadOfCrashing() throws {
        let folder = try makeMessagesFolder(named: "garbage")
        defer { try? FileManager.default.removeItem(at: folder) }

        var garbage = Data(capacity: 4096)
        var seed: UInt64 = 0x5eed
        for _ in 0..<4096 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            garbage.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        try garbage.write(to: folder.appendingPathComponent("chat.db"))

        #expect(throws: (any Error).self) {
            _ = try MessagesStoreImporter().loadChatCandidates(from: folder, useContacts: false)
        }
    }

    @Test
    func truncatedRealHeaderDatabaseThrowsInsteadOfCrashing() throws {
        let folder = try makeMessagesFolder(named: "truncated")
        defer { try? FileManager.default.removeItem(at: folder) }

        // A real SQLite magic header followed by a truncated, zeroed body —
        // the shape of a partially copied chat.db.
        var truncated = Data("SQLite format 3\0".utf8)
        truncated.append(Data(count: 700))
        try truncated.write(to: folder.appendingPathComponent("chat.db"))

        #expect(throws: (any Error).self) {
            _ = try MessagesStoreImporter().loadChatCandidates(from: folder, useContacts: false)
        }
    }

    @Test
    func zeroMessageValidDatabaseYieldsNoCandidatesGracefully() throws {
        let folder = try makeMessagesFolder(named: "empty")
        defer { try? FileManager.default.removeItem(at: folder) }

        let dbPath = folder.appendingPathComponent("chat.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER, item_type INTEGER, associated_message_type INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let candidates = try MessagesStoreImporter().loadChatCandidates(from: folder, useContacts: false)
        #expect(candidates.isEmpty)
    }

    @Test
    func unreadableFolderThrowsInsteadOfHanging() throws {
        let folder = try makeMessagesFolder(named: "denied")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try Data("SQLite format 3\0".utf8).write(to: folder.appendingPathComponent("chat.db"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)

        // Approximates denied Full Disk Access: the same read-refused class the
        // OS produces when TCC blocks the Messages folder.
        #expect(throws: (any Error).self) {
            _ = try MessagesStoreImporter().loadChatCandidates(from: folder, useContacts: false)
        }
    }
}
