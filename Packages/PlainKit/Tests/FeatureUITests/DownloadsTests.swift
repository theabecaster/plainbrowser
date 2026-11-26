@testable import FeatureUI
import Foundation
import Testing

@Suite struct DownloadStatusTextTests {
    @Test func runningShowsBytesSoFarAndTotal() {
        let text = DownloadStatusText.subtitle(
            isInProgress: true, isCancelled: false, isFinished: false, completed: 1_000_000, total: 4_000_000
        )
        #expect(text == "\(DownloadStatusText.bytes(1_000_000)) of \(DownloadStatusText.bytes(4_000_000))")
        #expect(DownloadStatusText.subtitle(
            isInProgress: true, isCancelled: false, isFinished: false, completed: 5_000, total: -1
        ) == DownloadStatusText.bytes(5_000))
        #expect(DownloadStatusText.subtitle(
            isInProgress: true, isCancelled: false, isFinished: false, completed: 0, total: 100
        ) == "Starting…")
    }

    @Test func endedStates() {
        #expect(DownloadStatusText.subtitle(
            isInProgress: false, isCancelled: false, isFinished: true, completed: 2_048, total: 2_048
        ) == DownloadStatusText.bytes(2_048))
        #expect(DownloadStatusText.subtitle(
            isInProgress: false, isCancelled: true, isFinished: false, completed: 10, total: 100
        ) == "Cancelled")
        #expect(DownloadStatusText.subtitle(
            isInProgress: false, isCancelled: false, isFinished: false, completed: 10, total: 100
        ) == "Failed")
    }

    @Test func filesAppAddressPointsAtTheFolder() {
        let folder = URL(filePath: "/var/mobile/Documents/Downloads/", directoryHint: .isDirectory)
        #expect(DownloadStatusText.filesAppURL(for: folder)?.absoluteString
            == "shareddocuments:///var/mobile/Documents/Downloads/")
    }
}
