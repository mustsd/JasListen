# JasPlayer 原生播放器架构（iOS + macOS）

## Summary

把现有网页播放器迁移为 **SwiftUI 原生多平台应用**，目标为 iPhone、iPad 和 Mac。首期不做云端账号或自动同步；每台设备独立保存音频和进度，用户可通过备份文件手动迁移。

SwiftUI 支持在 Apple 平台间共享界面代码；Apple 也提供跨 iOS 与 macOS 的多平台应用目标。[SwiftUI 多平台开发](https://developer.apple.com/documentation/technologyoverviews/swiftui)、[配置多平台应用目标](https://developer.apple.com/documentation/Xcode/configuring-a-multiplatform-app-target)

## 架构与接口

- **界面层：** SwiftUI 自适应界面，手机使用单栏课程库和播放器，Mac 使用侧栏课程库与播放器详情。
- **应用层：** 播放状态和课程操作由独立控制器管理，不把播放逻辑写进界面组件。
- **数据层：** iOS 17、iPadOS 17、macOS 14 起，使用 SwiftData 保存课程元数据；将导入的音频复制到应用自己的文件目录，数据库只保存相对路径、标题、时长和播放进度。SwiftData 是 Apple 的持久化方案，支持与 SwiftUI 配合。[SwiftData](https://developer.apple.com/documentation/swiftdata)
- **原生播放：** 使用 AVFoundation 的 `AVPlayer` 播放本地 MP3、控制速率、定位和 A–B 循环。iOS 配置后台音频与系统锁屏媒体控制；系统播放、耳机操作和应用内控件都调用同一个播放器控制器。`AVPlayer` 支持 MP3 和本地媒体文件。[AVPlayer](https://developer.apple.com/documentation/AVFoundation/AVPlayer)
- **模块边界：** 提供 `LessonRepository`（课程与进度读写）、`AudioPlaybackController`（播放、暂停、定位、速度和循环状态）和 `BackupService`（导入、导出）。首期不新增网络 API 或同步服务。
- **音频导入：** 用户通过系统文件选择器选取音频；先复制至应用目录，再保存课程记录。复制或数据库写入失败时清理未完成文件，并保留已有课程。

## 备份与网页迁移

- 原生备份使用版本化 `.stillbackup` ZIP 包，包含 `manifest.json` 和音频文件；manifest 保存课程 ID、标题、媒体路径、时长及播放进度。使用 ZIPFoundation 处理归档。[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- 恢复前验证备份版本、文件路径和媒体文件；按合并方式加入课程。ID 冲突时重新分配导入 ID，不覆盖现有课程。
- 提供旧网页导出的 `still-listening-backup` v1 JSON 导入器，将其中的 Base64 音频与播放进度转换到原生存储。
- 验证网页备份成功迁移后，停止维护现有网页播放器；不尝试直接读取浏览器 IndexedDB。

## 测试与发布验收

- 单元测试：播放状态转换、A–B 区间边界、seek/循环行为、进度保存、重复 ID 合并。
- 导入导出测试：MP3 导入和播放、原网页 v1 备份导入、原生备份往返、损坏或不支持的备份、音频复制或存储失败。
- 真机验收：iPhone 锁屏后继续播放，锁屏控件、耳机播放/暂停/定位可用；Mac 上播放、定位、速率和后台继续播放正常。
- 两个平台均通过课程新增、删除、重启恢复进度和手动备份迁移验收后，再停用网页版本。

## 已确认的假设

- 首期目标为 iOS/iPadOS 与 macOS，最低系统版本为 iOS/iPadOS 17、macOS 14。
- 手机端必须支持锁屏/后台播放和系统媒体控件。
- iPhone 与 Mac 的数据首期各自保存在本机，通过备份文件手动搬运，不自动同步。
- 当前网页只作为迁移来源；原生版达到验收标准并能导入网页备份后，网页版本停用。
