# 灵动网速 IslandSpeed

用 iPhone 灵动岛显示 Wi‑Fi 和蜂窝网络的下载、上传速率。App 通过读取本机网卡字节计数计算网速。短按灵动岛打开 App，长按可看最近样本和采样时间。

## 用 GitHub Actions 生成 IPA

1. 解压完整项目，将包含 `build.sh` 的这一层目录里的全部内容提交到仓库根目录。请包含隐藏目录 `.github`、`scripts` 和 `App` 中的两段 WAV 音频。
2. 提交到 `main` 或 `master` 会自动构建。也可以打开 **Actions → Build unsigned IPA → Run workflow** 手动启动。
3. 进入本次成功的运行，在 **Artifacts** 下载 **IslandSpeed-unsigned**。解压得到 `IslandSpeed-unsigned.ipa`。
4. 用自己的签名工具签名并安装，保留内嵌的 `IslandSpeedWidget.appex`。如工具更改了主 App 包名，且 App 提示后台任务标识不匹配，将 `project.yml` 中的 `ISLANDSPEED_TASK_BUNDLE_ID` 设为提示的最终主 App 包名，重新构建并签名。

## 在 Mac 上使用

完整包附带 `IslandSpeed.xcodeproj` 和共享的 `IslandSpeed` scheme，可以用带 iPhoneOS 26 或更高版本 SDK 的 Xcode 直接打开。真机调试时为主 App 和扩展选择自己的开发团队，扩展包名应以主 App 包名加点开头。

使用命令行生成未签名 IPA，可运行以下命令。构建时脚本会按 `project.yml` 重新生成工程。

```sh
brew install xcodegen
bash build.sh
```

输出位于 `dist/IslandSpeed-unsigned.ipa`。脚本会检查源音频以及成品中的主程序、Widget、音频和后台任务标识。若文件缺失，构建日志会显示具体路径。

## 使用和核对后台采样

在 iOS 26 及以上版本选择「系统后台测量」，设定约 5、30 或 60 分钟的测量时长，点「开启灵动岛网速」。看到「后台测量已启动」后，可以切换到其他 App。若系统进度圈占据灵动岛，长按可查看速率。系统可以提前结束任务，岛上的绘制频率也受系统调度影响。

要核对是否持续刷新，可以在 Safari 开始一段下载，长按灵动岛看样本编号和时间是否推进。一分钟后回到 App，「后台诊断」会显示离开期间的新增采样数和实时活动提交返回次数。数据过期时，界面会标出上一条样本。

最低部署版本为 iOS 16.2。较早的系统可选择「仅前台」或「实验性音频」模式。音频模式循环播放本地音频，可能增加耗电或影响其他音频播放。速率为 Wi‑Fi 和蜂窝接口的估算值，VPN 隧道接口不单独计入。
