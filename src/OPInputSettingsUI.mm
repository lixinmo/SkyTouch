#import "OPInputSettingsUI.h"
#import "OPInputSettings.h"
#import "OPPhoneProfile.h"
#import "OPGlobalProfile.h"
#import "OPSessionSupervisor.h"
#include "OPPhoneMotionMath.hpp"
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>

namespace {
NSArray<NSString *> *physicalKeys(){return @[@"action",@"volumeUp",@"volumeDown",@"side"];}
NSArray<NSString *> *physicalNames(){return @[@"操作按钮",@"音量 +",@"音量 −",@"侧边按钮（锁屏键）"];}
NSInteger selectedType(){NSDictionary *profile=OPReadGlobalProfile(nil);return profile ? [profile[@"deviceType"] integerValue] : 0;}
void alert(UIViewController *owner,NSString *message) {
    UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"输入设置" message:message preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [owner presentViewController:notice animated:YES completion:nil];
}
}
@interface OPLogicalKeyPicker:UITableViewController
@property(nonatomic,copy) NSArray<NSString *> *keys;
@property(nonatomic,copy) NSArray<NSString *> *displayNames;
@property(nonatomic,copy) NSString *selectedKey;
@property(nonatomic,copy) BOOL (^choose)(NSString *key);
@end
@implementation OPLogicalKeyPicker
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{(void)tableView;(void)section;return self.keys.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"key"] ?: [[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"key"];
    NSString *key=self.keys[indexPath.row];cell.textLabel.text=self.displayNames.count==self.keys.count ? self.displayNames[indexPath.row] : key;
    cell.textLabel.numberOfLines=0;
    cell.accessoryType=[key isEqual:self.selectedKey] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(self.choose && self.choose(self.keys[indexPath.row]))[self.navigationController popViewControllerAnimated:YES];
}
@end

@interface OPInputSettingsController:UITableViewController {
    int _configurationLease;
}
@property(nonatomic,copy) NSDictionary *settings;
@property(nonatomic,copy) NSString *leaseError;
- (void)acquireLease;
- (void)releaseLease;
- (BOOL)save:(NSDictionary *)settings;
@end
@implementation OPInputSettingsController
- (instancetype)initWithStyle:(UITableViewStyle)style {
    if((self=[super initWithStyle:style]))_configurationLease=-1;return self;
}
- (void)acquireLease {
    if(_configurationLease>=0)return;
    self.leaseError=nil;
    NSString *path=OPSupervisorConfigurationLockPath;
    if(!path.isAbsolutePath){self.leaseError=@"配置会话目录不可用，当前无法修改输入设置。";return;}
    int fd=open(path.fileSystemRepresentation,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
    struct stat opened{},named{};
    BOOL valid=fd>=0 && fstat(fd,&opened)==0 && S_ISREG(opened.st_mode) && opened.st_nlink==1 &&
        (opened.st_uid==0 || opened.st_uid==501) && !(opened.st_mode&0077);
    if(!valid){if(fd>=0)close(fd);self.leaseError=@"配置会话锁的类型、所有者或权限无效，当前无法修改输入设置。";return;}
    if(flock(fd,LOCK_EX|LOCK_NB)!=0) {
        int failure=errno;close(fd);
        self.leaseError=(failure==EWOULDBLOCK || failure==EAGAIN) ?
            @"原方案编辑会话仍在使用配置。请保存并退出原编辑器；如已退出，请回到桌面后重新打开凌触。当前设置不可编辑。" :
            @"无法取得配置会话锁，当前设置不可编辑。";
        return;
    }
    if(lstat(path.fileSystemRepresentation,&named) || !S_ISREG(named.st_mode) || named.st_nlink!=1 ||
       opened.st_dev!=named.st_dev || opened.st_ino!=named.st_ino) {
        close(fd);self.leaseError=@"配置会话锁已变化，请返回后重试。";return;
    }
    _configurationLease=fd;
}
- (void)releaseLease {if(_configurationLease>=0){close(_configurationLease);_configurationLease=-1;}}
- (void)didMoveToParentViewController:(UIViewController *)parent {
    [super didMoveToParentViewController:parent];
    // A pushed logical-key picker leaves this controller in the navigation
    // stack. Only removal of the settings root releases the editing lease.
    if(!parent)[self releaseLease];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(![self.navigationController.viewControllers containsObject:self])[self releaseLease];
}
- (void)dealloc {[self releaseLease];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"输入模式与手机按键";self.settings=OPReadInputSettings();}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];self.settings=OPReadInputSettings();[self.tableView reloadData];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{(void)tableView;return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{(void)tableView;return section==0 ? 2 : section==1 ? 4 : 4;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;return @[@"输入模式",@"手机实体键 → 方案逻辑键",@"手机体感（开发预览）"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return self.leaseError ?: @"编辑输入设置期间，映射触点与手机按键接管暂停；返回主页面后恢复。两个模式共用原方案，手机模式保留方案中的摇杆设置，但运行时停用摇杆及依赖摇杆的动作。手机模式仍为开发预览，请松开按键后切换。";
    if(section==1)return @"绑定全局生效；所选逻辑键仍执行原方案中的动作。未绑定的逻辑键继续保留。键鼠方案暂不支持手机输入。";
    return @"基础灵敏度与方案原有灵敏度共同生效，默认 1.0 倍；方案中的反向设置继续保留。手柄模式默认使用原体感来源，可选手机体感（开发预览，待更多手柄实测）。手机体感跟随手机转动。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting"] ?: [[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting"];
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    cell.textLabel.textColor=UIColor.labelColor;cell.selectionStyle=UITableViewCellSelectionStyleDefault;cell.accessoryType=UITableViewCellAccessoryNone;
    if(indexPath.section==0) {
        NSString *mode=indexPath.row==0 ? @"controller" : @"phone";
        cell.textLabel.text=indexPath.row==0 ? @"手柄模式" : @"手机模式 · 开发预览";
        cell.detailTextLabel.text=indexPath.row==0 ? ([self.settings[@"controllerMotion"] isEqual:@"phone"] ?
            @"手柄按键与摇杆；使用手机体感（开发预览）" : @"保留现有手柄按键、摇杆与体感行为") : @"手机四键 + 手机内置陀螺仪；无需手柄";
        if([self.settings[@"mode"] isEqual:mode])cell.accessoryType=UITableViewCellAccessoryCheckmark;
    } else if(indexPath.section==1) {
        cell.textLabel.text=physicalNames()[indexPath.row];cell.detailTextLabel.text=self.settings[@"phoneBindings"][physicalKeys()[indexPath.row]];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(indexPath.row<2) {
        cell.textLabel.text=indexPath.row==0 ? @"手机模式：手机内置陀螺仪" : @"手柄模式体感来源";
        cell.detailTextLabel.text=indexPath.row==0 ? @"转动手机控制方案中的体感视野" :
            [self.settings[@"controllerMotion"] isEqual:@"phone"] ? @"手机体感 · 开发预览" : @"手柄原体感（默认）";
        cell.selectionStyle=indexPath.row==0 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        if(indexPath.row==1)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSString *axis=indexPath.row==2 ? @"motionScaleX" : @"motionScaleY";
        cell.textLabel.text=indexPath.row==2 ? @"水平基础灵敏度" : @"垂直基础灵敏度";
        const double baseline=indexPath.row==2 ? op_phone::defaultMotionScaleX : op_phone::defaultMotionScaleY;
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%.3g ×",[self.settings[axis] doubleValue]/baseline];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    }
    if(_configurationLease<0){cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.textLabel.textColor=UIColor.secondaryLabelColor;}
    return cell;
}
- (BOOL)save:(NSDictionary *)settings {
    if(_configurationLease<0){alert(self,self.leaseError ?: @"配置会话已结束，请返回后重新打开输入设置。");return NO;}
    NSString *error=nil;
    if(!OPWriteInputSettings(settings,&error)){alert(self.navigationController.visibleViewController ?: self,error ?: @"保存失败。");return NO;}
    self.settings=OPReadInputSettings();[self.tableView reloadData];return YES;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(_configurationLease<0)return;
    if(indexPath.section==0) {
        NSString *mode=indexPath.row==0 ? @"controller" : @"phone";
        if([self.settings[@"mode"] isEqual:mode])return;
        if(indexPath.row==1 && !OPPhoneBindableKeys(selectedType()).count){alert(self,@"当前键鼠方案暂不支持手机输入。请先选择手柄或半柄方案，原方案不会被修改。");return;}
        NSMutableDictionary *changed=[self.settings mutableCopy];changed[@"mode"]=mode;[self save:changed];
    } else if(indexPath.section==1) {
        NSArray *keys=OPPhoneBindableKeys(selectedType());
        if(!keys.count){alert(self,@"当前键鼠方案的按键编码暂未支持，请先选择手柄或半柄方案。");return;}
        NSString *physical=physicalKeys()[indexPath.row];
        OPLogicalKeyPicker *picker=[[OPLogicalKeyPicker alloc]initWithStyle:UITableViewStyleInsetGrouped];
        picker.title=physicalNames()[indexPath.row];picker.keys=keys;picker.selectedKey=self.settings[@"phoneBindings"][physical];
        __weak OPInputSettingsController *weak=self;
        picker.choose=^BOOL(NSString *key){
            OPInputSettingsController *owner=weak;if(!owner)return NO;
            NSMutableDictionary *changed=[owner.settings mutableCopy],*bindings=[changed[@"phoneBindings"] mutableCopy];
            bindings[physical]=key;changed[@"phoneBindings"]=bindings;return [owner save:changed];
        };
        [self.navigationController pushViewController:picker animated:YES];
    } else if(indexPath.row==1) {
        OPLogicalKeyPicker *picker=[[OPLogicalKeyPicker alloc]initWithStyle:UITableViewStyleInsetGrouped];
        picker.title=@"手柄模式体感来源";picker.keys=@[@"controller",@"phone"];
        picker.displayNames=@[@"手柄原体感（默认）",@"手机体感（开发预览）"];
        picker.selectedKey=self.settings[@"controllerMotion"];
        __weak OPInputSettingsController *weak=self;
        picker.choose=^BOOL(NSString *source){
            OPInputSettingsController *owner=weak;if(!owner)return NO;
            if([source isEqual:@"phone"] && !OPPhoneBindableKeys(selectedType()).count) {
                alert(owner.navigationController.visibleViewController ?: owner,@"当前键鼠方案暂不支持使用手机体感。请选择手柄或半柄方案，原方案不会被修改。");return NO;
            }
            if([owner.settings[@"controllerMotion"] isEqual:source])return YES;
            NSMutableDictionary *changed=[owner.settings mutableCopy];changed[@"controllerMotion"]=source;return [owner save:changed];
        };
        [self.navigationController pushViewController:picker animated:YES];
    } else if(indexPath.row>=2) {
        NSString *key=indexPath.row==2 ? @"motionScaleX" : @"motionScaleY";
        const double baseline=indexPath.row==2 ? op_phone::defaultMotionScaleX : op_phone::defaultMotionScaleY;
        UIAlertController *editor=[UIAlertController alertControllerWithTitle:indexPath.row==2 ? @"水平基础灵敏度" : @"垂直基础灵敏度" message:@"输入 0.1 至 10 倍，默认 1.0 倍。与方案原有灵敏度共同生效。" preferredStyle:UIAlertControllerStyleAlert];
        [editor addTextFieldWithConfigurationHandler:^(UITextField *field){field.keyboardType=UIKeyboardTypeDecimalPad;field.text=[NSString stringWithFormat:@"%.3g",[self.settings[key] doubleValue]/baseline];}];
        [editor addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak OPInputSettingsController *weak=self;
        __weak UIAlertController *weakEditor=editor;
        [editor addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            OPInputSettingsController *owner=weak;if(!owner)return;
            NSString *text=[weakEditor.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSScanner *scanner=[NSScanner scannerWithString:text ?: @""];double value=0;
            if(![scanner scanDouble:&value] || !scanner.isAtEnd || !std::isfinite(value) || value<.1 || value>10){alert(owner,@"请输入 0.1 至 10 之间的倍率。");return;}
            NSMutableDictionary *changed=[owner.settings mutableCopy];changed[key]=@(value*baseline);[owner save:changed];
        }]];
        [self presentViewController:editor animated:YES completion:nil];
    }
}
@end
UIViewController *OPMakeInputSettingsController(void) {
    OPInputSettingsController *controller=[[OPInputSettingsController alloc]initWithStyle:UITableViewStyleInsetGrouped];
    // Acquire before presentation so the supervisor can cancel the active
    // engine before any settings control accepts user input.
    [controller acquireLease];return controller;
}
