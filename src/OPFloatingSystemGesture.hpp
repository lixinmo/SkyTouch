#pragma once

#include "OPFloatingDockState.hpp"
#include <cmath>
#include <unordered_map>
#include <vector>

namespace op_floating_gesture {
struct Sample {
    unsigned key=0;
    op_floating_dock::Point point{};
    bool began=false,touching=false,cancelled=false;
};
struct Result {bool started=false,ended=false,active=false;};

// A candidate edge contact is still an ordinary UI touch. Yield only once
// that same finger has actually moved inward, and never steal a finger whose
// initial Down belonged to the floating icon or its hidden wake target.
class Tracker {
    enum class Edge {Top,Bottom};
    struct Finger {
        op_floating_dock::Point origin;
        Edge edge;
        bool active=false;
    };
    std::unordered_map<unsigned,Finger> fingers;
    double lastActive=0;

    void markActivity(double now) {
        if(std::isfinite(now) && now>=lastActive)lastActive=now;
    }
public:
    bool active() const {
        for(const auto &entry:fingers)if(entry.second.active)return true;
        return false;
    }
    double lastActiveTime() const {return lastActive;}
    void reset() {fingers.clear();lastActive=0;}

    Result update(const std::vector<Sample> &samples,bool allLifted,bool cancelAll,double now,
                  op_floating_dock::Size displaySize,op_floating_dock::Rect iconHitRect,bool iconInteractive) {
        const bool wasActive=active();
        bool started=false;
        if(cancelAll) {
            if(wasActive)markActivity(now);
            fingers.clear();
            return {false,wasActive,false};
        }
        for(const Sample &sample:samples) {
            auto existing=fingers.find(sample.key);
            if(existing!=fingers.end() && existing->second.active)markActivity(now);
            if(sample.cancelled || !sample.touching) {
                if(existing!=fingers.end())fingers.erase(existing);
                continue;
            }
            if(sample.began) {
                // A reused identity starts a new contact; its old candidate
                // cannot turn an icon Down into a system gesture.
                if(existing!=fingers.end())fingers.erase(existing);
                const auto point=sample.point;
                if(!std::isfinite(point.x) || !std::isfinite(point.y) ||
                   displaySize.width<=0 || displaySize.height<=0 ||
                   point.x<0 || point.x>displaySize.width || point.y<0 || point.y>displaySize.height ||
                   (iconInteractive && iconHitRect.contains(point)))continue;
                if(point.y<=18)fingers.emplace(sample.key,Finger{point,Edge::Top,false});
                else if(point.y>=displaySize.height-24)fingers.emplace(sample.key,Finger{point,Edge::Bottom,false});
                continue;
            }
            // A Move without a captured edge Down must never manufacture a
            // system gesture, even if it appears deep inside the screen.
            if(existing==fingers.end() || existing->second.active ||
               !std::isfinite(sample.point.x) || !std::isfinite(sample.point.y))continue;
            Finger &finger=existing->second;
            const double dx=sample.point.x-finger.origin.x;
            const double dy=sample.point.y-finger.origin.y;
            const double inward=finger.edge==Edge::Top ? dy : -dy;
            if(inward>=16 && std::abs(dy)>=std::abs(dx)) {
                if(!wasActive)started=true;
                finger.active=true;markActivity(now);
            }
        }
        if(allLifted) {
            if(active())markActivity(now);
            fingers.clear();
        }
        const bool isActive=active();
        return {started,(wasActive || started) && !isActive,isActive};
    }
};
}
