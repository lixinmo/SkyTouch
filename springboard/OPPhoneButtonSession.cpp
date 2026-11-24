#include "OPPhoneButtonSession.h"
#include "OPPhoneButtonTransport.hpp"
#include <new>
#include <poll.h>

using namespace op_phone_buttons;

struct OPButtonSession {
    OPButtonSessionCallbacks callbacks;
    sockaddr_un destination;
    std::string directory, peerPath;
    Stream connection;
    Packet session;
    Sequence incoming;
    uint64_t outgoing=0, lastSeen=0, lastAttempt=0, lastCommand=0;
    bool connecting=false, welcomed=false;

    OPButtonSession(const OPButtonSessionCallbacks &host, const sockaddr_un &socket, std::string parent, const char *peer)
        : callbacks(host), destination(socket), directory(std::move(parent)), peerPath(peer) {}

    void diagnose(Diagnostic stage, uint8_t detail=0) const {
        callbacks.diagnose(static_cast<uint8_t>(stage),detail);
    }

    bool endpointTrusted(uint32_t capabilities) const {
        int fd=open(directory.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(fd<0) {
            if(capabilities==all)diagnose(errno==ENOENT ? Diagnostic::WaitingEndpoint : Diagnostic::EndpointRejected,1);
            return false;
        }
        struct stat parent{}, socket{};
        const bool valid=!fstat(fd,&parent) && parent.st_uid==0 && (parent.st_mode&0777)==0755 &&
            !fstatat(fd,socketName,&socket,AT_SYMLINK_NOFOLLOW) && S_ISSOCK(socket.st_mode) &&
            socket.st_uid==501 && (socket.st_mode&0777)==0600;
        close(fd);
        if(!valid && capabilities==all)diagnose(Diagnostic::EndpointRejected,2);
        return valid;
    }

    void disconnect() {
        connection.close();
        connecting=welcomed=false;
        session={};incoming={};outgoing=lastSeen=lastCommand=0;
        callbacks.connectionChanged(false);
    }

    bool receive(const Packet &packet) {
        const uint64_t now=nowNs();
        if(!valid(packet,now) || !incoming.accept(packet.sequence))return false;
        if(!welcomed) {
            if(packet.kind!=Kind::Welcome || packet.capabilities || packet.flags || packet.mapped || packet.physical)return false;
            session=packet;welcomed=true;lastSeen=now;
            return callbacks.welcome();
        }
        if(!sameGeneration(packet,session) || packet.kind!=Kind::Lease || !packet.command ||
           packet.command<lastCommand || packet.capabilities || packet.mapped || packet.physical || (packet.flags&~1u))return false;
        lastCommand=packet.command;lastSeen=now;
        return callbacks.lease(packet.command,packet.sequence,packet.timestamp+leaseNs,(packet.flags&1u)!=0);
    }

    bool startConnection(uint32_t capabilities, uint64_t now) {
        if(now-lastAttempt<500*NSEC_PER_MSEC)return false;
        lastAttempt=now;
        if(!endpointTrusted(capabilities))return false;
        const int fd=socket(AF_UNIX,SOCK_STREAM,0);
        if(fd<0)return false;
        if(!configureSocket(fd)){close(fd);return false;}
        if(connect(fd,reinterpret_cast<const sockaddr *>(&destination),sizeof(destination)) && errno!=EINPROGRESS) {
            close(fd);return false;
        }
        connection.fd=fd;connecting=true;lastSeen=now;
        callbacks.connectionChanged(true);
        diagnose(Diagnostic::Connecting);
        return true;
    }

    bool finishConnection(uint64_t now) {
        pollfd descriptor{connection.fd,POLLOUT,0};
        const int ready=poll(&descriptor,1,0);
        if(ready==0 || (ready<0 && errno==EINTR)) {
            if(now-lastSeen>staleNs){diagnose(Diagnostic::TransportLost,1);disconnect();}
            return false;
        }
        int error=0;socklen_t length=sizeof(error);
        if(ready<0 || getsockopt(connection.fd,SOL_SOCKET,SO_ERROR,&error,&length) || error) {
            diagnose(Diagnostic::TransportLost,1);disconnect();return false;
        }
        PeerFailure failure=PeerFailure::None;
        if(!peerIs(connection.fd,0,peerPath,&failure)) {
            diagnose(Diagnostic::PeerRejected,static_cast<uint8_t>(failure));disconnect();return false;
        }
        connecting=false;diagnose(Diagnostic::Handshaking);
        return true;
    }
};

OPButtonSession *OPCreateButtonSession(const char *path, const char *peer, const OPButtonSessionCallbacks &callbacks) {
    if(!path || !peer || peer[0]!='/')return nullptr;
    const char *leaf=strrchr(path,'/');
    if(!leaf || leaf==path || strcmp(leaf+1,socketName))return nullptr;
    try {
        sockaddr_un destination{};
        if(!address(path,destination))return nullptr;
        return new OPButtonSession(callbacks,destination,std::string(path,static_cast<size_t>(leaf-path)),peer);
    } catch(const std::bad_alloc &) {
        return nullptr;
    }
}

void OPDestroyButtonSession(OPButtonSession *session) {delete session;}
void OPDisconnectButtonSession(OPButtonSession *session) {session->disconnect();}

void OPTickButtonSession(OPButtonSession *session, uint32_t capabilities) {
    const uint64_t now=nowNs();
    if(session->connection.fd<0 && !session->startConnection(capabilities,now))return;
    if(session->connecting && !session->finishConnection(now))return;
    if(!session->connection.read([session](const Packet &packet){return session->receive(packet);}) ||
       !session->connection.flush()) {
        session->diagnose(Diagnostic::TransportLost,2);session->disconnect();return;
    }
    if(nowNs()-session->lastSeen>staleNs){session->diagnose(Diagnostic::TransportLost,3);session->disconnect();}
}

bool OPSendButtonPacket(OPButtonSession *session, uint16_t kind, uint64_t command, uint32_t capabilities,
                uint32_t physical, uint32_t mapped, uint32_t flags, uint64_t timestamp) {
    if(!session->welcomed || (kind!=(uint16_t)Kind::Hello && kind!=(uint16_t)Kind::State))return false;
    Packet packet=session->session;
    packet.kind=static_cast<Kind>(kind);packet.sequence=++session->outgoing;packet.timestamp=timestamp;packet.command=command;
    packet.capabilities=capabilities;packet.physical=physical;packet.mapped=mapped;packet.flags=flags;
    try {
        return session->connection.queue(packet) && session->connection.flush();
    } catch(const std::bad_alloc &) {
        return false;
    }
}
