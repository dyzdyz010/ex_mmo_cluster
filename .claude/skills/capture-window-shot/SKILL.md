---
name: capture-window-shot
description: Windows 下对一个运行中的程序窗口截图成 PNG，发给用户看静态画面。尤其适用于 D3D / 硬件加速 / UE（如 Voxia UE5.8）等视口窗口——这类窗口用 UE 内 HighResShot / 离屏 / gdigrab title 抓常常不落盘或得全黑帧，本 skill 改抓 DWM 合成的桌面区域并按窗口客户区屏幕矩形截取，能正确截到画面。何时用：用户要"截图""截个图""把窗口/视口截下来""看某一帧画面""定点对比图"，或需要把某个程序某一时刻的画面存成 PNG。是同目录 record-window-gif 的姊妹（那个录动图、这个抓静帧，共用同一窗口定位法）。全程只用 ffmpeg（不依赖 ImageMagick）。
user-invocable: true
allowed-tools:
  - Bash
  - PowerShell
  - Read
  - Write
---

# capture-window-shot — Windows 窗口静帧截图（PNG）

对一个运行中的程序窗口截一张（或定时连拍多张）PNG。专门解决 **D3D / 硬件加速 / UE 视口窗口**
用 HighResShot / 离屏 / `gdigrab title` 抓图**不落盘或全黑**的问题。全程仅用 **ffmpeg**。

与同目录的 [`record-window-gif`](../record-window-gif/SKILL.md) 是**姊妹 skill**：那个录动图，这个抓静帧，
共用同一套「抓 DWM 桌面合成区域 + 按客户区屏幕矩形截取」的窗口定位法。

核心脚本：`capture-window-shot.ps1`（与本文件同目录）。

## 工具链

- **ffmpeg**：脚本先用 `Get-Command ffmpeg` 探测；找不到再回退到绝对路径
  `C:\Users\moonl\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.0.1-full_build\bin\ffmpeg.exe`。
- **ImageMagick 不可用**，不要用它。

## 关键经验（踩过的坑，务必遵守）

1. **D3D/硬件加速/UE 视口不能用 UE 内 `HighResShot`、离屏渲染或 `gdigrab -i title=`** —— 前两者常
   不落盘或超时，后者抓到**全黑帧**（swapchain 不在 GDI 表面）。**必须用 `gdigrab -i desktop` 抓 DWM
   合成的桌面画面**，再用 `-offset_x/-offset_y/-video_size` 截取窗口客户区屏幕矩形。脚本已这样实现。
2. **抓的是桌面合成区域，所以目标窗口必须置前且不被遮挡**。脚本用 Win32（`GetClientRect` +
   `ClientToScreen` + `ShowWindow`/`SetWindowPos(TOPMOST)`/`SetForegroundWindow`）精确求客户区屏幕矩形，
   不硬编码边框偏移。
3. **UE `-game` 启动不要带 `-log`**：`-log` 会另开独立日志控制台窗口，`MainWindowHandle` 会抓到日志窗
   而不是 3D 视口。无 `-log` 时主窗口即视口。
4. **检测"该截了"的时机和截图必须在同一进程里**。若分两次工具调用（先 grep 日志、再截），模型往返
   延迟会错过一次性时机。用 `-LogFile` + `-LogMarkerRegex` 让脚本在标志命中后**同进程**立刻截。
5. **低亮度不等于全黑**：静态 3D 场景可能整体偏暗但有内容。**必须 `Read` 出 PNG 肉眼/读图确认**，
   不要只看文件大小或亮度就下结论。

## 用法

```powershell
# 三种定位窗口方式（优先级 ProcessId > WindowTitleLike > ProcessName）
.\capture-window-shot.ps1 -WindowTitleLike "*Voxia*" -OutPng "D:\tmp\voxia.png"
.\capture-window-shot.ps1 -ProcessId 12345         -OutPng "D:\tmp\voxia.png"
.\capture-window-shot.ps1 -ProcessName "VoxiaClient" -OutPng "D:\tmp\voxia.png"
```

### 参数

| 参数 | 说明 | 默认 |
|------|------|------|
| `-ProcessId` / `-WindowTitleLike` / `-ProcessName` | 定位窗口，三选一 | — |
| `-OutPng` | 输出 PNG 绝对路径（必填）；连拍时插入序号 `out.001.png` | — |
| `-LogFile` + `-LogMarkerRegex` | 轮询该日志，命中正则后才截（同进程内，避免往返延迟） | — |
| `-MarkerTimeoutSeconds` | 等 marker 超时 | 120 |
| `-Count` | 连拍张数（>1 时按间隔连拍，文件名带序号） | 1 |
| `-IntervalSeconds` | 连拍间隔秒（仅 `-Count`>1 有效） | 2 |

脚本内部流程：定位窗口 → 置前+取客户区屏幕矩形 →（可选）等 marker → ffmpeg `gdigrab -i desktop`
`-frames:v 1` 截该屏幕矩形出 PNG（可连拍）→ 解除置顶 → 打印每张路径和大小。窗口找不到 / 进程退出 /
marker 超时都会清晰报错而非卡死。

### 在 Claude Code 里怎么跑

用 **PowerShell** 工具调用脚本，例如：

```powershell
& "D:\dev\ex_mmo_cluster\.claude\skills\capture-window-shot\capture-window-shot.ps1" `
  -WindowTitleLike "*Voxia*" -OutPng "D:\tmp\voxia.png"
```

跑完 **Read** 输出里的 PNG，确认不是全黑（坑 5），再把结论/图报给用户。

## examples — 截 Voxia UE `-game` 首窗与流送推进

真实场景：Voxia UE5.8 `-game` 启动（**不带 `-log`**，见坑 3），等根 ready 后截首窗，再连拍看流送：

```powershell
# 等唯一根 ready 后截一张首窗
& "D:\dev\ex_mmo_cluster\.claude\skills\capture-window-shot\capture-window-shot.ps1" `
  -ProcessName "VoxiaClient" `
  -LogFile "D:\dev\ex_mmo_cluster\clients\Voxia\Saved\Logs\Voxia.log" `
  -LogMarkerRegex "voxel_world_root_ready" `
  -OutPng "D:\tmp\voxia-firstwindow.png"

# 进入后每 3s 连拍 5 张看 near/far 流送推进
& "D:\dev\ex_mmo_cluster\.claude\skills\capture-window-shot\capture-window-shot.ps1" `
  -ProcessName "VoxiaClient" -Count 5 -IntervalSeconds 3 `
  -OutPng "D:\tmp\voxia-stream.png"
```

要点回顾：
- 用 `-ProcessName VoxiaClient` 定位**视口**主窗口（无 `-log` 时 MainWindowHandle 即视口，坑 3）。
- `-LogFile/-LogMarkerRegex` 让脚本在标志命中后**同进程**立刻截，不会被模型往返延迟错过（坑 4）。
- 截的是 desktop 合成区域裁出的客户区矩形，能正确截到 D3D 视口画面（坑 1、2）。
- 转完 Read 出 PNG 确认非全黑（坑 5）后再报给用户。
