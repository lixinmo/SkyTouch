#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <cmath>

// Private, local, same-device protocol. Fixed-width fields and an exact size
// make truncated/unknown messages fatal instead of guessing an input state.
namespace op_phone_buttons {
constexpr uint32_t action=1, volumeUp=2, volumeDown=4, side=8, all=15;
constexpr uint32_t magic=0x534B4232;
constexpr uint16_t version=1;
constexpr uint64_t leaseNs=200000000, staleNs=250000000, heartbeatNs=50000000;
constexpr size_t maximumPending=128;
constexpr const char *socketDirectory="/tmp/skytouch-buttons";
constexpr const char *socketName="s";
// Non-authoritative, volatile diagnostics only. Contains no key state or user
// paths; neither endpoint ever uses this notification to authorize capture.
constexpr const char *diagnosticNotification="com.lixinmo.skytouch.buttons.bridge-status";
constexpr const char *suppressionNotification="com.lixinmo.skytouch.buttons.suppression-counts";
enum class Diagnostic:uint8_t {
    Unseen=0, Starting, ResolvingRoot, ImagePathRejected, RootLibraryRejected,
    RootMismatch, EndpointTooLong, WaitingClasses, ABIMismatch, WaitingEndpoint,
    EndpointRejected, Connecting, PeerRejected, Handshaking, ReadyDisarmed,
    Armed, Maintenance, TransportLost, HookConflict
};
inline const char *diagnosticName(Diagnostic value) {
    switch(value) {
        case Diagnostic::Unseen:return "not-observed";
        case Diagnostic::Starting:return "starting";
        case Diagnostic::ResolvingRoot:return "resolving-installation";
        case Diagnostic::ImagePathRejected:return "bridge-image-path-rejected";
        case Diagnostic::RootLibraryRejected:return "roothide-library-unavailable";
        case Diagnostic::RootMismatch:return "installation-root-mismatch";
        case Diagnostic::EndpointTooLong:return "socket-path-too-long";
        case Diagnostic::WaitingClasses:return "waiting-for-system-classes";
        case Diagnostic::ABIMismatch:return "system-button-abi-unavailable";
        case Diagnostic::WaitingEndpoint:return "waiting-for-mapping-service";
        case Diagnostic::EndpointRejected:return "mapping-endpoint-rejected";
        case Diagnostic::Connecting:return "connecting";
        case Diagnostic::PeerRejected:return "mapping-peer-identity-rejected";
        case Diagnostic::Handshaking:return "handshaking";
        case Diagnostic::ReadyDisarmed:return "ready-disarmed";
        case Diagnostic::Armed:return "armed";
        case Diagnostic::Maintenance:return "package-maintenance-reload-required";
        case Diagnostic::TransportLost:return "transport-or-lease-lost";
        case Diagnostic::HookConflict:return "button-hook-conflict";
    }
    return "unknown";
}
enum class Kind:uint16_t { Welcome=1, Hello=2, Lease=3, State=4, Goodbye=5 };
struct Packet {
    uint32_t marker=magic;
    uint16_t protocol=version;
    Kind kind=Kind::Goodbye;
    uint64_t generation[2]{};
    uint64_t sequence=0;
    uint64_t timestamp=0;
    uint64_t command=0;
    uint32_t capabilities=0;
    uint32_t physical=0;
    uint32_t mapped=0;
    uint32_t flags=0; // bit 0: armed; bit 1: waiting for physical release.
};
static_assert(sizeof(Packet)==64,"Phone button protocol layout changed");
inline bool valid(const Packet &p,uint64_t now) {
    return p.marker==magic && p.protocol==version &&
        p.kind>=Kind::Welcome && p.kind<=Kind::Goodbye &&
        (p.generation[0] || p.generation[1]) && p.sequence && p.timestamp &&
        p.timestamp<=now && now-p.timestamp<=staleNs &&
        !(p.capabilities&~all) && !(p.physical&~all) && !(p.mapped&~all) &&
        !(p.mapped&~p.physical) && !(p.flags&~3u);
}
inline bool sameGeneration(const Packet &a,const Packet &b) {
    return a.generation[0]==b.generation[0] && a.generation[1]==b.generation[1];
}
struct Sequence {
    uint64_t last=0;
    bool accept(uint64_t next) {
        if(last==std::numeric_limits<uint64_t>::max() || next!=last+1)return false;
        last=next;return true;
    }
};
// Only the SpringBoard main thread mutates this state. An owned physical press
// stays swallowed until its real up even after disarm/connection loss. Mapped
// state is cancelled immediately. Re-arm waits for *all* physical keys to lift.
struct Ownership {
    uint32_t physical=0,owned=0,mapped=0;
    bool armed=false,waitingRelease=false;
    void setArmed(bool value) {
        if(!value){armed=false; mapped=0; waitingRelease=physical!=0;return;}
        if(!armed){armed=true;waitingRelease=physical!=0;}
    }
    bool event(uint32_t bit,bool down,bool mayCapture) {
        if(!bit || (bit&(bit-1)) || (bit&~all))return false;
        const bool wasDown=(physical&bit)!=0;
        if(down) {
            if(!wasDown) {
                physical|=bit;
                if(armed && !waitingRelease && mayCapture){owned|=bit;mapped|=bit;}
            }
            return (owned&bit)!=0;
        }
        const bool swallow=(owned&bit)!=0;
        physical&=~bit;owned&=~bit;mapped&=~bit;
        if(!physical)waitingRelease=false;
        return swallow;
    }
};
// Native click/long-press recognizers can finish after the input up was
// delivered. Preserve the ownership of the *specific timestamped press*;
// never infer delayed action ownership from today's armed flag or a time window.
struct PressRecord {
    uint64_t token=0;
    double down=0,up=0,last=0;
    bool owned=false,released=false;
    bool exclusiveDown=false;
};
struct PressHistory {
    static constexpr size_t depth=64;
    std::array<std::array<PressRecord,depth>,4> records{};
    std::array<size_t,4> next{};
    std::array<uint64_t,4> active{};
    uint64_t sequence=0;
    PressRecord *byToken(uint32_t bit,uint64_t token) {
        const int i=index(bit);if(i<0 || !token)return nullptr;
        for(auto &record:records[(size_t)i])if(record.token==token)return &record;
        return nullptr;
    }
    static int index(uint32_t bit) {
        for(int i=0;i<4;++i)if(bit==(1u<<i))return i;
        return -1;
    }
    PressRecord find(uint32_t bit,double timestamp) const {
        const int i=index(bit);if(i<0 || !std::isfinite(timestamp) || timestamp<=0)return {};
        PressRecord result;
        for(const auto &record:records[(size_t)i]) {
            if(!record.token || (record.exclusiveDown && timestamp<=record.down) || timestamp+0.000001<record.down ||
               (record.released && timestamp>record.up+0.000001))continue;
            if(record.token>result.token)result=record;
        }
        return result;
    }
    PressRecord observe(uint32_t bit,bool down,double timestamp,bool owned) {
        const int i=index(bit);if(i<0 || !std::isfinite(timestamp) || timestamp<=0)return {};
        auto &items=records[(size_t)i];
        PressRecord *record=nullptr;
        for(auto &item:items)if(item.token && item.token==active[(size_t)i]){record=&item;break;}
        if(down) {
            if(!record) {
                record=&items[next[(size_t)i]++%depth];
                *record={++sequence,timestamp,0,timestamp,owned,false};active[(size_t)i]=record->token;
            }
            record->last=timestamp;return *record;
        }
        if(!record)return find(bit,timestamp);
        if(timestamp+0.000001<record->down)return find(bit,timestamp);
        record->last=record->up=timestamp;record->released=true;active[(size_t)i]=0;
        return *record;
    }
};
struct NativeClaim {
    uint64_t token=0;
    bool owned=false,ended=false,bound=false;
    double timestamp=0;
};
struct NativeClaims {
    std::array<std::deque<NativeClaim>,4> pending;
    bool overflow=false;
    PressRecord completed(PressHistory &history,uint32_t bit,double timestamp) {
        const int index=PressHistory::index(bit);if(index<0 || !std::isfinite(timestamp) || timestamp<=0)return {};
        const PressRecord existing=history.find(bit,timestamp);if(existing.token)return existing;
        const NativeClaim *selected=nullptr;
        for(const auto &claim:pending[(size_t)index])if(claim.bound && claim.ended && timestamp>=claim.timestamp &&
            (!selected || claim.token>selected->token))selected=&claim;
        if(!selected)return {};
        PressRecord *record=history.byToken(bit,selected->token);if(!record)return {};
        // A terminal gesture may publish the release timestamp before the
        // duplicate UIPress up. Complete only that already-ended native claim;
        // never touch the current physical/mapped state or invent another edge.
        record->up=record->last=timestamp;record->released=true;return *record;
    }
    PressRecord begin(Ownership &state,PressHistory &history,uint32_t bit,bool capture) {
        const int index=PressHistory::index(bit);if(index<0)return {};
        const size_t i=(size_t)index;
        if(state.physical&bit) {
            if(auto *record=history.byToken(bit,history.active[i]))return *record;
            for(const auto &claim:pending[i])if(claim.token==history.active[i])
                return {claim.token,0,0,0,claim.owned,claim.ended};
            return {};
        }
        if(pending[i].size()>=PressHistory::depth){overflow=true;return {};}
        const bool owned=state.event(bit,true,capture);
        NativeClaim claim{++history.sequence,owned,false,false,0};pending[i].push_back(claim);
        history.active[i]=claim.token;
        return {claim.token,0,0,0,owned,false};
    }
    void end(Ownership &state,PressHistory &history,uint32_t bit,uint64_t token) {
        const int index=PressHistory::index(bit);if(index<0 || !token)return;
        const size_t i=(size_t)index;
        for(auto &claim:pending[i])if(claim.token==token) {
            if(claim.ended)return;
            claim.ended=true;
            if(history.active[i]==token){(void)state.event(bit,false,false);history.active[i]=0;}
            // This is a provisional endpoint only. The timestamped up later
            // fills the real interval; the completed raw press cannot absorb
            // a later timestamped began while we wait for it.
            if(auto *record=history.byToken(bit,token)) {
                record->released=true;record->up=record->down;
            }
            return;
        }
    }
    PressRecord transition(Ownership &state,PressHistory &history,uint32_t bit,int phase,double timestamp,bool capture) {
        const int index=PressHistory::index(bit);if(index<0 || !std::isfinite(timestamp) || timestamp<=0)return {};
        const size_t i=(size_t)index;const bool down=phase!=3 && phase!=4;
        PressRecord existing=history.find(bit,timestamp);
        if(down && phase!=0) {
            for(const auto &claim:pending[i])if(claim.bound && claim.ended && timestamp>=claim.timestamp &&
                (!existing.token || existing.token==claim.token)) {
                if(auto *record=history.byToken(bit,claim.token))return *record;
            }
        }
        if(!down) {
            for(auto iterator=pending[i].begin();iterator!=pending[i].end();++iterator) {
                if(!iterator->bound) {
                    if(existing.token>iterator->token)continue;
                    // A native action may supply the down before a gesture
                    // publishes any timestamp. Its first timestamped up still
                    // belongs to that FIFO claim. Bound the missing begin by
                    // the previous observed release, not a guessed duration.
                    double previousUp=0;
                    for(const auto &record:history.records[i])if(record.token<iterator->token && record.released && record.up<timestamp)
                        previousUp=std::max(previousUp,record.up);
                    auto &record=history.records[i][history.next[i]++%PressHistory::depth];
                    record={iterator->token,previousUp,timestamp,timestamp,iterator->owned,true,true};
                    if(history.active[i]==iterator->token){(void)state.event(bit,false,false);history.active[i]=0;}
                    const PressRecord result=record;pending[i].erase(iterator);return result;
                }
                if(timestamp+0.000001<iterator->timestamp)continue;
                // A later timestamped press owns its own up. Do not consume
                // an older raw claim merely because its duplicate up is late.
                if(existing.token && existing.token!=iterator->token && existing.down>iterator->timestamp)continue;
                PressRecord *record=history.byToken(bit,iterator->token);if(!record)continue;
                if(history.active[i]==iterator->token){(void)state.event(bit,false,false);history.active[i]=0;}
                record->up=record->last=timestamp;record->released=true;
                const PressRecord result=*record;pending[i].erase(iterator);return result;
            }
        }
        if(existing.released)return existing;
        if(down && !existing.token) {
            for(auto &claim:pending[i])if(!claim.bound) {
                claim.bound=true;claim.timestamp=timestamp;
                auto &record=history.records[i][history.next[i]++%PressHistory::depth];
                record={claim.token,timestamp,claim.ended ? timestamp : 0,timestamp,claim.owned,claim.ended};
                if(!claim.ended)history.active[i]=claim.token;
                return record; // Native down already emitted its one edge.
            }
        }
        const bool owned=state.event(bit,down,capture && phase==0);
        return history.observe(bit,down,timestamp,owned);
    }
};
}
