<#
.SYNOPSIS
    对 Windows 上某个程序窗口截图成 PNG。
    专为 D3D / 硬件加速 / UE 视口窗口设计：抓 DWM 合成的桌面区域，而不是窗口 GDI 表面，
    避免 HighResShot / gdigrab title / 离屏 那套在 UE 视口上出全黑或不落盘的老坑。
    与同目录的 record-window-gif 是姊妹：那个录动图，这个抓静帧；共用同一套窗口定位法。
    全程仅用 ffmpeg（不依赖 ImageMagick）。

.DESCRIPTION
    工作流：
      1. 通过 -ProcessId / -WindowTitleLike / -ProcessName 三选一定位目标窗口。
      2. 把窗口置前 + 置顶 + 还原（避免被遮挡/最小化），用 Win32 GetClientRect+ClientToScreen
         算出客户区在屏幕上的真实矩形（原点 + 偶数宽高）。
      3. （可选）轮询日志文件，命中 -LogMarkerRegex 后才截图 —— 检测与截图在同一进程里，
         不经过模型往返延迟，适合"进入场景后立刻截"这类一次性时机。
      4. ffmpeg gdigrab -i desktop + -offset_x/-offset_y/-video_size 截该屏幕矩形出 PNG。
      5. 可选定时连拍多张（看流送/加载推进）。
      6. 打印 PNG 路径与大小；调用方应 Read 出来确认不是全黑（低亮度不等于黑，静态 3D 场景正常）。

    关键经验（与 record-window-gif 同源，勿改）：
      - D3D/硬件加速窗口不能用 `gdigrab -i title=<标题>` 抓，会得到全黑帧（swapchain 不在 GDI 表面）。
        必须抓 `-i desktop` 再用 offset/video_size 截窗口所在屏幕矩形。
      - 抓的是桌面合成区域，所以目标窗口必须置前且不被遮挡，否则会截到别的窗口。
      - 客户区原点通常带边框偏移（实测约 (8,31)），这里用 ClientToScreen 精确求得，不要硬编码。
      - UE `-game` 启动不要带 `-log`：`-log` 会另开独立日志控制台窗口，MainWindowHandle 会抓到日志窗
        而非 3D 视口。无 `-log` 时主窗口即视口。

.PARAMETER ProcessId
    目标进程 PID。三种定位方式优先级：ProcessId > WindowTitleLike > ProcessName。

.PARAMETER WindowTitleLike
    窗口标题的 -like 通配模式，例如 "*Voxia*"。

.PARAMETER ProcessName
    进程名（不含 .exe），例如 "VoxiaClient"。会取该进程里有可见主窗口的那个。

.PARAMETER OutPng
    输出 PNG 的绝对路径。必填。连拍（-Count>1）时在扩展名前插入序号，如 out.001.png。

.PARAMETER LogFile
    （可选）要轮询的日志文件路径。配合 -LogMarkerRegex：命中后立刻截图。

.PARAMETER LogMarkerRegex
    （可选）在 -LogFile 中匹配的正则。命中即截。

.PARAMETER MarkerTimeoutSeconds
    等待 marker 的超时（秒）。默认 120。超时报错退出。

.PARAMETER Count
    连拍张数。默认 1。>1 时按 -IntervalSeconds 间隔连拍，文件名带序号。

.PARAMETER IntervalSeconds
    连拍间隔（秒）。默认 2。仅 -Count>1 时有效。

.EXAMPLE
    # 对已打开的 Voxia 视口截一张
    .\capture-window-shot.ps1 -WindowTitleLike "*Voxia*" -OutPng "D:\tmp\voxia.png"

.EXAMPLE
    # 等进入场景后，每 3s 连拍 5 张看流送推进
    .\capture-window-shot.ps1 -ProcessName "VoxiaClient" -Count 5 -IntervalSeconds 3 `
        -LogFile "D:\dev\ex_mmo_cluster\clients\Voxia\Saved\Logs\Voxia.log" `
        -LogMarkerRegex "voxel_world_root_ready|EnteredScene" `
        -OutPng "D:\tmp\voxia-stream.png"
#>
[CmdletBinding()]
param(
    [int]$ProcessId,
    [string]$WindowTitleLike,
    [string]$ProcessName,
    [Parameter(Mandatory = $true)][string]$OutPng,
    [string]$LogFile,
    [string]$LogMarkerRegex,
    [int]$MarkerTimeoutSeconds = 120,
    [int]$Count = 1,
    [double]$IntervalSeconds = 2
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Win32 互操作：定位窗口、置前置顶、取客户区屏幕矩形（与 record-window-gif 同源）
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
        $p = Get-Process | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like $WindowTitleLike
        } | Select-Object -First 1
        if (-not $p) { throw "找不到标题匹配 '$WindowTitleLike' 且有可见主窗口的进程。" }
        return $p
    }
    if ($ProcessName) {
        $name = $ProcessName -replace '\.exe$', ''
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $p) { throw "找不到名为 '$name' 且有可见主窗口的进程。" }
        return $p
    }
    throw "必须提供 -ProcessId / -WindowTitleLike / -ProcessName 三者之一来定位窗口。"
}

function Get-ClientScreenRect {
    param([IntPtr]$Hwnd)

    if (-not [Win32.WinApi]::IsWindow($Hwnd)) { throw "窗口句柄已失效（进程可能已退出）。" }

    [void][Win32.WinApi]::ShowWindow($Hwnd, [Win32.WinApi]::SW_RESTORE)
    [void][Win32.WinApi]::SetWindowPos($Hwnd, [Win32.WinApi]::HWND_TOPMOST, 0, 0, 0, 0,
        ([Win32.WinApi]::SWP_NOMOVE -bor [Win32.WinApi]::SWP_NOSIZE -bor [Win32.WinApi]::SWP_SHOWWINDOW))
    [void][Win32.WinApi]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 400

    $rc = New-Object Win32.RECT
    if (-not [Win32.WinApi]::GetClientRect($Hwnd, [ref]$rc)) { throw "GetClientRect 失败。" }

    $origin = New-Object Win32.POINT
    $origin.X = 0; $origin.Y = 0
    if (-not [Win32.WinApi]::ClientToScreen($Hwnd, [ref]$origin)) { throw "ClientToScreen 失败。" }

    $w = $rc.Right - $rc.Left
    $h = $rc.Bottom - $rc.Top
    if ($w -le 0 -or $h -le 0) { throw "客户区尺寸异常（${w}x${h}），窗口可能被最小化。" }
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

$outDir = Split-Path -Parent $OutPng
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

if ($LogFile -and $LogMarkerRegex) {
    Wait-ForLogMarker -Path $LogFile -Regex $LogMarkerRegex -TimeoutSec $MarkerTimeoutSeconds
} elseif ($LogFile -xor $LogMarkerRegex) {
    throw "-LogFile 和 -LogMarkerRegex 必须同时提供或同时省略。"
}

# marker 命中后再取矩形，确保此刻窗口在最前
$rect = Get-ClientScreenRect -Hwnd $hwnd
Write-Host "[rect] x=$($rect.X) y=$($rect.Y) size=$($rect.Width)x$($rect.Height)"

function Capture-One {
    param([string]$Path)
    $grabArgs = @(
        '-y', '-f', 'gdigrab',
        '-offset_x', "$($rect.X)", '-offset_y', "$($rect.Y)",
        '-video_size', "$($rect.Width)x$($rect.Height)",
        '-i', 'desktop', '-frames:v', '1', $Path
    )
    # PS 5.1 下 $ErrorActionPreference='Stop' 会把 native stderr 行当终止错误，临时放开
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $ffmpeg @grabArgs *>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) { throw "ffmpeg 截图失败（exit $code）。" }
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) { throw "截图产物为空：$Path" }
}

$produced = @()
if ($Count -le 1) {
    Capture-One -Path $OutPng
    $produced += $OutPng
} else {
    $base = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($OutPng),
        [System.IO.Path]::GetFileNameWithoutExtension($OutPng))
    $ext = [System.IO.Path]::GetExtension($OutPng)
    if (-not $ext) { $ext = ".png" }
    for ($i = 1; $i -le $Count; $i++) {
        $p = "{0}.{1:000}{2}" -f $base, $i, $ext
        Capture-One -Path $p
        $produced += $p
        Write-Host "[shot $i/$Count] $p"
        if ($i -lt $Count) { Start-Sleep -Seconds $IntervalSeconds }
    }
}

# 解除置顶，恢复窗口正常 z-order
[void][Win32.WinApi]::SetWindowPos($hwnd, [Win32.WinApi]::HWND_NOTOPMOST, 0, 0, 0, 0,
    ([Win32.WinApi]::SWP_NOMOVE -bor [Win32.WinApi]::SWP_NOSIZE))

Write-Host ""
Write-Host "=== 完成 ==="
foreach ($p in $produced) {
    $info = Get-Item $p
    $kb = [math]::Round($info.Length / 1KB, 1)
    Write-Host "PNG: $($info.FullName)  ($kb KB)"
}
Write-Host "提醒：Read 这些 PNG 确认不是全黑（低亮度不等于黑，静态 3D 场景正常）。"
