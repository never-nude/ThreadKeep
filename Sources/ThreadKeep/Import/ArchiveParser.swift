import Foundation

enum ArchiveParserError: LocalizedError, Sendable {
    case unreadableFile(String)
    case invalidJSON(String)
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let message):
            return message
        case .invalidJSON(let message):
            return message
        case .unsupportedFileType(let message):
            return message
        }
    }
}

struct ParsedArchivePayload: Sendable {
    let archive: ImportedConversationArchive
    let rawData: Data
    let sourceKind: ImportSourceKind

    func storedFilename(for threadID: String) -> String {
        "\(threadID).\(sourceKind.defaultFileExtension)"
    }

    static func snapshot(archive: ImportedConversationArchive, sourceKind: ImportSourceKind) throws -> ParsedArchivePayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rawData = try encoder.encode(ConversationArchiveDTO(archive: archive))
        return ParsedArchivePayload(archive: archive, rawData: rawData, sourceKind: sourceKind)
    }
}

struct ArchiveParser {
    static func parseFile(at url: URL) throws -> ParsedArchivePayload {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveParserError.unreadableFile("Could not read `\(url.lastPathComponent)`: \(error.localizedDescription)")
        }

        switch url.pathExtension.lowercased() {
        case "json":
            return try parse(data: data, sourceFilename: url.lastPathComponent)
        case "pdf":
            return try parseMessagesPDF(data: data, sourceFilename: url.lastPathComponent)
        default:
            throw ArchiveParserError.unsupportedFileType(
                "Unsupported import file type `.\(url.pathExtension)`. Import a Messages PDF or a ConversationArchive JSON file."
            )
        }
    }

    static func parse(data: Data, sourceFilename: String?) throws -> ParsedArchivePayload {
        let decoder = JSONDecoder()
        let dto: ConversationArchiveDTO

        do {
            dto = try decoder.decode(ConversationArchiveDTO.self, from: data)
        } catch {
            throw ArchiveParserError.invalidJSON("The archive JSON could not be decoded: \(error.localizedDescription)")
        }

        let archive = try ArchiveValidator.validate(dto, sourceFilename: sourceFilename)
        return ParsedArchivePayload(archive: archive, rawData: data, sourceKind: .jsonArchive)
    }

    static func parseMessagesPDF(data: Data, sourceFilename: String?) throws -> ParsedArchivePayload {
        let archive = try MessagesPDFImporter().parse(data: data, sourceFilename: sourceFilename)
        return ParsedArchivePayload(archive: archive, rawData: data, sourceKind: .messagesPDF)
    }
}
