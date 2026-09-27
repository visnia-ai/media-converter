import Foundation
import Testing
@testable import MediaCore

@Suite struct OutputSecurityTests {
    @Test func rejectsOutputOutsideDestination() throws {
        let w = try Workspace(); defer { w.clean() }
        #expect(throws: (any Error).self) {
            try OutputFiles.prepare(w.source.appendingPathComponent("escaped.jpg"), root: w.destination)
        }
        #expect(throws: (any Error).self) {
            try OutputFiles.prepare(w.destination.appendingPathComponent("../escaped.jpg"), root: w.destination)
        }
    }

    @Test func replacingParentWithSymlinkCannotRedirectConversion() throws {
        let w = try Workspace(); defer { w.clean() }
        let nested = w.destination.appendingPathComponent("Nested")
        let prepared = try OutputFiles.prepare(nested.appendingPathComponent("image.jpg"), root: w.destination)
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: w.source)
        try Data("converted".utf8).write(to: prepared.temporary)
        #expect(throws: (any Error).self) { try prepared.publish(source: prepared.temporary) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.source.path).isEmpty)
    }

    @Test func replacingParentWithAnotherDirectoryIsRejected() throws {
        let w = try Workspace(); defer { w.clean() }
        let nested = w.destination.appendingPathComponent("Nested")
        let prepared = try OutputFiles.prepare(nested.appendingPathComponent("image.jpg"), root: w.destination)
        try FileManager.default.moveItem(at: nested, to: w.destination.appendingPathComponent("Moved"))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("converted".utf8).write(to: prepared.temporary)
        #expect(throws: (any Error).self) { try prepared.publish(source: prepared.temporary) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test func concurrentOutputIsNeverOverwrittenAndWorkspaceIsRemoved() throws {
        let w = try Workspace(); defer { w.clean() }
        let output = w.destination.appendingPathComponent("image.jpg")
        var workspace: URL!
        do {
            let prepared = try OutputFiles.prepare(output, root: w.destination)
            workspace = prepared.temporary.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try Data("converted".utf8).write(to: prepared.temporary)
            try Data("original".utf8).write(to: output)
            #expect(throws: (any Error).self) { try prepared.publish(source: prepared.temporary) }
            #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path) == ["image.jpg"])
    }

    @Test func successfulPublicationPreservesBytesAndProtectsPermissions() throws {
        let w = try Workspace(); defer { w.clean() }
        let output = w.destination.appendingPathComponent("Nested/image.jpg")
        let prepared = try OutputFiles.prepare(output, root: w.destination)
        let bytes = Data(repeating: 42, count: 1_100_000)
        try bytes.write(to: prepared.temporary)
        #expect(try prepared.publish(source: prepared.temporary) == Int64(bytes.count))
        #expect(try Data(contentsOf: output) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
