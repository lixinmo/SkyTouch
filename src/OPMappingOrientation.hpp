#pragma once

// These are UIInterfaceOrientation values, NOT UIDeviceOrientation. UIKit
// deliberately swaps the two landscape names relative to device orientation.
namespace op::mapping {
inline constexpr int portrait=1;
inline constexpr int portraitUpsideDown=2;
inline constexpr int landscapeRight=3;
inline constexpr int landscapeLeft=4;
inline int canonicalLandscapeOrientation(int displayOrientation) {
    // Portrait mapping is the portrait image rotated counter-clockwise:
    // native (x,y) -> logical (y,W-x), hence logical -> native (W-y,x).
    // Upside-down portrait composes its 180-degree display rotation first.
    switch(displayOrientation) {
        case portrait:return landscapeRight;
        case portraitUpsideDown:return landscapeLeft;
        case landscapeRight:return landscapeRight;
        case landscapeLeft:return landscapeLeft;
        default:return 0;
    }
}
}
