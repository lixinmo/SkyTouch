#pragma once
#include <algorithm>
#include <cmath>
#include "OPMappingOrientation.hpp"

// Display-space docking. HID samples arrive in fixed portrait coordinates;
// keep that conversion explicit rather than using UIWindow's nil window space.
namespace op_floating_dock {
struct Point { double x=0,y=0; };
struct Size { double width=0,height=0; };
struct Insets { double top=0,left=0,bottom=0,right=0; };
struct Rect {
    double x=0,y=0,width=0,height=0;
    bool contains(Point point) const {
        return point.x>=x && point.y>=y && point.x<=x+width && point.y<=y+height;
    }
};
inline Size displaySize(Size native,int orientation) {
    return orientation==3 || orientation==4 ? Size{native.height,native.width} : native;
}
inline Point fromNative(Point point,Size native,int orientation) {
    switch(orientation) {
        case 2:return {native.width-point.x,native.height-point.y};
        case op::mapping::landscapeRight:return {point.y,native.width-point.x};
        case op::mapping::landscapeLeft:return {native.height-point.y,point.x};
        default:return point;
    }
}
inline Point toNative(Point point,Size native,int orientation) {
    switch(orientation) {
        case 2:return {native.width-point.x,native.height-point.y};
        case op::mapping::landscapeRight:return {native.width-point.y,point.x};
        case op::mapping::landscapeLeft:return {point.y,native.height-point.x};
        default:return point;
    }
}
inline Rect toNative(Rect rectangle,Size native,int orientation) {
    Point a=toNative(Point{rectangle.x,rectangle.y},native,orientation);
    Point b=toNative(Point{rectangle.x+rectangle.width,rectangle.y+rectangle.height},native,orientation);
    return {std::min(a.x,b.x),std::min(a.y,b.y),std::abs(a.x-b.x),std::abs(a.y-b.y)};
}
inline Insets displayInsets(Insets native,int orientation) {
    switch(orientation) {
        case 2:return {native.bottom,native.right,native.top,native.left};
        case op::mapping::landscapeRight:return {native.right,native.top,native.left,native.bottom};
        case op::mapping::landscapeLeft:return {native.left,native.bottom,native.right,native.top};
        default:return native;
    }
}
enum class Side { Left,Right,Top,Bottom };
enum class Action { None,Reveal,Open,Close,Dock };

class State {
    Size viewport{390,844};
    Insets safe{};
    double diameter=57;
    Point down{},last{},start{},dragCenter{};
    bool tracking=false,dragging=false,hiddenOnDown=false;
    double lowX() const {return safe.left+diameter/2;}
    double highX() const {return std::max(lowX(),viewport.width-safe.right-diameter/2);}
    double lowY() const {return safe.top+diameter/2;}
    double highY() const {return std::max(lowY(),viewport.height-safe.bottom-diameter/2);}
    Point clamp(Point point) const {
        return {std::clamp(point.x,diameter/2,viewport.width-diameter/2),
                std::clamp(point.y,diameter/2,viewport.height-diameter/2)};
    }
    Side nearestSide(Point point) const {
        point={std::clamp(point.x,0.0,viewport.width),std::clamp(point.y,0.0,viewport.height)};
        auto distance=[&](Side edge) {
            switch(edge) {
                case Side::Left:return point.x;
                case Side::Right:return viewport.width-point.x;
                case Side::Top:return point.y;
                case Side::Bottom:return viewport.height-point.y;
            }
            return point.x;
        };
        // Starting with the saved edge keeps exact ties stable. Other ties
        // follow this fixed order rather than depending on drag history.
        Side closest=side;
        for(Side edge:{Side::Left,Side::Right,Side::Top,Side::Bottom})
            if(distance(edge)<distance(closest))closest=edge;
        return closest;
    }
    void placeAlongSide(Point point) {
        const bool vertical=side==Side::Left || side==Side::Right;
        const double low=vertical ? lowY() : lowX(),high=vertical ? highY() : highX();
        const double value=vertical ? point.y : point.x;
        fraction=high>low ? (std::clamp(value,low,high)-low)/(high-low) : .5;
    }
public:
    Side side=Side::Left;
    double fraction=.3;
    bool hidden=false;
    void configure(Size size,Insets insets,double iconDiameter) {
        if(!std::isfinite(size.width) || !std::isfinite(size.height) || size.width<=0 || size.height<=0)return;
        viewport=size;
        const double limit=std::min(size.width,size.height);
        diameter=std::clamp(std::isfinite(iconDiameter) ? iconDiameter : 57.0,std::min(24.0,limit),limit);
        auto inset=[](double value,double room) {return std::isfinite(value) ? std::clamp(value,0.0,room) : 0.;};
        // Insets constrain only the axis along an edge, keeping the icon away
        // from corners. They never move a docked icon inward from that edge.
        // Left/right fractions retain their V2 along-edge interpretation.
        safe={inset(insets.top,(size.height-diameter)/2),inset(insets.left,(size.width-diameter)/2),
              inset(insets.bottom,(size.height-diameter)/2),inset(insets.right,(size.width-diameter)/2)};
        fraction=std::isfinite(fraction) ? std::clamp(fraction,0.0,1.0) : .3;
        if(tracking) {
            dragCenter=dragging ? clamp(dragCenter) : dockCenter();
            start={dragCenter.x-(last.x-down.x),dragCenter.y-(last.y-down.y)};
        }
    }
    Point dockCenter() const {
        switch(side) {
            case Side::Left:return {diameter/2,lowY()+(highY()-lowY())*fraction};
            case Side::Right:return {viewport.width-diameter/2,lowY()+(highY()-lowY())*fraction};
            case Side::Top:return {lowX()+(highX()-lowX())*fraction,diameter/2};
            case Side::Bottom:return {lowX()+(highX()-lowX())*fraction,viewport.height-diameter/2};
        }
        return {};
    }
    Point center() const {
        if(dragging)return dragCenter;
        Point result=dockCenter();
        if(hidden)switch(side) {
            case Side::Left:result.x=-diameter/2-1;break;
            case Side::Right:result.x=viewport.width+diameter/2+1;break;
            case Side::Top:result.y=-diameter/2-1;break;
            case Side::Bottom:result.y=viewport.height+diameter/2+1;break;
        }
        return result;
    }
    Rect hitRect() const {
        Point point=dragging ? dragCenter : dockCenter();
        if(hidden) {
            const bool vertical=side==Side::Left || side==Side::Right;
            const double width=std::min(viewport.width,vertical ? 32.0 : 64.0);
            const double height=std::min(viewport.height,vertical ? 64.0 : 32.0);
            return {vertical ? (side==Side::Left ? 0 : viewport.width-width) :
                        std::clamp(point.x-width/2,0.0,viewport.width-width),
                    vertical ? std::clamp(point.y-height/2,0.0,viewport.height-height) :
                        (side==Side::Top ? 0 : viewport.height-height),width,height};
        }
        const double radius=diameter/2+3;
        return {std::max(0.0,point.x-radius),std::max(0.0,point.y-radius),
                std::min(viewport.width,point.x+radius)-std::max(0.0,point.x-radius),
                std::min(viewport.height,point.y+radius)-std::max(0.0,point.y-radius)};
    }
    void dockAt(Point point) {
        side=nearestSide(point);placeAlongSide(point);
    }
    bool begin(Point point) {
        if(tracking || !hitRect().contains(point))return false;
        tracking=true;dragging=false;hiddenOnDown=hidden;down=point;last=point;start=dockCenter();dragCenter=start;
        return true;
    }
    void move(Point point) {
        if(!tracking)return;
        last=point;
        if(std::hypot(point.x-down.x,point.y-down.y)>8)dragging=true;
        if(dragging){hidden=false;dragCenter=clamp({start.x+point.x-down.x,start.y+point.y-down.y});}
    }
    Action end(bool cancelled,bool expanded,bool preparing) {
        if(!tracking)return Action::None;
        const bool moved=dragging;Point position=dragCenter;
        tracking=false;dragging=false;
        if(cancelled){hidden=hiddenOnDown;return Action::None;}
        if(moved){hidden=false;side=nearestSide(last);placeAlongSide(position);return Action::Dock;}
        if(hiddenOnDown){hidden=false;return Action::Reveal;}
        return expanded ? Action::Close : preparing ? Action::None : Action::Open;
    }
    void cancel() {if(tracking)hidden=hiddenOnDown;tracking=false;dragging=false;}
    void reveal() {hidden=false;}
    void hide() {if(!tracking)hidden=true;}
    bool hasGesture() const {return tracking;}
    bool isDragging() const {return dragging;}
};
}
