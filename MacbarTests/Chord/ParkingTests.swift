import CoreGraphics
import Testing
@testable import Macbar

// AX coordinates. Main display 1440×900 at the origin.
private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let rightOfMain = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
private let leftOfMain = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
private let size = CGSize(width: 800, height: 600)

@Suite struct ParkingCorners {
    @Test func bottomRightWithOnePointShowing() {
        #expect(Parking.frame(for: size, display: main, otherDisplays: []) == CGRect(x: 1439, y: 899, width: 800, height: 600))
    }

    @Test func bottomLeftWhenADisplayIsToTheRight() {
        #expect(Parking.frame(for: size, display: main, otherDisplays: [rightOfMain]) == CGRect(x: -799, y: 899, width: 800, height: 600))
    }

    @Test func belowWhenDisplaysOnBothSides() {
        #expect(Parking.frame(for: size, display: main, otherDisplays: [leftOfMain, rightOfMain]) == CGRect(x: 0, y: 899, width: 800, height: 600))
    }

    @Test func parkedFramesNeverCoverOtherDisplays() {
        for others in [[], [rightOfMain], [leftOfMain], [leftOfMain, rightOfMain]] {
            let p = Parking.frame(for: size, display: main, otherDisplays: others)
            for d in others {
                let i = d.intersection(p)
                #expect(i.isNull || i.width * i.height == 0, "\(others)")
            }
        }
    }
}

@Suite struct ParkingRecovery {
    @Test func parkedPositionsAreDetected() {
        let displays = [main]
        #expect(Parking.isParked(CGRect(x: 1439, y: 899, width: 800, height: 600), displays: displays))
        #expect(Parking.isParked(CGRect(x: -799, y: 899, width: 800, height: 600), displays: displays))
        #expect(Parking.isParked(CGRect(x: 0, y: 899, width: 800, height: 600), displays: displays))
        #expect(Parking.isParked(CGRect(x: 5000, y: 5000, width: 800, height: 600), displays: displays))
    }

    @Test func normalWindowsAreNotParked() {
        #expect(!Parking.isParked(CGRect(x: 100, y: 100, width: 800, height: 600), displays: [main]))
        #expect(!Parking.isParked(CGRect(x: 1400, y: 100, width: 800, height: 600), displays: [main, rightOfMain]))
        #expect(!Parking.isParked(CGRect(x: 1438, y: 100, width: 800, height: 600), displays: [main]))
    }

    @Test func homeIsTheDisplayWithTheMostOverlap() {
        #expect(Parking.home(of: CGRect(x: 1439, y: 899, width: 800, height: 600), displays: [leftOfMain, main]) == 1)
        #expect(Parking.home(of: CGRect(x: 1400, y: 100, width: 800, height: 600), displays: [main, rightOfMain]) == 1)
        #expect(Parking.home(of: CGRect(x: 9000, y: 9000, width: 10, height: 10), displays: [main]) == nil)
    }

    @Test func centeredCapsToTheVisibleArea() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(Parking.centered(size, in: visible) == CGRect(x: 320, y: 162, width: 800, height: 600))
        #expect(Parking.centered(CGSize(width: 3000, height: 2000), in: visible) == visible)
    }
}

@Suite struct ParkingRestores {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let mainVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test func aFrameOnADisplayIsKept() {
        let f = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(Parking.restored(f, displays: [main], fallback: mainVisible) == f)
    }

    @Test func aFrameWhoseDisplayIsGoneIsCentredOnTheFallback() {
        let f = CGRect(x: 2000, y: 100, width: 800, height: 600)
        #expect(Parking.restored(f, displays: [main], fallback: mainVisible) == CGRect(x: 320, y: 162, width: 800, height: 600))
    }

    @Test func centringCapsTheSize() {
        let f = CGRect(x: 2000, y: 100, width: 2000, height: 1200)
        #expect(Parking.restored(f, displays: [main], fallback: mainVisible) == mainVisible)
    }
}
