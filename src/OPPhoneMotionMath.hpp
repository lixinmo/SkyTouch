#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace op_phone {
// One common counts/radian unit for both user-editable multipliers. Hardware
// recommendations belong to settings; the runtime consumes saved scales only.
inline constexpr double motionScalePerMultiplier = 2048.0;
// Preserve the complete absolute-value range accepted by existing v2 settings.
inline constexpr double maximumMotionScale = 220160.0;
inline constexpr double maxSampleAge = 0.10;
struct Delta { std::int16_t x=0,y=0; };
class MotionAccumulator {
    double last_=0,x_=0,y_=0;
    int orientation_=0;
public:
    void reset() {last_=x_=y_=0;}
    void discardPending() {x_=y_=0;}
    void orient(int value) {if(value!=orientation_){orientation_=value;reset();}}
    double lastTimestamp() const {return last_;}
    bool fresh(double now) const {return last_>0 && now>=last_ && now-last_<=maxSampleAge;}
    bool sample(double timestamp,double now,double rx,double ry,double rz,double sx,double sy) {
        if(!std::isfinite(timestamp)||!std::isfinite(now)||!std::isfinite(rx)||!std::isfinite(ry)||!std::isfinite(rz)||
           !std::isfinite(sx)||!std::isfinite(sy)||sx<1||sy<1||sx>maximumMotionScale||sy>maximumMotionScale||
           timestamp<=0||timestamp>now+.002||now-timestamp>maxSampleAge||(orientation_!=3&&orientation_!=4)) {
            reset();return false;
        }
        if(last_ && timestamp<=last_)return false; // Duplicate/out-of-order never integrates twice.
        const double dt=last_ ? timestamp-last_ : 0;last_=timestamp;
        if(dt<=0 || dt>maxSampleAge){x_=y_=0;return true;}
        // Device axes remain portrait-fixed. UI landscape names differ from
        // UIDeviceOrientation: use only UIInterfaceOrientation values 3/4.
        // iOS 17.1 / iPhone 15 Pro Max user comparison against the original
        // controller established the vendor-relative baseline sign on BOTH
        // axes. This source conversion precedes, and never changes, FDG gains
        // or the user's per-axis reversal settings.
        const double yaw=orientation_==4 ? rx : -rx;
        const double pitch=orientation_==4 ? -ry : ry;
        x_=std::clamp(x_+yaw*dt*sx,-8192.0,8192.0);
        y_=std::clamp(y_+pitch*dt*sy,-8192.0,8192.0);
        return true;
    }
    Delta consume(double now) {
        if(!fresh(now)){reset();return {};}
        auto take=[](double &value) {
            const double integer=std::trunc(value);
            const auto output=static_cast<std::int16_t>(std::clamp(integer,-2048.0,2047.0));
            // Retain sub-count precision. Saturation discards excess, never
            // releases a backlog as movement after the device has stopped.
            value-=integer;return output;
        };
        return {take(x_),take(y_)};
    }
};
inline std::array<std::uint8_t,20> neutralReport() {
    std::array<std::uint8_t,20> bytes{};bytes[0]=bytes[1]=bytes[2]=bytes[3]=128;
    bytes[6]=bytes[7]=128;bytes[18]=0xfe;return bytes;
}
inline void encodeButtons(std::array<std::uint8_t,20> &bytes,std::uint32_t buttons) {
    bytes[4]=buttons&255;bytes[5]=(buttons>>8)&255;bytes[9]=(buttons>>16)&255;bytes[8]=(buttons>>24)&127;
}
inline void encodeMotion(std::array<std::uint8_t,20> &bytes,Delta delta) {
    const auto x=static_cast<std::uint16_t>(delta.x)&0xfff;
    const auto y=static_cast<std::uint16_t>(delta.y)&0xfff;
    bytes[11]=x&255;bytes[12]=((x>>8)&15)|((y&15)<<4);bytes[13]=(y>>4)&255;
}
// Metadata is not a control frame. Unknown formats never supply held state.
inline bool isControlReport(const std::uint8_t *b,std::size_t length) {
    if(!b || (length!=14 && length!=20))return false;
    if(length==20 && (b[18]!=0xfe || b[19]!=0 || (b[0]==0xac&&b[1]==0xc0)))return false;
    if(length==14 && b[6]==0xba && b[7]==0xc0)return false;
    return !(b[9]&0x80);
}
inline std::uint32_t buttonsIn(const std::array<std::uint8_t,20> &b) {
    return b[4]|(std::uint32_t(b[5])<<8)|(std::uint32_t(b[9])<<16)|(std::uint32_t(b[8]&127)<<24);
}
inline bool releasedControls(const std::array<std::uint8_t,20> &b) {
    if(buttonsIn(b))return false;
    // Real sticks need not settle at exactly 128. This small radial tolerance
    // gates startup/resume only; it never recenters or filters forwarded axes.
    constexpr int centerTolerance=16;
    for(unsigned offset : {0U,2U}) {
        const int x=int(b[offset])-128,y=int(b[offset+1])-128;
        if(x*x+y*y>centerTolerance*centerTolerance)return false;
    }
    return true;
}
}
