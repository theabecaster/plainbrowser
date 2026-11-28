@testable import DesignSystem
import Foundation
import Testing

/// Pull to refresh's color loop: OKLab round trips, the loop's table, and a phase that speeds up
/// as the pull nears its threshold.
@Suite struct ColorCycleTests {
    @Test func okLabRoundTripsTheBrandColors() {
        for hex: UInt32 in [0x33DBC7, 0x2973FF, 0x6B4BFF, 0xFF6E5E, 0xFFFFFF, 0x000000] {
            let color = SRGB(hex: hex)
            let back = OKLab(color).srgb
            #expect(abs(back.red - color.red) < 0.002 && abs(back.green - color.green) < 0.002 && abs(back.blue - color.blue) < 0.002)
        }
        // White is lightness 1, black 0.
        #expect(abs(OKLab(SRGB(hex: 0xFFFFFF)).lightness - 1) < 0.001)
        #expect(abs(OKLab(SRGB(hex: 0x000000)).lightness) < 0.001)
    }

    @Test func theLoopStartsOnItsFirstStopAndStaysInItsBand() {
        let stops = [SRGB(hex: 0x33DBC7), SRGB(hex: 0x2973FF), SRGB(hex: 0x6B4BFF), SRGB(hex: 0xFF6E5E)]
        let free = ColorCycle(stops: stops, samples: 64)
        #expect(free.table.count == 64)
        #expect(abs(free.table[0].green - stops[0].green) < 0.002)
        let banded = ColorCycle(stops: stops, lightness: 0...0.62, samples: 64)
        #expect(banded.table.allSatisfy { OKLab($0).lightness <= 0.625 })
        let night = ColorCycle(stops: stops, lightness: 0.74...1, samples: 64)
        #expect(night.table.allSatisfy { OKLab($0).lightness >= 0.735 })
    }

    @Test func aBlendKeepsItsLightnessUnlikeSRGB() {
        // Lagoon to coral: the sRGB midpoint is a dull grey-violet, the OKLab one keeps the pair's
        // lightness between theirs.
        let lagoon = OKLab(SRGB(hex: 0x2973FF)), coral = OKLab(SRGB(hex: 0xFF6E5E))
        let middle = lagoon.mixed(with: coral, 0.5)
        #expect(abs(middle.lightness - (lagoon.lightness + coral.lightness) / 2) < 0.0001)
    }

    @Test func thePhaseSpeedsUpNearTheThreshold() {
        let turns = 2.0
        let early = ColorCycle.phase(fraction: 0.2, turns: turns) - ColorCycle.phase(fraction: 0.1, turns: turns)
        let late = ColorCycle.phase(fraction: 1.0, turns: turns) - ColorCycle.phase(fraction: 0.9, turns: turns)
        #expect(late > early * 5, "the same 10% of pull moves the colors faster near the end")
        #expect(ColorCycle.phase(fraction: 0, turns: turns) == 0)
        #expect(ColorCycle.phase(fraction: 1, turns: turns) == turns)
        #expect(ColorCycle.phase(fraction: 3, turns: turns) == turns, "clamped past the threshold")
        let cycle = ColorCycle(stops: [SRGB(hex: 0x2973FF), SRGB(hex: 0xFF6E5E)], samples: 10)
        #expect(cycle.index(atPhase: 0) == 0)
        #expect(cycle.index(atPhase: 1.0) == 0, "whole turns wrap")
        #expect(cycle.index(atPhase: 0.55) == 5)
    }
}
