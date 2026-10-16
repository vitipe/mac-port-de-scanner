import Foundation
import Testing
import ScannerCore

private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
    let node = FileNode(name: name, kind: .directory, size: 0)
    for child in children { node.insert(child) }
    return node
}

private func file(_ name: String, _ size: Int64) -> FileNode {
    FileNode(name: name, kind: .file, size: size, fileCount: 1)
}

@Suite struct SunburstLayoutTests {
    // root (1000) = A (600: A1 300, A2 300) + B (400)
    let tree = directory("root", [
        directory("A", [file("A1", 300), file("A2", 300)]),
        file("B", 400),
    ])

    func layout(_ focus: FileNode? = nil) -> SunburstLayout {
        SunburstLayout(focus: focus ?? tree, innerRadius: 50, ringWidth: 30, ringCount: 3)
    }

    @Test func firstRingCoversTheCircle() {
        let ring = layout().rings[0]
        #expect(ring.map(\.node?.name) == ["A", "B"])
        #expect(ring.first?.start == 0)
        #expect(abs((ring.last?.end ?? 0) - 2 * .pi) < 1e-9)
        #expect(abs((ring[0].end - ring[0].start) - 0.6 * 2 * .pi) < 1e-9)
    }

    @Test func childrenStayInsideTheirParent() {
        let l = layout()
        let a = l.rings[0][0]
        #expect(l.rings[1].count == 2)
        for arc in l.rings[1] {
            #expect(arc.start >= a.start && arc.end <= a.end + 1e-9)
            #expect(arc.owner.parent === a.node)
        }
        #expect(l.rings[2].isEmpty)
    }

    @Test func groupsTinyItems() throws {
        // Cada uno mide ~0,04 pt, pero juntos ~19 pt.
        let many = (0..<500).map { file("f\($0)", 100) }
        let root = directory("root", [file("big", 1_000_000)] + many)
        let ring = layout(root).rings[0]
        try #require(ring.count == 2)
        guard case .smaller(_, let count, let size) = ring[1].content else {
            Issue.record("se esperaba un grupo de elementos chicos")
            return
        }
        #expect(count == 500)
        #expect(size == 50_000)
    }

    @Test func syntheticNodesGoLastAndAreNotGrouped() {
        let root = directory("disk", [file("data", 300)])
        root.appendSynthetic(FileNode(name: "Libre", kind: .free, size: 700))
        let ring = layout(root).rings[0]
        #expect(ring.map(\.node?.name) == ["data", "Libre"])
    }

    @Test func hitTesting() {
        let l = layout()
        let a = l.rings[0][0]
        #expect(l.arc(radius: 65, angle: a.mid)?.node?.name == "A")
        #expect(l.arc(radius: 95, angle: 0.01)?.node?.name == "A1")
        #expect(l.arc(radius: 65, angle: 6.0)?.node?.name == "B")
        #expect(l.arc(radius: 10, angle: 1) == nil)
        #expect(l.arc(radius: 500, angle: 1) == nil)
        // Anillo 2 vacío.
        #expect(l.arc(radius: 125, angle: 1) == nil)
    }

    @Test func angleIsClockwiseFromTop() {
        #expect(SunburstLayout.angle(x: 0, y: -1) == 0)
        #expect(abs(SunburstLayout.angle(x: 1, y: 0) - .pi / 2) < 1e-9)
        #expect(abs(SunburstLayout.angle(x: 0, y: 1) - .pi) < 1e-9)
        #expect(abs(SunburstLayout.angle(x: -1, y: 0) - 3 * .pi / 2) < 1e-9)
    }

    @Test func subtreeMembership() {
        let l = layout()
        let a = l.rings[0][0]
        let b = l.rings[0][1]
        let a1 = l.rings[1][0]
        #expect(a1.isWithin(a))
        #expect(!a1.isWithin(b))
        #expect(!a.isWithin(a1))
    }
}
