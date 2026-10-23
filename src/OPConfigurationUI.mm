#import "OPStoragePaths.h"
#import "OPConfigurationUI.h"
#import "OPOriginalContext.h"
#import "OPOriginalBridge.h"
#import "OPOriginalMotionFix.h"
#import "OPOriginalMotionPersistence.h"
#import "OPOriginalMOBAEditor.h"
#import "OPOriginalBluetoothClient.h"
#import "OPInputSettings.h"
#import "OPBluetoothBroker.h"
#import "OPControllerIdentity.h"
#import "OPOriginalOfflineEditor.h"
#import "OPOriginalCloudTransport.h"
#import "OPSessionSupervisor.h"
#import "OPGlobalProfile.h"
#import "OPServicePaths.h"
#import "OPFloatingOrientation.hpp"
#import <PhotosUI/PhotosUI.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#include <cstring>
#include <cerrno>
extern char **environ;
NSNotificationName const OPConfigurationApplyAndStartNotification=@"com.lixinmo.skytouch.configuration.apply-and-start";
NSNotificationName const OPConfigurationSelectionDidChangeNotification=@"com.lixinmo.skytouch.configuration.selection-changed";
static_assert(UIInterfaceOrientationLandscapeRight==op::mapping::landscapeRight &&
              UIInterfaceOrientationLandscapeLeft==op::mapping::landscapeLeft,
              "Mapping geometry must use UIKit interface orientation, not device orientation");
static UIInterfaceOrientation floatingDisplayOrientation=UIInterfaceOrientationPortrait;
void OPSetFloatingConfigurationDisplayOrientation(UIInterfaceOrientation orientation) {
    if(op::mapping::canonicalLandscapeOrientation((int)orientation)!=0)
        floatingDisplayOrientation=orientation;
}
static UIInterfaceOrientation floatingLogicalOrientation(void) {return UIInterfaceOrientationLandscapeLeft;}

@interface OPFloatingLandscapeController:UIViewController
@property(nonatomic) UIViewController *contentController;
@property(nonatomic) UIView *landscapeCanvas;
@property(nonatomic) UIInterfaceOrientation canvasOrientation;
- (void)layoutLandscapeCanvas;
@end
@implementation OPFloatingLandscapeController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {return UIInterfaceOrientationPortrait;}
- (BOOL)shouldAutorotate {return NO;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.clearColor;
    self.landscapeCanvas=[UIView new];self.landscapeCanvas.backgroundColor=UIColor.clearColor;
    [self.view addSubview:self.landscapeCanvas];
    [self addChildViewController:self.contentController];
    self.contentController.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.contentController.view.transform=CGAffineTransformIdentity;
    [self.landscapeCanvas addSubview:self.contentController.view];
    [self.contentController didMoveToParentViewController:self];
    [self layoutLandscapeCanvas];
}
- (void)layoutLandscapeCanvas {
    if(!self.isViewLoaded || !self.landscapeCanvas)return;
    const auto layout=op::floating::landscapeLayout(self.view.bounds.size.width,self.view.bounds.size.height,(int)self.canvasOrientation);
    UIView *canvas=self.landscapeCanvas;
    canvas.bounds=CGRectMake(0,0,layout.width,layout.height);
    canvas.center=CGPointMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds));
    canvas.transform=CGAffineTransformMake(layout.a,layout.b,layout.c,layout.d,0,0);
    // The child has ordinary landscape coordinates. Its root transform stays
    // identity, so UIKit cannot cancel our rotation during its own layout.
    self.contentController.view.transform=CGAffineTransformIdentity;
    self.contentController.view.frame=canvas.bounds;
    [self.contentController.view setNeedsLayout];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self layoutLandscapeCanvas];}
@end

UIViewController *OPFloatingWindowContentController(UIWindow *window) {
    UIViewController *root=window.rootViewController;
    return [root isKindOfClass:OPFloatingLandscapeController.class] ? ((OPFloatingLandscapeController *)root).contentController : root;
}
void OPLayoutFloatingConfigurationWindow(UIWindow *window,UIInterfaceOrientation orientation) {
    if(!window.rootViewController)return;
    if(!op::mapping::canonicalLandscapeOrientation((int)orientation))orientation=floatingDisplayOrientation;
    CGRect fixed=UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    if(fixed.size.width<=0 || fixed.size.height<=0)return;
    OPFloatingLandscapeController *root;
    if([window.rootViewController isKindOfClass:OPFloatingLandscapeController.class])root=(id)window.rootViewController;
    else {
        UIViewController *content=window.rootViewController;
        content.definesPresentationContext=YES;
        root=[OPFloatingLandscapeController new];root.contentController=content;
        root.canvasOrientation=orientation;
        // Detach before adding as a child. The original manager still owns
        // exactly the same FZCentralViewController and all its controls.
        window.rootViewController=nil;
        window.rootViewController=root;
    }
    root.canvasOrientation=orientation;
    window.transform=CGAffineTransformIdentity;window.frame=fixed;
    window.bounds=CGRectMake(0,0,fixed.size.width,fixed.size.height);
    root.view.transform=CGAffineTransformIdentity;root.view.frame=window.bounds;
    [root layoutLandscapeCanvas];
}

namespace {
NSString *fixedTarget,*fixedName,*fixedDocuments;
BOOL originalLoaded=NO,originalReady=NO,contextPinned=NO,preparing=NO;
BOOL bridgeInstalled=NO;
BOOL screenshotLoading=NO;
BOOL floatingConfiguration=NO;
BOOL floatingPickerVisible=NO;
BOOL nativeEditorActive=NO;
BOOL managementQuiesced=NO;
using FloatingOrientationCheck=void(*)(id,SEL);
FloatingOrientationCheck originalFloatingOrientationCheck=nullptr;
void *originalLibrary=nullptr;
int configurationLease=-1;
UIWindow *controlsWindow;
NSString *const localTarget=@"com.lixinmo.skytouch.local";
NSString *const editorSelectionPath=OPSettingPath(@"com.lixinmo.skytouch.editor-selection.plist");
NSDictionary *editorControllerIdentity(void) {
    if(OPPhoneModeSelected()) {
        NSDictionary *profile=OPReadGlobalProfile(nil);
        NSNumber *type=profile[@"deviceType"];
        if(!type)type=OPLastKnownControllerIdentity()[@"peripheralType"] ?: @2;
        // This is a scheme layout, not a claimed connected phone peripheral.
        return @{@"peripheralType":type,@"name":@"",@"source":@"phone-scheme-layout"};
    }
    NSDictionary *known=OPLastKnownControllerIdentity();
    NSDictionary *broker=OPBluetoothBrokerStatus();
    id current=broker[@"currentPeripheralType"];
    if([broker[@"connected"] boolValue] && [current isKindOfClass:NSNumber.class] &&
        OPControllerIdentityTypeIsValid([current integerValue]))
        return @{@"peripheralType":current,@"name":broker[@"deviceName"] ?: @"",@"source":@"connected-device"};
    if(known)return @{@"peripheralType":known[@"peripheralType"],@"name":known[@"name"],@"source":@"last-connected-device"};
    // Upgrade fallback: older releases retained a BLE device name, but not a
    // global type record. Wasp's v1 layout is the exact rule in the original
    // updatePeripheralType:, so it can be recovered without inventing input.
    NSString *name=[broker[@"deviceName"] isKindOfClass:NSString.class] ? broker[@"deviceName"] : @"";
    if(!name.length) {
        NSDictionary *selected=[NSDictionary dictionaryWithContentsOfFile:OPBluetoothBrokerSelectionPath];
        if([selected[@"name"] isKindOfClass:NSString.class])name=selected[@"name"];
    }
    if([name containsString:@"Wasp"])
        return @{@"peripheralType":@2,@"name":name,@"source":@"legacy-device-layout"};
    // With no observed hardware history, retain the existing saved plan's
    // category. This is an editor default, never recorded as a real device.
    NSDictionary *profile=OPReadGlobalProfile(nil);id type=profile[@"deviceType"];
    if([type isKindOfClass:NSNumber.class] && OPControllerIdentityTypeIsValid([type integerValue]))
        return @{@"peripheralType":type,@"name":name,@"source":@"saved-plan-fallback"};
    return @{@"peripheralType":@0,@"name":name,@"source":@"initial-gamepad-default"};
}
void checkFloatingCanvasOrientation(id owner,SEL selector) {
    // In a floating process the host owns visibility and the original editor
    // always retains a long-by-short canvas, even when displayed on a portrait
    // desktop. Its old check only hid controls based on UIApplication's status
    // bar; it neither rotated nor laid them out. Do not lie to UIKit globally.
    if(!floatingConfiguration && originalFloatingOrientationCheck)originalFloatingOrientationCheck(owner,selector);
}
BOOL installFloatingOrientationCheck(NSString **error) {
    if(originalFloatingOrientationCheck)return YES;
    Class cls=NSClassFromString(@"FZCentralViewController");
    SEL selector=NSSelectorFromString(@"checkOrientation");
    Method implementation=cls ? class_getInstanceMethod(cls,selector) : nullptr;
    NSMethodSignature *signature=implementation ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(implementation)] : nil;
    if(!signature || signature.numberOfArguments!=2 || std::strcmp(signature.methodReturnType,@encode(void)) ||
       std::strcmp([signature getArgumentTypeAtIndex:0],@encode(id)) ||
       std::strcmp([signature getArgumentTypeAtIndex:1],@encode(SEL))) {
        if(error)*error=@"原版横向画布方向接口不兼容，未打开配置。";return NO;
    }
    originalFloatingOrientationCheck=(FloatingOrientationCheck)method_getImplementation(implementation);
    class_replaceMethod(cls,selector,(IMP)checkFloatingCanvasOrientation,method_getTypeEncoding(implementation));
    return YES;
}
BOOL localSource(NSString *target) {return [target isEqual:localTarget] || [target isEqual:@"com.lixinmo.skytouch.probe"];}
BOOL rememberSelection(NSDictionary *target) {
    if(![@{@"version":@1,@"bundle":target[@"bundle"],@"name":target[@"name"]} writeToFile:editorSelectionPath atomically:YES])return NO;
    if(geteuid()==0 && chown(editorSelectionPath.fileSystemRepresentation,501,501)!=0)return NO;
    return chmod(editorSelectionPath.fileSystemRepresentation,0600)==0;
}
BOOL method(id object,NSString *name,const char *type) {
    NSMethodSignature *signature=[object methodSignatureForSelector:NSSelectorFromString(name)];
    return signature && signature.numberOfArguments==2 && !std::strcmp(signature.methodReturnType,type);
}
id get(id object,NSString *name) {
    return method(object,name,"@") ? ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)) : nil;
}
BOOL call(id object,NSString *name) {
    if (!method(object,name,"v")) return NO;
    ((void(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)); return YES;
}
void stopConfigurationBluetooth(void) {
    OPStopOriginalBluetoothClient();
    id controller=OPOriginalController();call(controller,@"removeScan");
    id manager=get(controller,@"manager"),peripheral=get(controller,@"peripheral");
    if([manager isKindOfClass:CBCentralManager.class]) {
        [(CBCentralManager *)manager setDelegate:nil];[(CBCentralManager *)manager stopScan];
        if([peripheral isKindOfClass:CBPeripheral.class])[(CBCentralManager *)manager cancelPeripheralConnection:peripheral];
    }
}
UIWindow *vendorWindow(void) {
    if (!originalReady) return nil;
    id manager=get(NSClassFromString(@"FLEXManager"),@"sharedManager");
    id window=get(manager,@"explorerWindow");
    return [window isKindOfClass:NSClassFromString(@"FZUIWindow")] ? window : nil;
}
void showVendor(BOOL show);
void alert(UIViewController *owner,NSString *title,NSString *message) {
    showVendor(NO);
    if(!floatingConfiguration)[owner.view.window makeKeyWindow];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if(floatingConfiguration)sheet.modalPresentationStyle=UIModalPresentationOverCurrentContext;
    // Error alerts temporarily cover the vendor window; dismissal must return
    // to its controls now that there is no permanent "reveal UI" button.
    [sheet addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){showVendor(YES);}]];
    [owner presentViewController:sheet animated:YES completion:nil];
}
NSArray<NSDictionary *> *installedTargets(NSString **error) {
    // Read-only iOS-17 LaunchServices metadata. No app/container content read.
    // https://github.com/MTACS/iOS-17-Runtime-Headers/tree/main/Frameworks/CoreServices.framework
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW|RTLD_LOCAL);
    id workspace=get(NSClassFromString(@"LSApplicationWorkspace"),@"defaultWorkspace");
    id proxies=get(workspace,@"allInstalledApplications");
    if (![proxies isKindOfClass:NSArray.class]) { if(error)*error=@"暂时无法读取已安装 App 列表。";return @[]; }
    NSMutableArray *targets=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for (id proxy in proxies) {
        NSString *kind=get(proxy,@"applicationType"),*bundle=get(proxy,@"applicationIdentifier"),*name=get(proxy,@"localizedName");
        if ([bundle isEqual:@"com.lixinmo.skytouch.probe"])continue;
        if (![kind isEqual:@"User"] || ![bundle isKindOfClass:NSString.class] || !OPManagedTargetIsValid(bundle) ||
            ![name isKindOfClass:NSString.class] || !name.length || [seen containsObject:bundle]) continue;
        [seen addObject:bundle]; [targets addObject:@{@"bundle":bundle,@"name":name}];
    }
    [targets sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"name"] localizedStandardCompare:b[@"name"]];}];
    if (!targets.count && error) *error=@"没有读取到可配置的用户 App。请安装目标 App 后重试。";
    return targets;
}
void prepareProfile(NSString *target,void (^completion)(NSString *error)) {
    // This helper also obtains the original-host flock. The previous engine
    // must have fully exited before it can change shared profile ownership.
    NSString *executable=NSBundle.mainBundle.executablePath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        typedef int (*Persona)(const posix_spawnattr_t*,uid_t,uint32_t);
        typedef int (*PersonaID)(const posix_spawnattr_t*,uid_t);
        auto persona=(Persona)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
        auto uid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
        auto gid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
        NSString *failure=nil;
        if (!persona || !uid || !gid) failure=@"当前安装缺少配置目录准备权限。";
        else {
            int finalCode=75;
            // The App just became foreground; allow the supervisor to drain
            // its old child. Retry only the lock-busy status, with a 4s bound.
            for (unsigned attempt=0;attempt<16;++attempt) {
                posix_spawnattr_t attributes; int code=posix_spawnattr_init(&attributes);
                if (code) { finalCode=code; break; }
                code=persona(&attributes,99,1); if(!code)code=uid(&attributes,0);if(!code)code=gid(&attributes,0);
                pid_t child=0;
                char *arguments[]={(char *)executable.fileSystemRepresentation,(char *)"--prepare-profile",(char *)target.UTF8String,nullptr};
                posix_spawn_file_actions_t actions;
                int actionCode=posix_spawn_file_actions_init(&actions);
                if(!code)code=actionCode;
                // Inherit the same open-file-description lease in this short
                // helper so parent background/exit cannot expose a handoff gap.
                if(!code)code=posix_spawn_file_actions_adddup2(&actions,configurationLease,configurationLease);
                if(!code)code=posix_spawn(&child,executable.fileSystemRepresentation,&actions,&attributes,arguments,environ);
                if(!actionCode)posix_spawn_file_actions_destroy(&actions);
                posix_spawnattr_destroy(&attributes);
                if(code) {finalCode=code;break;}
                int status=0;
                const double deadline=NSProcessInfo.processInfo.systemUptime+5;
                pid_t waited=0;
                while((waited=waitpid(child,&status,WNOHANG))==0 && NSProcessInfo.processInfo.systemUptime<deadline)usleep(20000);
                if(waited==0){kill(child,SIGKILL);(void)waitpid(child,&status,0);finalCode=70;break;}
                if(waited!=child) {finalCode=70;break;}
                finalCode=WIFEXITED(status) ? WEXITSTATUS(status) : 70;
                if(finalCode!=75)break;
                usleep(250000);
            }
            if(finalCode)failure=finalCode==75 ? @"上一映射会话尚未停止。请稍后重新进入配置。" :
                [NSString stringWithFormat:@"配置目录准备失败（%d）；没有打开原界面。",finalCode];
        }
        dispatch_async(dispatch_get_main_queue(),^{completion(failure);});
    });
}
void showVendor(BOOL show) {
    if(!originalReady)return;
    if(floatingConfiguration)OPLayoutFloatingConfigurationWindow(vendorWindow(),floatingDisplayOrientation);
    vendorWindow().hidden=!show;
    if(show)call(get(NSClassFromString(@"FLEXManager"),@"sharedManager"),@"showExplorer");
}
BOOL floatingWindowYes(__unused id object,__unused SEL selector) {return YES;}
BOOL floatingWindowNo(__unused id object,__unused SEL selector) {return NO;}
void markFloatingWindowClass(Class cls) {
    if(!cls)return;
    // UIKit can inspect these flags while creating its CAContext. Install
    // before window allocation, only in the dedicated floating host process.
    class_addMethod(object_getClass(cls),NSSelectorFromString(@"_isSystemWindow"),(IMP)floatingWindowYes,"B@:");
    class_addMethod(cls,NSSelectorFromString(@"_isWindowServerHostingManaged"),(IMP)floatingWindowNo,"B@:");
    class_addMethod(cls,NSSelectorFromString(@"_isSecure"),(IMP)floatingWindowYes,"B@:");
    class_addMethod(cls,NSSelectorFromString(@"_shouldCreateContextAsSecure"),(IMP)floatingWindowYes,"B@:");
}

}

@interface OPConfigurationControlsWindow:UIWindow
@property(nonatomic,weak) UIView *bar;
@end
@implementation OPConfigurationControlsWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return self.bar && !self.bar.hidden && [self.bar pointInside:[self.bar convertPoint:point fromView:self] withEvent:event];
}
@end

@interface OPConfigurationBarController:UIViewController
@property(nonatomic) UIStackView *bar;
@property(nonatomic) CGPoint normalizedCenter;
- (void)dragHandle:(UIPanGestureRecognizer *)gesture;
@end
@implementation OPConfigurationBarController
- (instancetype)init {
    if((self=[super init]))_normalizedCenter=CGPointMake(.5,1);
    return self;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidLoad { [super viewDidLoad];self.view.backgroundColor=UIColor.clearColor; }
- (CGRect)placementBounds {
    CGRect bounds=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    bounds=CGRectInset(bounds,8,8);
    return CGRectMake(bounds.origin.x,bounds.origin.y,MAX(1,bounds.size.width),MAX(1,bounds.size.height));
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect available=[self placementBounds];
    CGSize size=CGSizeMake(MIN(266,available.size.width),MIN(44,available.size.height));
    CGFloat spanX=MAX(0,available.size.width-size.width),spanY=MAX(0,available.size.height-size.height);
    self.bar.frame=CGRectMake(available.origin.x+spanX*self.normalizedCenter.x,
        available.origin.y+spanY*self.normalizedCenter.y,size.width,size.height);
}
- (void)dragHandle:(UIPanGestureRecognizer *)gesture {
    CGRect available=[self placementBounds];
    CGPoint translation=[gesture translationInView:self.view];
    CGFloat spanX=MAX(0,available.size.width-self.bar.bounds.size.width),spanY=MAX(0,available.size.height-self.bar.bounds.size.height);
    CGFloat x=MIN(MAX(self.bar.frame.origin.x+translation.x,available.origin.x),available.origin.x+spanX);
    CGFloat y=MIN(MAX(self.bar.frame.origin.y+translation.y,available.origin.y),available.origin.y+spanY);
    self.normalizedCenter=CGPointMake(spanX>0 ? (x-available.origin.x)/spanX : .5,spanY>0 ? (y-available.origin.y)/spanY : .5);
    self.bar.frame=CGRectMake(x,y,self.bar.bounds.size.width,self.bar.bounds.size.height);
    [gesture setTranslation:CGPointZero inView:self.view];
}
@end

@interface OPConfigurationWorkspace:UIViewController <PHPickerViewControllerDelegate>
@property(nonatomic,copy) NSDictionary *target;
@property(nonatomic) UIImageView *background;
@property(nonatomic) UILabel *hint;
@property(nonatomic) UIButton *retry;
@property(nonatomic) UIViewController *controls;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL pickerVisible;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL startScheduled;
@property(nonatomic) BOOL hasAppeared;
@property(nonatomic,copy) NSString *startWaitStage;
@property(nonatomic) BOOL orientationRequested;
@property(nonatomic) BOOL prepared;
@property(nonatomic) BOOL preparingProfile;
@property(nonatomic) NSTimeInterval leaseWaitStarted;
@property(nonatomic) BOOL floating;
@property(nonatomic,copy) dispatch_block_t didCommitAndClose;
- (void)scheduleStart;
- (void)writeStage:(NSString *)stage error:(nullable NSString *)error;
- (void)showFailure:(NSString *)error;
- (void)acquireConfigurationLease;
@end
@implementation OPConfigurationWorkspace
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=self.floating ? UIColor.clearColor : UIColor.blackColor;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    self.background=[[UIImageView alloc] initWithFrame:self.view.bounds]; self.background.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.background.contentMode=UIViewContentModeScaleAspectFit; [self.view addSubview:self.background];
    self.hint=[[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds,40,60)]; self.hint.autoresizingMask=self.background.autoresizingMask;
    self.hint.textColor=UIColor.whiteColor; self.hint.textAlignment=NSTextAlignmentCenter; self.hint.numberOfLines=0;
    self.hint.text=@"正在打开原版配置界面…"; [self.view addSubview:self.hint];
    self.retry=[UIButton buttonWithType:UIButtonTypeSystem];self.retry.translatesAutoresizingMaskIntoConstraints=NO;
    [self.retry setTitle:@"重试" forState:UIControlStateNormal];self.retry.backgroundColor=UIColor.secondarySystemBackgroundColor;
    self.retry.layer.cornerRadius=10;self.retry.hidden=YES;[self.retry addTarget:self action:@selector(retryStart) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.retry];
    [NSLayoutConstraint activateConstraints:@[[self.retry.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.retry.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:80],
        [self.retry.widthAnchor constraintEqualToConstant:120],[self.retry.heightAnchor constraintEqualToConstant:44]]];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    // A cold-launch URL or system permission UI can finish activation after
    // the initial presentation. Recheck once on that lifecycle event.
    [self scheduleStart];
}
- (void)showFailure:(NSString *)error {
    self.hint.text=self.floating ? [error stringByAppendingString:@"\n可点悬浮图标收起后重新打开。"] : error;
    self.hint.hidden=NO;self.retry.hidden=NO;
    [self writeStage:@"initialization-failed" error:error];
}
- (void)retryStart {
    if(self.closing || self.preparingProfile)return;
    self.retry.hidden=YES;self.hint.text=@"正在打开映射方案…";
    if(!originalReady)self.started=NO;
    [self refreshSupportedOrientation];[self scheduleStart];
}
- (void)writeStage:(NSString *)stage error:(NSString *)error {
    UIWindow *window=self.viewIfLoaded.window;
    UIInterfaceOrientation orientation=self.floating ? floatingDisplayOrientation :
        window.windowScene ? window.windowScene.interfaceOrientation : UIApplication.sharedApplication.statusBarOrientation;
    UIView *canvas=self.floating ? self.view.superview : nil;
    CGAffineTransform rotation=canvas.transform;
    UIView *vendor=OPFloatingWindowContentController(vendorWindow()).viewIfLoaded;
    NSDictionary *state=@{@"pid":@(getpid()),@"uid":@(geteuid()),@"time":@(NSDate.date.timeIntervalSince1970),
        @"stage":stage,@"error":error ?: @"",@"target":self.target[@"bundle"] ?: @"",@"orientation":@(orientation),
        @"hasWindowScene":@(window.windowScene!=nil),@"width":@(self.view.bounds.size.width),@"height":@(self.view.bounds.size.height),
        @"originalLoaded":@(originalLoaded),@"originalReady":@(originalReady),
        @"logicalOrientation":@(self.floating ? floatingLogicalOrientation() : orientation),
        @"orientationLayout":self.floating ? @"display-aligned/portrait-counter-clockwise-landscape" : @"UIKit-managed",
        @"canvasTransform":@[@(rotation.a),@(rotation.b),@(rotation.c),@(rotation.d)],
        @"windowWidth":@(window.bounds.size.width),@"windowHeight":@(window.bounds.size.height),
        @"vendorWidth":@(vendor.bounds.size.width),@"vendorHeight":@(vendor.bounds.size.height),
        @"motionConfigurationSync":OPOriginalMotionConfigurationFixStatus(),
        @"offlineEditor":OPOriginalOfflineEditorStatus(),
        @"vendorWindowVisible":@(originalReady && vendorWindow() && !vendorWindow().hidden)};
    [state writeToFile:OPRuntimePath(@"com.lixinmo.skytouch.configuration-status.plist") atomically:YES];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];self.hasAppeared=YES;
    // The app's supported orientations make the legacy (non-scene) launch
    // landscape too. A preference on this presented controller alone did not.
    [self makeControls];
    [self writeStage:@"workspace-presented" error:nil];
    if(!self.floating)[self refreshSupportedOrientation];
    if(@available(iOS 16.0,*)) {
      if(!self.floating && self.view.window.windowScene && !self.orientationRequested) {
        self.orientationRequested=YES;
        UIWindowSceneGeometryPreferencesIOS *geometry=[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        __weak OPConfigurationWorkspace *weakSelf=self;
        [self.view.window.windowScene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError *error){
            dispatch_async(dispatch_get_main_queue(),^{
                OPConfigurationWorkspace *owner=weakSelf;
                if(!owner || owner.closing || owner.started)return;
                [owner writeStage:@"orientation-request-failed" error:error.localizedDescription];
                [owner showFailure:@"暂时无法打开横屏配置。请重试，或点“返回”。"];
            });
        }];
      }
    }
    [self scheduleStart];
    __weak OPConfigurationWorkspace *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        OPConfigurationWorkspace *owner=weakSelf;
        if(!owner || owner.closing || owner.started || owner.preparingProfile)return;
        UIInterfaceOrientation orientation=owner.floating ? floatingLogicalOrientation() :
            owner.view.window.windowScene ? owner.view.window.windowScene.interfaceOrientation : UIApplication.sharedApplication.statusBarOrientation;
        if(UIInterfaceOrientationIsLandscape(orientation) && owner.view.bounds.size.width>owner.view.bounds.size.height) {
            // UIKit may finish a cold presentation without another size
            // transition callback. Readiness must wake the deferred start.
            [owner scheduleStart];return;
        }
        [owner showFailure:@"横屏配置尚未就绪。请重试，或点“返回”。"];
        [owner writeStage:@"waiting-for-landscape" error:nil];
    });
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context){
        if(originalReady && !self.pickerVisible && !self.closing) {
            UIInterfaceOrientation orientation=self.floating ? floatingLogicalOrientation() :
                self.view.window.windowScene ? self.view.window.windowScene.interfaceOrientation : UIApplication.sharedApplication.statusBarOrientation;
            OPSetTargetOrientation(orientation);
        }
        [self scheduleStart];
    }];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Native presentation can lay out landscape bounds before UIKit updates
    // its interface orientation. Both hosts need the later layout wakeup.
    // scheduleStart waits for viewDidAppear, then defers window creation until
    // the layout stack returns and coalesces duplicate callbacks.
    [self scheduleStart];
}
- (void)scheduleStart {
    if(self.startScheduled || self.started || self.closing || self.preparingProfile ||
        !self.hasAppeared || !self.viewIfLoaded.window)return;
    self.startScheduled=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        self.startScheduled=NO;
        // Load the vendor UI only after the UIKit presentation/layout stack
        // has returned. Window creation inside layoutSubviews is reentrant.
        [self startIfLandscape];
    });
}
- (void)startIfLandscape {
    if(self.started || self.closing || self.preparingProfile || !self.hasAppeared || !self.viewIfLoaded.window ||
        UIApplication.sharedApplication.applicationState==UIApplicationStateBackground)return;
    if(self.view.bounds.size.width<=self.view.bounds.size.height) {
        if(![self.startWaitStage isEqual:@"waiting-for-layout"]) {
            self.startWaitStage=@"waiting-for-layout";[self writeStage:self.startWaitStage error:nil];
        }
        return;
    }
    UIInterfaceOrientation orientation=self.floating ? floatingLogicalOrientation() :
        self.view.window.windowScene ? self.view.window.windowScene.interfaceOrientation : UIApplication.sharedApplication.statusBarOrientation;
    if(!UIInterfaceOrientationIsLandscape(orientation)) {
        if(![self.startWaitStage isEqual:@"waiting-for-landscape"]) {
            self.startWaitStage=@"waiting-for-landscape";[self writeStage:self.startWaitStage error:nil];
        }
        return;
    }
    self.startWaitStage=nil;
    if(!self.prepared) {[self prepareEditor];return;}
    __weak OPConfigurationWorkspace *weakSelf=self;
    OPSetOriginalCloudSourceRequiredHandler(^{
        OPConfigurationWorkspace *workspace=weakSelf;if(!workspace || workspace.closing)return;
        showVendor(NO);
        alert(workspace,@"先选择云方案对应的游戏",@"当前是本地方案库。请在凌触中选择对应游戏，再点悬浮图标配置云方案。映射会对桌面和所有 App 生效。");
    });
    self.started=YES;
    [self writeStage:@"initializing-original" error:nil];
    NSString *target=self.target[@"bundle"],*error=nil;
    if(contextPinned && ![fixedTarget isEqual:target])error=@"本次配置会话已绑定其他游戏，请收起后重新打开。";
    if(!error && !contextPinned) {
        fixedTarget=[target copy];fixedName=[self.target[@"name"] copy];fixedDocuments=OPOriginalDocumentsForTarget(target);
        if(!OPImportOriginalProfileDefaults(target,&error)){[self showFailure:error];[self makeControls];return;}
        contextPinned=YES;
    }
    if(!error && !originalLoaded) {
        NSString *path=[OPApplicationBundlePath() stringByAppendingPathComponent:@"Original/flydigi.dylib"];
        originalLibrary=path.length ? dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL) : nullptr;
        originalLoaded=originalLibrary!=nullptr;
        if(!originalLibrary) {
            const char *detail=dlerror();
            NSLog(@"[OriginalPort] Configuration resource load failed: %s",detail ?: "missing application bundle path");
            error=@"无法加载原版配置资源，请重新安装完整包。";
        }
    }
    if(!error && !originalReady) {
        if(self.floating)markFloatingWindowClass(NSClassFromString(@"FZUIWindow"));
        if(!originalLibrary)error=@"原版配置资源尚未加载。";
        else if(self.floating && !installFloatingOrientationCheck(&error)) {}
        else if(!OPInstallOriginalMotionPersistenceFix(&error)) {}
        else if(!OPConfigureOriginalContext(originalLibrary,target,fixedDocuments,&error)) {}
        else if(!OPInstallOriginalCloudTransport(target,&error)) {}
        else if(!OPDisableOriginalAutomaticCloudLoading(&error)) {}
        else if(!OPInstallOriginalMotionConfigurationFix(&error)) {}
        else if(!OPInstallOriginalMOBAEditor(&error)) {}
        else if(!self.floating && !OPInstallOriginalOfflineEditor(&error)) {}
        else {
            if(!bridgeInstalled)bridgeInstalled=OPInstallOriginalBridge(^BOOL(const fsm::TouchFrame &,UIInterfaceOrientation){return YES;},^{},&error);
            if(bridgeInstalled && OPInstallOriginalBluetoothClient(&error)) {
                OPSetTargetOrientation(orientation);originalReady=OPStartOriginalUIWithInput(!OPPhoneModeSelected(),&error);
            }
        }
    }
    if(error || !originalReady) {[self showFailure:error ?: @"原版配置界面未创建。请重试。"];[self makeControls];return;}
    if(!self.floating) {
        NSDictionary *identity=editorControllerIdentity();
        if(!OPPrepareOriginalOfflineEditor([identity[@"peripheralType"] integerValue],identity[@"name"],&error)) {
            [self showFailure:error ?: @"未能按上次手柄类型打开配置。"];[self makeControls];return;
        }
    }
    self.hint.hidden=YES;self.retry.hidden=YES;self.background.image=[UIImage imageWithContentsOfFile:[fixedDocuments stringByAppendingPathComponent:@"background.png"]];
    OPSetTargetOrientation(orientation);showVendor(YES);[self makeControls];
    [self writeStage:@"original-ready" error:nil];
}
- (void)prepareEditor {
    if(self.preparingProfile || self.closing)return;
    NSString *target=self.target[@"bundle"];
    if(contextPinned) {
        if(![fixedTarget isEqual:target]) {
            [self showFailure:@"已记住所选游戏。请先回到桌面，再重新打开凌触编辑该游戏；当前方案已保留。"];
            return;
        }
        self.prepared=YES;[self scheduleStart];return;
    }
    if(preparing){[self showFailure:@"正在结束上一配置准备，请稍后重试。"];return;}
    preparing=YES;self.preparingProfile=YES;self.leaseWaitStarted=NSProcessInfo.processInfo.systemUptime;
    self.hint.text=@"正在准备 App 内配置…";
    [self acquireConfigurationLease];
}
- (void)acquireConfigurationLease {
    // The floating switcher only briefly reads/applies saved plans. Wait for
    // that operation without stopping its icon or starting a second editor.
    if(self.closing || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) {
        preparing=NO;self.preparingProfile=NO;
        if(!contextPinned && configurationLease>=0){close(configurationLease);configurationLease=-1;}
        return;
    }
    if(configurationLease<0) {
        configurationLease=open(OPSupervisorConfigurationLockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if(configurationLease<0 || flock(configurationLease,LOCK_EX|LOCK_NB)!=0) {
            const int failure=errno;
            if(configurationLease>=0)close(configurationLease);configurationLease=-1;
            if((failure==EWOULDBLOCK || failure==EAGAIN) && NSProcessInfo.processInfo.systemUptime-self.leaseWaitStarted<8) {
                self.hint.text=@"正在等待当前方案切换完成…";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self acquireConfigurationLease];});
                return;
            }
            preparing=NO;self.preparingProfile=NO;
            [self showFailure:@"暂时无法取得配置会话，请稍后重试。当前方案未改动。"];return;
        }
    }
    self.hint.text=@"正在打开映射方案…";
    notify_post("com.lixinmo.skytouch.original.ui-only.stop");
    prepareProfile(self.target[@"bundle"],^(NSString *error){
        preparing=NO;self.preparingProfile=NO;
        if(self.closing || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) {
            if(!contextPinned && configurationLease>=0){close(configurationLease);configurationLease=-1;}
            return;
        }
        if(error){if(configurationLease>=0)close(configurationLease);configurationLease=-1;[self showFailure:error];return;}
        self.prepared=YES;[self scheduleStart];
    });
}
- (void)makeControls {
    if(controlsWindow)return;
    if(self.floating)markFloatingWindowClass(OPConfigurationControlsWindow.class);
    OPConfigurationControlsWindow *window=self.view.window.windowScene ? [[OPConfigurationControlsWindow alloc] initWithWindowScene:self.view.window.windowScene] : [[OPConfigurationControlsWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    OPConfigurationBarController *controller=[OPConfigurationBarController new];
    UIStackView *bar=[UIStackView new];bar.axis=UILayoutConstraintAxisHorizontal;bar.spacing=8;bar.distribution=UIStackViewDistributionFill;
    bar.backgroundColor=[UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:.95];bar.layer.cornerRadius=12;
    bar.layoutMargins=UIEdgeInsetsMake(0,8,0,12);bar.layoutMarginsRelativeArrangement=YES;controller.bar=bar;
    [controller.view addSubview:bar];
    UIImageView *handle=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    handle.contentMode=UIViewContentModeCenter;handle.tintColor=UIColor.secondaryLabelColor;handle.userInteractionEnabled=YES;
    handle.isAccessibilityElement=YES;handle.accessibilityLabel=@"拖动工具栏";handle.accessibilityHint=@"拖动此处移动返回和加载截图按钮";
    [handle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:controller action:@selector(dragHandle:)]];
    [bar addArrangedSubview:handle];[handle.widthAnchor constraintEqualToConstant:34].active=YES;
    NSArray *titles=@[@"返回",@"加载截图"];
    NSArray *actions=@[NSStringFromSelector(@selector(finish)),NSStringFromSelector(@selector(pickImage))];
    for(NSUInteger i=0;i<titles.count;++i){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:titles[i] forState:UIControlStateNormal];[button addTarget:self action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];[bar addArrangedSubview:button];}
    window.rootViewController=controller;window.windowLevel=UIWindowLevelAlert+200;window.bar=bar;controlsWindow=window;self.controls=controller;
    if(self.floating)OPLayoutFloatingConfigurationWindow(window,floatingDisplayOrientation);
    window.hidden=NO;
    [controller.view setNeedsLayout];
}
- (BOOL)ownsReadyEditor {return self.started && originalReady && [fixedTarget isEqual:self.target[@"bundle"]];}
- (void)refreshSupportedOrientation {
    if(self.floating)return;
    if(@available(iOS 16.0,*)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
    else [UIViewController attemptRotationToDeviceOrientation];
}
- (void)pickImage {
    if(![self ownsReadyEditor])return;
    if(self.pickerVisible || self.presentedViewController)return;
    if(screenshotLoading){alert(self,@"截图正在加载",@"请等待当前截图加载和保存完成后再选择。");return;}
    if(!self.view.window || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground)return;
    self.pickerVisible=YES;if(self.floating)floatingPickerVisible=YES;
    showVendor(NO);controlsWindow.hidden=YES;
    // PhotosUI and its extension belong to this foreground App. The vendor
    // window was key while editing; return input ownership to the native
    // workspace before presenting the system picker and its keyboard.
    if(!self.floating)[self.view.window makeKeyWindow];
    PHPickerConfiguration *configuration=[[PHPickerConfiguration alloc] init];configuration.selectionLimit=1;configuration.filter=PHPickerFilter.imagesFilter;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:configuration];picker.delegate=self;
    picker.modalPresentationStyle=self.floating ? UIModalPresentationCurrentContext : UIModalPresentationFullScreen;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSItemProvider *provider=results.firstObject.itemProvider;
    BOOL canLoadImage=[provider canLoadObjectOfClass:UIImage.class];
    // Include the picker-dismissal animation: a selected image is already
    // pending, and tapping the floating icon must not discard that request.
    if(canLoadImage)screenshotLoading=YES;
    [picker dismissViewControllerAnimated:YES completion:^{
        self.pickerVisible=NO;if(self.floating)floatingPickerVisible=NO;
        if(self.closing){screenshotLoading=NO;return;}
        showVendor(YES);controlsWindow.hidden=NO;
        if(!canLoadImage)return;
        // Wait for the picker dismissal before an immediate load error can
        // present its alert; otherwise UIKit can silently reject the alert.
        [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object,NSError *error){
            dispatch_async(dispatch_get_main_queue(),^{
                screenshotLoading=NO;
                if(self.closing)return;
                if(error || ![(id)object isKindOfClass:UIImage.class]) {alert(self,@"截图未加载",@"请选择一张游戏截图后重试。");return;}
                UIImage *image=(UIImage *)object;
                NSData *png=UIImagePNGRepresentation(image);
                if(![png writeToFile:[fixedDocuments stringByAppendingPathComponent:@"background.png"] atomically:YES]) {
                    alert(self,@"截图未保存",@"未能保存所选截图，已保留原截图。请重新加载后重试。");return;
                }
                self.background.image=image;
            });
        }];
    }];
}
- (void)finish {
    if(self.closing)return;
    NSString *error=nil;
    if(!OPCommitConfigurationSession(&error)){showVendor(NO);alert(self,@"配置尚未保存",error);return;}
    [self closeWorkspace];
}
- (void)closeWorkspace {
    // The floating host restarts only after its own final preparation/exec
    // succeeds. Leave every control usable when that final step fails.
    if(self.floating){if(self.didCommitAndClose)self.didCommitAndClose();return;}
    self.closing=YES;OPHideConfigurationSession();
    OPFinishOriginalOfflineEditor();
    OPSetOriginalCloudSourceRequiredHandler(nil);
    if(!contextPinned && !self.preparingProfile && configurationLease>=0){close(configurationLease);configurationLease=-1;}
    [self.view.window makeKeyWindow];
    nativeEditorActive=NO;
    [self dismissViewControllerAnimated:YES completion:^{
        // The original singleton remains fixed to this source library until
        // real backgrounding exits the process and releases its lease. Keep
        // the App usable so the same library can be reopened without races.
        [UIViewController attemptRotationToDeviceOrientation];
    }];
}
@end

@interface OPConfigurationPicker:UITableViewController <UISearchResultsUpdating>
@property(nonatomic,copy) NSArray<NSDictionary *> *targets;
@property(nonatomic,copy) NSArray<NSDictionary *> *allTargets;
@end
@implementation OPConfigurationPicker
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"飞智云方案：选择游戏";
    NSString *error=nil;@try{self.targets=installedTargets(&error);}@catch(__unused NSException *exception){self.targets=@[];error=@"读取 App 列表失败。";}
    self.allTargets=self.targets ?: @[];
    UISearchController *search=[[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater=self;search.obscuresBackgroundDuringPresentation=NO;search.searchBar.placeholder=@"搜索对应游戏";
    self.navigationItem.searchController=search;self.definesPresentationContext=YES;
    UILabel *explanation=[[UILabel alloc] initWithFrame:CGRectMake(0,0,320,115)];explanation.numberOfLines=0;explanation.textAlignment=NSTextAlignmentCenter;
    explanation.text=error ?: @"选择账号中保存云方案的对应游戏，然后在凌触内下载、编辑方案和加载截图。悬浮图标只用于切换已经保存到本地的方案。";
    self.tableView.tableHeaderView=explanation;
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.targets=query.length ? [self.allTargets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,__unused NSDictionary *bindings){
        return [item[@"name"] localizedStandardContainsString:query] || [item[@"bundle"] localizedStandardContainsString:query];
    }]] : self.allTargets;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;(void)section;return self.targets.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"target"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"target"];
    NSDictionary *target=self.targets[path.row];cell.textLabel.text=target[@"name"];cell.detailTextLabel.text=@"在凌触内配置该游戏的方案";
    cell.accessoryType=[OPCurrentEditorSelection()[@"bundle"] isEqual:target[@"bundle"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(preparing)return;
    NSString *error=nil;
    if(!OPSelectConfigurationTarget(self.targets[path.row][@"bundle"],&error)){alert(self,@"未能选择游戏",error);return;}
    [tableView reloadData];[self.navigationController popViewControllerAnimated:YES];
}
@end

UIViewController *OPMakeConfigurationPicker(void) { return [[OPConfigurationPicker alloc] initWithStyle:UITableViewStyleInsetGrouped]; }
BOOL OPSelectConfigurationTarget(NSString *targetBundleID,NSString **error) {
    if(error)*error=nil;
    if(!NSThread.isMainThread || !OPManagedTargetIsValid(targetBundleID)) {
        if(error)*error=@"请选择有效的游戏。";return NO;
    }
    NSString *name=localSource(targetBundleID) ? @"本地映射方案" : targetBundleID;
    for(NSDictionary *candidate in installedTargets(nil))if([candidate[@"bundle"] isEqual:targetBundleID]){name=candidate[@"name"];break;}
    NSDictionary *selection=@{@"bundle":targetBundleID,@"name":name};
    if(!rememberSelection(selection)){if(error)*error=@"未能保存所选游戏，请重试。";return NO;}
    [NSNotificationCenter.defaultCenter postNotificationName:OPConfigurationSelectionDidChangeNotification object:nil userInfo:selection];
    return YES;
}
NSDictionary *OPCurrentEditorSelection(void) {
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:editorSelectionPath];
    NSString *target=[saved[@"bundle"] isKindOfClass:NSString.class] ? saved[@"bundle"] : nil;
    NSString *name=[saved[@"name"] isKindOfClass:NSString.class] ? saved[@"name"] : nil;
    if(!OPManagedTargetIsValid(target)) {
        NSDictionary *prior=[NSDictionary dictionaryWithContentsOfFile:OPSupervisorConfiguredTargetsPath];
        target=prior[@"activeProfileTarget"];name=prior[@"activeProfileDisplayName"];
    }
    if(!OPManagedTargetIsValid(target)){target=localTarget;name=@"本地映射方案";}
    if(localSource(target))name=@"本地映射方案";
    if(![name isKindOfClass:NSString.class] || !name.length || name.length>256)name=target;
    return @{@"bundle":target,@"name":name,@"local":@(localSource(target))};
}
static NSDictionary *selectionForEditor(NSString *targetBundleID) {
    NSDictionary *selection=OPCurrentEditorSelection();
    if(OPManagedTargetIsValid(targetBundleID) && ![selection[@"bundle"] isEqual:targetBundleID]) {
        NSString *name=localSource(targetBundleID) ? @"本地映射方案" : targetBundleID;
        for(NSDictionary *candidate in installedTargets(nil))if([candidate[@"bundle"] isEqual:targetBundleID]){name=candidate[@"name"];break;}
        selection=@{@"bundle":targetBundleID,@"name":name};
    }
    return selection;
}
UIViewController *OPMakeConfigurationEditor(NSString *targetBundleID) {
    NSDictionary *selection=selectionForEditor(targetBundleID);
    rememberSelection(selection);
    if(contextPinned && ![fixedTarget isEqual:selection[@"bundle"]]) {
        UIAlertController *notice=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"已选择：%@",selection[@"name"]]
            message:@"已记住所选游戏。请先回到桌面，再重新打开凌触编辑该游戏；当前方案已保留，悬浮图标和手柄连接会继续运行。"
            preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        return notice;
    }
    OPConfigurationWorkspace *workspace=[OPConfigurationWorkspace new];workspace.target=selection;workspace.modalPresentationStyle=UIModalPresentationFullScreen;
    nativeEditorActive=YES;
    return workspace;
}
UIViewController *OPMakeFloatingConfigurationEditor(NSString *targetBundleID,dispatch_block_t didCommitAndClose) {
    // Selection belongs to the mobile launcher. A root host must not rewrite
    // that 0600 preference as root and prevent the next game selection.
    floatingConfiguration=YES;
    OPConfigurationWorkspace *workspace=[OPConfigurationWorkspace new];workspace.target=selectionForEditor(targetBundleID);
    workspace.floating=YES;workspace.prepared=YES;workspace.didCommitAndClose=didCommitAndClose;
    workspace.definesPresentationContext=YES;
    return workspace;
}
BOOL OPCommitConfigurationSession(NSString **error) {
    if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"请在配置界面中保存方案。";return NO;}
    if(screenshotLoading) {
        if(error)*error=@"截图正在加载和保存，请等待完成后再收起配置页面。";return NO;
    }
    if(OPOriginalCloudTransferInProgress()) {
        if(error)*error=@"正在登录或下载方案，请等待完成后再收起配置页面。";return NO;
    }
    if(!contextPinned)return YES;
    // A new/empty library can always be closed after preserving its local
    // preferences. It must not replace a previously published global plan.
    NSDictionary *selection=originalReady ? OPOriginalCurrentConfigurationState() : nil;
    BOOL hasPlan=[selection[@"valid"] boolValue];
    if(hasPlan && !OPValidateOriginalCurrentPlanOnDisk([selection[@"deviceType"] integerValue],error))return NO;
    if(!OPExportOriginalProfileDefaults(fixedTarget,error))return NO;
    if(!hasPlan)return YES;
    if(!OPPublishGlobalProfile(fixedTarget,fixedName,[selection[@"deviceType"] integerValue],error))return NO;
    notify_post(OPSupervisorProfileUpdatedNotification);
    // Deliver synchronously before the UI disappears or the host restarts.
    [NSNotificationCenter.defaultCenter postNotificationName:OPConfigurationApplyAndStartNotification object:nil];
    return YES;
}
NSArray<UIWindow *> *OPConfigurationOverlayWindows(void) {
    NSMutableArray<UIWindow *> *windows=[NSMutableArray array];
    UIWindow *vendor=vendorWindow();if(vendor)[windows addObject:vendor];
    if(controlsWindow)[windows addObject:controlsWindow];
    return windows;
}
BOOL OPConfigurationPresentationInProgress(void) {return screenshotLoading || floatingPickerVisible;}
UIViewController *OPMakeConfigurationPickerForTarget(NSString *targetBundleID) {return OPMakeConfigurationEditor(targetBundleID);}
BOOL OPConfigurationSessionLoaded(void) { return contextPinned; }
BOOL OPConfigurationNativeEditorActive(void) {return nativeEditorActive;}
void OPHideConfigurationSession(void) {
    if(originalReady) {OPStopOriginalTouches();showVendor(NO);}
    controlsWindow.hidden=YES;controlsWindow=nil;
}
BOOL OPPrepareConfigurationForManagement(BOOL replacing,NSString **error) {
    if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"请从凌触的管理配置页面执行此操作。";return NO;}
    // Complete every fallible check and preference write before quiescing.
    // The public result distinguishes a retryable refusal from a process
    // that must exit before it may use any configuration again.
    if(managementQuiesced){if(error)*error=@"配置管理操作已结束，请重新打开凌触。";return NO;}
    if(nativeEditorActive || screenshotLoading || floatingPickerVisible || preparing || OPOriginalCloudTransferInProgress()) {
        if(error)*error=@"请等待方案、截图或云端操作完成，并关闭配置页面后重试。";return NO;
    }
    if(contextPinned && !OPExportOriginalProfileDefaults(fixedTarget,error))return NO;
    if(![NSUserDefaults.standardUserDefaults synchronize]) {
        if(error)*error=@"未能保存当前设置，请稍后重试。";return NO;
    }
    if(!replacing)return YES;
    managementQuiesced=YES;
    OPHideConfigurationSession();
    OPSetOriginalCloudSourceRequiredHandler(nil);
    stopConfigurationBluetooth();
    if(configurationLease>=0){close(configurationLease);configurationLease=-1;}
    return YES;
}
void OPConfigurationDidEnterBackground(void) {
    // Replacement has already saved and stopped the old editor. Writing its
    // cached defaults here would recreate cleared files or overwrite restore.
    if(managementQuiesced)return;
    if(!contextPinned){if(configurationLease>=0)exit(0);return;}
    NSString *error=nil;
    if(!OPExportOriginalProfileDefaults(fixedTarget,&error))NSLog(@"[SkyTouch] original profile defaults export failed: %@",error);
    OPHideConfigurationSession();
    stopConfigurationBluetooth();
    // Only true App backgrounding ends this fixed-target process. Permission
    // alerts and PHPicker transient resign-active do not call this path.
    // Exit also destroys original BLE timers, preventing its didDisconnect
    // auto-enableScan from racing the independent foreground engine session.
    // Applying already published/notified the immutable global revision.
    // Backgrounding alone must not reload it or restart a healthy engine.
    exit(0);
}
