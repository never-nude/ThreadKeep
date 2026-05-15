import Testing
@testable import ThreadKeep

struct ExportDisplayTests {
    @Test
    func standardPDFModeUsesSingleVisibleExportName() {
        #expect(PDFExportMode.allCases.allSatisfy { $0.displayName == "Export PDF" })
    }
}
