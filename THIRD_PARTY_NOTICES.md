# 第三方组件

## Flydigi 原版运行库与资源

`vendor/flydigi/` 包含从原版 Flydigi 1.6.6 安装包选取的 `flydigi.dylib` 和 `FZKeymappingHelper.bundle` 静态资源，以及用于完整性校验的清单。

这些文件是凌触构建所需的第三方输入，不是凌触编译输出或手机上的用户数据。原版运行库未提供源码，本仓库不能重新编译它；构建只复制并临时签名，同时验证原始代码段及资源未被改写。资源中的 `default_config.fdg` 是原版出厂模板。

原版运行库与资源的权利归各自权利人所有。本仓库未将其重新许可为 MIT、BSD 或其他开源许可证。

## fishhook

- 来源：[facebook/fishhook](https://github.com/facebook/fishhook)
- 固定提交：`aadc161ac3b80db07a9908851839a17ba63a9eb1`
- 本地位置：`vendor/fishhook/`
- 许可：BSD 3-Clause，完整声明见 [licenses/fishhook-BSD-3-Clause.txt](licenses/fishhook-BSD-3-Clause.txt)。文件来源和哈希见 `vendor/fishhook/ORIGIN.json`。

## TrollSpeed

- 来源：[Lessica/TrollSpeed](https://github.com/Lessica/TrollSpeed)
- 参考提交：`a609be260c8261ead36509c3bc4ded8479da9c40`
- 凌触的全局 UIKit 宿主实现参考了该项目，相关说明见 `src/OPHUDHost.mm`。
- 许可：MIT，完整声明见 [licenses/TrollSpeed-MIT.txt](licenses/TrollSpeed-MIT.txt)。
