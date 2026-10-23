#pragma once
#include "../shared/core/MappingEngine.hpp"
#include <array>
#include <cmath>
#include <cstdint>

namespace originalport {
// Output transport state only. The original binary still decides which slots
// are pressed, where they move, and when they end. No bindings or actions here.
class TouchAdapter {
public:
    // The legacy C engine uses 0..5. The original FZMapping allocates and
    // releases 0..9 (uinput_report_all_release_event, 0x6a608c: cmp #0xa).
    static constexpr std::size_t slotCount = 10;
    static_assert(slotCount<=fsm::kMaxTouches,"Original slots must fit the HID frame");
    static constexpr std::size_t queueCapacity = 256;
    struct Rejection { int slot=-1; float x=0,y=0,width=0,height=0; bool coordinates=false; };
    bool begin(int slot, float x, float y) noexcept {
        if (!valid(slot,x,y) || failed_) return false;
        auto &s=slots_[static_cast<std::size_t>(slot)];
        // A reused original slot denotes a new contact. Preserve the old end
        // before this begin, including relative order with every other slot.
        if (s.down && !end(slot)) return false;
        s={true,x,y};
        return append(slot,fsm::TouchPhase::Began);
    }
    bool move(int slot, float x, float y) noexcept {
        if (!valid(slot,x,y) || failed_) return false;
        auto &s=slots_[static_cast<std::size_t>(slot)];
        // Cancellation cannot be undone by a stale held-contact move.
        if (!s.down) return true;
        s.x=x; s.y=y;
        return append(slot,fsm::TouchPhase::Moved);
    }
    bool end(int slot, fsm::TouchPhase phase=fsm::TouchPhase::Ended) noexcept {
        if (!validSlot(slot) || failed_ ||
            (phase!=fsm::TouchPhase::Ended && phase!=fsm::TouchPhase::Cancelled)) return false;
        auto &s=slots_[static_cast<std::size_t>(slot)];
        if (!s.down) return true;
        // Capture the terminal coordinate before retiring the input contact.
        const bool result=append(slot,phase);
        s.down=false;
        return result;
    }
    void clear() noexcept { slots_={}; output_={}; head_=count_=0; failed_=preparedQueued_=false; }
    bool prepare(float landscapeWidth, float landscapeHeight, std::uint64_t time,
                 fsm::TouchFrame &frame,
                 const std::array<fsm::TouchPhase,slotCount> *sourcePhases=nullptr) const noexcept {
        frame={}; frame.timestampNs=time; preparedQueued_=false;
        if (failed_) return false;
        if (!std::isfinite(landscapeWidth) || !std::isfinite(landscapeHeight) ||
            landscapeWidth<=0 || landscapeHeight<=0) {
            rejectCoordinates(-1,0,0,landscapeWidth,landscapeHeight);return false;
        }
        if (count_) {
            // Historical lifecycle frames must never be overwritten by the
            // vendor's newest mutable UITouch phase at the eventual flush.
            const auto &pending=queue_[head_];
            for (std::size_t i=0;i<slotCount;++i) {
                const auto &sample=pending.samples[i];
                if (!sample.present) continue;
                const float x=sample.x/landscapeWidth,y=sample.y/landscapeHeight;
                if (!std::isfinite(x) || !std::isfinite(y)) { rejectCoordinates(static_cast<int>(i),sample.x,sample.y,landscapeWidth,landscapeHeight);return false; }
                // Original UIKit keeps a captured touch when a wheel/drag
                // moves past the screen edge. Preserve its finite coordinate;
                // cancelling or clamping it changes the original gesture.
                if (x<0 || x>1 || y<0 || y>1) {
                    ++outsideRangeSamples_;lastOutsideRange_={static_cast<int>(i),sample.x,sample.y,landscapeWidth,landscapeHeight,true};
                }
                frame.touches[frame.count++]={static_cast<std::uint32_t>(i+1),x,y,sample.phase};
            }
            preparedQueued_=true;
            return true;
        }
        // Retain the original periodic flush for held contacts. Only this
        // no-history case follows its explicit Moved/Stationary phase.
        for (std::size_t i=0;i<slotCount;++i) {
            if (!output_[i].down) continue;
            auto phase=fsm::TouchPhase::Stationary;
            if (sourcePhases && ((*sourcePhases)[i]==fsm::TouchPhase::Moved ||
                (*sourcePhases)[i]==fsm::TouchPhase::Stationary)) phase=(*sourcePhases)[i];
            frame.touches[frame.count++]={static_cast<std::uint32_t>(i+1),output_[i].x,output_[i].y,phase};
        }
        return true;
    }
    void acknowledge(const fsm::TouchFrame &frame) noexcept {
        for (const auto &touch:frame) {
            if (!touch.id || touch.id>slotCount) continue;
            auto &s=output_[touch.id-1];
            s={touch.phase!=fsm::TouchPhase::Ended && touch.phase!=fsm::TouchPhase::Cancelled,touch.x,touch.y};
        }
        if (preparedQueued_ && count_) { head_=(head_+1)%queueCapacity; --count_; }
        preparedQueued_=false;
    }
    bool hasOutput() const noexcept {
        for (const auto &s:output_) if (s.down) return true;
        return false;
    }
    bool hasPending() const noexcept { return count_!=0; }
    std::size_t pendingCount() const noexcept { return count_; }
    std::size_t maximumPendingCount() const noexcept { return maximumCount_; }
    std::uint64_t overflowCount() const noexcept { return overflows_; }
    std::uint64_t coordinateRejectCount() const noexcept { return coordinateRejects_; }
    std::uint64_t slotRejectCount() const noexcept { return slotRejects_; }
    Rejection lastRejection() const noexcept { return lastRejection_; }
    std::uint64_t outsideRangeSampleCount() const noexcept { return outsideRangeSamples_; }
    Rejection lastOutsideRange() const noexcept { return lastOutsideRange_; }
private:
    struct Slot { bool down=false; float x=0,y=0; };
    struct Sample { bool present=false; float x=0,y=0; fsm::TouchPhase phase=fsm::TouchPhase::Stationary; };
    struct Snapshot { std::array<Sample,slotCount> samples{}; fsm::TouchPhase change= fsm::TouchPhase::Stationary; unsigned changedSlots=0; };
    bool append(int slot,fsm::TouchPhase phase) noexcept {
        const bool moving=phase==fsm::TouchPhase::Moved;
        // Keep simultaneous, nonconflicting multi-finger starts/releases in
        // one original-flush frame. Movement can coalesce within a run with
        // no lifecycle boundary. Different phases never cross each other.
        const unsigned bit=1U<<static_cast<unsigned>(slot);
        if (count_ && queue_[(head_+count_-1)%queueCapacity].change==phase &&
            (moving || !(queue_[(head_+count_-1)%queueCapacity].changedSlots&bit))) {
            auto &tail=queue_[(head_+count_-1)%queueCapacity];
            const auto &s=slots_[static_cast<std::size_t>(slot)];
            tail.samples[static_cast<std::size_t>(slot)]={true,s.x,s.y,phase};
            tail.changedSlots|=bit;
            return true;
        }
        if (count_==queueCapacity) { ++overflows_;failed_=true; return false; }
        auto &pending=queue_[(head_+count_)%queueCapacity]; pending={}; pending.change=phase; pending.changedSlots=bit;
        for (std::size_t i=0;i<slotCount;++i) {
            const auto &s=slots_[i];
            if (s.down) pending.samples[i]={true,s.x,s.y,fsm::TouchPhase::Stationary};
        }
        auto &sample=pending.samples[static_cast<std::size_t>(slot)];
        const auto &s=slots_[static_cast<std::size_t>(slot)];
        sample={true,s.x,s.y,phase}; ++count_;
        if(count_>maximumCount_)maximumCount_=count_;
        return true;
    }
    bool validSlot(int slot) noexcept {
        if(slot>=0 && static_cast<std::size_t>(slot)<slotCount)return true;
        ++slotRejects_;lastRejection_={slot,0,0,0,0,false};return false;
    }
    bool valid(int slot,float x,float y) noexcept {
        if(!validSlot(slot))return false;
        if(std::isfinite(x) && std::isfinite(y))return true;
        rejectCoordinates(slot,x,y,0,0);return false;
    }
    void rejectCoordinates(int slot,float x,float y,float width,float height) const noexcept {
        ++coordinateRejects_;lastRejection_={slot,x,y,width,height,true};
    }
    std::array<Slot,slotCount> slots_{},output_{};
    std::array<Snapshot,queueCapacity> queue_{};
    std::size_t head_=0,count_=0;
    std::size_t maximumCount_=0;
    std::uint64_t overflows_=0;
    std::uint64_t slotRejects_=0;
    mutable std::uint64_t coordinateRejects_=0;
    mutable Rejection lastRejection_{};
    mutable std::uint64_t outsideRangeSamples_=0;
    mutable Rejection lastOutsideRange_{};
    bool failed_=false;
    mutable bool preparedQueued_=false;
};
} // namespace originalport
