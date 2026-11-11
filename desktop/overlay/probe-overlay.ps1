param(
  [int]$X = 400,
  [int]$Y = 300,
  [int]$Size = 36,
  [int]$DurationMs = 6000
)

# 最小分层窗探针：验证四件事——不被 AMSI 拦、不抢焦点、不动指针、能干净退出。
# 真正的 overlay 会在此基础上加"命令文件轮询 + 滑行动画"。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class AciOverlayProbeForm : Form {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);

  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

  protected override bool ShowWithoutActivation { get { return true; } }

  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= 0x00000008;   // WS_EX_TOPMOST
      cp.ExStyle |= 0x00000020;   // WS_EX_TRANSPARENT (click-through)
      cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW (no taskbar)
      cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
      return cp;
    }
  }

  public static IntPtr ForegroundWindowHandle() { return GetForegroundWindow(); }
  public static string CursorPosition() {
    POINT p;
    GetCursorPos(out p);
    return p.X + "," + p.Y;
  }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

$form = New-Object AciOverlayProbeForm
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds = New-Object System.Drawing.Rectangle($X, $Y, $Size, $Size)
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta

$form.add_Paint({
  param($sender, $e)
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 40, 160, 255))
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
  $g.FillEllipse($brush, 2, 2, $Size - 4, $Size - 4)
  $g.DrawEllipse($pen, 2, 2, $Size - 4, $Size - 4)
  $brush.Dispose()
  $pen.Dispose()
})

$fgBefore = [AciOverlayProbeForm]::ForegroundWindowHandle()
$cursorBefore = [AciOverlayProbeForm]::CursorPosition()

$form.Show()

$fgAfterShow = [AciOverlayProbeForm]::ForegroundWindowHandle()
$cursorAfterShow = [AciOverlayProbeForm]::CursorPosition()

$rectInfo = New-Object 'System.Collections.Hashtable'
$rectInfo['x'] = $X
$rectInfo['y'] = $Y
$rectInfo['width'] = $Size
$rectInfo['height'] = $Size

$report = New-Object 'System.Collections.Hashtable'
$report['ok'] = $true
$report['mode'] = 'probe'
$report['rect'] = $rectInfo
$report['foregroundBefore'] = [long]$fgBefore
$report['foregroundAfterShow'] = [long]$fgAfterShow
$report['cursorBefore'] = $cursorBefore
$report['cursorAfterShow'] = $cursorAfterShow

$reportPath = Join-Path $env:TEMP 'aci-overlay-probe.json'
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath -Encoding UTF8

$deadline = (Get-Date).AddMilliseconds($DurationMs)
while ((Get-Date) -lt $deadline) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 30
}

$report['foregroundAtEnd'] = [long]([AciOverlayProbeForm]::ForegroundWindowHandle())
$report['cursorAtEnd'] = [AciOverlayProbeForm]::CursorPosition()
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath -Encoding UTF8

$form.Close()
$form.Dispose()

$report | ConvertTo-Json -Depth 4
