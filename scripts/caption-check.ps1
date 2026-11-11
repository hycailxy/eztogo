<#
  光标旁"实时说明"回归检查。

  起一个真实的叠加层进程（和 MCP 用的是同一个 codex-cursor.ps1），
  连续发两条不同的说明文字，各截一次说明框区域，断言两帧像素不同、并把图存下来人工看。
  不碰正在跑的叠加层：只杀自己拉起的这个实例（-ParentPid $PID，脚本退出它就是孤儿会自己收）。

  用法：pwsh -NoProfile -File eztogo/scripts/caption-check.ps1
#>
param(
  [int]$X = 780,
  [int]$Y = 520,
  [string]$OutDir = "$env:TEMP\cu-caption-check"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$overlay = Join-Path (Split-Path -Parent $PSScriptRoot) 'desktop\overlay\codex-cursor.ps1'
if (-not (Test-Path $overlay)) { throw "找不到叠加层脚本：$overlay" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cmdFile = Join-Path $OutDir 'cmd.json'
$lastSeq = 0

function Send-Cmd([hashtable]$payload) {
  $script:lastSeq++
  $payload['seq'] = $script:lastSeq
  $json = $payload | ConvertTo-Json -Compress
  $enc = New-Object System.Text.UTF8Encoding($false)
  # 叠加层每 16ms 读一次命令文件：偶发占用就重试，别把测试判成"没反应"
  for ($i = 0; $i -lt 20; $i++) {
    try {
      [System.IO.File]::WriteAllText($cmdFile, $json, $enc)
      return
    } catch {
      Start-Sleep -Milliseconds 25
    }
  }
  throw "写命令文件失败：$cmdFile"
}

function Shot([string]$path, [int]$left, [int]$top, [int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  return $bmp
}

# 注意：不能叫 Diff —— 「diff」是 Compare-Object 的内置别名，别名优先于函数，函数永远不会被调用
function Measure-ChangedPixels {
  param([System.Drawing.Bitmap]$A, [System.Drawing.Bitmap]$B)
  $changed = 0
  for ($yy = 0; $yy -lt $A.Height; $yy += 2) {
    for ($xx = 0; $xx -lt $A.Width; $xx += 2) {
      $pa = $A.GetPixel($xx, $yy); $pb = $B.GetPixel($xx, $yy)
      if ([Math]::Abs($pa.R - $pb.R) -gt 12 -or [Math]::Abs($pa.G - $pb.G) -gt 12 -or [Math]::Abs($pa.B - $pb.B) -gt 12) { $changed++ }
    }
  }
  return [int]$changed
}

Send-Cmd @{ op = 'hide' }
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $overlay,
  '-CommandFile', $cmdFile, '-ParentPid', "$PID", '-IdleTimeoutMs', '120000'
)

$ready = Join-Path $OutDir 'cmd.json.ready'
$waited = 0
while (-not (Test-Path $ready) -and $waited -lt 20000) { Start-Sleep -Milliseconds 200; $waited += 200 }
if (-not (Test-Path $ready)) { try { $proc.Kill() } catch {}; throw '叠加层没有在 20s 内 ready' }

# 说明框贴着指针右下角：从指针位置往右下截够大的一块（含 1.5 倍 DPI 的余量）
$left = $X - 20; $top = $Y - 20; $w = 520; $h = 150

Send-Cmd @{ op = 'start'; state = 'controlling'; value = 'compute use · 记事本' }
Send-Cmd @{ op = 'point'; x = $X; y = $Y; app = '记事本'; caption = '点击「保存」' }
Start-Sleep -Milliseconds 900
$shotA = Shot (Join-Path $OutDir 'a-click.png') $left $top $w $h

Send-Cmd @{ op = 'caption'; caption = '读取「记事本」界面' }
Start-Sleep -Milliseconds 500
$shotB = Shot (Join-Path $OutDir 'b-read.png') $left $top $w $h

Send-Cmd @{ op = 'act'; x = ($X - 160); y = ($Y + 40); w = 120; h = 32; app = '记事本'; caption = '输入 12 个字' }
Start-Sleep -Milliseconds 700
$shotC = Shot (Join-Path $OutDir 'c-type.png') ($X - 220) ($Y + 10) $w $h

$diffAB = Measure-ChangedPixels -A $shotA -B $shotB
$diffBC = Measure-ChangedPixels -A $shotB -B $shotC
$shotA.Dispose(); $shotB.Dispose(); $shotC.Dispose()

Send-Cmd @{ op = 'quit' }
try { $proc.WaitForExit(3000) | Out-Null } catch {}
try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}

[ordered]@{
  ok = ($diffAB -gt 150 -and $diffBC -gt 150)
  diffCaptionChange = $diffAB
  diffSecondAction = $diffBC
  shots = @(
    (Join-Path $OutDir 'a-click.png'),
    (Join-Path $OutDir 'b-read.png'),
    (Join-Path $OutDir 'c-type.png')
  )
} | ConvertTo-Json -Compress
