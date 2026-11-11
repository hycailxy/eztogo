param(
  [int]$X = 0,
  [int]$Y = 0,
  [int]$Radius = 18
)

# 采样屏幕上一个点周围的像素，用来判断"代理光标是不是画在那里"。
# 只做 CopyFromScreen，不改任何东西。

Add-Type -AssemblyName System.Drawing

$size = $Radius * 2
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X - $Radius, $Y - $Radius, 0, 0, $bmp.Size)
$g.Dispose()

$maxBlue = 0
$minRed = 255
$blueHits = 0
for ($yy = 0; $yy -lt $size; $yy++) {
  for ($xx = 0; $xx -lt $size; $xx++) {
    $p = $bmp.GetPixel($xx, $yy)
    if ($p.B -gt $maxBlue) { $maxBlue = $p.B }
    if ($p.R -lt $minRed) { $minRed = $p.R }
    if ($p.B -gt 200 -and $p.R -lt 90 -and $p.G -gt 110 -and $p.G -lt 200) { $blueHits++ }
  }
}
$bmp.Dispose()

$result = New-Object 'System.Collections.Hashtable'
$result['x'] = $X
$result['y'] = $Y
$result['maxBlue'] = $maxBlue
$result['minRed'] = $minRed
$result['blueHits'] = $blueHits
$result['samples'] = $size * $size
$result | ConvertTo-Json -Compress
