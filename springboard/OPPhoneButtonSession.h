#pragma once
#include <cstdint>

struct OPButtonSession;

// All socket operations and callbacks run on the serial transport queue.
struct OPButtonSessionCallbacks {
    void (*connectionChanged)(bool connected);
    void (*diagnose)(uint8_t stage, uint8_t detail);
    bool (*welcome)(void);
    bool (*lease)(uint64_t command, uint64_t sequence, uint64_t deadline, bool armed);
};

OPButtonSession *OPCreateButtonSession(const char *socketPath, const char *peerPath,
                                       const OPButtonSessionCallbacks &callbacks);
void OPDestroyButtonSession(OPButtonSession *session);
void OPTickButtonSession(OPButtonSession *session, uint32_t capabilities);
void OPDisconnectButtonSession(OPButtonSession *session);
bool OPSendButtonPacket(OPButtonSession *session, uint16_t kind, uint64_t command,
                        uint32_t capabilities, uint32_t physical, uint32_t mapped,
                        uint32_t flags, uint64_t timestamp);
