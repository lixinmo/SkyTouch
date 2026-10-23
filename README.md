# 凌触 SkyTouch

凌触 1.0.0 是面向 RootHide 环境的 iPhone 手柄触屏映射工具。维护账号：`lixinmo`。

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

推送到 `main` 后自动运行，也可在 **Actions → Build SkyTouch → Run workflow** 手动启动。成功后，在该次运行底部的 **Artifacts** 下载 `SkyTouch-运行编号`，解压得到 `.deb` 和 `SHA256SUMS`。构建产物保留 7 天，不自动创建 Release。

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
