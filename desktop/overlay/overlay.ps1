param(
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [int]$Size = 34,
  [int]$GlideMs = 260,
  [int]$IdleTimeoutMs = 12000,
  [int]$ParentPid = 0,
  [switch]$ReducedMotion
)

# 代理光标 overlay（D1=b：只服务"不动指针"的动作）。
# 契约：
#   - 不抢焦点（WS_EX_NOACTIVATE + ShowWithoutActivation）
#   - 点击穿透（WS_EX_TRANSPARENT）
#   - 不进任务栏（WS_EX_TOOLWINDOW）
#   - 绝不调用 SetCursorPos；真实指针由调用方负责
#   - 命令文件轮询：{"seq":N,"op":"point"|"hide"|"quit","x":..,"y":..}
#   - 只在 UI 线程 DoEvents，不做 Application.Run

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class AciAgentCursorForm : Form {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);

  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

  protected override bool ShowWithoutActivation { get { return true; } }

  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= 0x00000008;   // WS_EX_TOPMOST
      cp.ExStyle |= 0x00000020;   // WS_EX_TRANSPARENT (click-through)
      cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW
      cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
      return cp;
    }
  }

  public static IntPtr ForegroundWindowHandle() { return GetForegroundWindow(); }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

$form = New-Object AciAgentCursorForm
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta

# 动画状态：当前点、目标点、脉冲强度
$script:state = @{
  x = -1000
  y = -1000
  ring = 0.0
  visible = $false
}

$form.add_Paint({
  param($sender, $e)
  if (-not $script:state.visible) { return }
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $r = $script:state.ring
  if ($r -gt 0) {
    $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](180 * $r), 40, 160, 255), 3)
    $ringSize = [int]($Size - 6 - 10 * (1 - $r))
    $g.DrawEllipse($ringPen, [int](($Size - $ringSize) / 2), [int](($Size - $ringSize) / 2), $ringSize, $ringSize)
    $ringPen.Dispose()
  }
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(225, 40, 160, 255))
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
  $g.FillEllipse($brush, 3, 3, $Size - 6, $Size - 6)
  $g.DrawEllipse($pen, 3, 3, $Size - 6, $Size - 6)
  $brush.Dispose()
  $pen.Dispose()
})

function Set-Position([int]$ax, [int]$ay) {
  $script:state.x = $ax
  $script:state.y = $ay
  $form.Bounds = New-Object System.Drawing.Rectangle(
    [int]($ax - $Size / 2), [int]($ay - $Size / 2), $Size, $Size)
}

function Show-Cursor {
  if (-not $script:state.visible) {
    $script:state.visible = $true
    $form.Show()
  }
}

function Hide-Cursor {
  $script:state.visible = $false
  $script:state.ring = 0.0
  if ($form.Visible) { $form.Hide() }
}

function Glide-To([int]$tx, [int]$ty) {
  $startX = $script:state.x
  $startY = $script:state.y
  if ($ReducedMotion -or $GlideMs -le 0) {
    Set-Position $tx $ty
    return
  }
  $steps = [Math]::Max(1, [int]($GlideMs / 16))
  $started = Get-Date
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / [double]$steps
    $ease = 1 - [Math]::Pow(1 - $t, 3)   # ease-out cubic
    Set-Position ([int]($startX + ($tx - $startX) * $ease)) ([int]($startY + ($ty - $startY) * $ease))
    $form.Invalidate()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 16
  }
}

function Pulse {
  if ($ReducedMotion) { return }
  for ($i = 0; $i -lt 8; $i++) {
    $script:state.ring = 1.0 - ($i / 8.0)
    $form.Invalidate()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 18
  }
  $script:state.ring = 0.0
}

$lastSeq = -1
$lastCommandAt = Get-Date

function Test-ParentAlive {
  if ($ParentPid -le 0) { return $true }
  $found = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  return ($null -ne $found)
}
$fgBefore = [AciAgentCursorForm]::ForegroundWindowHandle()

while ($true) {
  $now = Get-Date
  if (($now - $lastCommandAt).TotalMilliseconds -gt $IdleTimeoutMs) {
    break
  }
  if (-not (Test-ParentAlive)) {
    break
  }
  if (Test-Path $CommandFile) {
    try {
      $cmd = Get-Content $CommandFile -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($null -ne $cmd -and [int]$cmd.seq -gt $lastSeq) {
        $lastSeq = [int]$cmd.seq
        $lastCommandAt = $now
        switch ([string]$cmd.op) {
          'quit' { break }
          'hide' { Hide-Cursor }
          'point' {
            Show-Cursor
            Set-Position ([int]$cmd.x) ([int]$cmd.y)
            Glide-To ([int]$cmd.x) ([int]$cmd.y)
            Pulse
          }
        }
        if ([string]$cmd.op -eq 'quit') { break }
      }
    } catch {
      # 半截文件/占用中：下一轮再读
    }
  }
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 25
}

$fgAfter = [AciAgentCursorForm]::ForegroundWindowHandle()
Hide-Cursor
$form.Close()
$form.Dispose()

$result = New-Object 'System.Collections.Hashtable'
$result['ok'] = $true
$result['mode'] = 'overlay'
$result['reducedMotion'] = [bool]$ReducedMotion
$result['foregroundBefore'] = [long]$fgBefore
$result['foregroundAfter'] = [long]$fgAfter
$result['lastCommandSeq'] = $lastSeq
$result | ConvertTo-Json -Depth 4
