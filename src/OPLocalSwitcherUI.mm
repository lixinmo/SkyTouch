#import "OPLocalSwitcherUI.h"
#import "OPLocalConfiguration.h"
#import "OPRuntimeControl.h"
#import "OPBluetoothBroker.h"
#import "OPControllerIdentity.h"
#import "OPLocalSwitcherFilter.h"
#import "OPInputSettings.h"
#include <cmath>
#include <signal.h>
#include <cerrno>
#include <climits>

static NSDictionary *OPCurrentSwitcherFilter(void) {
    if(OPPhoneModeSelected())return @{@"mode":@"phone",@"deviceType":@-1,@"deviceID":@""};
    NSDictionary *broker=OPBluetoothBrokerStatus();
    long long pid=[broker[@"pid"] longLongValue];
    BOOL alive=pid>1 && pid<=INT_MAX && (kill((pid_t)pid,0)==0 || errno==EPERM);
    NSDictionary *remembered=broker[@"currentPeripheralType"] ? nil : OPLastKnownControllerIdentity();
    return OPLocalSwitcherFilterState(broker,remembered,NSDate.date.timeIntervalSince1970,alive);
}

typedef NS_ENUM(NSInteger, OPLocalSwitcherAction) {
    OPLocalSwitcherActionNone=-1,
    OPLocalSwitcherActionCollapse=-2,
    OPLocalSwitcherActionStopMapping=-3,
    OPLocalSwitcherActionOpenApplication=-4,
};

@interface OPLocalSwitcher:UIViewController
@property(nonatomic,copy) NSString *target;
@property(nonatomic,copy) NSString *sourceName;
@property(nonatomic,copy) dispatch_block_t close;
@property(nonatomic) UIView *card;
@property(nonatomic) UILabel *titleLabel;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UIButton *closeButton;
@property(nonatomic) UIButton *stopButton;
@property(nonatomic) UIButton *openAppButton;
@property(nonatomic) UIScrollView *list;
@property(nonatomic) NSArray<NSDictionary *> *rows;
@property(nonatomic) NSArray<NSDictionary *> *allRows;
@property(nonatomic,copy) NSDictionary *filterState;
@property(nonatomic,copy) NSString *catalogError;
@property(nonatomic) NSTimeInterval lastConnectionCheck;
@property(nonatomic) NSMutableArray<UIButton *> *buttons;
@property(nonatomic) NSNumber *finger;
@property(nonatomic) NSInteger pressedIndex;
@property(nonatomic) CGPoint down;
@property(nonatomic) CGPoint lastPoint;
@property(nonatomic) CGFloat initialOffset;
@property(nonatomic) BOOL dragging;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL applying;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL openingApplication;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,copy) NSString *lastAppliedID;
@property(nonatomic,copy) NSString *lastError;
- (void)reload;
- (BOOL)refreshConnection;
- (void)renderRows;
- (void)consume:(NSDictionary *)snapshot;
@end

@implementation OPLocalSwitcher
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:.22];
    self.card=[UIView new];self.card.backgroundColor=UIColor.secondarySystemBackgroundColor;
    self.card.layer.cornerRadius=20;self.card.clipsToBounds=YES;[self.view addSubview:self.card];
    self.titleLabel=[UILabel new];self.titleLabel.text=@"切换本地方案";
    self.titleLabel.font=[UIFont boldSystemFontOfSize:21];[self.card addSubview:self.titleLabel];
    self.closeButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.closeButton setTitle:@"收起" forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.closeButton];
    self.openAppButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.openAppButton setTitle:@"打开凌触" forState:UIControlStateNormal];
    [self.openAppButton addTarget:self action:@selector(openApplication) forControlEvents:UIControlEventTouchUpInside];
    self.stopButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopButton setTitle:@"关闭映射" forState:UIControlStateNormal];
    [self.stopButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stopMapping) forControlEvents:UIControlEventTouchUpInside];
    for(UIButton *button in @[self.openAppButton,self.stopButton]) {
        button.backgroundColor=UIColor.tertiarySystemBackgroundColor;button.layer.cornerRadius=11;
        button.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [self.card addSubview:button];
    }
    self.statusLabel=[UILabel new];self.statusLabel.font=[UIFont systemFontOfSize:13];
    self.statusLabel.textColor=UIColor.secondaryLabelColor;self.statusLabel.numberOfLines=2;[self.card addSubview:self.statusLabel];
    self.list=[UIScrollView new];self.list.alwaysBounceVertical=NO;self.list.showsVerticalScrollIndicator=YES;
    self.list.scrollEnabled=NO;[self.card addSubview:self.list];self.buttons=[NSMutableArray array];
    self.pressedIndex=OPLocalSwitcherActionNone;[self reload];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGSize size=self.view.bounds.size;
    CGFloat width=MIN(640,MAX(220,size.width-56)),height=MIN(460,MAX(0,size.height-32));
    self.card.frame=CGRectMake((size.width-width)/2,(size.height-height)/2,width,height);
    self.titleLabel.frame=CGRectMake(20,15,width-110,30);
    self.closeButton.frame=CGRectMake(width-78,10,64,44);
    self.statusLabel.frame=CGRectMake(20,48,width-40,38);
    // Reserve the footer outside the scroll region, including on a 320-point
    // landscape display. Scrolling a row never moves a runtime control.
    const CGFloat footerY=height-58,buttonWidth=(width-36)/2;
    self.list.frame=CGRectMake(12,94,width-24,MAX(0,footerY-104));
    self.openAppButton.frame=CGRectMake(12,footerY,buttonWidth,44);
    self.stopButton.frame=CGRectMake(24+buttonWidth,footerY,buttonWidth,44);
    for(NSUInteger i=0;i<self.buttons.count;++i)self.buttons[i].frame=CGRectMake(0,i*65,self.list.bounds.size.width,59);
    self.list.contentSize=CGSizeMake(self.list.bounds.size.width,self.buttons.count*65);
    self.list.contentOffset=CGPointMake(0,MIN(self.list.contentOffset.y,MAX(0,self.list.contentSize.height-self.list.bounds.size.height)));
}
- (void)closePanel {if(self.close)self.close();}
- (void)stopMapping {
    if(self.stopping)return;
    [self cancelContact];self.stopping=YES;self.lastError=nil;
    self.stopButton.enabled=NO;self.openAppButton.enabled=NO;self.statusLabel.text=@"正在关闭映射和浮标…";
    __weak OPLocalSwitcher *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *error=nil;BOOL stopped=OPStopMappingRuntime(&error);
        dispatch_async(dispatch_get_main_queue(),^{
            OPLocalSwitcher *owner=weak;if(!owner || stopped)return;
            owner.stopping=NO;owner.stopButton.enabled=YES;owner.openAppButton.enabled=!owner.openingApplication;
            owner.lastError=error.length ? error : @"关闭映射失败，请重试。";owner.statusLabel.text=owner.lastError;
        });
    });
}
- (void)openApplication {
    if(self.stopping || self.openingApplication)return;
    [self cancelContact];self.openingApplication=YES;self.lastError=nil;
    self.openAppButton.enabled=NO;self.statusLabel.text=@"正在打开凌触…";
    __weak OPLocalSwitcher *weak=self;
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"lixinmo-skytouch://home"] options:@{}
        completionHandler:^(BOOL opened) {
            dispatch_async(dispatch_get_main_queue(),^{
                OPLocalSwitcher *owner=weak;if(!owner)return;
                owner.openingApplication=NO;owner.openAppButton.enabled=!owner.stopping;
                if(owner.stopping)return;
                if(opened)[owner closePanel];
                else {owner.lastError=@"无法打开凌触，请从桌面打开 App。";owner.statusLabel.text=owner.lastError;}
            });
        }];
}
- (void)cancelContact {
    self.finger=nil;self.dragging=NO;self.pressedIndex=OPLocalSwitcherActionNone;
    for(UIButton *button in self.buttons)button.highlighted=NO;
    self.closeButton.highlighted=NO;self.stopButton.highlighted=NO;self.openAppButton.highlighted=NO;
}
- (BOOL)refreshConnection {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(self.filterState && now-self.lastConnectionCheck<.25)return NO;
    self.lastConnectionCheck=now;
    NSDictionary *state=OPCurrentSwitcherFilter();
    if([self.filterState isEqual:state])return NO;
    self.filterState=state;[self cancelContact];
    self.list.contentOffset=CGPointZero;
    if(self.isViewLoaded)[self renderRows];
    return YES;
}
- (void)renderRows {
    [self cancelContact];
    self.rows=OPFilterLocalSwitcherRows(self.allRows ?: @[],self.filterState ?: OPCurrentSwitcherFilter());
    for(UIView *button in self.buttons)[button removeFromSuperview];[self.buttons removeAllObjects];
    for(NSUInteger index=0;index<self.rows.count;++index) {
        NSDictionary *row=self.rows[index];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
        button.tag=(NSInteger)index;button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
        button.backgroundColor=[row[@"isCurrent"] boolValue] ? [UIColor.systemBlueColor colorWithAlphaComponent:.15] : UIColor.tertiarySystemBackgroundColor;
        button.layer.cornerRadius=11;button.titleLabel.numberOfLines=2;button.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        button.contentEdgeInsets=UIEdgeInsetsMake(6,14,6,14);
        NSString *name=[row[@"name"] isKindOfClass:NSString.class] ? row[@"name"] : @"本地方案";
        NSString *kind=[row[@"deviceTypeName"] isKindOfClass:NSString.class] ? row[@"deviceTypeName"] : @"";
        [button setTitle:[NSString stringWithFormat:@"%@%@\n%@",[row[@"isCurrent"] boolValue] ? @"✓  " : @"",name,kind] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(selectButton:) forControlEvents:UIControlEventTouchUpInside];
        [self.list addSubview:button];[self.buttons addObject:button];
    }
    if(!self.stopping && !self.openingApplication && !self.applying) {
        NSString *mode=self.filterState[@"mode"];
        NSInteger type=[self.filterState[@"deviceType"] integerValue];
        NSString *typeName=type>=0 && type<=2 ? @[@"手柄",@"键鼠",@"半柄"][(NSUInteger)type] : @"";
        self.statusLabel.text=self.lastError.length ? self.lastError : self.catalogError.length ? self.catalogError :
            [mode isEqual:@"phone"] ? (self.rows.count ? [NSString stringWithFormat:@"%@ · 手机模式（轮盘暂停）",self.sourceName] :
                @"没有可用的手柄／半柄方案，请在凌触 App 中保存。") :
            [mode isEqual:@"identifying"] ? @"已连接，正在识别手柄类型…" :
            [mode isEqual:@"type"] ? (self.rows.count ? [NSString stringWithFormat:@"%@ · 仅显示%@方案",self.sourceName,typeName] :
                [NSString stringWithFormat:@"暂无%@本地方案，请在凌触 App 中导入或保存。",typeName]) :
            self.rows.count ? [NSString stringWithFormat:@"%@ · 未连接，显示全部方案",self.sourceName] :
                @"还没有本地方案。请在凌触 App 中导入或保存方案。";
    }
    [self.view setNeedsLayout];
}
- (void)reload {
    [self cancelContact];if(!self.isViewLoaded)return;
    [self refreshConnection];
    // Reopening or changing source must not admit a second publication while
    // the previous tap is still committing. Its completion refreshes this
    // controller's then-current source, including a source selected meanwhile.
    if(self.applying || self.stopping)return;
    NSUInteger generation=++self.generation;NSString *target=[self.target copy];
    if(!self.openingApplication)self.statusLabel.text=@"正在读取本地方案…";self.busy=YES;
    __weak OPLocalSwitcher *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *error=nil;NSArray *rows=OPLocalConfigurationsForTarget(target,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            OPLocalSwitcher *owner=weak;if(!owner || owner.generation!=generation)return;
            [owner cancelContact];
            owner.allRows=rows ?: @[];owner.catalogError=error;owner.busy=NO;
            owner.filterState=OPCurrentSwitcherFilter();[owner renderRows];
        });
    });
}
- (void)selectButton:(UIButton *)button { [self selectIndex:button.tag]; }
- (void)selectIndex:(NSInteger)index {
    if(self.busy || self.stopping || self.openingApplication || index<0 || index>=(NSInteger)self.rows.count)return;
    NSDictionary *row=self.rows[(NSUInteger)index];NSString *identifier=row[@"id"];
    if(![identifier isKindOfClass:NSString.class])return;
    self.applying=YES;self.busy=YES;self.statusLabel.text=@"正在切换方案…";
    NSString *target=[self.target copy],*name=[self.sourceName copy];
    __weak OPLocalSwitcher *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *error=nil;BOOL applied=NO;
        if(OPLocalSwitcherRowAllowed(row,OPCurrentSwitcherFilter()))applied=OPApplyLocalConfiguration(target,identifier,name,&error);
        else error=@"输入模式或方案类型已变化，请重新选择方案。";
        dispatch_async(dispatch_get_main_queue(),^{
            OPLocalSwitcher *owner=weak;if(!owner)return;
            owner.applying=NO;owner.busy=NO;
            if(owner.stopping)return;
            if(applied){owner.lastAppliedID=identifier;owner.lastError=nil;[owner reload];}
            else if(![owner.target isEqual:target])[owner reload];
            else {owner.lastError=error ?: @"方案切换失败，请重试。";owner.statusLabel.text=owner.lastError;}
        });
    });
}
- (CGPoint)localPoint:(NSDictionary *)path {
    CGPoint native=CGPointMake([path[@"x"] doubleValue],[path[@"y"] doubleValue]);
    UIWindow *window=self.view.window;
    CGPoint local=[window convertPoint:native fromCoordinateSpace:UIScreen.mainScreen.fixedCoordinateSpace];
    return [self.view convertPoint:local fromView:window];
}
- (NSInteger)indexAt:(CGPoint)point {
    if(CGRectContainsPoint(self.closeButton.bounds,[self.closeButton convertPoint:point fromView:self.view]))return OPLocalSwitcherActionCollapse;
    if(self.stopButton.enabled && CGRectContainsPoint(self.stopButton.bounds,[self.stopButton convertPoint:point fromView:self.view]))return OPLocalSwitcherActionStopMapping;
    if(self.openAppButton.enabled && CGRectContainsPoint(self.openAppButton.bounds,[self.openAppButton convertPoint:point fromView:self.view]))return OPLocalSwitcherActionOpenApplication;
    CGPoint local=[self.list convertPoint:point fromView:self.view];
    if(!CGRectContainsPoint(self.list.bounds,local))return OPLocalSwitcherActionNone;
    for(NSUInteger i=0;i<self.buttons.count;++i)if(CGRectContainsPoint(self.buttons[i].frame,local))return (NSInteger)i;
    return OPLocalSwitcherActionNone;
}
- (UIButton *)buttonForAction:(NSInteger)action {
    if(action==OPLocalSwitcherActionCollapse)return self.closeButton;
    if(action==OPLocalSwitcherActionStopMapping)return self.stopButton;
    if(action==OPLocalSwitcherActionOpenApplication)return self.openAppButton;
    return action>=0 && action<(NSInteger)self.buttons.count ? self.buttons[(NSUInteger)action] : nil;
}
- (void)finishContact:(BOOL)cancelled point:(CGPoint)point {
    NSInteger pressed=self.pressedIndex;BOOL activate=!cancelled && !self.dragging && [self indexAt:point]==pressed;
    [self cancelContact];
    if(activate && pressed==OPLocalSwitcherActionCollapse)[self closePanel];
    else if(activate && pressed==OPLocalSwitcherActionStopMapping)[self stopMapping];
    else if(activate && pressed==OPLocalSwitcherActionOpenApplication)[self openApplication];
    else if(activate && pressed>=0)[self selectIndex:pressed];
}
- (void)consume:(NSDictionary *)snapshot {
    // A connection change can move rows under a finger. Cancel that contact
    // and require a new press against the newly displayed list.
    if([self refreshConnection])return;
    if([snapshot[@"cancelAll"] boolValue]){[self cancelContact];return;}
    for(NSDictionary *path in snapshot[@"paths"]) {
        NSNumber *key=path[@"key"];unsigned mask=[path[@"mask"] unsignedIntValue];
        BOOL touching=([path[@"proximity"] unsignedCharValue]&(1U<<1))!=0;
        BOOL cancelled=(mask&(1U<<7)) || ([snapshot[@"cancel"] boolValue] && !touching);
        CGPoint point=[self localPoint:path];
        if(!self.finger && touching && !cancelled && (mask&(1U<<1))) {
            const NSInteger action=[self indexAt:point];
            if((self.busy || self.stopping || self.openingApplication) && action>=0)continue;
            CGPoint listPoint=[self.list convertPoint:point fromView:self.view];
            if(action==OPLocalSwitcherActionNone && !CGRectContainsPoint(self.list.bounds,listPoint))continue;
            self.finger=key;self.down=point;self.initialOffset=self.list.contentOffset.y;
            self.pressedIndex=action;self.dragging=NO;
            [self buttonForAction:action].highlighted=YES;
        }
        if(![key isEqual:self.finger])continue;
        self.lastPoint=point;
        if(std::hypot(point.x-self.down.x,point.y-self.down.y)>8)self.dragging=YES;
        if(self.dragging) {
            [self buttonForAction:self.pressedIndex].highlighted=NO;
            // A control gesture can only cancel its own press. Only contacts
            // that began inside the list may scroll it or activate a row.
            if(self.pressedIndex>=OPLocalSwitcherActionNone) {
                CGFloat offset=self.initialOffset+self.down.y-point.y;
                self.list.contentOffset=CGPointMake(0,MAX(0,MIN(offset,MAX(0,self.list.contentSize.height-self.list.bounds.size.height))));
            }
        }
        if(cancelled || !touching)[self finishContact:cancelled point:point];
    }
    // A terminal frame without a final path must never leave a pressed row.
    if([snapshot[@"allLifted"] boolValue] && self.finger)[self finishContact:[snapshot[@"cancel"] boolValue] point:self.lastPoint];
}
@end

UIViewController *OPMakeLocalSwitcher(NSString *target,NSString *name,dispatch_block_t close) {
    OPLocalSwitcher *controller=[OPLocalSwitcher new];controller.target=target;controller.sourceName=name;controller.close=close;return controller;
}
void OPRefreshLocalSwitcher(UIViewController *controller,NSString *target,NSString *name) {
    if(![controller isKindOfClass:OPLocalSwitcher.class])return;
    OPLocalSwitcher *switcher=(id)controller;switcher.target=target;switcher.sourceName=name;[switcher reload];
}
void OPRefreshLocalSwitcherConnection(UIViewController *controller) {
    if([controller isKindOfClass:OPLocalSwitcher.class])[(OPLocalSwitcher *)controller refreshConnection];
}
void OPConsumeLocalSwitcherInput(UIViewController *controller,NSDictionary *snapshot) {
    if([controller isKindOfClass:OPLocalSwitcher.class])[(OPLocalSwitcher *)controller consume:snapshot];
}
void OPCancelLocalSwitcherInput(UIViewController *controller) {
    if([controller isKindOfClass:OPLocalSwitcher.class])[(OPLocalSwitcher *)controller cancelContact];
}
BOOL OPLocalSwitcherBusy(UIViewController *controller) {
    return [controller isKindOfClass:OPLocalSwitcher.class] && ((OPLocalSwitcher *)controller).busy;
}
NSDictionary *OPLocalSwitcherStatus(UIViewController *controller) {
    if(![controller isKindOfClass:OPLocalSwitcher.class])return @{};
    OPLocalSwitcher *switcher=(id)controller;
    return @{@"rowCount":@(switcher.rows.count),@"busy":@(switcher.busy),@"stopping":@(switcher.stopping),@"openingApplication":@(switcher.openingApplication),
        @"allRowCount":@(switcher.allRows.count),@"filter":switcher.filterState ?: @{},
        @"lastAppliedID":switcher.lastAppliedID ?: @"",@"error":switcher.lastError ?: @""};
}
