import Foundation
import Testing
@testable import ScannerCore

/// Árbol temporal:
///
///     root/
///       a/big.bin       200 KB
///       a/b/small.txt   5 B
///       c.bin           50 KB
///       d.bin           hardlink a c.bin
///       link            symlink a a/big.bin
///       locked/         sin permisos, con un archivo adentro
private final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("locked"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: url("a/big.bin"))
        try Data("hello".utf8).write(to: url("a/b/small.txt"))
        try Data(count: 50_000).write(to: url("c.bin"))
        try Data(count: 10_000).write(to: url("locked/secret.bin"))
        try fm.linkItem(at: url("c.bin"), to: url("d.bin"))
        try fm.createSymbolicLink(atPath: url("link").path, withDestinationPath: url("a/big.bin").path)
        chmod(url("locked").path, 0)
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func blocks(_ relative: String) -> Int64 {
        var st = stat()
        lstat(relative.isEmpty ? root.path : url(relative).path, &st)
        return Int64(st.st_blocks) * 512
    }

    deinit {
        chmod(url("locked").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct DiskScannerTests {
    @Test func countsAllocatedSizeOnce() throws {
        let fixture = try Fixture()
        let progress = ScanProgress()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, progress: progress))

        let expected = ["", "a", "a/b", "locked", "a/big.bin", "a/b/small.txt", "c.bin", "link"]
            .reduce(0) { $0 + fixture.blocks($1) }
        #expect(tree.size == expected)
        // big, small, c (d es el mismo inodo), link
        #expect(tree.fileCount == 4)
        #expect(progress.fileCount == 4)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fixture = try Fixture()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, progress: ScanProgress()))
        let link = tree.children.first { $0.name == "link" }
        #expect((link?.size ?? 0) < 100_000)
    }

    @Test func marksInaccessibleFolders() throws {
        let fixture = try Fixture()
        let progress = ScanProgress()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, progress: progress))
        let locked = try #require(tree.children.first { $0.name == "locked" })
        #expect(locked.isInaccessible)
        #expect(locked.children.isEmpty)
        #expect(progress.inaccessibleCount == 1)
        #expect(tree.inaccessibleCount == 1)
    }

    @Test func sortsChildrenAndLinksParents() throws {
        let fixture = try Fixture()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, progress: ScanProgress()))
        #expect(tree.children.first?.name == "a")
        #expect(zip(tree.children, tree.children.dropFirst()).allSatisfy { $0.size >= $1.size })
        for child in tree.children { #expect(child.parent === tree) }
        let small = try #require(tree.descendant(atPath: fixture.url("a/b/small.txt").path))
        #expect(small.path == fixture.url("a/b/small.txt").path)
    }

    @Test func mapsDisplayPaths() throws {
        let fixture = try Fixture()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, displayPath: "/", progress: ScanProgress()))
        let small = try #require(tree.descendant(atPath: "/a/b/small.txt"))
        #expect(small.displayPath == "/a/b/small.txt")
        #expect(small.path == fixture.url("a/b/small.txt").path)
    }

    @Test func cancelledScanReturnsNil() throws {
        let fixture = try Fixture()
        let progress = ScanProgress()
        progress.cancel()
        #expect(DiskScanner.scan(path: fixture.root.path, progress: progress) == nil)
    }

    @Test func treeEditsKeepTotals() throws {
        let fixture = try Fixture()
        let tree = try #require(DiskScanner.scan(path: fixture.root.path, progress: ScanProgress()))
        let total = tree.size
        let a = try #require(tree.children.first { $0.name == "a" })
        let big = try #require(a.children.first { $0.name == "big.bin" })

        big.removeFromParent()
        #expect(tree.size == total - big.size)
        #expect(a.children.allSatisfy { $0 !== big })
        #expect(big.parent == nil)

        let locked = try #require(tree.children.first { $0.name == "locked" })
        locked.insert(big, renamedTo: "big 2.bin")
        #expect(tree.size == total)
        #expect(big.path == fixture.url("locked/big 2.bin").path)

        let fresh = FileNode(name: "x", kind: .directory, size: 1_000)
        tree.replace(a, with: fresh)
        #expect(fresh.name == "a")
        #expect(tree.size == total - a.size + 1_000)
    }
}
