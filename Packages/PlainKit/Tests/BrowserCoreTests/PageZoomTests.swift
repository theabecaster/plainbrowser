import BrowserCore
import Testing

@Suite struct PageZoomTests {
    @Test func stepsInAndOutOfActualSize() {
        #expect(PageZoom.zoomedIn(from: 1) == 1.15)
        #expect(PageZoom.zoomedOut(from: 1) == 0.85)
        #expect(PageZoom.zoomedIn(from: 3) == nil)
        #expect(PageZoom.zoomedOut(from: 0.5) == nil)
    }

    @Test func offStepValuesMoveToTheNextStep() {
        #expect(PageZoom.zoomedIn(from: 1.1) == 1.15)
        #expect(PageZoom.zoomedOut(from: 1.1) == 1.0)
        #expect(PageZoom.nearestStep(to: 1.2) == 1.15 || PageZoom.nearestStep(to: 1.2) == 1.25)
        #expect(PageZoom.nearestStep(to: 9) == 3)
    }

    @Test func percentIsWhole() {
        #expect(PageZoom.percent(1.15) == 115)
        #expect(PageZoom.percent(0.85) == 85)
        #expect(PageZoom.percent(1) == 100)
    }

    @Test func stepsAreSortedAndIncludeActualSize() {
        #expect(FixedChoices.pageZoomSteps == FixedChoices.pageZoomSteps.sorted())
        #expect(FixedChoices.pageZoomSteps.contains(PageZoom.actualSize))
    }
}
