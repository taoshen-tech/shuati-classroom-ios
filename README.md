# 刷题课堂 iOS

一个独立开发的原生 iOS 课程学习应用。通过你自己的 Alist 服务读取 NAS 课程，支持递归目录、断点续播、学习计划、手动已看和按课程同步学习记录。

## 功能

- Alist 地址、课程根目录、用户名与 FLV 转封装地址均可配置，不包含任何内置 NAS 地址或账号。
- 课程根目录可直接放视频，也可按课程分文件夹；课程内部支持任意层级子文件夹。
- MP4、MOV、M4V、M3U8 使用 AVPlayer 直接播放；FLV 通过可配置的 NAS 转封装服务播放。
- 本地学习记录、真实视频目录完成度、最近学习、计划日期和云端合并。
- 每门课程有独立的防抖同步任务，不共用一个会互相覆盖进度的全局任务。
- 自定义横屏播放器、加载与失败状态、重试、上一集与下一集。
- 未签名 IPA 的 GitHub Actions 构建流程。

## 播放手势

| 操作 | 行为 |
| --- | --- |
| 单击播放区域 | 显示或隐藏控制层；锁屏后显示解锁按钮 |
| 双击播放区域 | 播放或暂停 |
| 横向滑动 | 预览目标位置，松手后精确 seek |
| 左侧竖向滑动 | 调整屏幕亮度 |
| 右侧竖向滑动 | 调整系统音量 |
| 长按播放区域 | 临时 2×，继续按住依次升至 3×、4×，松手恢复原倍速 |
| 进度条 | 拖动预览，松手后定位 |

只有播放器收到当前视频的自然播放结束通知，才会自动标为已看。拖动进度条或横滑到末尾不会自动已看；手动标记已看或未看始终可用。

## 使用

1. 在局域网内准备好 Alist，并确认 iPhone 与 NAS 网络互通。
2. 首次打开 App，填写 Alist 地址、课程根目录、用户名和密码。
3. 如课程中有 FLV，再填写转封装服务地址。可以直接填服务地址，App 会追加 `url` 查询参数；也可以填包含 `{url}` 的完整模板。
4. 打开课程后自动扫描所有层级的视频。右滑课程行可安排计划，左滑可切换已看状态。

服务器配置保存在 `UserDefaults`，Alist token 与密码保存在 iOS Keychain。学习状态同时保存在本机 Application Support 和课程根目录下的 `.shuati-classroom` 文件夹中，每门课使用独立 JSON 文件。

## 本地开发

- iOS 15.0+
- Swift 5.9
- UIKit + AVFoundation
- XcodeGen
- 无第三方运行时依赖

```bash
brew install xcodegen
xcodegen generate
open ShuaTiClassroom.xcodeproj
```

选择自己的开发团队即可签名运行。应用不依赖 CocoaPods 或 Swift Package Manager。

## GitHub Actions 未签名 IPA

每次推送到 `main` 或手动运行 `Test and unsigned IPA` 工作流时，会依次执行单元测试、无签名 Archive 和 IPA 打包。完成后在 Actions 运行详情中下载 `ShuaTiClassroom-unsigned-ipa` 构件，再使用自己的签名工具安装。

## 实现参考

设计时对照研究了 ZFPlayer 的手势仲裁、Swiftfin 的 AVPlayer 代际隔离与恢复播放、AlistClient 的 Alist 请求行为，以及 KSPlayer 的状态驱动控制层。本仓库为独立实现，没有整体引入这些项目或复制其播放控制代码。

## 当前边界

当前按家庭局域网使用设计，但服务器地址并未写死，后续可接入 HTTPS 外网访问。MKV、AVI、TS、WebM 会出现在课程目录中，但本版本不宣称 AVPlayer 能直接播放这些格式；建议转换为 MP4。转封装服务的部署与转码参数由 NAS 端负责。
