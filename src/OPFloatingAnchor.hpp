#pragma once

#include "OPFloatingDockState.hpp"
#include <optional>
#include <string>

// The saved anchor and all touch/geometry APIs below use fixed-screen portrait
// coordinates, matching raw HID and the icon's UIWindow. Interface rotation
// only changes the artwork transform; it never reconfigures this viewport.
namespace op_floating_anchor {
using op_floating_dock::Point;
using op_floating_dock::Size;
using op_floating_dock::Insets;
using op_floating_dock::Rect;
using op_floating_dock::Side;

inline constexpr unsigned currentVersion=4;
inline constexpr const char *fixedCoordinateSpace="fixed-screen";
struct SavedPosition {
    unsigned version=currentVersion;
    std::string coordinateSpace=fixedCoordinateSpace;
    // V4: native side. V2/V3: legacy display side, before conversion.
    Side side=Side::Left;
    double fraction=.3;
    // Only legacy records use this. Zero means the old record did not save it.
    int displayOrientation=0;
};
enum class RestoreResult {Restored,AlreadyRestored,PendingGeometry,PendingOrientation,InvalidRecord};
struct LegacyPlacement {
    Side side;
    Point center;
    Rect wakeRect;
};

inline bool validOrientation(int orientation) {return orientation>=1 && orientation<=4;}
inline bool validSide(Side side) {
    switch(side) {
        case Side::Left:case Side::Right:case Side::Top:case Side::Bottom:return true;
    }
    return false;
}
inline bool validSize(Size size) {
    return std::isfinite(size.width) && std::isfinite(size.height) && size.width>0 && size.height>0;
}
// System-edge gesture recognition still uses interface-display coordinates.
// Convert only its copy of the native hotspot, never the stored anchor.
inline Rect displayRect(Rect nativeRectangle,Size nativeSize,int displayOrientation) {
    const Point a=op_floating_dock::fromNative(Point{nativeRectangle.x,nativeRectangle.y},nativeSize,displayOrientation);
    const Point b=op_floating_dock::fromNative(
        Point{nativeRectangle.x+nativeRectangle.width,nativeRectangle.y+nativeRectangle.height},nativeSize,displayOrientation);
    return {std::min(a.x,b.x),std::min(a.y,b.y),std::abs(a.x-b.x),std::abs(a.y-b.y)};
}
inline double artworkRotationRadians(int displayOrientation) {
    constexpr double pi=3.14159265358979323846264338327950288;
    switch(displayOrientation) {
        case op::mapping::portraitUpsideDown:return pi;
        case op::mapping::landscapeRight:return pi/2;
        case op::mapping::landscapeLeft:return -pi/2;
        default:return 0;
    }
}
inline Side nativeSide(Side displaySide,int orientation) {
    switch(orientation) {
        case op::mapping::portraitUpsideDown:
            switch(displaySide) {
                case Side::Left:return Side::Right;
                case Side::Right:return Side::Left;
                case Side::Top:return Side::Bottom;
                case Side::Bottom:return Side::Top;
            }
            break;
        case op::mapping::landscapeRight:
            switch(displaySide) {
                case Side::Left:return Side::Top;
                case Side::Right:return Side::Bottom;
                case Side::Top:return Side::Right;
                case Side::Bottom:return Side::Left;
            }
            break;
        case op::mapping::landscapeLeft:
            switch(displaySide) {
                case Side::Left:return Side::Bottom;
                case Side::Right:return Side::Top;
                case Side::Top:return Side::Left;
                case Side::Bottom:return Side::Right;
            }
            break;
        default:break;
    }
    return displaySide;
}

// Project both visible center and hidden wake geometry before throwing away
// the old display coordinate space. The explicit edge transform preserves the
// correct physical edge even if a corner center is equidistant from two edges.
inline std::optional<LegacyPlacement> legacyPlacement(const SavedPosition &saved,int currentOrientation,
                                                     Size native,Insets nativeInsets,double diameter) {
    if((saved.version!=2 && saved.version!=3) || !validSide(saved.side) || !validSize(native))return std::nullopt;
    const int orientation=validOrientation(saved.displayOrientation) ? saved.displayOrientation : currentOrientation;
    if(!validOrientation(orientation))return std::nullopt;
    op_floating_dock::State previous;
    previous.side=saved.side;previous.fraction=saved.fraction;
    previous.configure(op_floating_dock::displaySize(native,orientation),
                       op_floating_dock::displayInsets(nativeInsets,orientation),diameter);
    const Point center=op_floating_dock::toNative(previous.dockCenter(),native,orientation);
    previous.hide();
    return LegacyPlacement{nativeSide(saved.side,orientation),center,
                           op_floating_dock::toNative(previous.hitRect(),native,orientation)};
}

class State {
    Size native{};
    Insets nativeInsets{};
    double diameter=57;
    bool configured=false,restoreFinished=false,restorePending=false;
public:
    // Alias this in the host to reuse existing raw-HID drag/tap handling. Pass
    // raw native points directly, without fromNative/toNative on every frame.
    op_floating_dock::State dock;

    bool configure(Size nativeSize,Insets fixedNativeInsets,double iconDiameter) {
        if(!validSize(nativeSize))return false;
        native=nativeSize;nativeInsets=fixedNativeInsets;diameter=iconDiameter;
        configured=true;dock.configure(native,nativeInsets,diameter);return true;
    }
    RestoreResult restore(const SavedPosition &saved,int currentOrientation=0) {
        if(restoreFinished)return RestoreResult::AlreadyRestored;
        restorePending=true;
        if(!validSide(saved.side) || (saved.version!=2 && saved.version!=3 && saved.version!=currentVersion) ||
           (saved.version==currentVersion && saved.coordinateSpace!=fixedCoordinateSpace))return RestoreResult::InvalidRecord;
        if(!configured)return RestoreResult::PendingGeometry;
        if(saved.version==currentVersion) {
            dock.cancel();dock.side=saved.side;dock.fraction=saved.fraction;
            dock.configure(native,nativeInsets,diameter);
        } else {
            const auto placement=legacyPlacement(saved,currentOrientation,native,nativeInsets,diameter);
            if(!placement)return RestoreResult::PendingOrientation;
            dock.cancel();dock.side=placement->side;dock.dockAt(placement->center);
        }
        restorePending=false;restoreFinished=true;return RestoreResult::Restored;
    }
    // Never replace a legacy record with a guessed physical edge while its
    // orientation is unknown. Once restored, repeated rotations/restore calls
    // cannot apply the old display-to-native conversion a second time.
    std::optional<SavedPosition> snapshot() const {
        if(!configured || restorePending)return std::nullopt;
        SavedPosition saved;saved.side=dock.side;saved.fraction=dock.fraction;return saved;
    }
    bool restorationPending() const {return restorePending;}
    bool restored() const {return restoreFinished;}
};
}
