#pragma once
#include <algorithm>
#include "OPMappingOrientation.hpp"

// The plan keeps its original long-by-short coordinates. Real landscape
// presentation follows the display. Portrait uses the virtual landscape image
// obtained by rotating the current portrait display counter-clockwise by 90°.
namespace op::floating {
struct Point { double x,y; };
struct LandscapeLayout {
    double width,height,nativeWidth,nativeHeight,scale,a,b,c,d;
    Point toNative(Point point) const {
        const double x=point.x-width/2,y=point.y-height/2;
        return {nativeWidth/2+a*x+c*y,nativeHeight/2+b*x+d*y};
    }
    Point fromNative(Point point) const {
        const double x=point.x-nativeWidth/2,y=point.y-nativeHeight/2;
        const double determinant=a*d-b*c;
        return {width/2+(d*x-c*y)/determinant,height/2+(-b*x+a*y)/determinant};
    }
};
inline LandscapeLayout landscapeLayout(double fixedWidth,double fixedHeight,int displayOrientation) {
    const double width=std::max(fixedWidth,fixedHeight),height=std::min(fixedWidth,fixedHeight);
    const int orientation=op::mapping::canonicalLandscapeOrientation(displayOrientation);
    const bool left=orientation==op::mapping::landscapeLeft;
    LandscapeLayout result{width,height,fixedWidth,fixedHeight,1,0,left ? -1.0 : 1.0,left ? 1.0 : -1.0,0};
    return result;
}
}
