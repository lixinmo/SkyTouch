#pragma once
#include <cmath>
#include <cstdint>
namespace op_phone_wire {
inline constexpr std::uint32_t magic=0x4f504d32,version=1;
enum Kind:std::uint32_t { Hello=1,Active=2,Inactive=3,Stop=4,Sample=5,Status=6 };
enum StatusCode:std::uint32_t { Available=1,Unavailable=2,SampleError=3 };
// Same executable/architecture at both ends. Fixed width, no pointers or text.
struct Packet {
    std::uint32_t magicValue=magic,versionValue=version,kind=0,flags=0;
    std::uint64_t session=0,generation=0,sequence=0;
    double timestamp=0,x=0,y=0,z=0;
};
static_assert(sizeof(Packet)==72,"motion wire ABI changed");
inline bool header(const Packet &p,std::uint64_t session) {
    return p.magicValue==magic&&p.versionValue==version&&p.session==session&&session!=0&&p.generation!=0&&
        std::isfinite(p.timestamp)&&std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z);
}
inline bool command(const Packet &p,std::uint64_t session) {
    return header(p,session)&&p.kind>=Hello&&p.kind<=Stop&&!p.flags&&!p.sequence&&
        p.timestamp==0&&p.x==0&&p.y==0&&p.z==0;
}
}
