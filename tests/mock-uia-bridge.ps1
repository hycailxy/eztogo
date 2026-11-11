# 假的桌面桥：只回固定结构，用来验证 server 层传给叠加层的"实时说明"文案，
# 不碰真实窗口、不产生任何桌面副作用。
param(
  [string]$Action = 'list_windows',
  [string]$ArgsBase64 = ''
)

# 和真实桥一致：stdout 必须是 UTF-8，否则中文元素名会被 Node 按 UTF-8 解成乱码
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$argsObj = @{}
if ($ArgsBase64) {
  $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ArgsBase64))
  if ($text.Trim()) {
    $parsed = $text | ConvertFrom-Json
    foreach ($p in $parsed.PSObject.Properties) { $argsObj[$p.Name] = $p.Value }
  }
}

$window = @{ handle = 1; pid = 4242; name = 'MockApp' }
$nodes = @(
  @{ path = '0'; name = 'MockApp'; controlType = 'ControlType.Window'; rect = @{ x = 100; y = 100; width = 800; height = 600 }; patterns = @{}; enabled = $true },
  @{ path = '0-1'; name = '正文编辑区'; controlType = 'ControlType.Document'; rect = @{ x = 300; y = 300; width = 400; height = 200 }; patterns = @{ valueSettable = $true }; enabled = $true },
  @{ path = '0-2'; name = '保存'; controlType = 'ControlType.Button'; rect = @{ x = 700; y = 320; width = 60; height = 28 }; patterns = @{ invokable = $true }; enabled = $true }
)

switch ($Action) {
  'list_windows' { $data = @{ windows = @(@{ name = 'MockApp'; processName = 'mockapp'; pid = 4242; handle = 1; className = 'Notepad' }) } }
  'tree' { $data = @{ window = $window; nodes = $nodes; truncated = $false } }
  'screenshot' {
    $path = [string]$argsObj['path']
    if ($path) {
      # 1x1 的合法 JPEG，够 captureImage 读字节用
      $bytes = [System.Convert]::FromBase64String('/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AmwA/9k=')
      try { [System.IO.File]::WriteAllBytes($path, $bytes) } catch { }
    }
    $data = @{ path = $path }
  }
  default { $data = @{ performed = 'Press'; focused = $null; action = $Action } }
}

@{ ok = $true; data = $data } | ConvertTo-Json -Depth 8 -Compress
