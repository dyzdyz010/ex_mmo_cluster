<#
.SYNOPSIS
    录制 Windows 上某个程序窗口（或桌面区域）并压缩成 gif。
    专为 D3D / 硬件加速 / UE 视口窗口设计：抓 DWM 合成的桌面区域，而不是窗口 GDI 表面。

.DESCRIPTION
    工作流：
      1. 通过 -ProcessId / -WindowTitleLike / -ProcessName 三选一定位目标窗口。
      2. 把窗口置前 + 置顶 + 还原（避免被遮挡/最小化），用 Win32 GetClientRect+ClientToScreen
         算出客户区在屏幕上的真实矩形（原点 + 偶数宽高）。
      3. （可选）轮询日志文件，命中 -LogMarkerRegex 后才开始录 —— 检测与起录在同一进程里，
         不经过模型往返延迟，适合一次性/定时触发的动作。
      4. ffmpeg gdigrab -i desktop + -offset_x/-offset_y/-video_size 截取该屏幕矩形录成 mp4。
      5. 调色板两步法把 mp4 转成 gif。
      6. 打印 gif 路径与大小，并抽一帧 png 供肉眼/读图确认不是全黑。

    关键经验（踩过的坑，勿改）：
      - D3D/硬件加速窗口不能用 `gdigrab -i title=<标题>` 抓，会得到全黑帧（swapchain 不在 GDI 表面）。
        必须抓 `-i desktop` 再用 offset/video_size 截窗口所在屏幕矩形。
      - 抓的是桌面合成区域，所以目标窗口必须置前且不被遮挡，否则会录到别的窗口。
      - video_size 宽高都取偶数（h264 / gif 要求）。客户区原点通常带边框偏移（实测约 (8,31)），
        这里用 ClientToScreen 精确求得，不要硬编码。
      - UE `-game` 启动不要带 `-log`：`-log` 会另开独立日志控制台窗口，MainWindowHandle 会抓到日志窗
        而非 3D 视口，结果录到滚动日志文字。无 `-log` 时主窗口即视口。

.PARAMETER ProcessId
    目标进程 PID。三种定位方式优先级：ProcessId > WindowTitleLike > ProcessName。

.PARAMETER WindowTitleLike
    窗口标题的 -like 通配模式，例如 "*Voxia*"。

.PARAMETER ProcessName
    进程名（不含 .exe），例如 "VoxiaClient"。会取该进程里有可见主窗口的那个。

.PARAMETER DurationSeconds
    录制时长（秒）。默认 15。

.PARAMETER OutGif
    输出 gif 的绝对路径。必填。

.PARAMETER LogFile
    （可选）要轮询的日志文件路径。配合 -LogMarkerRegex 使用：命中后立刻开录。

.PARAMETER LogMarkerRegex
    （可选）在 -LogFile 中匹配的正则。命中即开录。

.PARAMETER MarkerTimeoutSeconds
    等待 marker 的超时（秒）。默认 120。超时报错退出。

.PARAMETER Fps
    gif 帧率。默认 12。

.PARAMETER WidthPx
    gif 输出宽度（高度按比例，保持偶数）。默认 720。

.PARAMETER TrimStartSeconds
    转 gif 时从 mp4 起点裁掉的秒数（裁掉头部静止段）。默认 0。

.PARAMETER KeepMp4
    保留中间 mp4（默认转完即删）。

.EXAMPLE
    # 录已经打开的记事本 3 秒
    .\record-window-gif.ps1 -WindowTitleLike "*Notepad*" -DurationSeconds 3 -OutGif C:\tmp\np.gif

.EXAMPLE
    # 录 UE -game 客户端的 dig/build 演示（无 -log 启动），等日志出现进入场景标志后开录
    .\record-window-gif.ps1 -ProcessName "VoxiaClient" -DurationSeconds 17 -Fps 12 -WidthPx 720 `
        -LogFile "D:\dev\ex_mmo_cluster\clients\Voxia\Saved\Logs\Voxia.log" `
        -LogMarkerRegex "EnteredScene|Voxel.*subscribed" `
        -OutGif "D:\tmp\voxia-dig-demo.gif"
#>
[CmdletBinding()]
param(
    [int]$ProcessId,
    [string]$WindowTitleLike,
    [string]$ProcessName,
    [int]$DurationSeconds = 15,
    [Parameter(Mandatory = $true)][string]$OutGif,
    [string]$LogFile,
    [string]$LogMarkerRegex,
    [int]$MarkerTimeoutSeconds = 120,
    [int]$Fps = 12,
    [int]$WidthPx = 720,
    [double]$TrimStartSeconds = 0,
    [switch]$KeepMp4
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Win32 互操作：定位窗口、置前置顶、取客户区屏幕矩形
# ---------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Win32.WinApi').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Win32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    public static class WinApi {
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);

        public const int SW_RESTORE = 9;
        public static readonly IntPtr HWND_TOPMOST   = new IntPtr(-1);
        public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_SHOWWINDOW = 0x0040;
    }
}
"@
}

function Resolve-FfmpegPath {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = "C:\Users\moonl\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.0.1-full_build\bin\ffmpeg.exe"
    if (Test-Path $fallback) { return $fallback }
    throw "找不到 ffmpeg：既不在 PATH 上，回退绝对路径也不存在（$fallback）。请先安装 ffmpeg。"
}

function Resolve-TargetProcess {
    if ($ProcessId) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $p) { throw "找不到 PID 为 $ProcessId 的进程。" }
        return $p
    }
    if ($WindowTitleLike) {
        $candidates = Get-Process | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like $WindowTitleLike
        }
        $p = $candidates | Select-Object -First 1
        if (-not $p) { throw "找不到标题匹配 '$WindowTitleLike' 且有可见主窗口的进程。" }
        return $p
    }
    if ($ProcessName) {
        $name = $ProcessName -replace '\.exe$', ''
        $candidates = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
        $p = $candidates | Select-Object -First 1
        if (-not $p) { throw "找不到名为 '$name' 且有可见主窗口的进程。" }
        return $p
    }
    throw "必须提供 -ProcessId / -WindowTitleLike / -ProcessName 三者之一来定位窗口。"
}

function Get-ClientScreenRect {
    param([IntPtr]$Hwnd)

    if (-not [Win32.WinApi]::IsWindow($Hwnd)) { throw "窗口句柄已失效（进程可能已退出）。" }

    # 置前 + 置顶 + 还原，确保桌面合成区域里录到的就是目标窗口客户区
    [void][Win32.WinApi]::ShowWindow($Hwnd, [Win32.WinApi]::SW_RESTORE)
    [void][Win32.WinApi]::SetWindowPos($Hwnd, [Win32.WinApi]::HWND_TOPMOST, 0, 0, 0, 0,
        ([Win32.WinApi]::SWP_NOMOVE -bor [Win32.WinApi]::SWP_NOSIZE -bor [Win32.WinApi]::SWP_SHOWWINDOW))
    [void][Win32.WinApi]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 400  # 等 DWM 把窗口提到最前并稳定

    $rc = New-Object Win32.RECT
    if (-not [Win32.WinApi]::GetClientRect($Hwnd, [ref]$rc)) { throw "GetClientRect 失败。" }

    $origin = New-Object Win32.POINT
    $origin.X = 0; $origin.Y = 0
    if (-not [Win32.WinApi]::ClientToScreen($Hwnd, [ref]$origin)) { throw "ClientToScreen 失败。" }

    $w = $rc.Right - $rc.Left
    $h = $rc.Bottom - $rc.Top
    if ($w -le 0 -or $h -le 0) { throw "客户区尺寸异常（${w}x${h}），窗口可能被最小化。" }

    # h264 / gif 要求偶数宽高
    if ($w % 2 -ne 0) { $w -= 1 }
    if ($h % 2 -ne 0) { $h -= 1 }

    [pscustomobject]@{ X = $origin.X; Y = $origin.Y; Width = $w; Height = $h }
}

function Wait-ForLogMarker {
    param([string]$Path, [string]$Regex, [int]$TimeoutSec)

    if (-not (Test-Path $Path)) {
        Write-Host "[marker] 日志文件尚不存在，等待其出现：$Path"
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            try {
                $hit = Select-String -Path $Path -Pattern $Regex -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) {
                    Write-Host "[marker] 命中标志：$($hit.Line.Trim())"
                    return
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "[marker] 等待标志 '$Regex' 超时（${TimeoutSec}s），未在 $Path 中命中。"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$ffmpeg = Resolve-FfmpegPath
Write-Host "[ffmpeg] $ffmpeg"

$proc = Resolve-TargetProcess
$hwnd = $proc.MainWindowHandle
Write-Host "[target] PID=$($proc.Id) 标题='$($proc.MainWindowTitle)' HWND=$hwnd"

$outDir = Split-Path -Parent $OutGif
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# 可选：等日志标志（检测 + 起录在同一进程，避免模型往返延迟错过一次性动作）
if ($LogFile -and $LogMarkerRegex) {
    Wait-ForLogMarker -Path $LogFile -Regex $LogMarkerRegex -TimeoutSec $MarkerTimeoutSeconds
} elseif ($LogFile -xor $LogMarkerRegex) {
    throw "-LogFile 和 -LogMarkerRegex 必须同时提供或同时省略。"
}

# 取客户区屏幕矩形（marker 命中后再取，确保此刻窗口在最前）
$rect = Get-ClientScreenRect -Hwnd $hwnd
Write-Host "[rect] x=$($rect.X) y=$($rect.Y) size=$($rect.Width)x$($rect.Height)"

$mp4 = [System.IO.Path]::ChangeExtension($OutGif, ".mp4")

# 步骤 1：gdigrab 抓 desktop 区域 -> mp4
# 注意：抓 desktop（DWM 合成）而非 title，才能正确录到 D3D/UE 视口。
$grabArgs = @(
    '-y',
    '-f', 'gdigrab',
    '-framerate', "$Fps",
    '-offset_x', "$($rect.X)",
    '-offset_y', "$($rect.Y)",
    '-video_size', "$($rect.Width)x$($rect.Height)",
    '-i', 'desktop',
    '-t', "$DurationSeconds",
    '-pix_fmt', 'yuv420p',
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    $mp4
)
Write-Host "[grab] 录制 ${DurationSeconds}s -> $mp4"
& $ffmpeg @grabArgs
if ($LASTEXITCODE -ne 0) { throw "ffmpeg 录制失败（exit $LASTEXITCODE）。" }
if (-not (Test-Path $mp4) -or (Get-Item $mp4).Length -eq 0) { throw "录制产物 mp4 为空。" }

# 解除置顶，恢复窗口正常 z-order
[void][Win32.WinApi]::SetWindowPos($hwnd, [Win32.WinApi]::HWND_NOTOPMOST, 0, 0, 0, 0,
    ([Win32.WinApi]::SWP_NOMOVE -bor [Win32.WinApi]::SWP_NOSIZE))

# 步骤 2：调色板两步法 mp4 -> gif（高质量、可控体积）
# 偶数宽度
$evenWidth = $WidthPx
if ($evenWidth % 2 -ne 0) { $evenWidth -= 1 }
$vf = "fps=$Fps,scale=${evenWidth}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3"

$gifArgs = @('-y')
if ($TrimStartSeconds -gt 0) { $gifArgs += @('-ss', "$TrimStartSeconds") }
$gifArgs += @('-i', $mp4, '-vf', $vf, '-loop', '0', $OutGif)

Write-Host "[gif] 转码 -> $OutGif"
& $ffmpeg @gifArgs
if ($LASTEXITCODE -ne 0) { throw "ffmpeg 转 gif 失败（exit $LASTEXITCODE）。" }
if (-not (Test-Path $OutGif) -or (Get-Item $OutGif).Length -eq 0) { throw "gif 产物为空。" }

# 步骤 3：抽一帧 png 供肉眼/读图确认不是全黑
# 注意：PS 5.1 下 $ErrorActionPreference='Stop' 会把 native 命令写到 stderr 的行
# 包成 ErrorRecord 当成终止错误。这里临时放开，并把所有流丢弃，避免误判失败。
$probePng = [System.IO.Path]::ChangeExtension($OutGif, ".frame.png")
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $ffmpeg -y -loglevel error -i $OutGif -frames:v 1 $probePng *>$null
$ErrorActionPreference = $prevEap

if (-not $KeepMp4) { Remove-Item $mp4 -ErrorAction SilentlyContinue }

$gifInfo = Get-Item $OutGif
$mb = [math]::Round($gifInfo.Length / 1MB, 2)
Write-Host ""
Write-Host "=== 完成 ==="
Write-Host "GIF: $($gifInfo.FullName)"
Write-Host "大小: $mb MB ($($gifInfo.Length) bytes)"
if (Test-Path $probePng) { Write-Host "首帧抽样（确认非全黑）: $probePng" }
