# 凌触 SkyTouch

凌触是面向 RootHide 环境的 iPhone 触屏映射工具。当前开发分支为 **2.0 开发预览**，稳定基线为 1.0.0。维护账号：`lixinmo`。

2.0 在同一 App、同一方案库内增加手机模式。升级默认保持原手柄模式，原配置、摇杆、宏和体感来源均保留。

| 功能 | 手柄模式 | 手机模式 |
| --- | --- | --- |
| 按键 | 已支持手柄的原输入 | 手机操作按钮、音量＋、音量−、侧边按钮 |
| 四键绑定 | 保留手柄定义 | 可配置，默认分别为 LB、A、B、LT |
| 摇杆／轮盘 | 原样执行 | 本次运行暂停，原方案中保留 |
| 体感 | 默认原手柄来源，可选手机体感（开发预览） | 手机原生陀螺仪 |
| 方案与浮标 | 共用 | 共用 |

在首页打开“输入模式与手机按键”切换模式、修改绑定和基础灵敏度。进入这段设置或原方案编辑时会暂停映射；返回首页后恢复。改键和切换模式时应先松开实体键；已按住的键要松开后再触发。手机模式不扫描或连接手柄。

手机模式使用同一方案的临时运行配置，停用摇杆及依赖摇杆的动作，退出后删除临时目录；不会把投影写回原方案。现阶段支持普通手柄和半柄布局，键鼠协议及特殊组合键不在首版手机输入范围。半柄可绑定 LB/A/B/LT；完整手柄可选择更多已核对的逻辑键。未绑定的逻辑键、原轮盘和宏仍保留在方案中。

手机四键由只注入 SpringBoard 的 `SkyTouchButtons` 组件接管。首次安装、更新该组件或卸载后需要重新加载桌面，普通切换模式不需要。组件、输入服务、屏幕状态或体感尚未就绪时不会接管新的系统按键。与 ActionGesture 等操作按钮插件并存时须验证实际事件路径。

手机体感采样使用独立 mobile 身份子进程，映射和虚拟触屏继续使用原特权宿主。选择手机体感后不会叠加手柄体感数据。手柄模式已提供可选的手机体感来源，默认仍保持原手柄体感；该选项属于开发预览，待更多手柄实测。手机体感跟随手机转动，普通黄蜂2兼容性尚未验证；其他品牌或任意蓝牙设备适配留待后续版本。

已在 **iPhone 15 Pro Max / iOS 17.1** 真机确认手机四键映射、体感视野方向，以及映射生效期间对操作按钮原功能、原音量调整和锁屏行为的抑制。此结果不代表其他 iPhone、系统版本或所有手柄均已完成兼容性验证。

App 用于选择游戏、编辑方案、加载背景截图，以及备份、恢复和清除本地配置。开启映射后，浮标可以在其他 App 或桌面切换已有方案；关闭映射会同时退出映射服务和浮标。未连接手柄时，编辑器使用上次连接的手柄类型。

这是完整安装包的构建仓库，包含最终功能源码、静态资源、打包脚本和必要的第三方依赖。`vendor/flydigi` 中的原版运行库是预编译依赖，无法由本仓库重新编译；构建会核对其哈希及代码段，原样保留原版资源。原版 `default_config.fdg` 是出厂模板，不是用户保存的方案。详见 [第三方说明](THIRD_PARTY_NOTICES.md)。

## 本地构建

需要 macOS、完整 Xcode 16.4（包含 iPhoneOS SDK）和系统 Python 3。无需个人签名证书、Apple 账号、手机连接或额外 Python 包。

在仓库目录执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
/usr/bin/python3 scripts/check_source_privacy.py
/usr/bin/python3 scripts/prepare_original.py
/usr/bin/python3 scripts/verify_original.py
bash scripts/build_candidate.sh
/usr/bin/python3 scripts/build_package.py
```

`build/` 保存临时构建文件，`dist/` 输出经过校验的 `.deb`；这两个目录均不提交。签名使用 `codesign --sign -`，安装包供 RootHide 环境使用，不是 App Store 或普通侧载包。构建和打包命令不会安装软件或连接手机。

## GitHub Actions 构建

推送到 `main` 或 `skytouch-2.0` 开发分支、创建面向 `main` 的 PR 后自动运行，也可在 **Actions → Build SkyTouch → Run workflow** 手动启动。成功后，在该次运行底部的 **Artifacts** 下载 `SkyTouch-运行编号`，解压得到 `.deb` 和 `SHA256SUMS`。构建产物保留 7 天，不自动创建 Release。

工作流使用标准 `macos-15` runner 和 Xcode 16.4，先检查待提交文件，再编译、签名、打包和校验。仅上传最终安装包及校验和，不上传中间文件或日志归档；不需要配置 Secrets。

GitHub 的标准 runner 对公开仓库免费；私有仓库使用账户包含的额度，超额可能计费。参考 [GitHub runner 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 和 [macOS 15 arm64 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)。云端构建验证不替代手机上的蓝牙、触屏和悬浮窗实测。

## 本地数据与隐私

用户方案、截图、账号记录、手柄身份、运行状态及配置备份只属于手机本地数据，不是构建输入。本仓库不收录这些数据，构建和 CI 不读取手机，也不把它们上传到 GitHub。不包含开发期间的回归测试、模拟样例或诊断工具。

手机上的方案及设置存放在 RootHide 的 `/var/mobile/Library/Application Support/com.lixinmo.skytouch/`，运行文件单独存放在 RootHide 的 `/var/mobile/Library/Caches/com.lixinmo.skytouch/Runtime/`。通过 App 主动创建的备份位于普通 iOS 目录：

```text
/var/mobile/Media/com.lixinmo.skytouchSetting.skytouchbackup
```

重复备份覆盖同一文件。普通卸载默认保留配置；需要清空时，先在 App 的“管理配置”中使用“清除配置”，再通过 Sileo 卸载。“清除配置”也会删除手机上的凌触备份。

上传前运行 `scripts/check_source_privacy.py` 检查 Git 暂存内容；`.gitignore` 同时排除构建产物、用户配置、设备记录和凭证。不要将手机导出的文件加入版本控制。

## 许可证

第三方组件保留各自的声明，参见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 `licenses/`。本仓库尚未为凌触自研代码指定统一的开源许可证，第三方许可证不自动适用于全部项目。
