#pragma once
#include <algorithm>

// Presentation gates for the independent floating process. Suspending only
// retains the current editor session: saving, committing and leaving the editor
// remain the caller's responsibility. Interface rotation is not a lifecycle
// event and intentionally has no representation in this policy.
namespace op_floating_presentation {
class State {
public:
    bool editing=false;
    bool suspended=false;
    bool systemUI=false;
    bool transitioning=false;
    bool systemGesture=false;
    double quietUntil=0;

    void beginEditing() {editing=true;suspended=false;}
    void suspend() {suspended=true;}
    void systemUIChanged(bool visible) {
        systemUI=visible;
        if(visible)suspend();
    }
    void transitionChanged(bool active) {
        transitioning=active;
        if(active)suspend();
    }
    void beginSystemGesture(double /* now */) {
        systemGesture=true;
        suspend();
    }
    void endSystemGesture(double now) {
        systemGesture=false;
        quietUntil=std::max(quietUntil,now+.35);
    }
    void launcherResigned(double now) {
        suspend();
        quietUntil=std::max(quietUntil,now+.5);
        // App resignation is not a touch begin. It may have no matching touch
        // end, so it must never leave the gesture gate permanently engaged.
    }
    void launcherActivated(double now) {
        // An explicit active-app lifecycle signal can recover an unavailable
        // system observer. It restores the icon, never an unsaved full panel.
        const bool recovering=suspended || systemUI || transitioning || systemGesture;
        // Activation can follow an editor modal. Keep an already-visible
        // page interactive; genuine backgrounding has suspended it earlier.
        systemUI=false;transitioning=false;systemGesture=false;
        if(recovering)quietUntil=std::max(quietUntil,now+.35);
    }
    bool iconAllowed(bool displayAllowed,double now) const {
        return displayAllowed && !systemUI && !transitioning && !systemGesture && now>=quietUntil;
    }
    bool panelAllowed(bool displayAllowed,double now) const {
        return editing && !suspended && iconAllowed(displayAllowed,now);
    }
    bool resume(bool displayAllowed,double now) {
        if(!iconAllowed(displayAllowed,now))return false;
        suspended=false;
        return true;
    }
    void endEditing() {editing=false;suspended=false;}
};
}
