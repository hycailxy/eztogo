param(
  [string]$Action = "list_windows",
  [string]$ArgsBase64 = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 必须在读取窗口矩形前声明 DPI 感知，否则 125% 缩放下会拿到虚拟化坐标
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AciDpi {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try {
  [void][AciDpi]::SetProcessDpiAwareness(2)
} catch {
  try { [void][AciDpi]::SetProcessDPIAware() } catch { }
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AciNative {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
  public static extern IntPtr SendMessageGetText(IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam);
  [DllImport("user32.dll", EntryPoint = "SendMessageW")]
  public static extern IntPtr SendMessagePtr(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class AciInput {
  [StructLayout(LayoutKind.Explicit, Size = 40)]
  public struct INPUT {
    [FieldOffset(0)] public uint type;
    [FieldOffset(8)] public ushort wVk;
    [FieldOffset(10)] public ushort wScan;
    [FieldOffset(12)] public uint dwFlags;
    [FieldOffset(16)] public uint time;
    [FieldOffset(24)] public IntPtr dwExtraInfo;
  }
  [DllImport("user32.dll")]
  public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
  private const uint INPUT_KEYBOARD = 1;
  private const uint KEYEVENTF_KEYUP = 0x0002;
  private const uint KEYEVENTF_UNICODE = 0x0004;

  private static INPUT Key(ushort vk, ushort scan, uint flags) {
    INPUT input = new INPUT();
    input.type = INPUT_KEYBOARD;
    input.wVk = vk;
    input.wScan = scan;
    input.dwFlags = flags;
    return input;
  }

  public static void SendUnicode(string text) {
    var inputs = new List<INPUT>();
    foreach (char ch in text) {
      inputs.Add(Key(0, (ushort)ch, KEYEVENTF_UNICODE));
      inputs.Add(Key(0, (ushort)ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }
    if (inputs.Count > 0) {
      SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }
  }

  public static void SendKey(ushort vk, bool ctrl, bool alt, bool shift) {
    var inputs = new List<INPUT>();
    if (ctrl) inputs.Add(Key(0x11, 0, 0));
    if (alt) inputs.Add(Key(0x12, 0, 0));
    if (shift) inputs.Add(Key(0x10, 0, 0));
    inputs.Add(Key(vk, 0, 0));
    inputs.Add(Key(vk, 0, KEYEVENTF_KEYUP));
    if (shift) inputs.Add(Key(0x10, 0, KEYEVENTF_KEYUP));
    if (alt) inputs.Add(Key(0x12, 0, KEYEVENTF_KEYUP));
    if (ctrl) inputs.Add(Key(0x11, 0, KEYEVENTF_KEYUP));
    SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
  }
}
"@

$Options = @{}
if ($ArgsBase64) {
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsBase64))
  $parsed = $json | ConvertFrom-Json
  if ($parsed) {
    foreach ($property in $parsed.PSObject.Properties) {
      $Options[$property.Name] = $property.Value
    }
  }
}

function Write-Json($value) {
  $json = $value | ConvertTo-Json -Depth 12 -Compress
  [Console]::Out.Write($json)
}

function Get-Rect($element) {
  try {
    $rect = $element.Current.BoundingRectangle
    if ($rect.IsEmpty) { return $null }
    return [ordered]@{
      x = [int]$rect.X
      y = [int]$rect.Y
      width = [int]$rect.Width
      height = [int]$rect.Height
    }
  } catch {
    return $null
  }
}

function Get-PatternInfo($element) {
  $info = [ordered]@{
    invokable = $false
    valueSettable = $false
    toggleable = $false
    selectable = $false
    expandable = $false
  }

  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
    $info.invokable = $true
  }
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
    $info.valueSettable = -not $pattern.Current.IsReadOnly
  }
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
    $info.toggleable = $true
  }
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
    $info.selectable = $true
  }
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
    $info.expandable = $true
  }
  return $info
}

function Get-WindowList {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
  $result = @()
  for ($index = 0; $index -lt $windows.Count; $index++) {
    $window = $windows.Item($index)
    $processName = ""
    try { $processName = (Get-Process -Id $window.Current.ProcessId -ErrorAction Stop).ProcessName } catch { }
    $result += [ordered]@{
      index = $index
      handle = $window.Current.NativeWindowHandle
      name = $window.Current.Name
      pid = $window.Current.ProcessId
      processName = $processName
      className = $window.Current.ClassName
      enabled = $window.Current.IsEnabled
      offscreen = $window.Current.IsOffscreen
      rect = Get-Rect $window
    }
  }
  return $result
}

function Get-WindowElement {
  if ($Options.ContainsKey("handle") -and $Options["handle"]) {
    return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$Options["handle"]))
  }

  $windows = Get-WindowList
  if ($Options.ContainsKey("index") -and $null -ne $Options["index"]) {
    $target = $windows | Where-Object { $_.index -eq [int]$Options["index"] } | Select-Object -First 1
    if ($target) {
      return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$target.handle))
    }
  }

  if ($Options.ContainsKey("name") -and $Options["name"]) {
    $needle = [string]$Options["name"]
    # Codex 用 bundle id 精确匹配；这里按「进程名精确 -> 标题精确 -> 标题包含」三级退让，
    # 否则 "Code" 会命中标题里含 codex 的记事本窗口。
    $target = $windows | Where-Object { $_.processName -eq $needle } | Select-Object -First 1
    if (-not $target) { $target = $windows | Where-Object { $_.name -eq $needle } | Select-Object -First 1 }
    if (-not $target -and $Options.ContainsKey("strictName") -and [bool]$Options["strictName"]) {
      throw "App not found: no window whose process or title equals `"$needle`"."
    }
    if (-not $target) { $target = $windows | Where-Object { $_.name -like "*$needle*" } | Select-Object -First 1 }
    if ($target) {
      return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$target.handle))
    }
  }

  throw "Window not found. Pass handle, index, or name."
}

function Get-ElementByPath($window, [string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $window }
  $current = $window
  $segments = $path.Trim("/").Split("/") | Where-Object { $_ -ne "" }
  foreach ($segment in $segments) {
    $targetIndex = [int]$segment
    $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($current)
    $cursor = 0
    while ($null -ne $child -and $cursor -lt $targetIndex) {
      $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child)
      $cursor++
    }
    if ($null -eq $child) { throw "Element path not found: $path" }
    $current = $child
  }
  return $current
}

function Walk-Tree($element, [string]$path, [int]$depth, [int]$maxDepth, [int]$maxNodes, $nodes, $deadline = $null) {
  if ($nodes.Count -ge $maxNodes) { return }
  if ($null -ne $deadline -and [DateTime]::UtcNow -gt $deadline) { return }
  $patterns = Get-PatternInfo $element
  $rect = Get-Rect $element
  $entry = [ordered]@{
    path = $path
    handle = $element.Current.NativeWindowHandle
    name = $element.Current.Name
    controlType = $element.Current.ControlType.ProgrammaticName
    automationId = $element.Current.AutomationId
    className = $element.Current.ClassName
    enabled = $element.Current.IsEnabled
    offscreen = $element.Current.IsOffscreen
    rect = $rect
    patterns = $patterns
      selected = $false
      expandState = ""
      value = ""
  }
    try {
      $vp = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $entry.value = [string]$vp.Current.Value }
    } catch { }
    try {
      $sp = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $entry.selected = [bool]$sp.Current.IsSelected }
    } catch { }
    try {
      $ep = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$ep)) { $entry.expandState = [string]$ep.Current.ExpandCollapseState }
    } catch { }
  [void]$nodes.Add($entry)

  if ($depth -ge $maxDepth -or $nodes.Count -ge $maxNodes) { return }
  $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($element)
  $childIndex = 0
  while ($null -ne $child -and $nodes.Count -lt $maxNodes) {
    $childPath = if ($path) { "$path/$childIndex" } else { "$childIndex" }
      Walk-Tree $child $childPath ($depth + 1) $maxDepth $maxNodes $nodes $deadline
    $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child)
    $childIndex++
  }
}

function Get-MousePoint($element) {
  $rect = $element.Current.BoundingRectangle
  if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
    throw "Element has no clickable rectangle."
  }
  return @{
    x = [int]($rect.X + $rect.Width / 2)
    y = [int]($rect.Y + $rect.Height / 2)
  }
}

function Focus-Window($element, [int]$delayMs = 250) {
  # Add-Type 在同一进程内重复注册同名类型会抛错；batch 场景下必须只注册一次。
  if (-not ("AciWindow" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AciWindow {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
}

"@
  }
  $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
  [AciWindow]::ShowWindow($handle, 9) | Out-Null
  $targetPid = 0
  $targetThread = [AciWindow]::GetWindowThreadProcessId($handle, [ref]$targetPid)
  $currentThread = [AciWindow]::GetCurrentThreadId()
  [AciWindow]::AttachThreadInput($currentThread, $targetThread, $true) | Out-Null
  [AciWindow]::BringWindowToTop($handle) | Out-Null
  [AciWindow]::SetForegroundWindow($handle) | Out-Null
  [AciWindow]::AttachThreadInput($currentThread, $targetThread, $false) | Out-Null
  if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
}

function Invoke-LeftClick([int]$x, [int]$y) {
  if (-not ("AciMouse" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AciMouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP = 0x0004;
}
"@
  }
  [AciMouse]::SetCursorPos($x, $y) | Out-Null
  [AciMouse]::mouse_event([AciMouse]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  [AciMouse]::mouse_event([AciMouse]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-GridHashes($bitmap, [int]$cols = 8, [int]$rows = 8) {
  # 把截图缩成 32x32 再切成 8x8 格，每格 4x4 像素做一次 SHA256。
  # 用途：模型看过的那一屏与"现在"比对，防止按旧截图点旧坐标。
  $cell = 4
  $smallWidth = $cols * $cell
  $smallHeight = $rows * $cell
  $small = New-Object System.Drawing.Bitmap($smallWidth, $smallHeight)
  $smallGraphics = [System.Drawing.Graphics]::FromImage($small)
  $smallGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $smallGraphics.DrawImage($bitmap, 0, 0, $smallWidth, $smallHeight)
  $smallGraphics.Dispose()
  $rect = New-Object System.Drawing.Rectangle(0, 0, $smallWidth, $smallHeight)
  $bits = $small.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $bits.Stride
  $buffer = New-Object byte[] ($stride * $smallHeight)
  [System.Runtime.InteropServices.Marshal]::Copy($bits.Scan0, $buffer, 0, $buffer.Length)
  $small.UnlockBits($bits)
  $small.Dispose()
  $hashes = New-Object System.Collections.ArrayList
  for ($ry = 0; $ry -lt $rows; $ry++) {
    for ($rx = 0; $rx -lt $cols; $rx++) {
      $bytes = New-Object byte[] ($cell * $cell * 4)
      $k = 0
      for ($y = 0; $y -lt $cell; $y++) {
        $rowOffset = ($ry * $cell + $y) * $stride
        for ($x = 0; $x -lt $cell; $x++) {
          $offset = $rowOffset + ($rx * $cell + $x) * 4
          $bytes[$k] = $buffer[$offset]; $k++
          $bytes[$k] = $buffer[$offset + 1]; $k++
          $bytes[$k] = $buffer[$offset + 2]; $k++
          $bytes[$k] = $buffer[$offset + 3]; $k++
        }
      }
      $sha = [System.Security.Cryptography.SHA256]::Create()
      $digest = $sha.ComputeHash($bytes)
      $sha.Dispose()
      [void]$hashes.Add(([System.BitConverter]::ToString($digest).Replace("-", "").ToLowerInvariant()).Substring(0, 8))
    }
  }
  return $hashes
}
function Save-Screenshot($element, [string]$path, $marks = $null) {
  $rect = $null
  if ($null -ne $element) {
    $rect = $element.Current.BoundingRectangle
  }
  if ($null -eq $rect -or $rect.IsEmpty) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $rect = New-Object System.Windows.Rect($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
  }

  $width = [Math]::Max(1, [int]$rect.Width)
  $height = [Math]::Max(1, [int]$rect.Height)
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $captured = $false
  if ($null -ne $element) {
    $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
      if ($handle -ne [IntPtr]::Zero) {
        # UWP 的 PrintWindow 常要等 1–2 秒甚至超时；窗口在前台时直接抓屏更快。
        $screenCopy = ($Options.ContainsKey("screenCopy") -and [bool]$Options["screenCopy"])
        if (-not $screenCopy) {
          $hdc = $graphics.GetHdc()
          $captured = [AciNative]::PrintWindow($handle, $hdc, 2)
          $graphics.ReleaseHdc($hdc)
        }
      }
  }
    if (-not $captured) {
      # 多显示器时窗口可能在主屏左侧（负坐标），CopyFromScreen 会失败或抓成黑色；
      # 先和虚拟屏求交，再按交集抓取。
      $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $left = [Math]::Max([int]$rect.X, $virtual.X)
      $top = [Math]::Max([int]$rect.Y, $virtual.Y)
      $right = [Math]::Min([int]($rect.X + $rect.Width), $virtual.X + $virtual.Width)
      $bottom = [Math]::Min([int]($rect.Y + $rect.Height), $virtual.Y + $virtual.Height)
      if ($right -gt $left -and $bottom -gt $top) {
        $offsetX = $left - [int]$rect.X
        $offsetY = $top - [int]$rect.Y
        $copySize = New-Object System.Drawing.Size(($right - $left), ($bottom - $top))
        try { $graphics.CopyFromScreen($left, $top, $offsetX, $offsetY, $copySize) } catch { }
      }
    }

  $gridCols = 8
  $gridRows = 8
  $wantGrid = -not ($Options.ContainsKey("skipGrid") -and [bool]$Options["skipGrid"])
  $grid = if ($wantGrid) { Get-GridHashes $bitmap $gridCols $gridRows } else { @() }

  if ($null -ne $marks -and @($marks).Count -gt 0) {
    $font = New-Object System.Drawing.Font("Segoe UI", 10)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 2)
    foreach ($item in @($marks)) {
      if ($null -eq $item) { continue }
      $x = [int]$item.x - [int]$rect.X
      $y = [int]$item.y - [int]$rect.Y
      $w = [int]$item.width
      $h = [int]$item.height
      if ($w -le 0 -or $h -le 0) { continue }
      $graphics.DrawRectangle($pen, $x, $y, $w, $h)
      $labelY = [Math]::Max(0, $y - 18)
      $graphics.DrawString([string]$item.mark, $font, $brush, [float]$x, [float]$labelY)
    }
    $pen.Dispose()
    $brush.Dispose()
    $font.Dispose()
  }

  $graphics.Dispose()

  # 区域裁剪：region 用绝对屏幕坐标（和 UIA rect 同一空间），裁完记下原点，
  # 让调用方能把图像像素换算回屏幕物理像素。
  $cropX = 0
  $cropY = 0
  $regionUsed = $null
  $region = if ($Options.ContainsKey("region")) { $Options["region"] } else { $null }
  if ($null -ne $region -and @($region).Count -eq 4) {
    $rx0 = [int]$region[0] - [int]$rect.X
    $ry0 = [int]$region[1] - [int]$rect.Y
    $rx1 = [int]$region[2] - [int]$rect.X
    $ry1 = [int]$region[3] - [int]$rect.Y
    $cropX = [Math]::Max(0, [Math]::Min($width - 1, [Math]::Min($rx0, $rx1)))
    $cropY = [Math]::Max(0, [Math]::Min($height - 1, [Math]::Min($ry0, $ry1)))
    $cropW = [Math]::Min($width - $cropX, [Math]::Abs($rx1 - $rx0))
    $cropH = [Math]::Min($height - $cropY, [Math]::Abs($ry1 - $ry0))
    if ($cropW -ge 2 -and $cropH -ge 2) {
      $cropped = New-Object System.Drawing.Bitmap($cropW, $cropH)
      $cropGraphics = [System.Drawing.Graphics]::FromImage($cropped)
      $destRect = New-Object System.Drawing.Rectangle(0, 0, $cropW, $cropH)
      $srcRect = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropW, $cropH)
      $cropGraphics.DrawImage($bitmap, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
      $cropGraphics.Dispose()
      $bitmap.Dispose()
      $bitmap = $cropped
      $width = $cropW
      $height = $cropH
      $regionUsed = @{ x = $cropX; y = $cropY; width = $cropW; height = $cropH }
    }
  }

  # 图像预算：超长边先等比缩小，再按 imageFormat 编码；orig/scale 回给调用方，
  # 让它自己决定要不要按比例换算坐标。
  $origWidth = $width
  $origHeight = $height
  $maxLongEdge = if ($Options.ContainsKey("maxLongEdge")) { [int]$Options["maxLongEdge"] } else { 0 }
  $scale = 1.0
  if ($maxLongEdge -gt 0) {
    $longEdge = [Math]::Max($width, $height)
    if ($longEdge -gt $maxLongEdge) {
      $scale = [double]$maxLongEdge / [double]$longEdge
      $newWidth = [Math]::Max(1, [int][Math]::Round($width * $scale))
      $newHeight = [Math]::Max(1, [int][Math]::Round($height * $scale))
      $resized = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
      $resizeGraphics = [System.Drawing.Graphics]::FromImage($resized)
      $resizeGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $resizeGraphics.DrawImage($bitmap, 0, 0, $newWidth, $newHeight)
      $resizeGraphics.Dispose()
      $bitmap.Dispose()
      $bitmap = $resized
      $width = $newWidth
      $height = $newHeight
    }
  }

  $imageFormat = if ($Options.ContainsKey("imageFormat")) { ([string]$Options["imageFormat"]).ToLowerInvariant() } else { "png" }
  $stream = New-Object System.IO.MemoryStream
  if ($imageFormat -eq "jpeg" -or $imageFormat -eq "jpg") {
    $imageFormat = "jpeg"
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
  } else {
    $imageFormat = "png"
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  $bytes = $stream.ToArray()
  $bitmap.Dispose()
  $stream.Dispose()

  if ($path) {
    [System.IO.File]::WriteAllBytes($path, $bytes)
  }
  $returnBase64 = if ($Options.ContainsKey("returnBase64")) { [bool]$Options["returnBase64"] } else { $true }
  return @{
    base64 = if ($returnBase64) { [Convert]::ToBase64String($bytes) } else { $null }
    width = $width
    height = $height
    origWidth = $origWidth
    origHeight = $origHeight
    scale = $scale
    format = $imageFormat
    path = $path
    grid = $grid
    gridCols = $gridCols
    gridRows = $gridRows
    windowRect = @{ x = [int]$rect.X; y = [int]$rect.Y; width = [int]$rect.Width; height = [int]$rect.Height }
    region = $regionUsed
    originX = if ($regionUsed) { $cropX + [int]$rect.X } else { [int]$rect.X }
    originY = if ($regionUsed) { $cropY + [int]$rect.Y } else { [int]$rect.Y }
  }
}

function Send-TextInput([string]$text) {
  [AciInput]::SendUnicode($text)
}

function Send-KeyInput([string]$combo) {
  $parts = @($combo.Trim() -split '\+')
  # Codex 的键名写法（super+a / return / escape / arrowup）与 SendKeys 不同，这里统一归一化。
  $rawKey = $parts[-1].Trim().ToUpperInvariant()
  $aliases = @{
    "ARROWUP" = "UP"; "ARROWDOWN" = "DOWN"; "ARROWLEFT" = "LEFT"; "ARROWRIGHT" = "RIGHT"
    "RETURN" = "ENTER"; "ESCAPE" = "ESC"; "DEL" = "DELETE"; "SPACEBAR" = "SPACE"
    "PGUP" = "PAGEUP"; "PGDN" = "PAGEDOWN"; "PAGE_UP" = "PAGEUP"; "PAGE_DOWN" = "PAGEDOWN"
    "BACKSPACE" = "BACKSPACE"; "CMD" = "CTRL"; "COMMAND" = "CTRL"; "SUPER" = "CTRL"; "META" = "CTRL"; "OPTION" = "ALT"
  }
  $keyName = if ($aliases.ContainsKey($rawKey)) { $aliases[$rawKey] } else { $rawKey }
  $ctrl = ($parts -contains "CTRL") -or ($parts -contains "SUPER") -or ($parts -contains "CMD") -or ($parts -contains "COMMAND") -or ($parts -contains "META")
  $alt = ($parts -contains "ALT") -or ($parts -contains "OPTION")
  $shift = $parts -contains "SHIFT"

  $special = @{
    ENTER = 0x0D; RETURN = 0x0D; TAB = 0x09; ESC = 0x1B; ESCAPE = 0x1B
    SPACE = 0x20; BACKSPACE = 0x08; DELETE = 0x2E
    UP = 0x26; DOWN = 0x28; LEFT = 0x25; RIGHT = 0x27
    HOME = 0x24; END = 0x23; PAGEUP = 0x21; PAGEDOWN = 0x22
    F1 = 0x70; F2 = 0x71; F3 = 0x72; F4 = 0x73; F5 = 0x74; F6 = 0x75
    F7 = 0x76; F8 = 0x77; F9 = 0x78; F10 = 0x79; F11 = 0x7A; F12 = 0x7B
  }

  if ($special.ContainsKey($keyName)) {
    $vk = [uint16]$special[$keyName]
  } elseif ($keyName.Length -eq 1) {
    $vk = [uint16][int][char]::ToUpperInvariant($keyName[0])
  } else {
    throw "Unsupported key: $keyName"
  }

  [AciInput]::SendKey($vk, $ctrl, $alt, $shift)
}

function Get-ElementText($element) {
  $pattern = $null
  if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
    return $pattern.Current.Value
  }
  if ($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
    $text = $pattern.DocumentRange.GetText(-1)
    if ($text) { return $text }
  }
  $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
  if ($handle -ne [IntPtr]::Zero) {
    $buffer = New-Object System.Text.StringBuilder 8192
    [void][AciNative]::SendMessageGetText($handle, 0x000D, [IntPtr]$buffer.Capacity, $buffer)
    if ($buffer.Length -gt 0) { return $buffer.ToString() }
    [void][AciNative]::GetWindowText($handle, $buffer, $buffer.Capacity)
    return $buffer.ToString()
  }
  return $element.Current.Name
}

function Set-ElementTextNative($element, [string]$text) {
  $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
  if ($handle -eq [IntPtr]::Zero) { return $false }
  [void][AciNative]::SendMessage($handle, 0x000C, [IntPtr]::Zero, $text)
  return $true
}

function Type-ElementTextNative($element, [string]$text) {
  $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
  if ($handle -eq [IntPtr]::Zero) { return $false }
  # EM_SETSEL(0, -1) 选中全部，随后 WM_CHAR 替换选中内容
  [void][AciNative]::SendMessagePtr($handle, 0x00B1, [IntPtr]::Zero, [IntPtr](-1))
  foreach ($character in $text.ToCharArray()) {
    [void][AciNative]::SendMessagePtr($handle, 0x0102, [IntPtr]([int]$character), [IntPtr]::Zero)
  }
  return $true
}

function Get-FocusInfo {
  $handle = [AciNative]::GetForegroundWindow()
  $name = ""
  $processId = 0
  if ($handle -ne [IntPtr]::Zero) {
    try {
      $element = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
      $name = $element.Current.Name
    } catch { }
    try { [void][AciNative]::GetWindowThreadProcessId($handle, [ref]$processId) } catch { }
  }
  $processName = ""
  if ($processId -gt 0) {
    try { $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { }
  }
  return [ordered]@{
    handle = [long]$handle
    title = $name
    pid = $processId
    processName = $processName
  }
}

function Get-FocusedElementInfo {
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) { return $null }
    return @{
      name = $focused.Current.Name
      controlType = $focused.Current.ControlType.ProgrammaticName
      automationId = $focused.Current.AutomationId
      className = $focused.Current.ClassName
    }
  } catch { return $null }
}

function Get-TreeDigest($element, [int]$maxDepth = 4, [int]$maxNodes = 200) {
  $nodes = New-Object System.Collections.ArrayList
  Walk-Tree $element "" 0 $maxDepth $maxNodes $nodes
  $parts = New-Object System.Collections.ArrayList
  foreach ($node in $nodes) {
    [void]$parts.Add(("{0}|{1}|{2}|{3}" -f $node.path, $node.controlType, $node.name, $node.enabled))
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
  $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
  $sha.Dispose()
  return [ordered]@{
    treeDigest = $hash.Substring(0, 32)
    nodeCount = $nodes.Count
    truncated = ($nodes.Count -ge $maxNodes)
  }
}

function Ensure-AciMouse2 {
  if ("AciMouse2" -as [type]) { return }
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AciMouse2 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  public const uint LEFTDOWN = 0x0002;
  public const uint LEFTUP = 0x0004;
  public const uint WHEEL = 0x0800;
  public static void LeftDown() { mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero); }
  public static void LeftUp() { mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero); }
  public static void Wheel(int delta) { mouse_event(WHEEL, 0, 0, (uint)delta, UIntPtr.Zero); }
}
"@
}

function Focus-BestEditable($window) {
  # Codex type_text targets the app focused element; focus drifts between processes,
  # so pick an editable control (Document/Edit with Value or Text) and focus it first.
  $candidates = @()
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $stack = New-Object System.Collections.Stack
  $stack.Push(@{ element = $window; depth = 0 })
  while ($stack.Count -gt 0) {
    $item = $stack.Pop()
    if ($item.depth -gt 6) { continue }
    $element = $item.element
    try {
      $type = $element.Current.ControlType.ProgrammaticName
      if ($type -eq "ControlType.Document" -or $type -eq "ControlType.Edit") {
        $hasValue = $false
        $vp = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $hasValue = $true }
        $tp = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$tp)) { $hasValue = $true }
        if ($hasValue) { $candidates += $element }
      }
    } catch { }
  try { $child = $walker.GetFirstChild($element, $cache) } catch { return }
    while ($null -ne $child) {
      $stack.Push(@{ element = $child; depth = ($item.depth + 1) })
    try { $child = $walker.GetNextSibling($child, $cache) } catch { break }
    }
  }
  if ($candidates.Count -eq 0) { return $false }
  try {
    $candidates[0].SetFocus()
    Start-Sleep -Milliseconds 80
    return $true
  } catch { return $false }
}

function New-AciTreeCache {
  # UIA 跨进程（尤其 UWP）每次读属性都是一次 RPC。CacheRequest 把这些属性一次性批量取回，
  # 之后读 Cached 属性不再走跨进程调用。
  $cache = New-Object System.Windows.Automation.CacheRequest
  $cache.TreeFilter = [System.Windows.Automation.Condition]::TrueCondition
  foreach ($prop in @(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    [System.Windows.Automation.AutomationElement]::IsEnabledProperty,
    [System.Windows.Automation.AutomationElement]::IsOffscreenProperty,
    [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty,
    [System.Windows.Automation.AutomationElement]::NativeWindowHandleProperty
  )) { $cache.Add($prop) }
  foreach ($pattern in @(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [System.Windows.Automation.TogglePattern]::Pattern,
    [System.Windows.Automation.SelectionItemPattern]::Pattern,
    [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
    [System.Windows.Automation.ValuePattern]::Pattern,
    [System.Windows.Automation.ScrollPattern]::Pattern
  )) { $cache.Add($pattern) }
  return $cache
}

function Walk-TreeCached($walker, $element, [string]$path, [int]$depth, [int]$maxDepth, [int]$maxNodes, $nodes, $deadline, $cache) {
  if ($nodes.Count -ge $maxNodes) { return }
  if ($null -ne $deadline -and [DateTime]::UtcNow -gt $deadline) { return }
  $patterns = @{}
  foreach ($p in @(
    @{ key = "invokable"; pattern = [System.Windows.Automation.InvokePattern]::Pattern },
    @{ key = "toggleable"; pattern = [System.Windows.Automation.TogglePattern]::Pattern },
    @{ key = "selectable"; pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern },
    @{ key = "expandable"; pattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern },
    @{ key = "valueSettable"; pattern = [System.Windows.Automation.ValuePattern]::Pattern },
    @{ key = "scrollable"; pattern = [System.Windows.Automation.ScrollPattern]::Pattern }
  )) {
    $holder = $null
    try { $patterns[$p.key] = [bool]$element.TryGetCachedPattern($p.pattern, [ref]$holder) } catch { $patterns[$p.key] = $false }
  }
  $rect = @{ x = 0; y = 0; width = 0; height = 0 }
  try {
    $r = $element.Cached.BoundingRectangle
    if (-not $r.IsEmpty) { $rect = @{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height } }
  } catch { }
  $entry = [ordered]@{
    path = $path
    handle = [long]([int]$element.Cached.NativeWindowHandle)
    name = [string]$element.Cached.Name
    controlType = [string]$element.Cached.ControlType.ProgrammaticName
    automationId = [string]$element.Cached.AutomationId
    className = [string]$element.Cached.ClassName
    enabled = [bool]$element.Cached.IsEnabled
    offscreen = [bool]$element.Cached.IsOffscreen
    rect = $rect
    patterns = $patterns
    selected = $false
    expandState = ""
    value = ""
  }
  try {
    $vp = $null
    if ($element.TryGetCachedPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $entry.value = [string]$vp.Current.Value }
  } catch { }
  try {
    $sp = $null
    if ($element.TryGetCachedPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $entry.selected = [bool]$sp.Current.IsSelected }
  } catch { }
  try {
    $ep = $null
    if ($element.TryGetCachedPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$ep)) { $entry.expandState = [string]$ep.Current.ExpandCollapseState }
  } catch { }
  [void]$nodes.Add($entry)
  if ($depth -ge $maxDepth -or $nodes.Count -ge $maxNodes) { return }
  $child = $null
  try { $child = $walker.GetFirstChild($element) } catch { return }
  $childIndex = 0
  while ($null -ne $child -and $nodes.Count -lt $maxNodes) {
    $childPath = if ($path) { "$path/$childIndex" } else { "$childIndex" }
    Walk-TreeCached $walker $child $childPath ($depth + 1) $maxDepth $maxNodes $nodes $deadline $cache
    try { $child = $walker.GetNextSibling($child) } catch { break }
    $childIndex++
  }
}

function Invoke-AciAction {
  param([string]$ActionName, $ActionOptions)
  # batch 内每个动作换一批 Options；helpers 里的 $Options 会解析到 script 作用域。
  $script:Options = $ActionOptions
  switch ($ActionName) {
    "list_windows" {
      return @{ windows = Get-WindowList }
    }
    "tree" {
      $window = Get-WindowElement
      $maxDepth = if ($Options.ContainsKey("maxDepth")) { [int]$Options["maxDepth"] } else { 4 }
      $maxNodes = if ($Options.ContainsKey("maxNodes")) { [int]$Options["maxNodes"] } else { 250 }
      $nodes = New-Object System.Collections.ArrayList
      $budgetMs = if ($Options.ContainsKey("budgetMs")) { [int]$Options["budgetMs"] } else { 2500 }
      $deadline = [DateTime]::UtcNow.AddMilliseconds($budgetMs)
      Walk-Tree $window "" 0 $maxDepth $maxNodes $nodes $deadline
      return @{
        window = @{ name = $window.Current.Name; handle = $window.Current.NativeWindowHandle }
        nodes = $nodes
        truncated = (($nodes.Count -ge $maxNodes) -or ([DateTime]::UtcNow -gt $deadline))
        maxNodes = $maxNodes
      }
    }
    "invoke" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      $pattern = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return @{ action = "invoke" }
      }
      if ($element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
        $pattern.Toggle()
        return @{ action = "toggle" }
      }
      if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
        return @{ action = "select" }
      }
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        if ($pattern.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) {
          $pattern.Collapse()
        } else {
          $pattern.Expand()
        }
        return @{ action = "expandCollapse" }
      }
      $handle = [IntPtr]([long]$element.Current.NativeWindowHandle)
      if ($handle -ne [IntPtr]::Zero -and $element.Current.ClassName -match "BUTTON") {
        [void][AciNative]::SendMessage($handle, 0x00F5, [IntPtr]::Zero, $null)
        return @{ action = "bmClick" }
      }
      throw "Element at path $($Options['path']) has no supported invoke/toggle/select/expand pattern."
    }
    "assert" {
      $window = Get-WindowElement
      $timeoutMs = if ($Options.ContainsKey("timeoutMs")) { [Math]::Min(30000, [int]$Options["timeoutMs"]) } else { 5000 }
      $intervalMs = if ($Options.ContainsKey("intervalMs")) { [Math]::Max(50, [int]$Options["intervalMs"]) } else { 250 }
      $stable = if ($Options.ContainsKey("stableSamples")) { [Math]::Max(1, [int]$Options["stableSamples"]) } else { 2 }
      $expectText = if ($Options.ContainsKey("expectText")) { [string]$Options["expectText"] } else { "" }
      $expectDigest = if ($Options.ContainsKey("expectDigest")) { [string]$Options["expectDigest"] } else { "" }
      $maxNodes = if ($Options.ContainsKey("maxNodes")) { [int]$Options["maxNodes"] } else { 400 }
      $started = Get-Date
      $deadline = $started.AddMilliseconds($timeoutMs)
      $passes = 0
      $samples = 0
      $lastDigest = ""
      $lastHit = ""
      while ((Get-Date) -lt $deadline) {
        $nodes = New-Object System.Collections.ArrayList
        Walk-Tree $window "" 0 6 $maxNodes $nodes
        $samples++
        $parts = New-Object System.Collections.ArrayList
        $textHit = $false
        foreach ($node in $nodes) {
          [void]$parts.Add(("{0}|{1}|{2}" -f $node.path, $node.controlType, $node.name))
          if ($expectText -and -not $textHit -and ([string]$node.name).IndexOf($expectText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $textHit = $true
            $lastHit = [string]$node.name
          }
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $lastDigest = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace("-", "").ToLowerInvariant()).Substring(0, 32)
        $sha.Dispose()
        $ok = $true
        if ($expectText -and -not $textHit) { $ok = $false }
        if ($expectDigest -and $lastDigest -ne $expectDigest) { $ok = $false }
        if ($ok) { $passes++ } else { $passes = 0 }
        if ($passes -ge $stable) {
          return @{ satisfied = $true; samples = $samples; elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds; digest = $lastDigest; matchedText = $lastHit }
        }
        Start-Sleep -Milliseconds $intervalMs
      }
      return @{ satisfied = $false; samples = $samples; elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds; digest = $lastDigest; matchedText = $lastHit }
    }
    "watch" {
      $window = Get-WindowElement
      $timeoutMs = if ($Options.ContainsKey("timeoutMs")) { [Math]::Min(60000, [int]$Options["timeoutMs"]) } else { 10000 }
      $intervalMs = if ($Options.ContainsKey("intervalMs")) { [Math]::Max(100, [int]$Options["intervalMs"]) } else { 500 }
      $baseline = if ($Options.ContainsKey("baselineDigest")) { [string]$Options["baselineDigest"] } else { "" }
      $started = Get-Date
      $deadline = $started.AddMilliseconds($timeoutMs)
      $samples = 0
      $lastDigest = ""
      while ((Get-Date) -lt $deadline) {
        $digestInfo = Get-TreeDigest $window
        $samples++
        $lastDigest = [string]$digestInfo.treeDigest
        if (-not $baseline) {
          $baseline = $lastDigest
        } elseif ($lastDigest -ne $baseline) {
          return @{ changed = $true; baselineDigest = $baseline; digest = $lastDigest; samples = $samples; elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds }
        }
        Start-Sleep -Milliseconds $intervalMs
      }
      return @{ changed = $false; baselineDigest = $baseline; digest = $lastDigest; samples = $samples; elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds }
    }
    "patch_hash" {
      $window = Get-WindowElement
      if (-not $Options.ContainsKey("x") -or -not $Options.ContainsKey("y")) {
        throw "patch_hash requires x and y"
      }
      $Options["returnBase64"] = $false
      $shot = Save-Screenshot $window "" $null
      $rect = $shot.windowRect
      $lx = [int]$Options["x"] - [int]$rect.x
      $ly = [int]$Options["y"] - [int]$rect.y
      if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge [int]$rect.width -or $ly -ge [int]$rect.height) {
        throw "Coordinates are outside the window."
      }
      $cols = [int]$shot.gridCols
      $rows = [int]$shot.gridRows
      $col = [Math]::Min($cols - 1, [int][Math]::Floor($lx * $cols / [double][int]$rect.width))
      $row = [Math]::Min($rows - 1, [int][Math]::Floor($ly * $rows / [double][int]$rect.height))
      $index = $row * $cols + $col
      return @{
        hash = [string]$shot.grid[$index]
        index = $index
        row = $row
        col = $col
        cols = $cols
        rows = $rows
        windowRect = $rect
      }
    }
    "describe" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      return @{
        path = [string]$Options["path"]
        name = $element.Current.Name
        controlType = $element.Current.ControlType.ProgrammaticName
        className = $element.Current.ClassName
        automationId = $element.Current.AutomationId
        enabled = $element.Current.IsEnabled
        offscreen = $element.Current.IsOffscreen
        rect = Get-Rect $element
        patterns = Get-PatternInfo $element
      }
    }
    "get_text" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      return @{ text = Get-ElementText $element }
    }
    "set_value" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      $pattern = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        $pattern.SetValue([string]$Options["value"])
      } elseif (Set-ElementTextNative $element ([string]$Options["value"])) {
        # Win32 Edit/RichEdit 没有 ValuePattern，直接 WM_SETTEXT
      } else {
        throw "Element at path $($Options['path']) does not support ValuePattern or WM_SETTEXT."
      }
      return @{ action = "setValue"; value = [string]$Options["value"] }
    }
    "type_text" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      $text = [string]$Options["text"]
      Focus-Window $window
      $pattern = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) -and -not $pattern.Current.IsReadOnly) {
        $pattern.SetValue($text)
        return @{ action = "setValue" }
      }
      if (Type-ElementTextNative $element $text) {
        return @{ action = "wmChar" }
      }
      $focused = $false
      try {
        $element.SetFocus()
        $focused = $true
      } catch { }
      if ($focused) {
        Start-Sleep -Milliseconds 100
        $escaped = $text -replace '([+^%~(){}\[\]])', '{$1}'
        [System.Windows.Forms.SendKeys]::SendWait($escaped)
        return @{ action = "sendKeys" }
      }
      $point = Get-MousePoint $element
      Invoke-LeftClick $point.x $point.y
      Start-Sleep -Milliseconds 150
      $escaped = $text -replace '([+^%~(){}\[\]])', '{$1}'
      [System.Windows.Forms.SendKeys]::SendWait($escaped)
      return @{ action = "clickSendKeys"; x = $point.x; y = $point.y }
    }
    "click" {
      $window = Get-WindowElement
      $previous = [AciNative]::GetForegroundWindow()
      Focus-Window $window
      $activationPulse = if ($Options.ContainsKey("activationPulse")) { [bool]$Options["activationPulse"] } else { $true }
      if ($activationPulse) {
        # Electron 窗口常常"看起来在前台但自己不认为是 active"，Codex 用视觉遮罩骗它；
        # Windows 这边的等价手段是直接补发 WM_ACTIVATE / WM_SETFOCUS。
        $pulseHandle = [IntPtr]([long]$window.Current.NativeWindowHandle)
        try { [void][AciNative]::SendMessagePtr($pulseHandle, 0x0006, [IntPtr]1, [IntPtr]::Zero) } catch { }
        try { [void][AciNative]::SendMessagePtr($pulseHandle, 0x0007, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
        Start-Sleep -Milliseconds 40
      }
      if ($Options.ContainsKey("path")) {
        $element = Get-ElementByPath $window ([string]$Options["path"])
        $point = Get-MousePoint $element
        Invoke-LeftClick $point.x $point.y
        $restore = if ($Options.ContainsKey("restoreFocus")) { [bool]$Options["restoreFocus"] } else { $true }
        $targetHandle = [IntPtr]([long]$window.Current.NativeWindowHandle)
        if ($restore -and $previous -ne [IntPtr]::Zero -and $previous -ne $targetHandle) {
          try { [void][AciWindow]::SetForegroundWindow($previous) } catch { }
        }
        return @{ action = "clickElement"; x = $point.x; y = $point.y; restoredForeground = ($restore -and $previous -ne $targetHandle); focused = (Get-FocusedElementInfo) }
        return @{ action = "clickElement"; x = $point.x; y = $point.y }
      } else {
        $x = [int]$Options["x"]
        $y = [int]$Options["y"]
        Invoke-LeftClick $x $y
        return @{ action = "click"; x = $x; y = $y }
      }
    }
    "send_text" {
      if (($Options.ContainsKey("handle") -and $Options["handle"]) -or ($Options.ContainsKey("index") -and $null -ne $Options["index"]) -or ($Options.ContainsKey("name") -and $Options["name"])) {
        $window = Get-WindowElement
      Focus-Window $window 80
      }
      $windowRef = $null
      try { $windowRef = Get-WindowElement } catch { }
      if ($null -ne $windowRef) {
        $focusedElement = $null
        try { $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement } catch { }
        $sameApp = $false
        if ($null -ne $focusedElement) {
          try { $sameApp = ($focusedElement.Current.ProcessId -eq $windowRef.Current.ProcessId) } catch { }
        }
        if (-not $sameApp) { [void](Focus-BestEditable $windowRef) }
      }
      Send-TextInput ([string]$Options["text"])
      return @{ action = "sendText" }
    }
    "send_key" {
      if (($Options.ContainsKey("handle") -and $Options["handle"]) -or ($Options.ContainsKey("index") -and $null -ne $Options["index"]) -or ($Options.ContainsKey("name") -and $Options["name"])) {
        $window = Get-WindowElement
      Focus-Window $window 80
      }
      Send-KeyInput ([string]$Options["key"])
      return @{ action = "sendKey"; key = [string]$Options["key"] }
    }
    "scroll_element" {
      $window = Get-WindowElement
      $element = if ($Options.ContainsKey("path") -and $Options["path"]) { Get-ElementByPath $window ([string]$Options["path"]) } else { $window }
      $direction = if ($Options.ContainsKey("direction")) { [string]$Options["direction"] } else { "down" }
      $pages = if ($Options.ContainsKey("pages")) { [int]$Options["pages"] } else { 1 }
      if ($pages -lt 1) { $pages = 1 }
      $scrollPattern = $null
      if ($element.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$scrollPattern)) {
        $vertical = if ($direction -eq "up") { [System.Windows.Automation.ScrollAmount]::LargeDecrement } else { [System.Windows.Automation.ScrollAmount]::LargeIncrement }
        $horizontal = [System.Windows.Automation.ScrollAmount]::NoAmount
        if ($direction -eq "left") { $horizontal = [System.Windows.Automation.ScrollAmount]::LargeDecrement; $vertical = [System.Windows.Automation.ScrollAmount]::NoAmount }
        if ($direction -eq "right") { $horizontal = [System.Windows.Automation.ScrollAmount]::LargeIncrement; $vertical = [System.Windows.Automation.ScrollAmount]::NoAmount }
        for ($i = 0; $i -lt $pages; $i++) {
          $scrollPattern.Scroll($horizontal, $vertical)
          Start-Sleep -Milliseconds 120
        }
        return @{ action = "scroll"; method = "ScrollPattern"; direction = $direction; pages = $pages }
      }
      $point = Get-MousePoint $element
      Ensure-AciMouse2
      $delta = if ($direction -eq "up") { 120 * $pages } else { -120 * $pages }
      if ($direction -eq "left" -or $direction -eq "right") { $delta = 0 }
      [AciMouse2]::SetCursorPos($point.X, $point.Y) | Out-Null
      if ($delta -ne 0) {
        $wheelData = if ($delta -lt 0) { [uint32](4294967296 + $delta) } else { [uint32]$delta }
        [AciMouse2]::mouse_event([AciMouse2]::WHEEL, 0, 0, $wheelData, [UIntPtr]::Zero)
      }
      return @{ action = "scroll"; method = "wheel"; direction = $direction; pages = $pages; point = @{ x = $point.X; y = $point.Y } }
    }

    "drag_paths" {
      $window = Get-WindowElement
      $fromPath = [string]$Options["fromPath"]
      $toPath = [string]$Options["toPath"]
      if (-not $fromPath -or -not $toPath) { throw "drag_paths requires fromPath and toPath" }
      $from = Get-MousePoint (Get-ElementByPath $window $fromPath)
      $to = Get-MousePoint (Get-ElementByPath $window $toPath)
      Ensure-AciMouse2
      [AciMouse2]::SetCursorPos($from.X, $from.Y) | Out-Null
      Start-Sleep -Milliseconds 60
      [AciMouse2]::mouse_event([AciMouse2]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      $steps = 12
      for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($from.X + (($to.X - $from.X) * $i / $steps))
        $y = [int]($from.Y + (($to.Y - $from.Y) * $i / $steps))
        [AciMouse2]::SetCursorPos($x, $y) | Out-Null
        Start-Sleep -Milliseconds 25
      }
      [AciMouse2]::mouse_event([AciMouse2]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
      return @{ action = "drag"; from = @{ x = $from.X; y = $from.Y }; to = @{ x = $to.X; y = $to.Y } }
    }
    "secondary_action" {
      $window = Get-WindowElement
      $element = Get-ElementByPath $window ([string]$Options["path"])
      $name = if ($Options.ContainsKey("action")) { [string]$Options["action"] } else { "Press" }
      $pattern = $null
      if ($name -match "^(?i)(raise|focus|activate)$") {
        Focus-Window $element
        return @{ action = "secondary"; performed = "Raise"; focused = (Get-FocusedElementInfo) }
      }
      if ($name -match "^(?i)expand$") {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) { throw "Element does not support Expand." }
        $pattern.Expand()
        Start-Sleep -Milliseconds 150
        return @{ action = "secondary"; performed = "Expand"; focused = (Get-FocusedElementInfo) }
      }
      if ($name -match "^(?i)collapse$") {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) { throw "Element does not support Collapse." }
        $pattern.Collapse()
        Start-Sleep -Milliseconds 150
        return @{ action = "secondary"; performed = "Collapse"; focused = (Get-FocusedElementInfo) }
      }
      if ($name -match "^(?i)select$") {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { throw "Element does not support Select." }
        $pattern.Select()
        return @{ action = "secondary"; performed = "Select"; focused = (Get-FocusedElementInfo) }
      }
      if ($name -match "^(?i)toggle$") {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { throw "Element does not support Toggle." }
        $pattern.Toggle()
        return @{ action = "secondary"; performed = "Toggle"; focused = (Get-FocusedElementInfo) }
      }
      if ($name -match "^(?i)(showmenu|menu)$") {
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) { throw "Element does not support ShowMenu." }
        $pattern.Expand()
        return @{ action = "secondary"; performed = "ShowMenu"; focused = (Get-FocusedElementInfo) }
      }
      if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return @{ action = "secondary"; performed = "Press"; focused = (Get-FocusedElementInfo) }
      }
      if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
        return @{ action = "secondary"; performed = "Select"; focused = (Get-FocusedElementInfo) }
      }
      throw "Element supports no secondary action."
    }

    "focused_element" {
      $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
      if ($null -eq $focused) { return @{ focused = $null } }
      return @{
        focused = @{
          name = $focused.Current.Name
          controlType = $focused.Current.ControlType.ProgrammaticName
          automationId = $focused.Current.AutomationId
          className = $focused.Current.ClassName
        }
      }
    }

    "tree_cached" {
      $window = Get-WindowElement
      $maxDepth = if ($Options.ContainsKey("maxDepth")) { [int]$Options["maxDepth"] } else { 4 }
      $maxNodes = if ($Options.ContainsKey("maxNodes")) { [int]$Options["maxNodes"] } else { 250 }
      $budgetMs = if ($Options.ContainsKey("budgetMs")) { [int]$Options["budgetMs"] } else { 2500 }
      $deadline = [DateTime]::UtcNow.AddMilliseconds($budgetMs)
      $nodes = New-Object System.Collections.ArrayList
      $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $cache = New-AciTreeCache
      $cache.Push()
      try {
        # 窗口根元素本身不在缓存里，先取一份带缓存的副本
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$window.Current.NativeWindowHandle))
        Walk-TreeCached $walker $root "" 0 $maxDepth $maxNodes $nodes $deadline $cache
      } finally {
        $cache.Pop()
      }
      return @{
        window = @{ name = $window.Current.Name; handle = $window.Current.NativeWindowHandle }
        nodes = $nodes
        truncated = (($nodes.Count -ge $maxNodes) -or ([DateTime]::UtcNow -gt $deadline))
        maxNodes = $maxNodes
        cached = $true
      }
    }

    "close" {
      $window = Get-WindowElement
      $pattern = $null
      if (-not $window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)) {
        throw "Window does not support WindowPattern.Close."
      }
      $pattern.Close()
      return @{ action = "close" }
    }
    "screenshot_marked" {
      $window = Get-WindowElement
      $path = if ($Options.ContainsKey("path")) { [string]$Options["path"] } else { "" }
      $marks = if ($Options.ContainsKey("marks")) { $Options["marks"] } else { @() }
      return Save-Screenshot $window $path $marks
    }
    "screenshot" {
      $window = $null
      if (($Options.ContainsKey("handle") -and $Options["handle"]) -or ($Options.ContainsKey("index") -and $null -ne $Options["index"]) -or ($Options.ContainsKey("name") -and $Options["name"])) {
        $window = Get-WindowElement
      }
      $path = if ($Options.ContainsKey("path")) { [string]$Options["path"] } else { "" }
      return Save-Screenshot $window $path
    }
    "hit_test" {
      if (-not $Options.ContainsKey("x") -or -not $Options.ContainsKey("y")) {
        throw "hit_test requires x and y"
      }
      $point = New-Object AciNative+POINT
      $point.X = [int]$Options["x"]
      $point.Y = [int]$Options["y"]
      $hit = [AciNative]::WindowFromPoint($point)
      $root = [IntPtr]::Zero
      if ($hit -ne [IntPtr]::Zero) { $root = [AciNative]::GetAncestor($hit, 2) }
      if ($root -eq [IntPtr]::Zero) { $root = $hit }
      $name = ""
      $className = ""
      if ($root -ne [IntPtr]::Zero) {
        try {
          $element = [System.Windows.Automation.AutomationElement]::FromHandle($root)
          $name = $element.Current.Name
          $className = $element.Current.ClassName
        } catch { }
      }
      $processId = 0
      if ($root -ne [IntPtr]::Zero) {
        try { [void][AciNative]::GetWindowThreadProcessId($root, [ref]$processId) } catch { }
      }
      $processName = ""
      if ($processId -gt 0) {
        try { $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { }
      }
      return @{
        x = [int]$Options["x"]
        y = [int]$Options["y"]
        handle = [long]$root
        name = $name
        className = $className
        pid = $processId
        processName = $processName
      }
    }
    "wait" {
      $ms = if ($Options.ContainsKey("ms")) { [int]$Options["ms"] } else { 250 }
      if ($ms -lt 0) { throw "ms must be non-negative" }
      if ($ms -gt 10000) { throw "ms exceeds maximum of 10000" }
      Start-Sleep -Milliseconds $ms
      return @{ action = "wait"; ms = $ms }
    }
    "state" {
      $focus = Get-FocusInfo
      $target = $null
      if (($Options.ContainsKey("handle") -and $Options["handle"]) -or ($Options.ContainsKey("index") -and $null -ne $Options["index"]) -or ($Options.ContainsKey("name") -and $Options["name"])) {
        $target = Get-WindowElement
      }
      if ($null -eq $target -and [long]$focus.handle -ne 0) {
        try { $target = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$focus.handle)) } catch { }
      }
      $windowInfo = $null
      $digest = @{ treeDigest = $null; nodeCount = 0; truncated = $false }
      if ($null -ne $target) {
        $windowInfo = @{ name = $target.Current.Name; handle = $target.Current.NativeWindowHandle }
        $digest = Get-TreeDigest $target
      }
      return @{
        focus = $focus
        window = $windowInfo
        treeDigest = $digest.treeDigest
        nodeCount = $digest.nodeCount
        truncated = $digest.truncated
      }
    }
    default {
      throw "Unknown action: $ActionName"
    }
  }
}

function ConvertTo-ActionOptions($item) {
  $hash = @{}
  if ($null -ne $item) {
    foreach ($property in $item.PSObject.Properties) {
      $hash[$property.Name] = $property.Value
    }
  }
  return $hash
}

function Invoke-AciBatch {
  # 注意：PowerShell 会把单元素数组在管道里拆开，所以这里必须直接赋值再 @()，
  # 不能写成 $x = if (...) { @(...) } —— 那样单动作 batch 会拿到 .Count = $null。
  $rawActions = @()
  if ($Options.ContainsKey("actions")) {
    $rawActions = @($Options["actions"])
  }
  $completed = New-Object System.Collections.ArrayList
  $failed = $null
  $aborted = $null
  $total = $rawActions.Count
  $abortFile = if ($Options.ContainsKey("abortFile")) { [string]$Options["abortFile"] } else { "" }
  $abortSince = $null
  if ($Options.ContainsKey("abortSince")) {
    try { $abortSince = [datetime]::Parse([string]$Options["abortSince"]).ToUniversalTime() } catch { }
  }
  for ($index = 0; $index -lt $total; $index++) {
    # 人在面板按了 Abort：读信号文件的 mtime，比本次调用开始时间新才生效。
    if ($abortFile -and $null -ne $abortSince -and (Test-Path $abortFile)) {
      try {
        $stamp = (Get-Item $abortFile).LastWriteTimeUtc
        if ($stamp -gt $abortSince) {
          $aborted = [ordered]@{ index = $index; reason = "aborted_by_user"; at = $stamp.ToString("o") }
          break
        }
      } catch { }
    }
    $item = $rawActions[$index]
    $op = [string]$item.action
    $opOptions = ConvertTo-ActionOptions $item
    # batch 里统一钉住窗口，避免每个动作各自按名字重新解析导致漂移
    if ($Options.ContainsKey("handle") -and $Options["handle"]) {
      $opOptions["handle"] = $Options["handle"]
    }
    try {
      $data = Invoke-AciAction $op $opOptions
      [void]$completed.Add([ordered]@{ action = $op; ok = $true; data = $data })
    } catch {
      $failed = [ordered]@{ index = $index; action = $op; error = $_.Exception.Message }
      break
    }
    if ($index -lt ($total - 1)) { Start-Sleep -Milliseconds 10 }
  }
  $remaining = $total - $completed.Count
  if ($null -ne $failed) { $remaining = $remaining - 1 }
  if ($null -ne $aborted) { $remaining = $remaining - 1 }
  return [ordered]@{
    completed = $completed
    failed = $failed
    aborted = $aborted
    remaining = [Math]::Max(0, $remaining)
    total = $total
  }
}

function Initialize-AciMsgPump {
  if ("AciMsgPump" -as [type]) { return }
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AciMsgPump {
  [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
  [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
  [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG lpMsg);
  [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG lpMsg);
  public static int Pump() {
    MSG msg; int count = 0;
    while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); count++; if (count > 500) { break; } }
    return count;
  }
}
"@
}

if ($Action -eq "serve") {
  # 常驻模式：UIA 与 Add-Type 只加载一次，之后按行收发 JSON。
  $stdin = [Console]::In
  $stdout = [Console]::Out
  [Console]::Error.WriteLine("ready")
  while ($true) {
    $line = $stdin.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }
    $request = $null
    try { $request = $line | ConvertFrom-Json } catch {
      $stdout.WriteLine('{"id":null,"ok":false,"error":"bad json"}')
      $stdout.Flush()
      continue
    }
    $reqId = if ($request.PSObject.Properties.Name -contains "id") { $request.id } else { $null }
    $reqAction = [string]$request.action
    $reqOptions = @{}
    if (($request.PSObject.Properties.Name -contains "args") -and ($null -ne $request.args)) {
      foreach ($property in $request.args.PSObject.Properties) { $reqOptions[$property.Name] = $property.Value }
    }
    try {
      $result = Invoke-AciAction $reqAction $reqOptions
      $payload = @{ id = $reqId; ok = $true; data = $result } | ConvertTo-Json -Depth 12 -Compress
      $stdout.WriteLine($payload)
    } catch {
      $payload = @{ id = $reqId; ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 6 -Compress
      $stdout.WriteLine($payload)
    }
    $stdout.Flush()
  }
  exit 0
}

try {
  if ($Action -eq "batch") {
    Write-Json @{ ok = $true; data = (Invoke-AciBatch) }
    exit 0
  }
  $data = Invoke-AciAction $Action $Options
  Write-Json @{ ok = $true; data = $data }
} catch {
  Write-Json @{ ok = $false; error = $_.Exception.Message }
  exit 1
}
