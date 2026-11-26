# 灵动网速 IslandSpeed（实验原型）

iOS 16.2+ / Dynamic Island iPhone。使用 SwiftUI、ActivityKit、WidgetKit。每秒读取 Wi-Fi 和蜂窝网络接口字节计数并计算差值；不主动下载测速，不访问服务器，不需要定位或 VPN。灵动岛左下载右上传，自动切换 B/s、KB/s、MB/s（十进制），长按查看大号显示。

## 无 Mac：GitHub Actions 构建
1. 解压 ZIP，将 IslandSpeed 文件夹内部所有文件（包括隐藏的 .github）提交到自己的 GitHub 仓库根目录。可以使用 GitHub Desktop 或 git push，注意网页上传可能漏掉隐藏目录；也可逐个创建 `.github/workflows/build.yml`。
2. 打开仓库 Actions → Build unsigned IPA → Run workflow。如工作流未显示，确认文件位于默认分支，且 Actions 已开启。push 到 main/master 也会自动触发。
3. 构建成功后点进该次任务，在 Artifacts 下载 IslandSpeed-unsigned，解压得到 IslandSpeed-unsigned.ipa。
4. 使用支持保留并签名 Widget/App Extension 的自签工具（例如 SideStore/AltStore；具体版本兼容性需验证），保留内嵌 IslandSpeedWidget.appex。主应用与扩展需要各自的标识和匹配的签名，扩展标识须以主应用标识加点为前缀。不要启用删除扩展选项。免费 Apple ID 可能受 App ID 数量及 7 天有效期限制。

## 有 Mac
安装 Xcode 和 Xcode 命令行工具、Homebrew，执行 `brew install xcodegen`，随后在目录执行 `bash build.sh`。输出 `dist/IslandSpeed-unsigned.ipa`。也可 `xcodegen generate` 后打开生成的 xcodeproj，为两个 target 配置自己的开发团队和标识，直接安装真机。

## 使用与测试
允许实时活动；若希望后台持续采样，先打开“实验性后台保活”再点开启。返回桌面或打开 Safari，进行视频播放/下载，检查灵动岛数值是否变化。对照 App 内数值和实际下载；测试锁屏、音频中断、低电量模式、Wi-Fi/蜂窝切换。关闭功能会结束实时活动和音频。数值过期后尝试显示暂停。单次活动最长 8 小时，之后需重新打开 App 开启。无声音频保活不是系统承诺，可能被中断/挂起，可能增加耗电或影响音频行为，不适合直接作为 App Store 上架方案。

## 状态与限制
这是源码原型，不是已编译 IPA。当前编写环境为 Linux，无 Xcode/iPhone 真机，未执行 iOS SDK 编译或真机验证；CI 首次构建可能需要修正 SDK/API/签名差异。iOS 27 兼容性、后台保活与灵动岛逐秒刷新均未实测。接口流量为估算值，包括协议开销；不测 VPN 隧道单独流量、不支持全部外接网络接口，避免常见重复计数。接口重置、计数器回绕等可能导致采样异常。灵动岛内容展示优先级及频率由系统控制，其他实时活动可能占用位置。没有任何系统级修改。
