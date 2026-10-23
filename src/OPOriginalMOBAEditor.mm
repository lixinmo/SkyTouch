#import "OPOriginalMOBAEditor.h"
#import "OPOriginalMOBAEditorState.h"
#import "OPOriginalMotionPersistence.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <cstring>

namespace op_moba_editor {
using VoidMethod = void (*)(id, SEL);
using ObjectMethod = id (*)(id, SEL);
using IntMethod = int (*)(id, SEL);
using SetIntMethod = void (*)(id, SEL, int);
static Class editorClass = Nil, itemClass = Nil, keyClass = Nil;
static Method initMethod = nullptr, updateMethod = nullptr, saveMethod = nullptr;
static IMP originalInit = nullptr, originalUpdate = nullptr, originalSave = nullptr;
static BOOL installed = NO;
static char panelKey;

static BOOL signature(Method method, char result, const char *arguments) {
    if (!method || method_getNumberOfArguments(method) != 2 + std::strlen(arguments)) return NO;
    NSMethodSignature *value = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    auto matches = [](const char *type, char expected) {
        if (!type) return false;
        while (*type && std::strchr("rnNoORV", *type)) ++type;
        return *type == expected && (type[1] == '\0' || (expected == '@' && type[1] == '"'));
    };
    if (!value || !matches(value.methodReturnType, result) ||
        !matches([value getArgumentTypeAtIndex:0], '@') || !matches([value getArgumentTypeAtIndex:1], ':')) return NO;
    for (NSUInteger i = 0; i < std::strlen(arguments); ++i)
        if (!matches([value getArgumentTypeAtIndex:i + 2], arguments[i])) return NO;
    return YES;
}
static BOOL owns(Class cls, Method method) {
    unsigned count = 0; Method *list = class_copyMethodList(cls, &count); BOOL found = NO;
    for (unsigned i = 0; i < count; ++i) if (list[i] == method) { found = YES; break; }
    free(list); return found;
}
static BOOL subclasses(Class cls, Class expected) {
    for (Class current = cls; current; current = class_getSuperclass(current)) if (current == expected) return YES;
    return NO;
}
static void fail(NSString *message) {
    [NSException raise:NSInternalInconsistencyException format:@"MOBA 体感编辑失败：%@", message];
}
static id getObject(id target, SEL selector) {
    if (!target) return nil;
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!signature(method, '@', "")) { fail(@"原界面对象接口不匹配"); return nil; }
    return ((ObjectMethod)method_getImplementation(method))(target, selector);
}
static int getInt(id target, SEL selector) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!target || !signature(method, 'i', "")) { fail(@"原配置数值接口不匹配"); return 0; }
    return ((IntMethod)method_getImplementation(method))(target, selector);
}
static void setInt(id target, SEL selector, int value) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!target || !signature(method, 'v', "i")) { fail(@"原配置保存接口不匹配"); return; }
    ((SetIntMethod)method_getImplementation(method))(target, selector, value);
}
static id propertyFor(id editor) {
    id item = getObject(editor, @selector(selfKey));
    if (!item) return nil;
    if (![item isKindOfClass:itemClass]) { fail(@"原按键对象不匹配"); return nil; }
    id property = getObject(item, @selector(propertyKey));
    if (property && ![property isKindOfClass:keyClass]) { fail(@"原按键配置不匹配"); return nil; }
    return property;
}
static UIView *viewFor(id editor, SEL selector) {
    id value = getObject(editor, selector);
    if (value && ![value isKindOfClass:UIView.class]) { fail(@"原界面布局接口不匹配"); return nil; }
    return value;
}
} // namespace op_moba_editor

@interface OPMOBAMotionPanel : UIView {
@public
    op_moba_editor::EditDraft draft;
}
@property(nonatomic, strong) id property;
@property(nonatomic, strong) NSArray<UIView *> *coveredViews;
@property(nonatomic, strong) NSArray<NSNumber *> *originalHidden;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *noteLabel;
@property(nonatomic, strong) UILabel *missingLabel;
@property(nonatomic, strong) NSArray<UILabel *> *axisLabels;
@property(nonatomic, strong) NSArray<UILabel *> *reverseLabels;
@property(nonatomic, strong) NSArray<UISlider *> *sliders;
@property(nonatomic, strong) NSArray<UISwitch *> *switches;
- (instancetype)initWithProperty:(id)property;
- (void)restoreCoveredViews;
@end

@implementation OPMOBAMotionPanel
- (instancetype)initWithProperty:(id)property {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    using namespace op_moba_editor;
    self.property = property;
    draft.horizontal = AxisDraft(getInt(property, @selector(senty_x)), OPOriginalMotionSensitivityIsPresent(property, YES));
    draft.vertical = AxisDraft(getInt(property, @selector(senty_y)), OPOriginalMotionSensitivityIsPresent(property, NO));
    self.backgroundColor = [UIColor colorWithWhite:35.0 / 255.0 alpha:1];
    self.accessibilityIdentifier = @"OPMOBAMotionEditor";
    self.scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    self.scroll.alwaysBounceVertical = NO;
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self addSubview:self.scroll];
    self.titleLabel = [self labelWithSize:19 weight:UIFontWeightSemibold];
    self.titleLabel.text = @"MOBA 体感视野";
    self.noteLabel = [self labelWithSize:12 weight:UIFontWeightRegular];
    self.noteLabel.text = @"调整左右、上下灵敏度；保留云端锁定设置。";
    self.noteLabel.numberOfLines = 2;
    self.missingLabel = [self labelWithSize:12 weight:UIFontWeightRegular];
    self.missingLabel.numberOfLines = 0;
    self.missingLabel.textColor = [UIColor colorWithRed:1 green:0.76 blue:0.39 alpha:1];
    self.missingLabel.text = @"部分参数未保存。重新下载云端配置可恢复，也可调整对应滑块重新设置。";
    NSMutableArray *labels = [NSMutableArray array], *reverses = [NSMutableArray array];
    NSMutableArray *sliders = [NSMutableArray array], *switches = [NSMutableArray array];
    for (NSUInteger axis = 0; axis < 2; ++axis) {
        UILabel *label = [self labelWithSize:15 weight:UIFontWeightMedium]; [labels addObject:label];
        UILabel *reverse = [self labelWithSize:13 weight:UIFontWeightRegular];
        reverse.text = @"反向"; [reverses addObject:reverse];
        UISlider *slider = [[UISlider alloc] init];
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.18 green:0.77 blue:0.89 alpha:1];
        slider.maximumTrackTintColor = [UIColor colorWithWhite:0.4 alpha:1];
        slider.minimumValue = 1; slider.maximumValue = 127; slider.tag = (NSInteger)axis;
        slider.accessibilityLabel = axis == 0 ? @"左右体感灵敏度" : @"上下体感灵敏度";
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.scroll addSubview:slider]; [sliders addObject:slider];
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.tag = (NSInteger)axis;
        toggle.onTintColor = slider.minimumTrackTintColor;
        toggle.accessibilityLabel = axis == 0 ? @"左右体感反向" : @"上下体感反向";
        [toggle addTarget:self action:@selector(reverseChanged:) forControlEvents:UIControlEventValueChanged];
        [self.scroll addSubview:toggle]; [switches addObject:toggle];
    }
    self.axisLabels = labels; self.reverseLabels = reverses; self.sliders = sliders; self.switches = switches;
    [self refresh];
    return self;
}
- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:0.94 alpha:1];
    [self.scroll addSubview:label]; return label;
}
- (void)refresh {
    for (NSUInteger axis = 0; axis < 2; ++axis) {
        const auto &value = axis == 0 ? draft.horizontal : draft.vertical;
        NSString *name = axis == 0 ? @"左右" : @"上下";
        if (!value.present && !value.touched) self.axisLabels[axis].text = [name stringByAppendingString:@"：未保存（调整以设置）"];
        else if (!value.touched && (value.original == 0 || value.original > 127 || value.original < -127))
            self.axisLabels[axis].text = [NSString stringWithFormat:@"%@：原值 %d（保持）", name, value.original];
        else self.axisLabels[axis].text = [NSString stringWithFormat:@"%@：%d", name, value.magnitude];
        self.sliders[axis].value = (float)value.magnitude;
        self.switches[axis].on = value.reversed;
    }
    self.missingLabel.hidden = draft.horizontal.present && draft.vertical.present;
}
- (void)sliderChanged:(UISlider *)sender {
    auto &value = sender.tag == 0 ? draft.horizontal : draft.vertical;
    value.setMagnitude(sender.value); [self refresh];
}
- (void)reverseChanged:(UISwitch *)sender {
    auto &value = sender.tag == 0 ? draft.horizontal : draft.vertical;
    value.setReversed(sender.on); [self refresh];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.scroll.frame = self.bounds;
    const CGFloat width = CGRectGetWidth(self.bounds), inset = 16;
    self.titleLabel.frame = CGRectMake(inset, 10, MAX(0, width - inset * 2), 24);
    self.noteLabel.frame = CGRectMake(inset, 38, MAX(0, width - inset * 2), 34);
    for (NSUInteger axis = 0; axis < 2; ++axis) {
        CGFloat y = 78 + axis * 78;
        self.axisLabels[axis].frame = CGRectMake(inset, y, MAX(0, width - 120), 24);
        self.reverseLabels[axis].frame = CGRectMake(MAX(inset, width - 108), y, 34, 24);
        self.switches[axis].frame = CGRectMake(MAX(inset, width - 68), y - 3, 51, 31);
        self.sliders[axis].frame = CGRectMake(inset, y + 28, MAX(0, width - inset * 2), 30);
    }
    self.missingLabel.frame = CGRectMake(inset, 240, MAX(0, width - inset * 2), 44);
    self.scroll.contentSize = CGSizeMake(width, self.missingLabel.hidden ? 238 : 296);
}
- (void)restoreCoveredViews {
    for (NSUInteger i = 0; i < self.coveredViews.count; ++i) self.coveredViews[i].hidden = self.originalHidden[i].boolValue;
}
@end

namespace op_moba_editor {
static void removePanel(id editor) {
    OPMOBAMotionPanel *panel = objc_getAssociatedObject(editor, &panelKey);
    if (!panel) return;
    [panel restoreCoveredViews]; [panel removeFromSuperview];
    objc_setAssociatedObject(editor, &panelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void ensurePanel(id editor) {
    id property = propertyFor(editor);
    OPMOBAMotionPanel *panel = objc_getAssociatedObject(editor, &panelKey);
    if (!property || getInt(property, @selector(type)) != 35) { if (panel) removePanel(editor); return; }
    if (panel && panel.property != property) { removePanel(editor); panel = nil; }
    UIView *host = (UIView *)editor;
    NSArray<UIView *> *bars = @[(viewFor(editor, @selector(leftTypeBar)) ?: [UIView new]),
                               (viewFor(editor, @selector(leftSubTypeBar)) ?: [UIView new]),
                               (viewFor(editor, @selector(rightBar)) ?: [UIView new])];
    CGRect content = CGRectNull;
    for (UIView *bar in bars) if ([bar isDescendantOfView:host] && !CGRectIsEmpty(bar.bounds))
        content = CGRectUnion(content, [host convertRect:bar.bounds fromView:bar]);
    if (CGRectIsNull(content) || CGRectIsEmpty(content)) { fail(@"原编辑区布局不可用，未覆盖体感配置"); return; }
    if (!panel) {
        panel = [[OPMOBAMotionPanel alloc] initWithProperty:property];
        NSMutableArray *covered = [bars mutableCopy];
        UIView *display = viewFor(editor, @selector(topBarBtnDisplay));
        if (display) [covered addObject:display];
        UIView *displayImage = viewFor(editor, @selector(topBarImgDisplay));
        if (displayImage) [covered addObject:displayImage];
        NSMutableArray *hidden = [NSMutableArray array];
        for (UIView *view in covered) [hidden addObject:@(view.hidden)];
        panel.coveredViews = covered; panel.originalHidden = hidden;
        [host addSubview:panel];
        objc_setAssociatedObject(editor, &panelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *view in panel.coveredViews) view.hidden = YES;
    panel.frame = content;
    [panel setNeedsLayout]; [host bringSubviewToFront:panel];
}
static void initData(id self, SEL command) {
    if (!NSThread.isMainThread) { fail(@"编辑界面必须在主线程初始化"); return; }
    removePanel(self); ((VoidMethod)originalInit)(self, command); ensurePanel(self);
}
static void updateUI(id self, SEL command) {
    if (!NSThread.isMainThread) { fail(@"编辑界面必须在主线程更新"); return; }
    ((VoidMethod)originalUpdate)(self, command); ensurePanel(self);
}
static void saveData(id self, SEL command) {
    if (!NSThread.isMainThread) { fail(@"编辑界面必须在主线程保存"); return; }
    id property = propertyFor(self);
    if (!property || getInt(property, @selector(type)) != 35) {
        ((VoidMethod)originalSave)(self, command); return;
    }
    OPMOBAMotionPanel *panel = objc_getAssociatedObject(self, &panelKey);
    if (!panel || panel.property != property) { fail(@"体感编辑状态不可用，未调用旧版覆盖保存"); return; }
    // Do not call the vendor saveData for type 35: its MOBA page writes type 5
    // and changes unrelated fields. The original confirm handler will still
    // call onFKPFinish:selfKey after this method returns.
    BOOL horizontal = panel->draft.horizontal.changed(), vertical = panel->draft.vertical.changed();
    panel->draft.writeChanged([&](bool x, int value) {
        setInt(property, x ? @selector(setSenty_x:) : @selector(setSenty_y:), value);
    });
    if (horizontal || vertical) OPMarkOriginalMotionSensitivityAxesPresent(property, horizontal, vertical);
    panel->draft.horizontal.accepted(); panel->draft.vertical.accepted();
}
static BOOL matchesInstalled(void) {
    return installed && method_getImplementation(initMethod) == (IMP)initData &&
        method_getImplementation(updateMethod) == (IMP)updateUI && method_getImplementation(saveMethod) == (IMP)saveData;
}
} // namespace op_moba_editor

BOOL OPInstallOriginalMOBAEditor(NSString **error) {
    using namespace op_moba_editor;
    if (error) *error = nil;
    if (!NSThread.isMainThread) { if (error) *error = @"MOBA 体感编辑器必须在主线程安装"; return NO; }
    if (installed) { BOOL valid = matchesInstalled(); if (!valid && error) *error = @"MOBA 体感编辑器方法已被替换"; return valid; }
    Class editor = NSClassFromString(@"FZCFGFloatingKeyProperty"), item = NSClassFromString(@"FZCFGFloatingItem");
    Class property = NSClassFromString(@"FZCFGPropertyKey");
    Method init = class_getInstanceMethod(editor, @selector(initAllData));
    Method update = class_getInstanceMethod(editor, @selector(updateUI));
    Method save = class_getInstanceMethod(editor, @selector(saveData));
    BOOL valid = editor && item && property && subclasses(editor, objc_getClass("UIView")) &&
        signature(init, 'v', "") && signature(update, 'v', "") && signature(save, 'v', "") &&
        owns(editor, init) && owns(editor, update) && owns(editor, save);
    for (NSString *name in @[@"selfKey", @"leftTypeBar", @"leftSubTypeBar", @"rightBar", @"topBarBtnDisplay", @"topBarImgDisplay"])
        valid = valid && signature(class_getInstanceMethod(editor, NSSelectorFromString(name)), '@', "");
    valid = valid && signature(class_getInstanceMethod(item, @selector(propertyKey)), '@', "");
    for (NSString *name in @[@"type", @"senty_x", @"senty_y"])
        valid = valid && signature(class_getInstanceMethod(property, NSSelectorFromString(name)), 'i', "");
    for (NSString *name in @[@"setSenty_x:", @"setSenty_y:"])
        valid = valid && signature(class_getInstanceMethod(property, NSSelectorFromString(name)), 'v', "i");
    if (!valid) { if (error) *error = @"原 MOBA 编辑接口 ABI 不匹配，未安装兼容编辑器"; return NO; }
    editorClass = editor; itemClass = item; keyClass = property;
    initMethod = init; updateMethod = update; saveMethod = save;
    originalInit = method_getImplementation(init); originalUpdate = method_getImplementation(update); originalSave = method_getImplementation(save);
    struct Change { Method method; IMP expected; IMP replacement; IMP observed; };
    Change changes[] = {{init, originalInit, (IMP)initData, nullptr}, {update, originalUpdate, (IMP)updateUI, nullptr},
                        {save, originalSave, (IMP)saveData, nullptr}};
    unsigned changed = 0; valid = YES;
    for (auto &change : changes) {
        change.observed = method_setImplementation(change.method, change.replacement); ++changed;
        if (change.observed != change.expected || method_getImplementation(change.method) != change.replacement) { valid = NO; break; }
    }
    if (!valid) {
        while (changed) { auto &change = changes[--changed];
            if (method_getImplementation(change.method) == change.replacement) method_setImplementation(change.method, change.observed); }
        if (error) *error = @"MOBA 体感编辑器安装冲突，已撤销"; return NO;
    }
    installed = YES; return YES;
}
