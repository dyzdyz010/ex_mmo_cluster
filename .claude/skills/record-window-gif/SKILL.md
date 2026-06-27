---
name: record-window-gif
description: Windows 下把一个运行中的程序窗口（或桌面区域）录屏并压缩成 gif，发给用户看动态效果。尤其适用于 D3D / 硬件加速 / UE（如 Voxia UE5.8）等视口窗口——这类窗口用 gdigrab title 抓会得到全黑帧，本 skill 改抓 DWM 合成的桌面区域并按窗口客户区屏幕矩形截取，能正确录到画面。何时用：用户要"录屏""录个 gif""把窗口/视口录下来""看运行效果的动图""录 dig/build 演示"，或需要把某个程序的动态行为做成可分享的 gif。全程只用 ffmpeg（不依赖 ImageMagick）。
user-invocable: true
allowed-tools:
  - Bash
  - PowerShell
  - Read
  - Write
---

# record-window-gif — Windows 窗口/桌面区域录屏转 gif

把一个运行中的程序窗口录成 gif。专门解决 **D3D / 硬件加速 / UE 视口窗口**录屏全黑的问题。
全程仅用 **ffmpeg**，不依赖 ImageMagick。

核心脚本：`record-window-gif.ps1`（与本文件同目录）。

## 工具链

- **ffmpeg**：脚本先用 `Get-Command ffmpeg` 探测；找不到再回退到绝对路径
  `C:\Users\moonl\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.0.1-full_build\bin\ffmpeg.exe`。
- **ImageMagick 不可用**，不要用它。

## 6 条关键经验（踩过的坑，务必遵守）

1. **D3D/硬件加速窗口不能用 `gdigrab -i title=<窗口标题>`** —— 会抓到**全黑帧**（swapchain
   不在 GDI 表面）。**必须用 `gdigrab -i desktop` 抓 DWM 合成的桌面画面**，再用
   `-offset_x/-offset_y/-video_size` 截取窗口所在的屏幕矩形。脚本已这样实现。

2. **抓的是桌面合成区域，所以目标窗口必须置前且不被遮挡**。脚本用 Win32（`Add-Type` 调
   user32.dll）做 `ShowWindow(SW_RESTORE)` + `SetWindowPos(HWND_TOPMOST)` + `SetForegroundWindow`，
   再用 `GetClientRect` + `ClientToScreen` 求客户区在屏幕上的真实原点和尺寸（窗口边框会偏移，
   实测客户区原点约在 (8,31)，但**不要硬编码**，脚本是精确求得的）。`video_size` 宽高都取偶数
   （h264 / gif 要求）。

3. **检测"该开始录了"的标志和启动 ffmpeg 必须在同一条命令/同一进程里**。若分两次工具调用
   （先检测、再录），模型循环往返延迟（实测 ~30s+）会让"一次性/定时触发的动作"在录制开始前就
   结束了。脚本支持可选地轮询一个**日志文件正则标志**（`-LogFile` + `-LogMarkerRegex`），命中后
   **立刻在同一进程内**启动 ffmpeg。要用就一次性把 marker 参数传给脚本，**别**自己先 grep 日志
   再单独调录制。

4. **UE `-game` 启动不要带 `-log`**：`-log` 会另开一个独立控制台日志窗口，
   `(Get-Process).MainWindowHandle` 会抓到那个日志窗而不是 3D 视口窗口，结果录到滚动的日志文字。
   无 `-log` 时主窗口就是视口。

5. **gif 转换用调色板两步法**保证质量：
   `fps=N,scale=W:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3`。
   可参数化 fps / 宽度 / 时长(`-t`) / 起点(`-ss`，用于裁掉头尾静止段）。典型 17s / 720p / 12fps
   的 gif 约 3-4MB，适合分享。

6. **低码率不代表黑屏**：静态摄像机的 3D 场景码率可能只有 ~160-240 kb/s 也是正常内容。
   **用提取一帧 `-frames:v 1` 出 png 再肉眼/读图确认**，而不是只看文件大小。脚本转完会自动抽一帧
   `*.frame.png`，应当 Read 它确认不是全黑。

## 用法

```powershell
# 三种定位窗口方式（优先级 ProcessId > WindowTitleLike > ProcessName）
.\record-window-gif.ps1 -WindowTitleLike "*Voxia*" -DurationSeconds 17 -OutGif "D:\tmp\demo.gif"
.\record-window-gif.ps1 -ProcessId 12345        -DurationSeconds 17 -OutGif "D:\tmp\demo.gif"
.\record-window-gif.ps1 -ProcessName "VoxiaClient" -DurationSeconds 17 -OutGif "D:\tmp\demo.gif"
```

### 参数

| 参数 | 说明 | 默认 |
|------|------|------|
| `-ProcessId` / `-WindowTitleLike` / `-ProcessName` | 定位窗口，三选一 | — |
| `-DurationSeconds` | 录制时长（秒） | 15 |
| `-OutGif` | 输出 gif 绝对路径（必填） | — |
| `-LogFile` + `-LogMarkerRegex` | 轮询该日志，命中正则后才开录（同进程内，避免往返延迟） | — |
| `-MarkerTimeoutSeconds` | 等 marker 超时 | 120 |
| `-Fps` | gif 帧率 | 12 |
| `-WidthPx` | gif 宽度（高度按比例，自动取偶数） | 720 |
| `-TrimStartSeconds` | 转 gif 时裁掉的头部静止秒数（`-ss`） | 0 |
| `-KeepMp4` | 保留中间 mp4（默认转完即删） | off |

脚本内部流程：定位窗口 → 置前+取客户区屏幕矩形 →（可选）等 marker → ffmpeg 抓 desktop 区域出 mp4
→ 调色板两步法转 gif → 抽一帧 png → 打印 gif 路径和大小。窗口找不到 / 进程退出 / marker 超时都会
清晰报错而非卡死。

### 在 Claude Code 里怎么跑

用 **PowerShell** 工具调用脚本，例如：

```powershell
& "D:\dev\ex_mmo_cluster\.claude\skills\record-window-gif\record-window-gif.ps1" `
  -WindowTitleLike "*Voxia*" -DurationSeconds 17 -OutGif "D:\tmp\voxia.gif"
```

跑完 **Read** 输出里的 `*.frame.png` 抽样帧，确认不是全黑（坑 6），再把 gif 路径报给用户。

## examples — 录制 UE `-game` 客户端的 dig/build 演示

真实场景：Voxia UE5.8 客户端 `-game` 启动（**不带 `-log`**，见坑 4），进入场景后做挖/放体素演示，
录成可分享 gif。日志里出现进入场景/订阅成功标志后再开录（坑 3），裁掉头 2s 加载静止段（坑 5）：

```powershell
& "D:\dev\ex_mmo_cluster\.claude\skills\record-window-gif\record-window-gif.ps1" `
  -ProcessName "VoxiaClient" `
  -DurationSeconds 17 -Fps 12 -WidthPx 720 -TrimStartSeconds 2 `
  -LogFile "D:\dev\ex_mmo_cluster\clients\Voxia\Saved\Logs\Voxia.log" `
  -LogMarkerRegex "EnteredScene|Voxel.*subscribed" `
  -OutGif "D:\tmp\voxia-dig-build-demo.gif"
```

要点回顾：
- 用 `-ProcessName VoxiaClient` 定位**视口**主窗口（无 `-log` 时 MainWindowHandle 即视口，坑 4）。
- `-LogFile/-LogMarkerRegex` 让脚本在标志命中后**同进程**立刻开录，不会被模型往返延迟错过（坑 3）。
- 录的是 desktop 合成区域裁出的客户区矩形，能正确录到 D3D 视口画面（坑 1、2）。
- 转完 Read `voxia-dig-build-demo.frame.png` 确认非全黑（坑 6）后再发给用户。
