#import "OPConfigurationManagerUI.h"
#import "OPConfigurationManager.h"
#import "OPConfigurationManagerPresentation.h"
#import "OPStoragePaths.h"
#include <cmath>
#include <cstdlib>

static BOOL OPManagementUIBusy=NO;
BOOL OPConfigurationManagementUIIsBusy(void) { return OPManagementUIBusy; }

static NSString *OPBackupDateDescription(id value) {
    NSTimeInterval time=OPConfigurationBackupTimestamp(value);
    if(time<=0)return @"日期未知";
    NSDate *date=[NSDate dateWithTimeIntervalSince1970:time];
    NSDateFormatter *formatter=[NSDateFormatter new];
    formatter.dateStyle=NSDateFormatterMediumStyle;formatter.timeStyle=NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

@interface OPConfigurationBackupPicker : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *backups;
@property(nonatomic,copy) void (^chooseBackup)(NSDictionary *backup);
@end

@implementation OPConfigurationBackupPicker
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"选择配置备份";
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;(void)section;return (NSInteger)self.backups.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"backup"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"];
    NSDictionary *backup=self.backups[(NSUInteger)indexPath.row];
    cell.textLabel.text=backup[@"filename"];cell.textLabel.numberOfLines=0;
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",OPBackupDateDescription(backup[@"createdAt"]),
        [NSByteCountFormatter stringFromByteCount:MAX(0,[backup[@"size"] longLongValue]) countStyle:NSByteCountFormatterCountStyleFile]];
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityHint=@"选择此备份以恢复配置";
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(self.chooseBackup && !OPManagementUIBusy)self.chooseBackup(self.backups[(NSUInteger)indexPath.row]);
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;(void)section;return @"请选择要恢复的备份。确认后会覆盖当前方案、截图和设置，备份文件本身会保留。";
}
@end

@interface OPConfigurationManagerController : UIViewController
@property(nonatomic) NSArray<UIButton *> *actionButtons;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) UIViewController *busyController;
@property(nonatomic) UIBarButtonItem *previousRightButton;
@property(nonatomic) BOOL previousBackHidden;
@property(nonatomic) BOOL previousPopEnabled;
@property(nonatomic) BOOL busy;
@end

@implementation OPConfigurationManagerController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"管理配置";self.view.backgroundColor=UIColor.systemBackgroundColor;
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=20;
    stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    UILabel *intro=[UILabel new];intro.numberOfLines=0;intro.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    intro.adjustsFontForContentSizeCategory=YES;
    intro.text=@"管理所有游戏的本地方案、截图和设置。备份与恢复前会先关闭映射，恢复完成后需重新打开凌触。";
    [stack addArrangedSubview:intro];
    NSMutableArray<UIButton *> *buttons=[NSMutableArray array];
    NSArray<NSString *> *titles=@[@"备份当前配置",@"恢复当前配置",@"清除配置"];
    const SEL actions[]={@selector(backupConfiguration),@selector(chooseBackup),@selector(confirmClear)};
    for(NSUInteger index=0;index<titles.count;++index) {
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *style=index==0 ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration borderedButtonConfiguration];
        if(index==2)style.baseForegroundColor=UIColor.systemRedColor;
        style.contentInsets=NSDirectionalEdgeInsetsMake(14,16,14,16);button.configuration=style;
        [button setTitle:titles[index] forState:UIControlStateNormal];
        [button addTarget:self action:actions[index] forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];[buttons addObject:button];
    }
    self.actionButtons=buttons;
    UILabel *description=[UILabel new];description.numberOfLines=0;description.textColor=UIColor.secondaryLabelColor;
    description.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];description.adjustsFontForContentSizeCategory=YES;
    description.text=@"备份固定保存为 /var/mobile/Media/com.lixinmo.skytouchSetting.skytouchbackup。再次备份会覆盖此文件。\n\n普通卸载会保留配置和备份。若要彻底清除，请先使用“清除配置”，再到包管理器卸载凌触。";
    [stack addArrangedSubview:description];
    self.statusLabel=[UILabel new];self.statusLabel.numberOfLines=0;self.statusLabel.textColor=UIColor.secondaryLabelColor;
    self.statusLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.statusLabel.adjustsFontForContentSizeCategory=YES;
    [stack addArrangedSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]]];
}
- (UIViewController *)alertPresenter { return self.navigationController.topViewController ?: self; }
- (void)beginOperation:(NSString *)message {
    self.busy=YES;OPManagementUIBusy=YES;self.statusLabel.text=message;
    for(UIButton *button in self.actionButtons)button.enabled=NO;
    self.busyController=[self alertPresenter];
    self.previousBackHidden=self.busyController.navigationItem.hidesBackButton;
    self.previousRightButton=self.busyController.navigationItem.rightBarButtonItem;
    self.previousPopEnabled=self.navigationController.interactivePopGestureRecognizer.enabled;
    self.busyController.navigationItem.hidesBackButton=YES;
    self.navigationController.interactivePopGestureRecognizer.enabled=NO;
    self.busyController.view.userInteractionEnabled=NO;
    UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.accessibilityLabel=message;[spinner startAnimating];
    self.busyController.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:spinner];
}
- (void)endOperation {
    self.busy=NO;OPManagementUIBusy=NO;
    for(UIButton *button in self.actionButtons)button.enabled=YES;
    self.busyController.navigationItem.hidesBackButton=self.previousBackHidden;
    self.busyController.navigationItem.rightBarButtonItem=self.previousRightButton;
    self.busyController.view.userInteractionEnabled=YES;
    self.navigationController.interactivePopGestureRecognizer.enabled=self.previousPopEnabled;
    self.busyController=nil;self.previousRightButton=nil;self.statusLabel.text=@"";
}
- (void)showMessage:(NSString *)title detail:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
}
- (void)performOperation:(NSString *)operation basename:(NSString *)basename message:(NSString *)message
    completion:(void (^)(NSDictionary *result))completion {
    if(self.busy)return;[self beginOperation:message];
    OPPerformConfigurationManagement(operation,basename,^(NSDictionary *result,NSString *error) {
        dispatch_async(dispatch_get_main_queue(),^{
            if(error.length || ![result isKindOfClass:NSDictionary.class]) {
                if([result isKindOfClass:NSDictionary.class] && [result[@"restartRequired"] boolValue]) {
                    NSString *detail=[NSString stringWithFormat:@"%@\n\n请重新打开凌触后再继续操作。",error.length ? error : @"操作未完成，原配置已保留。"];
                    [self requireRestart:@"操作未完成" detail:detail];
                    return;
                }
                [self endOperation];
                [self showMessage:@"操作未完成" detail:error.length ? error : @"未能完成操作，请稍后重试。"];
                return;
            }
            // Successful restore/clear deliberately remains blocked until exit.
            // This avoids returning to controllers with stale configuration.
            if(![result[@"restartRequired"] boolValue])[self endOperation];
            completion(result);
        });
    });
}
- (void)openBackupInFilza:(NSString *)path {
    NSURL *url=OPStorageNativeBackupPathIsSafe(path) ? OPConfigurationBackupFileURL(path) : nil;
    if(!url){[self showMessage:@"无法打开 Filza" detail:@"备份已保存到手机的 /var/mobile/Media，但无法生成文件链接。可稍后在 Filza 中查看该目录。"] ;return;}
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if(success)return;
        dispatch_async(dispatch_get_main_queue(),^{
            [self showMessage:@"无法打开 Filza" detail:@"备份已保存到手机的 /var/mobile/Media。请确认已安装 Filza，并允许通过链接打开；也可稍后自行查看备份目录。"];
        });
    }];
}
- (void)backupConfiguration {
    [self performOperation:@"backup" basename:nil message:@"正在备份配置…" completion:^(NSDictionary *result) {
        NSString *filename=[result[@"backupFilename"] isKindOfClass:NSString.class] ? result[@"backupFilename"] : @"配置备份";
        NSString *path=[result[@"backupPath"] isKindOfClass:NSString.class] ? result[@"backupPath"] : @"";
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"备份完成"
            message:[NSString stringWithFormat:@"已保存到手机的 /var/mobile/Media：\n%@\n\n再次备份会覆盖此文件。可在 Filza 中查看或复制到其他位置保存。",filename] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"在 Filza 中打开" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self openBackupInFilza:path];
        }]];
        [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
    }];
}
- (void)chooseBackup {
    [self performOperation:@"list" basename:nil message:@"正在读取备份…" completion:^(NSDictionary *result) {
        NSArray<NSDictionary *> *backups=OPConfigurationSortedBackupRows(result[@"backups"]);
        if(!backups.count){[self showMessage:@"没有可恢复的备份" detail:@"尚未找到配置备份。请先使用“备份当前配置”。"];return;}
        OPConfigurationBackupPicker *picker=[[OPConfigurationBackupPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
        picker.backups=backups;
        __weak OPConfigurationManagerController *weakSelf=self;
        picker.chooseBackup=^(NSDictionary *backup){[weakSelf confirmRestore:backup];};
        [self.navigationController pushViewController:picker animated:YES];
    }];
}
- (void)confirmRestore:(NSDictionary *)backup {
    if(self.busy)return;
    NSString *filename=backup[@"filename"];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"恢复此备份？"
        message:[NSString stringWithFormat:@"%@\n\n恢复会关闭映射，并用备份覆盖当前所有游戏的方案、截图和设置。当前配置不会保留，建议先备份。恢复后需重新打开凌触。",filename]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"覆盖并恢复" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self performOperation:@"restore" basename:filename message:@"正在恢复配置…" completion:^(__unused NSDictionary *result) {
            [self requireRestart:@"配置已恢复" detail:@"方案、截图和设置已恢复。请重新打开凌触，映射保持关闭。"];
        }];
    }]];
    [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
}
- (void)confirmClear {
    if(self.busy)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除全部配置和备份？"
        message:@"此操作会关闭映射，并永久删除所有本地方案、背景截图、设置、账号登录状态，以及备份目录内的所有凌触配置备份。\n\n删除后无法恢复。如需保留备份，请先在 Filza 中复制到其他位置。清除后可在包管理器卸载凌触。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除全部配置和备份" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self performOperation:@"clear" basename:nil message:@"正在清除配置和备份…" completion:^(__unused NSDictionary *result) {
            [self requireRestart:@"配置和备份已清除" detail:@"所有本地方案、截图、设置和配置备份已清除。点击“确定”退出凌触；可重新打开开始配置，或到包管理器卸载凌触。"];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)requireRestart:(NSString *)title detail:(NSString *)detail {
    // No further action is permitted against the pre-restore in-memory state.
    self.statusLabel.text=@"请重新打开凌触后再继续操作。";
    self.busyController.navigationItem.rightBarButtonItem=nil;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        std::exit(0);
    }]];
    [[self alertPresenter] presentViewController:alert animated:YES completion:nil];
}
@end

UIViewController *OPMakeConfigurationManager(void) { return [OPConfigurationManagerController new]; }
