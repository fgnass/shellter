import AppKit
import XCTest

final class PortClassifierTests: XCTestCase {
    func testPortOnTheCommandLine() {
        XCTAssertTrue(PortClassifier.argumentsMention(4000, ["node", "server.js", "--port", "4000"]))
        XCTAssertTrue(PortClassifier.argumentsMention(4000, ["vite", "--port=4000"]))
        XCTAssertTrue(PortClassifier.argumentsMention(8080, ["python3", "-m", "http.server", "-p8080"]))
        XCTAssertTrue(PortClassifier.argumentsMention(3000, ["serve", "localhost:3000"]))
    }

    func testOtherNumbersDoNotCount() {
        XCTAssertFalse(PortClassifier.argumentsMention(4000, ["node", "server.js", "--retries", "40000"]))
        XCTAssertFalse(PortClassifier.argumentsMention(4000, ["4000"]), "argv 0 is the program")
    }
}

final class ProjectColorTests: XCTestCase {
    func testDarkBlueGetsLightOnDarkSidebar() {
        let navy = NSColor(srgbRed: 0.1, green: 0.15, blue: 0.4, alpha: 1)
        XCTAssertGreaterThanOrEqual(ProjectColor.luminance(ProjectColor.legible(navy, onDark: true)), 0.24)
    }

    func testLightOrangeGetsDarkOnLightSidebar() {
        let orange = NSColor(srgbRed: 0.97, green: 0.68, blue: 0.33, alpha: 1)
        XCTAssertLessThanOrEqual(ProjectColor.luminance(ProjectColor.legible(orange, onDark: false)), 0.28)
    }

    func testLegibleColorsStayUnchanged() {
        let orange = NSColor(srgbRed: 0.97, green: 0.68, blue: 0.33, alpha: 1)
        let result = ProjectColor.legible(orange, onDark: true).usingColorSpace(.sRGB)!
        XCTAssertEqual(result.redComponent, 0.97, accuracy: 0.001)
    }
}

final class IconComposerRendererTests: XCTestCase {
    func testRendersTheAppIcon() {
        let icon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcon.icon")
        let image = IconComposerRenderer.render(icon)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 128)
    }
}

final class ProjectColorsTests: XCTestCase {
    func testHexRoundTrip() {
        let c = ProjectColors.color(hex: "#3E63DD")!
        XCTAssertEqual(ProjectColors.hex(of: c), "#3E63DD")
        XCTAssertNil(ProjectColors.color(hex: "#12345"))
        XCTAssertNil(ProjectColors.color(hex: "nothex"))
    }

    func testPaletteColorsAreValid() {
        for swatch in ProjectColors.palette {
            XCTAssertEqual(ProjectColors.hex(of: swatch.color), swatch.hex, swatch.name)
        }
    }
}
