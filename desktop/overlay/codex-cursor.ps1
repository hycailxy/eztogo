param(
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [int]$IdleTimeoutMs = 20000,
  [int]$ParentPid = 0,
[int]$GlideMs = 220,
[int]$RippleMs = 420,
[int]$FrameHoldMs = 1400,
  [switch]$ReducedMotion
)

# Codex 的功能 + ego lite 的观感。
#   - 全屏点击穿透窗口：光标环、高亮框、涟漪
#   - 底部状态胶囊（照 ego 的样式：暂停条 + 星芒 + 两行字 + 接管/终止任务）
#   - UIA 给物理像素，WPF 画布是 DIP：所有输入坐标都要除以 DPI 缩放
#
# 命令（JSON 文件，seq 递增）：point / click / frame / act / drag / hide / quit

# 这个进程必须先声明 per-monitor DPI 感知，否则 WPF 报的虚拟屏尺寸与物理像素不一致，
# 胶囊会被算到屏幕外（本机踩过：1296 vs 1080）。声明之后所有坐标都是物理像素。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CuDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Enable() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
    try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
    try { SetProcessDPIAware(); } catch { }
  }
}
'@

try { [CuDpi]::Enable() } catch { }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CuScreen {
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  public static int X { get { return GetSystemMetrics(76); } }
  public static int Y { get { return GetSystemMetrics(77); } }
  public static int W { get { return GetSystemMetrics(78); } }
  public static int H { get { return GetSystemMetrics(79); } }
}
'@

$virtual = New-Object System.Windows.Rect([double][CuScreen]::X, [double][CuScreen]::Y, [double][CuScreen]::W, [double][CuScreen]::H)

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        Left="$($virtual.X)" Top="$($virtual.Y)"
        Width="$($virtual.Width)" Height="$($virtual.Height)"
        IsHitTestVisible="False" Focusable="False">
  <Canvas x:Name="Root" Background="Transparent" IsHitTestVisible="False">
    <Canvas x:Name="Ambient" IsHitTestVisible="False" Visibility="Collapsed">
      <Rectangle x:Name="DotDark" IsHitTestVisible="False" Opacity="0.85" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="0,0,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#4DFFFFFF"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="DotLight" IsHitTestVisible="False" Opacity="0.85" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="0,0,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#3D000000"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="DotWaveD1" IsHitTestVisible="False" Opacity="0" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="5,5,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#8CFFFFFF"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="DotWaveD2" IsHitTestVisible="False" Opacity="0" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="0,0,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#66FFFFFF"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="DotWaveL1" IsHitTestVisible="False" Opacity="0" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="5,5,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#8C000000"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="DotWaveL2" IsHitTestVisible="False" Opacity="0" Visibility="Collapsed">
        <Rectangle.Fill><DrawingBrush TileMode="Tile" Viewport="0,0,10,10" ViewportUnits="Absolute" Stretch="None">
          <DrawingBrush.Drawing><GeometryDrawing Brush="#8C000000"><GeometryDrawing.Geometry><EllipseGeometry Center="5,5" RadiusX="1.8" RadiusY="1.8"/></GeometryDrawing.Geometry></GeometryDrawing></DrawingBrush.Drawing>
        </DrawingBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="EdgeLeft" IsHitTestVisible="False">
        <Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#D94A8EE8" Offset="0.0"/><GradientStop Color="#804A8EE8" Offset="0.35"/><GradientStop Color="#004A8EE8" Offset="1.0"/>
        </LinearGradientBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="EdgeRight" IsHitTestVisible="False">
        <Rectangle.Fill><LinearGradientBrush StartPoint="1,0" EndPoint="0,0">
          <GradientStop Color="#D94A8EE8" Offset="0.0"/><GradientStop Color="#804A8EE8" Offset="0.35"/><GradientStop Color="#004A8EE8" Offset="1.0"/>
        </LinearGradientBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="EdgeTop" IsHitTestVisible="False">
        <Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#B34A8EE8" Offset="0.0"/><GradientStop Color="#664A8EE8" Offset="0.35"/><GradientStop Color="#004A8EE8" Offset="1.0"/>
        </LinearGradientBrush></Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="EdgeBottom" IsHitTestVisible="False">
        <Rectangle.Fill><LinearGradientBrush StartPoint="0,1" EndPoint="0,0">
          <GradientStop Color="#B34A8EE8" Offset="0.0"/><GradientStop Color="#664A8EE8" Offset="0.35"/><GradientStop Color="#004A8EE8" Offset="1.0"/>
        </LinearGradientBrush></Rectangle.Fill>
      </Rectangle>
      <Ellipse x:Name="Ring0" Width="520" Height="520" Stroke="#59A9D2FF" StrokeThickness="56" Fill="Transparent" IsHitTestVisible="False" Visibility="Collapsed">
        <Ellipse.RenderTransform><ScaleTransform x:Name="RingScale0" CenterX="260" CenterY="260" ScaleX="0.1" ScaleY="0.1"/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Ring1" Width="520" Height="520" Stroke="#59A9D2FF" StrokeThickness="56" Fill="Transparent" IsHitTestVisible="False" Visibility="Collapsed">
        <Ellipse.RenderTransform><ScaleTransform x:Name="RingScale1" CenterX="260" CenterY="260" ScaleX="0.1" ScaleY="0.1"/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Ring2" Width="520" Height="520" Stroke="#59A9D2FF" StrokeThickness="56" Fill="Transparent" IsHitTestVisible="False" Visibility="Collapsed">
        <Ellipse.RenderTransform><ScaleTransform x:Name="RingScale2" CenterX="260" CenterY="260" ScaleX="0.1" ScaleY="0.1"/></Ellipse.RenderTransform>
      </Ellipse>
      <Canvas x:Name="ParticleLayer" IsHitTestVisible="False"/>
    </Canvas>
    <Canvas x:Name="Highlight" Visibility="Collapsed" IsHitTestVisible="False">
      <Border x:Name="GlowOuter" CornerRadius="10" BorderThickness="6" BorderBrush="#14FFFFFF"/>
      <Border x:Name="FrameShadow" CornerRadius="10" BorderThickness="3.4" BorderBrush="#59000000"/>
      <Border x:Name="GlowMid" CornerRadius="10" BorderThickness="3" BorderBrush="#2EFFFFFF"/>
      <Border x:Name="FrameEdge" CornerRadius="10" BorderThickness="1.6" BorderBrush="#F2FFFFFF"/>
    </Canvas>
    <Canvas x:Name="CursorLayer" IsHitTestVisible="False" Width="0" Height="0">
      <Canvas.RenderTransform>
        <TranslateTransform x:Name="CursorTranslate" X="-2000" Y="-2000"/>
      </Canvas.RenderTransform>
      <!-- 光标：ego lite 的指针样式（深色箭头 + 白描边，浅/深底都看得见），尖端对准目标点 -->
      <Path x:Name="CursorArrow" IsHitTestVisible="False" Stroke="#FFFFFFFF" StrokeThickness="1.2"
            StrokeLineJoin="Round" Fill="#FF232E33"
            Data="M0,0 L0,15 L4.6,11.6 L6.8,17.4 L9.2,16.6 L7.2,10.8 L14,10.6 Z"/>
      <Ellipse x:Name="RingShadow" Width="27" Height="27" Stroke="#00000000" StrokeThickness="0" Fill="Transparent" IsHitTestVisible="False"/>
      <Ellipse x:Name="Ring" Width="26" Height="26" Stroke="#00000000" StrokeThickness="0" Fill="Transparent" IsHitTestVisible="False"/>
      <Ellipse x:Name="Core" Width="1" Height="1" Fill="#00000000" IsHitTestVisible="False"/>
      <Border x:Name="CursorLabel" Opacity="0" IsHitTestVisible="False" Background="#E62E3134"
              CornerRadius="12" Padding="14,8" Canvas.Left="14" Canvas.Top="11">
        <TextBlock x:Name="CursorLabelText" Text="正在浏览网页" Foreground="#F5F6F7" FontSize="11.5"/>
      </Border>
    </Canvas>
    <Canvas x:Name="RippleLayer" IsHitTestVisible="False">
      <Ellipse x:Name="RippleSh" Width="20" Height="20" Opacity="0" Stroke="#59000000" StrokeThickness="3.2" RenderTransformOrigin="0.5,0.5">
        <Ellipse.RenderTransform><ScaleTransform x:Name="RippleShScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Ripple" Width="20" Height="20" Opacity="0" Stroke="#CC4A8EE8" StrokeThickness="2" RenderTransformOrigin="0.5,0.5">
        <Ellipse.RenderTransform>
          <ScaleTransform x:Name="RippleScale" ScaleX="1" ScaleY="1"/>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Ripple2Sh" Width="20" Height="20" Opacity="0" Stroke="#40000000" StrokeThickness="3" RenderTransformOrigin="0.5,0.5">
        <Ellipse.RenderTransform><ScaleTransform x:Name="Ripple2ShScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="Ripple2" Width="20" Height="20" Opacity="0" Stroke="#99FFFFFF" StrokeThickness="1.4" RenderTransformOrigin="0.5,0.5">
        <Ellipse.RenderTransform>
          <ScaleTransform x:Name="Ripple2Scale" ScaleX="1" ScaleY="1"/>
        </Ellipse.RenderTransform>
      </Ellipse>
    </Canvas>
  </Canvas>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
# 关键：WPF 用 DIP，而屏幕尺寸是物理像素。窗口必须设成 物理/缩放 的 DIP 尺寸，
# 否则窗口比屏幕大，右边/下边的元素会落到屏幕外（之前右侧没有边缘光就是这个原因）。
$winScale = 1.0
try {
  $dpiInfo = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
  if ($dpiInfo.DpiScaleX -gt 0) { $winScale = $dpiInfo.DpiScaleX }
} catch { }
if ($winScale -le 0) { $winScale = 1.0 }
$window.Width = $virtual.Width / $winScale
$window.Height = $virtual.Height / $winScale

# ---- 独立胶囊窗口：不再放进全屏 Canvas。SizeToContent 让 WPF 自己算尺寸，
#      位置用 SystemParameters.WorkArea（同样是 DIP），绕开 Canvas 与窗口尺寸打架的问题。----
[xml]$pillXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" WindowStartupLocation="Manual">
  <Grid x:Name="PillRoot" Background="Transparent">
    <Border x:Name="StatusPill" CornerRadius="30" Background="#E6101824" BorderBrush="#5CFFFFFF"
            BorderThickness="1" Padding="20,14">
      <Border.Effect>
        <DropShadowEffect x:Name="StatusGlow" Color="#FFFFFF" BlurRadius="16" ShadowDepth="0" Opacity="0.45"/>
      </Border.Effect>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0">
          <Rectangle Width="2.5" Height="14" Fill="#C9D2E0" RadiusX="1" RadiusY="1" Margin="0,0,3,0"/>
          <Rectangle Width="2.5" Height="14" Fill="#C9D2E0" RadiusX="1" RadiusY="1"/>
        </StackPanel>
        <Canvas Width="20" Height="20" VerticalAlignment="Center" Margin="0,0,11,0">
          <Canvas.RenderTransform>
            <ScaleTransform x:Name="StatusSparkleScale" ScaleX="1" ScaleY="1" CenterX="10" CenterY="10"/>
          </Canvas.RenderTransform>
          <Path Stroke="#D9E2EC" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M14,10 L17,10 M12.8,12.8 L14.9,14.9 M10,14 L10,17 M7.2,12.8 L5.1,14.9 M6,10 L3,10 M7.2,7.2 L5.1,5.1 M10,6 L10,3 M12.8,7.2 L14.9,5.1"/>
          <Path Fill="#F2F5FF" Data="M8.6,7.4 L15.2,10.1 L11.9,11.3 L10.7,14.6 Z"/>
        </Canvas>
        <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="StatusTitle" Text="Agent 任务" Foreground="#E2E3E4" FontSize="13.5" FontWeight="SemiBold"/>
          <TextBlock x:Name="StatusSub" Text="Agent 正在控制" Foreground="#4A8EE8" FontSize="12.5" FontWeight="SemiBold" Margin="0,2,0,0"/>
        </StackPanel>
        <Border x:Name="TakeoverButton" CornerRadius="16" Padding="14,7" Margin="0,0,8,0" VerticalAlignment="Center" Cursor="Hand">
          <Border.Style>
            <Style TargetType="Border">
              <Setter Property="Background" Value="#1FFFFFFF"/>
              <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter Property="Background" Value="#38FFFFFF"/>
                </Trigger>
              </Style.Triggers>
            </Style>
          </Border.Style>
          <TextBlock x:Name="TakeoverLabel" Text="接管" Foreground="#E2E3E4" FontSize="12.5"/>
        </Border>
        <Border x:Name="AbortButton" CornerRadius="16" Padding="14,7" VerticalAlignment="Center" Cursor="Hand">
          <Border.Style>
            <Style TargetType="Border">
              <Setter Property="Background" Value="#1FFFFFFF"/>
              <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter Property="Background" Value="#38FFFFFF"/>
                </Trigger>
              </Style.Triggers>
            </Style>
          </Border.Style>
          <TextBlock x:Name="AbortLabel" Text="终止" Foreground="#E67062" FontSize="12.5"/>
        </Border>
      </StackPanel>
    </Border>
    <!-- 收起态：小太阳（可拖动）。点击展开回原位。 -->
    <Canvas x:Name="MiniSun" Width="56" Height="56" Visibility="Collapsed" Cursor="SizeAll" Background="Transparent">
      <Ellipse Width="46" Height="46" Canvas.Left="5" Canvas.Top="5" Stroke="#66FFFFFF" StrokeThickness="1.2">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#C8101824" Offset="0.0"/>
            <GradientStop Color="#8C101824" Offset="0.72"/>
            <GradientStop Color="#00101824" Offset="1.0"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.Effect>
          <DropShadowEffect Color="#FFFFFF" BlurRadius="14" ShadowDepth="0" Opacity="0.35"/>
        </Ellipse.Effect>
      </Ellipse>
      <Canvas Width="28" Height="28" Canvas.Left="14" Canvas.Top="14" RenderTransformOrigin="0.5,0.5">
        <Canvas.RenderTransform>
          <RotateTransform x:Name="MiniSunSpin" Angle="0" CenterX="14" CenterY="14"/>
        </Canvas.RenderTransform>
        <Path Stroke="#D9E2EC" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Data="M19,14 L23,14 M17.5,17.5 L20.3,20.3 M14,19 L14,23 M10.5,17.5 L7.7,20.3 M9,14 L5,14 M10.5,10.5 L7.7,7.7 M14,9 L14,5 M17.5,10.5 L20.3,7.7"/>
        <Path Fill="#F2F5FF" Data="M12,10.4 L21.2,14.1 L16.6,15.8 L15,20.4 Z"/>
      </Canvas>
    </Canvas>
  </Grid>
</Window>
"@
$pillReader = New-Object System.Xml.XmlNodeReader $pillXaml
$pillWin = [Windows.Markup.XamlReader]::Load($pillReader)
$pillWin.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
$statusPill = $pillWin.FindName("StatusPill")
$pillRoot = $pillWin.FindName("PillRoot")
$miniSun = $pillWin.FindName("MiniSun")
$miniSunSpin = $pillWin.FindName("MiniSunSpin")
$statusTitle = $pillWin.FindName("StatusTitle")
$statusSub = $pillWin.FindName("StatusSub")
$statusSparkleScale = $pillWin.FindName("StatusSparkleScale")
$statusGlow = $pillWin.FindName("StatusGlow")
$takeoverButton = $pillWin.FindName("TakeoverButton")
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeGlass {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@

$takeoverLabel = $pillWin.FindName("TakeoverLabel")
$abortButton = $pillWin.FindName("AbortButton")

# ---- "强制结束"确认弹窗：同风格，独立小窗口，居中显示 ----
[xml]$confirmXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" WindowStartupLocation="Manual">
  <!-- 外面留 26px：投影需要空间，否则会被窗口边界裁出硬矩形边（之前看到的"矩形边框残留"） -->
  <Grid Margin="26">
    <Border x:Name="ConfirmCard" CornerRadius="18" Background="#F2101824" BorderBrush="#5CFFFFFF" BorderThickness="1" Padding="22,18">
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="26" ShadowDepth="0" Opacity="0.55"/>
      </Border.Effect>
      <StackPanel Width="300">
        <TextBlock Text="强制结束本次 compute use？" Foreground="#E2E3E4" FontSize="14" FontWeight="SemiBold"/>
        <TextBlock Text="正在执行的动作会立即中断，已产生的操作不会回滚。" Foreground="#8B93A1" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
          <Border x:Name="ConfirmCancel" CornerRadius="15" Padding="16,8" Margin="0,0,10,0" Cursor="Hand" Background="#1FFFFFFF">
            <TextBlock Text="取消" Foreground="#E2E3E4" FontSize="12.5"/>
          </Border>
          <Border x:Name="ConfirmOk" CornerRadius="15" Padding="16,8" Cursor="Hand" Background="#33E67062">
            <TextBlock Text="强制结束" Foreground="#FFD9D3" FontSize="12.5"/>
          </Border>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
$confirmReader = New-Object System.Xml.XmlNodeReader $confirmXaml
$confirmWin = [Windows.Markup.XamlReader]::Load($confirmReader)
$confirmWin.SizeToContent = [System.Windows.SizeToContent]::Manual
$confirmCard = $confirmWin.FindName("ConfirmCard")
$confirmCancel = $confirmWin.FindName("ConfirmCancel")
$confirmOk = $confirmWin.FindName("ConfirmOk")
$brushBlue  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#4A8EE8")
$brushWhite = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E2E3E4")
$brushGrey  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8B93A1")


$phys = [System.Windows.Forms.SystemInformation]::VirtualScreen
$script:physW = [double]$phys.Width
$script:physH = [double]$phys.Height

$highlight = $window.FindName("Highlight")
$glowOuter = $window.FindName("GlowOuter")
$frameShadow = $window.FindName("FrameShadow")
$ringShadow = $window.FindName("RingShadow")
$glowMid = $window.FindName("GlowMid")
$frameEdge = $window.FindName("FrameEdge")
$cursorLayer = $window.FindName("CursorLayer")
$cursorTranslate = $window.FindName("CursorTranslate")
$ring = $window.FindName("Ring")
$cursorArrow = $window.FindName("CursorArrow")
$core = $window.FindName("Core")
$cursorLabel = $window.FindName("CursorLabel")
$cursorLabelText = $window.FindName("CursorLabelText")
$ripple = $window.FindName("Ripple")
$rippleScale = $window.FindName("RippleScale")
$ripple2 = $window.FindName("Ripple2")
$ripple2Scale = $window.FindName("Ripple2Scale")
$rippleSh = $window.FindName("RippleSh")
$rippleShScale = $window.FindName("RippleShScale")
$ripple2Sh = $window.FindName("Ripple2Sh")
$ripple2ShScale = $window.FindName("Ripple2ShScale")
$ambient = $window.FindName("Ambient")
$dotDark = $window.FindName("DotDark")
$dotLight = $window.FindName("DotLight")
$dotWaveD1 = $window.FindName("DotWaveD1")
$dotWaveD2 = $window.FindName("DotWaveD2")
$dotWaveL1 = $window.FindName("DotWaveL1")
$dotWaveL2 = $window.FindName("DotWaveL2")
$edgeLeft = $window.FindName("EdgeLeft")
$edgeRight = $window.FindName("EdgeRight")
$edgeTop = $window.FindName("EdgeTop")
$edgeBottom = $window.FindName("EdgeBottom")
$waveRings = $window.FindName("WaveRings")
$Ring0 = $window.FindName("Ring0")
$Ring1 = $window.FindName("Ring1")
$Ring2 = $window.FindName("Ring2")
$RingScale0 = $window.FindName("RingScale0")
$RingScale1 = $window.FindName("RingScale1")
$RingScale2 = $window.FindName("RingScale2")
$particleLayer = $window.FindName("ParticleLayer")

function Center([System.Windows.FrameworkElement]$el, [double]$size) {
  [System.Windows.Controls.Canvas]::SetLeft($el, -$size / 2)
  [System.Windows.Controls.Canvas]::SetTop($el, -$size / 2)
}
Center $ring 26; Center $core 6; Center $ripple 20; Center $ringShadow 27; Center $ripple2 20; Center $rippleSh 20; Center $ripple2Sh 20

function To-DipX([double]$px) { return ($px - $virtual.X) / $winScale }
function To-DipY([double]$py) { return ($py - $virtual.Y) / $winScale }

$EaseOut = New-Object System.Windows.Media.Animation.CubicEase
$EaseOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

# 文案直接取自 ego 的 Locales/zh-CN.pak（偏移 133444 附近），不自己编：
#   Agent 任务 / Agent 正在控制 / 你正在控制 / 正在浏览网页 / 接管 / 交还给 Agent / 终止任务
$script:stateText = @{
  controlling = "Agent 正在控制"
  browsing    = "正在浏览网页"
  human       = "你正在控制"
  paused      = "已暂停"
  completed   = "任务已完成"
  failed      = "任务失败"
}
$script:hasCursor = $false
$script:holdVisible = $false
$script:pillInitialized = $false
# 光标旁那行字的内容（实时说明）——下面的 $script:liveCaption 见 Set-CursorCaption
# 是否已经开过场（start 或任一动作）。冷启动期间为 false，用来压掉"刚起就闪胶囊"
$script:sessionOpened = $false
# 光标旁的实时说明（"点击「保存」"这种）；空表示回到状态文案
$script:liveCaption = ""
# 当前状态文案，实时说明清空时按它回落
$script:currentStateText = "Agent 正在控制"
$script:pillCollapsed = $false
$script:humanTakeover = $false
$script:taskEnded = $false
$script:abortClicks = 0
$script:abortTimer = $null
$script:abortPaused = $false
$script:pillAnchorX = 0
$script:pillAnchorY = 0
$script:pillW = 0
$script:pillH = 0
$script:ambientForcedOff = $false
$script:wasHold = $false
$script:drawCount = 0
$script:paused = $false

function Write-Control([string]$action) {
  try {
    [System.IO.File]::WriteAllText("$CommandFile.control", $action, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Update-DotMode {
  # 底纹已移除，什么都不做
}

function Update-AmbientLayout {
  # 用实际渲染尺寸（DIP）。尺寸没变就直接返回，避免每帧重排。
  $w = if ($window.ActualWidth -gt 1) { [double]$window.ActualWidth } else { [double]$window.Width }
  $h = if ($window.ActualHeight -gt 1) { [double]$window.ActualHeight } else { [double]$window.Height }
  if ($script:ambientW -eq $w -and $script:ambientH -eq $h) { Update-DotMode; return }
  $script:ambientW = $w; $script:ambientH = $h
  $edgeH = 150.0
  $edgeV = 60.0
  [System.Windows.Controls.Canvas]::SetLeft($edgeLeft, 0); [System.Windows.Controls.Canvas]::SetTop($edgeLeft, 0)
  $edgeLeft.Width = $edgeH; $edgeLeft.Height = $h
  [System.Windows.Controls.Canvas]::SetLeft($edgeRight, [Math]::Max(0, $w - $edgeH)); [System.Windows.Controls.Canvas]::SetTop($edgeRight, 0)
  $edgeRight.Width = $edgeH; $edgeRight.Height = $h
  [System.Windows.Controls.Canvas]::SetLeft($edgeTop, 0); [System.Windows.Controls.Canvas]::SetTop($edgeTop, 0)
  $edgeTop.Width = $w; $edgeTop.Height = $edgeV
  [System.Windows.Controls.Canvas]::SetLeft($edgeBottom, 0); [System.Windows.Controls.Canvas]::SetTop($edgeBottom, [Math]::Max(0, $h - $edgeV))
  $edgeBottom.Width = $w; $edgeBottom.Height = $edgeV
  foreach ($dt in @($dotDark, $dotLight, $dotWaveD1, $dotWaveD2, $dotWaveL1, $dotWaveL2)) {
    [System.Windows.Controls.Canvas]::SetLeft($dt, 0); [System.Windows.Controls.Canvas]::SetTop($dt, 0)
    $dt.Width = $w; $dt.Height = $h
  }
  Update-DotMode
}

function Update-RingCenter {
  # 波源 = 胶囊的实际中心（问胶囊窗口要矩形，再换算到本窗口 DIP）
  $cx = $script:ambientW / 2; $cy = $script:ambientH - 70
  try {
    if ($pillWin) {
      $hlp = New-Object System.Windows.Interop.WindowInteropHelper($pillWin)
      $rc = New-Object "NativeGlass+RECT"
      if ([NativeGlass]::GetWindowRect($hlp.Handle, [ref]$rc)) {
        $pt = $window.PointFromScreen((New-Object System.Windows.Point((($rc.Left + $rc.Right) / 2.0), (($rc.Top + $rc.Bottom) / 2.0))))
        $cx = $pt.X; $cy = $pt.Y
      }
    }
  } catch { }
  $script:pillCx = $cx; $script:pillCy = $cy
  foreach ($el in @($Ring0, $Ring1, $Ring2)) {
    [System.Windows.Controls.Canvas]::SetLeft($el, $cx - 260)
    [System.Windows.Controls.Canvas]::SetTop($el, $cy - 260)
  }
}

function Initialize-Ambient {
  Update-AmbientLayout
  Update-RingCenter
  if ($ReducedMotion) { return }

  # 边缘呼吸：实测 ego 边缘蓝光峰峰约 2.8s，谷底接近消失（Duration 1400 + AutoReverse）
  $gb = New-Object System.Windows.Media.Animation.DoubleAnimation
  $gb.From = 0.35; $gb.To = 1.0
  $gb.Duration = [TimeSpan]::FromMilliseconds(1400)
  $gb.AutoReverse = $true
  $gb.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $gs = New-Object System.Windows.Media.Animation.SineEase
  $gs.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
  $gb.EasingFunction = $gs
  foreach ($el in @($edgeLeft, $edgeRight, $edgeTop, $edgeBottom)) {
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $gb)
  }

  # 底纹已按用户要求移除，波动动画一并去掉（省 CPU）
}

function Show-Ambient {
  if ($script:ambientForcedOff) { return }
  try { Update-AmbientLayout; Update-RingCenter } catch { }
  if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) {
    $ambient.Visibility = [System.Windows.Visibility]::Visible
  }
}

function Hide-Ambient {
  if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { return }
  $ambient.Visibility = [System.Windows.Visibility]::Collapsed
}

function Get-GlassAlpha([int]$px, [int]$py) {
  # 采样屏幕亮度决定玻璃底的透明度：亮背景用更实的底、暗背景用更透的底
  try {
    $bmp = New-Object System.Drawing.Bitmap(4, 4)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($px, $py, 0, 0, (New-Object System.Drawing.Size 4, 4))
    $g.Dispose()
    $s = 0.0
    for ($y = 0; $y -lt 4; $y++) { for ($x = 0; $x -lt 4; $x++) { $c = $bmp.GetPixel($x, $y); $s += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B) } }
    $bmp.Dispose()
    $lum = $s / 16.0
    if ($lum -gt 150) { return 0xE0 }
    if ($lum -gt 70) { return 0xC8 }
    return 0xB0
  } catch { return 0xD8 }
}

function Apply-GlassTint {
  try {
    $p = [System.Windows.Forms.Cursor]::Position
    $a = Get-GlassAlpha $p.X $p.Y
    $statusPill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($a, 0x10, 0x18, 0x24))
  } catch { }
}

function Update-PillPlacement {
  # 窗口是 SizeToContent=WidthAndHeight：尺寸由 WPF 按内容算，这里只负责摆位置。
  # 之前手工设 Width/Height，文案一变长（"终止"→"交还给 Agent"）宽度就跟不上，右侧被裁。
  try {
    $pillWin.UpdateLayout()
    $pw = if ($pillWin.ActualWidth -gt 8) { [double]$pillWin.ActualWidth } else { 0.0 }
    $ph = if ($pillWin.ActualHeight -gt 8) { [double]$pillWin.ActualHeight } else { 0.0 }
    if ($pw -le 0) { return }
    if ($script:pillCollapsed) {
      $pillWin.Left = $script:pillAnchorX
      $pillWin.Top = $script:pillAnchorY
    } else {
      $wa = [System.Windows.SystemParameters]::WorkArea
      $pillWin.Left = $wa.Left + ($wa.Width - $pw) / 2
      $pillWin.Top  = $wa.Bottom - $ph - 40
    }
    $hlpP = New-Object System.Windows.Interop.WindowInteropHelper($pillWin)
    $rcP = New-Object "NativeGlass+RECT"
    if ([NativeGlass]::GetWindowRect($hlpP.Handle, [ref]$rcP)) {
      [System.IO.File]::WriteAllText("$CommandFile.rect", "$($rcP.Left),$($rcP.Top),$($rcP.Right-$rcP.Left),$($rcP.Bottom-$rcP.Top)")
    }
  } catch { try { Add-Content -Path "$CommandFile.err" -Value ("place: " + $_.Exception.Message) } catch { } }
}

function Set-PillCollapsed([bool]$collapsed) {
  # 不做 early-return：以这次调用为准，避免"标记与画面不同步"导致点不动
  $script:pillCollapsed = $collapsed
  if ($collapsed) {
    # 记住当前胶囊中心，小太阳就出现在那儿
    $script:pillAnchorX = [double]$pillWin.Left
    $script:pillAnchorY = [double]$pillWin.Top
    if ($script:pillAnchorX -eq 0 -and $script:pillAnchorY -eq 0) {
      $wa = [System.Windows.SystemParameters]::WorkArea
      $script:pillAnchorX = $wa.Left + ($wa.Width - 56) / 2
      $script:pillAnchorY = $wa.Bottom - 56 - 40
    }
    $statusPill.Visibility = [System.Windows.Visibility]::Collapsed
    $miniSun.Visibility = [System.Windows.Visibility]::Visible
  } else {
    $miniSun.Visibility = [System.Windows.Visibility]::Collapsed
    $statusPill.Visibility = [System.Windows.Visibility]::Visible
  }
  Update-PillPlacement
}

function Move-Cursor([double]$x, [double]$y, [bool]$animate) {
  $lx = To-DipX $x
  $ly = To-DipY $y
  if ($animate -and -not $ReducedMotion) {
    $ax = New-Object System.Windows.Media.Animation.DoubleAnimation
    $ax.To = $lx; $ax.Duration = [TimeSpan]::FromMilliseconds($GlideMs); $ax.EasingFunction = $EaseOut
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation
    $ay.To = $ly; $ay.Duration = [TimeSpan]::FromMilliseconds($GlideMs); $ay.EasingFunction = $EaseOut
    $cursorTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ax)
    $cursorTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
  } else {
    $cursorTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $cursorTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $cursorTranslate.X = $lx
    $cursorTranslate.Y = $ly
  }
}

# 光标旁的说明框贴着指针右下角；贴到屏幕右/下边就翻到另一侧，避免被截断
function Update-CursorLabelPlacement {
  if (-not $cursorLabel) { return }
  try {
    $w = [double]$cursorLabel.ActualWidth
    if ($w -le 0) { $w = [double]$cursorLabel.DesiredSize.Width }
    $h = [double]$cursorLabel.ActualHeight
    if ($h -le 0) { $h = [double]$cursorLabel.DesiredSize.Height }
    $cx = [double]$cursorTranslate.X
    $cy = [double]$cursorTranslate.Y
    $left = 14.0
    if ($script:winW -gt 0 -and ($cx + 14 + $w) -gt ($script:winW - 6)) { $left = -($w + 10) }
    $top = 11.0
    if ($script:winH -gt 0 -and ($cy + 11 + $h) -gt ($script:winH - 6)) { $top = -($h + 8) }
    if ([Math]::Abs(([double][System.Windows.Controls.Canvas]::GetLeft($cursorLabel)) - $left) -gt 0.5) {
      [System.Windows.Controls.Canvas]::SetLeft($cursorLabel, $left)
    }
    if ([Math]::Abs(([double][System.Windows.Controls.Canvas]::GetTop($cursorLabel)) - $top) -gt 0.5) {
      [System.Windows.Controls.Canvas]::SetTop($cursorLabel, $top)
    }
  } catch { }
}

# 写光标旁的实时说明；空字符串回落到当前状态文案（Agent 正在控制 / 你正在控制）
function Set-CursorCaption([string]$text) {
  if (-not $cursorLabelText) { return }
  if ([string]::IsNullOrWhiteSpace($text)) {
    $script:liveCaption = ""
    try { $cursorLabelText.Text = [string]$script:currentStateText } catch { }
  } else {
    $script:liveCaption = $text
    try { $cursorLabelText.Text = $text } catch { }
  }
  try {
    $cursorLabel.InvalidateMeasure()
    $cursorLabel.UpdateLayout()
  } catch { }
  Update-CursorLabelPlacement
}

function Show-ClickRipple([double]$x, [double]$y) {
  if ($ReducedMotion) { return }
  # Codex 的点击涟漪：单圈，0.35→3.6 倍，420ms，CubicEase 淡出（见 research/codex-cu/00-parity.md）
  [System.Windows.Controls.Canvas]::SetLeft($ripple, (To-DipX $x))
  [System.Windows.Controls.Canvas]::SetTop($ripple, (To-DipY $y))
  # 先摘掉上一轮的动画时钟：否则 Opacity/Scale 会被上次的 HoldEnd 钉住，新动画看起来"一帧就没"
  $ripple.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  $rippleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
  $rippleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
  $ripple.Opacity = 1
  $rippleScale.ScaleX = 0.35; $rippleScale.ScaleY = 0.35
  $scale = New-Object System.Windows.Media.Animation.DoubleAnimation
  $scale.From = 0.35; $scale.To = 3.6
  $scale.Duration = [TimeSpan]::FromMilliseconds($RippleMs)
  $cubic = New-Object System.Windows.Media.Animation.CubicEase
  $cubic.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  $scale.EasingFunction = $cubic
  $rippleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scale)
  $rippleScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scale)
  $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
  $fade.From = 1; $fade.To = 0
  $fade.Duration = [TimeSpan]::FromMilliseconds($RippleMs)
  $fade.EasingFunction = $cubic
  $ripple.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
  # 其余几层是上一版 ego 双圈的遗留，保持隐藏
  foreach ($el in @($ripple2, $rippleSh, $ripple2Sh)) { try { $el.Opacity = 0 } catch { } }
}

function Show-Highlight([double]$x, [double]$y, [double]$w, [double]$h, [int]$holdMs) {
  $left = To-DipX $x
  $top = To-DipY $y
  foreach ($b in @($frameShadow, $glowOuter, $glowMid, $frameEdge)) {
    [System.Windows.Controls.Canvas]::SetLeft($b, $left)
    [System.Windows.Controls.Canvas]::SetTop($b, $top)
    $b.Width = $w
    $b.Height = $h
  }
  $highlight.Visibility = [System.Windows.Visibility]::Visible
  $highlight.Opacity = 1
  $script:drawCount++
  if (-not $ReducedMotion) {
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 1; $fade.To = 0
    $fade.BeginTime = [TimeSpan]::FromMilliseconds($holdMs)
    $fade.Duration = [TimeSpan]::FromMilliseconds(280)
    $highlight.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
  }
}

function Show-Drag([double]$fx, [double]$fy, [double]$tx, [double]$ty) {
  $script:hasCursor = $true
  $cursorLayer.Visibility = [System.Windows.Visibility]::Visible
      try { $cursorLabel.Opacity = 1 } catch { }
  Move-Cursor $fx $fy $false
  Start-Sleep -Milliseconds 40
  Move-Cursor $tx $ty $true
  Show-ClickRipple $tx $ty
  $script:drawCount++
}

# ---- 收起/展开 + 拖动小太阳 ----
$script:miniDrag = $false
$script:miniMoved = $false
$script:miniStart = $null
$script:miniWinStart = $null

# 点胶囊（不是点按钮）→ 收成小太阳
$statusPill.Add_MouseLeftButtonDown({
  param($s, $e)
  if ($e.Handled) { return }
  # 点在"接管/终止任务"上时不要收起胶囊 —— 那两个按钮要执行自己的动作
  $src = $e.OriginalSource
  while ($src -and $src -ne $statusPill) {
    if ($src -eq $takeoverButton -or $src -eq $abortButton) { return }
    try { $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src) } catch { $src = $null }
  }
  $script:lastCommandAt = Get-Date
  $script:pillCollapsed = $false
  Set-PillCollapsed $true
  $e.Handled = $true
})

# 小太阳：按下记录起点；移动就拖窗口；松开时没移动过就展开归位
$miniSun.Add_MouseLeftButtonDown({
  param($s, $e)
  $script:miniDrag = $true
  $script:miniMoved = $false
  # 必须用屏幕坐标：用元素相对坐标的话，窗口跟着鼠标走会让相对位移恒为 0（原地不动）
  $script:miniStart = [System.Windows.Forms.Cursor]::Position
  $script:miniWinStart = @([double]$pillWin.Left, [double]$pillWin.Top)
  [void]$miniSun.CaptureMouse()
  $e.Handled = $true
})
$miniSun.Add_MouseMove({
  param($s, $e)
  if (-not $script:miniDrag) { return }
  $cur = [System.Windows.Forms.Cursor]::Position
  $dx = ($cur.X - $script:miniStart.X) / $winScale
  $dy = ($cur.Y - $script:miniStart.Y) / $winScale
  if (-not $script:miniMoved -and ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3)) { $script:miniMoved = $true }
  if ($script:miniMoved) {
    $script:pillAnchorX = $script:miniWinStart[0] + $dx
    $script:pillAnchorY = $script:miniWinStart[1] + $dy
    $pillWin.Left = $script:pillAnchorX
    $pillWin.Top = $script:pillAnchorY
  }
})
$miniSun.Add_MouseLeftButtonUp({
  param($s, $e)
  # 只有"在小太阳上按下过"才认这次抬起；否则会把胶囊收起时的那次抬起
  # 当成点击小太阳，立刻又展开（就是"缩一下马上弹回"的原因）。
  if (-not $script:miniDrag) { $e.Handled = $true; return }
  $moved = $script:miniMoved
  $script:miniDrag = $false
  [void]$miniSun.ReleaseMouseCapture()
  if (-not $moved) {
    $script:lastCommandAt = Get-Date
    $script:pillCollapsed = $true   # 先纠正标记
    Set-PillCollapsed $false
  } else {
    Update-PillPlacement
  }
  $e.Handled = $true
})

# ---- 接管 / 终止任务 ----
# 接管：把控制权交给用户，按钮变成"交还给 Agent"；再点一次还给 Agent。
$abortLabel = $pillWin.FindName("AbortLabel")
$confirmCancel.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$confirmCancel.Add_MouseLeftButtonUp({ param($s, $e) $script:lastCommandAt = Get-Date; $confirmWin.Hide(); $e.Handled = $true })
$confirmOk.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$confirmOk.Add_MouseLeftButtonUp({
  param($s, $e)
  $script:lastCommandAt = Get-Date
  Write-Control "abort"
  $confirmWin.Hide()
  Stop-ComputeUse
  $e.Handled = $true
})

$takeoverButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$takeoverButton.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$takeoverButton.Add_MouseLeftButtonUp({
  param($s, $e)
  $script:lastCommandAt = Get-Date
  if ($script:humanTakeover) {
    $script:humanTakeover = $false
    Write-Control "resume"
    $statusSub.Text = $script:stateText["controlling"]
    $statusSub.Foreground = $brushBlue
    $takeoverLabel.Text = "接管"
  } else {
    $script:humanTakeover = $true
    Write-Control "takeover"
    $statusSub.Text = $script:stateText["human"]
    $statusSub.Foreground = $brushWhite
    $takeoverLabel.Text = "交还给 Agent"
  }
  try { Update-PillPlacement; Update-RingCenter } catch { }
  $e.Handled = $true
})

# 终止/继续：单击 = 终止⇄继续 切换；双击 = 弹"强制结束"确认框
$abortButton.Add_MouseLeftButtonDown({
  param($s, $e)
  $e.Handled = $true
})
$abortButton.Add_MouseLeftButtonUp({
  param($s, $e)
  $script:lastCommandAt = Get-Date
  $script:abortClicks = [int]$script:abortClicks + 1
  if ($script:abortClicks -ge 2) {
    # 双击：撤掉待执行的单击动作，改弹确认框
    $script:abortClicks = 0
    if ($script:abortTimer) { $script:abortTimer.Stop() }
    Show-ForceEndConfirm
  } else {
    # 单等 260ms：这段时间内没有第二次点击才执行单击动作
    if ($script:abortTimer) { $script:abortTimer.Stop() }
    $script:abortTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:abortTimer.Interval = [TimeSpan]::FromMilliseconds(260)
    $script:abortTimer.Add_Tick({
      $script:abortTimer.Stop()
      $script:abortClicks = 0
      Invoke-AbortToggle
    })
    $script:abortTimer.Start()
  }
  $e.Handled = $true
})


function Invoke-AbortToggle {
  # 终止 ⇄ 继续
  if ($script:abortPaused) {
    $script:abortPaused = $false
    Write-Control "resume"
    $statusSub.Text = $script:stateText["controlling"]
    $statusSub.Foreground = $brushBlue
    $abortLabel.Text = "终止"
  } else {
    $script:abortPaused = $true
    Write-Control "abort"
    $statusSub.Text = $script:stateText["paused"]
    $statusSub.Foreground = $brushWhite
    $abortLabel.Text = "继续"
  }
  try { Update-PillPlacement; Update-RingCenter } catch { }
}

function Stop-ComputeUse {
  # 结束本次 compute use：胶囊淡出 + 边缘光淡出，然后整体收起来
  $script:taskEnded = $true
  $script:holdVisible = $false
  $script:sessionOpened = $false
  try {
    $script:abortTimer = $null
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 1.0; $fade.To = 0.0
    $fade.Duration = [TimeSpan]::FromMilliseconds(320)
    $sine = New-Object System.Windows.Media.Animation.SineEase
    $sine.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
    $fade.EasingFunction = $sine
    $statusPill.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $ambient.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $cursorLayer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $fade.add_Completed({
      try {
        $statusPill.Visibility = [System.Windows.Visibility]::Collapsed
        $ambient.Visibility = [System.Windows.Visibility]::Collapsed
    try { $cursorLabel.Opacity = 0 } catch { }
        $cursorLayer.Visibility = [System.Windows.Visibility]::Collapsed
        $highlight.Visibility = [System.Windows.Visibility]::Collapsed
        $statusPill.Opacity = 1.0
        $ambient.Opacity = 1.0
        $cursorLayer.Opacity = 1.0
      } catch { }
    })
  } catch { }
}

function Show-ForceEndConfirm {
  # 同风格确认弹窗：居中显示在胶囊上方
  try {
    $confirmCard.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $ds = $confirmCard.DesiredSize
    $cw = if ($ds.Width -gt 8) { $ds.Width } else { 344.0 }
    $ch = if ($ds.Height -gt 8) { $ds.Height } else { 170.0 }
    $confirmWin.Width = $cw + 52; $confirmWin.Height = $ch + 52   # 加上 Grid 的 26px 边距，投影才不被裁
    $wa = [System.Windows.SystemParameters]::WorkArea
    $confirmWin.Left = $wa.Left + ($wa.Width - $cw) / 2
    $confirmWin.Top  = $wa.Bottom - $ch - 150
    if (-not $confirmWin.IsVisible) { $confirmWin.Show() }
  } catch { try { Add-Content -Path "$CommandFile.err" -Value ("confirm: " + $_.Exception.Message) } catch { } }
}

function Initialize-StatusPill {
  # 胶囊是独立窗口：先按内容量尺寸、摆位，再挂呼吸动画
  Update-PillPlacement
  Apply-GlassTint
  if ($ReducedMotion) { return }
  $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
  $pulse.From = 0.90; $pulse.To = 1.0
  # ego 的呼吸是整个胶囊的不透明度在起伏（实测 72.8..97.3）；AutoReverse ⇒ 整周期 1.2s
  $pulse.Duration = [TimeSpan]::FromMilliseconds(600)
  $pulse.AutoReverse = $true
  $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sine = New-Object System.Windows.Media.Animation.SineEase
  $sine.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
  $pulse.EasingFunction = $sine
  $statusPill.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
  if ($statusGlow) {
    $glowPulse = New-Object System.Windows.Media.Animation.DoubleAnimation
    $glowPulse.From = 0.25; $glowPulse.To = 0.65
    $glowPulse.Duration = [TimeSpan]::FromMilliseconds(600)
    $glowPulse.AutoReverse = $true
    $glowPulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $glowPulse.EasingFunction = $sine
    $statusGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowPulse)
  }
  # 小太阳保持静止（用户明确不要它一直转）
}

function Show-StatusPill {
  if ($statusPill.Visibility -eq [System.Windows.Visibility]::Visible) { return }
  $statusPill.Visibility = [System.Windows.Visibility]::Visible   # 先可见，量尺寸才准
  try { Update-PillPlacement } catch { }
  try { Update-RingCenter } catch { }
}

function Hide-StatusPill {
  if ($statusPill.Visibility -ne [System.Windows.Visibility]::Visible) { return }
  $statusPill.Visibility = [System.Windows.Visibility]::Collapsed
}

$script:lastSeq = -1
$script:lastCommandAt = Get-Date
$script:quit = $false

function Invoke-OverlayCommand($cmd) {
  # 冷启动的叠加层只等命令、不画东西：只有真的开过场（start / 点 / 输入 / 滚动 / 拖拽）才允许显示胶囊
  $op = [string]$cmd.op
  if ($op -eq 'start' -or $op -eq 'point' -or $op -eq 'act' -or $op -eq 'frame' -or $op -eq 'drag') {
    $script:sessionOpened = $true
  }
  if ($cmd.state -and $script:stateText.ContainsKey([string]$cmd.state)) {
    $statusSub.Text = $script:stateText[[string]$cmd.state]
    # 状态变了就复位实时说明：正在做什么 → 谁在控制
    $script:liveCaption = ""
    $script:currentStateText = [string]$script:stateText[[string]$cmd.state]
    if ($cursorLabelText) { $cursorLabelText.Text = $script:currentStateText }
    try { Update-CursorLabelPlacement } catch { }
    Update-PillPlacement
    try { Update-RingCenter } catch { }
  }
  # 实时说明跟着动作一起来（同一帧生效，不会和动作抢同一次写入）
  if ($cmd.PSObject.Properties.Name -contains 'caption') {
    try { Set-CursorCaption ([string]$cmd.caption) } catch { }
  }
  switch ([string]$cmd.op) {
    'start' {
      $script:taskEnded = $false
      $script:holdVisible = $true
      if ($cmd.value) { try { $statusTitle.Text = [string]$cmd.value } catch { } }
      try { Show-StatusPill } catch { try { Add-Content -Path "$CommandFile.err" -Value ("start-pill: " + $_.Exception.Message) } catch { } }
      try { Show-Ambient } catch { try { Add-Content -Path "$CommandFile.err" -Value ("start-ambient: " + $_.Exception.Message) } catch { } }
    }
    'end' { try { Stop-ComputeUse } catch { } }
    'title' {
      try { $statusTitle.Text = [string]$cmd.value; Update-PillPlacement } catch { }
    }
    'hold' { $script:holdVisible = $true; try { Show-Ambient } catch { } }
    'release' { $script:holdVisible = $false }
    'ambient' {
      $script:ambientForcedOff = ([string]$cmd.value -eq 'off')
      if ($script:ambientForcedOff) { Hide-Ambient } else { Show-Ambient }
    }
    'probe' {
      # .cursor 必须保持纯 "x,y"（cu-motion-spec 直接 split(",") 取数），
      # 其它诊断写进 .diag2，别污染这两个数。
      try {
        [System.IO.File]::WriteAllText("$CommandFile.cursor", "$($cursorTranslate.X),$($cursorTranslate.Y)")
        $msg = "pill=$([Math]::Round($script:pillCx,0)),$([Math]::Round($script:pillCy,0)) amb=$([int]$ambient.Visibility) win=$([Math]::Round($script:ambientW,0))x$([Math]::Round($script:ambientH,0))"
        [System.IO.File]::WriteAllText("$CommandFile.diag2", $msg)
      } catch { }
    }
    'quit' { $script:quit = $true }
    'hide' {
      $script:hasCursor = $false
      $cursorLayer.Visibility = [System.Windows.Visibility]::Collapsed
      $highlight.Visibility = [System.Windows.Visibility]::Collapsed
      Hide-StatusPill
    }
    'point' {
        # 动作 op 自带"确保会话可见"：beginSession 的 start 与动作连写时会被单文件通道覆盖
        $script:holdVisible = $true
        try { Show-StatusPill } catch { }
        try { if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { Show-Ambient } } catch { }
      try { $cursorLabel.Opacity = 1 } catch { }
      $script:hasCursor = $true
      $cursorLayer.Visibility = [System.Windows.Visibility]::Visible
      try { $cursorLabel.Opacity = 1 } catch { }
      Move-Cursor ([double]$cmd.x) ([double]$cmd.y) $true
    }
    'click' { Show-ClickRipple ([double]$cmd.x) ([double]$cmd.y) }
    'frame' {
        # 动作 op 自带"确保会话可见"：beginSession 的 start 与动作连写时会被单文件通道覆盖
        $script:holdVisible = $true
        try { Show-StatusPill } catch { }
        try { if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { Show-Ambient } } catch { }
        # 打字/滚动的目标也不再画矩形框，只把光标移过去（用户要求去掉外框）
        $fx = ([double]$cmd.x) + ([double]$cmd.w) / 2
        $fy = ([double]$cmd.y) + ([double]$cmd.h) / 2
        $script:hasCursor = $true
        $cursorLayer.Visibility = [System.Windows.Visibility]::Visible
        try { $cursorLabel.Opacity = 1 } catch { }
        Move-Cursor $fx $fy $true
    }
    'act' {
        # 动作 op 自带"确保会话可见"：beginSession 的 start 与动作连写时会被单文件通道覆盖
        $script:holdVisible = $true
        try { Show-StatusPill } catch { }
        try { if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { Show-Ambient } } catch { }
      $x = [double]$cmd.x; $y = [double]$cmd.y; $w = [double]$cmd.w; $h = [double]$cmd.h
        # 点击不再画矩形外框（用户要求），只留光标滑行 + 涟漪
      $script:hasCursor = $true
      $cursorLayer.Visibility = [System.Windows.Visibility]::Visible
      try { $cursorLabel.Opacity = 1 } catch { }
      Move-Cursor ($x + $w / 2) ($y + $h / 2) $true
      Show-ClickRipple ($x + $w / 2) ($y + $h / 2)
    }
    'drag' {
        # 动作 op 自带"确保会话可见"：beginSession 的 start 与动作连写时会被单文件通道覆盖
        $script:holdVisible = $true
        try { Show-StatusPill } catch { }
        try { if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { Show-Ambient } } catch { }
        # 拖拽也不画矩形外框
      Show-Drag (([double]$cmd.x) + ([double]$cmd.w / 2)) (([double]$cmd.y) + ([double]$cmd.h / 2)) ([double]$cmd.toX) ([double]$cmd.toY)
    }
  }
}

$window.Show()
try { Initialize-Ambient } catch { try { Add-Content -Path "$CommandFile.err" -Value ("ambient: " + $_.Exception.Message) } catch { } }

# 预热：胶囊窗口第一次 Show() 会有 ~500ms 的合成渐入，肉眼就是"慢慢浮出来"。
# 先在屏幕外 Show 一次再藏起来，之后每次显示就是瞬时的（ego 实测 <=22ms）。
try {
  $pillWin.Left = -6000; $pillWin.Top = -6000
  $pillWin.Show()
  $pillWin.UpdateLayout()
  $script:pillInitialized = $true
  Initialize-StatusPill
  start-sleep -Milliseconds 60
  $statusPill.Visibility = [System.Windows.Visibility]::Collapsed
  Update-PillPlacement
} catch { try { Add-Content -Path "$CommandFile.err" -Value ("warm: " + $_.Exception.Message) } catch { } }
$window.UpdateLayout()
$script:winW = if ($window.ActualWidth -gt 0) { [double]$window.ActualWidth } else { [double]$window.Width }
$script:winH = if ($window.ActualHeight -gt 0) { [double]$window.ActualHeight } else { [double]$window.Height }
try { [System.IO.File]::WriteAllText("$CommandFile.ready", [string]$PID) } catch { }

$whileStart = Get-Date
while (-not $script:quit) {
  $now = Get-Date
  if (Test-Path $CommandFile) {
    try {
      # 必须显式给 FileShare.ReadWrite：ReadAllText 只允许共享读，会把写入方（Node 的 writeFileSync）
      # 挡在门外，偶发的 EBUSY/EPERM 就是命令被吞、说明没刷新的来源。
      $fs = [System.IO.File]::Open($CommandFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
      $raw = $reader.ReadToEnd()
      $reader.Dispose()
      $fs.Dispose()
      $raw = $raw.TrimStart([char]0xFEFF)
      $cmd = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $cmd -and [int]$cmd.seq -gt $script:lastSeq) {
        $script:lastSeq = [int]$cmd.seq
        $script:lastCommandAt = $now
        Invoke-OverlayCommand $cmd
      }
    } catch { try { Add-Content -Path "$CommandFile.err" -Value ($_.Exception.Message) } catch { } }
  }

  if ($script:taskEnded) { } elseif ($script:holdVisible) {
    # 兜底：hold 期间每帧确保可见（单文件命令通道里 start 可能被 act 覆盖，导致胶囊不出现）
    if (-not $script:taskEnded) {
      if ($statusPill.Visibility -ne [System.Windows.Visibility]::Visible) { try { Show-StatusPill } catch { } }
      if ($ambient.Visibility -ne [System.Windows.Visibility]::Visible) { try { Show-Ambient } catch { } }
    }
    if (-not $script:pillCollapsed) { try { Show-StatusPill } catch { } }
    try { Show-Ambient } catch { }
  } else {
    try {
      # 没开过场就一律不显示：否则任何客户端一启动 MCP，屏幕上都会闪 2.5 秒胶囊
      if ($script:sessionOpened -and (($now - $script:lastCommandAt).TotalMilliseconds -lt 2500)) {
        if (-not $script:pillCollapsed) { Show-StatusPill }
      } else { Hide-StatusPill }
    } catch { try { Add-Content -Path "$CommandFile.err" -Value ("pill: " + $_.Exception.Message) } catch { } }
  }
  if ((($now - $script:lastCommandAt).TotalMilliseconds % 400) -lt 20) {
    try { [System.IO.File]::WriteAllText("$CommandFile.diag", "vis=$($statusPill.Visibility) left=$([System.Windows.Controls.Canvas]::GetLeft($statusPill)) top=$([System.Windows.Controls.Canvas]::GetTop($statusPill)) w=$($statusPill.ActualWidth) h=$($statusPill.ActualHeight) op=$($statusPill.Opacity)") } catch { }
  }

  if ($script:hasCursor -and (($now - $script:lastCommandAt).TotalMilliseconds -gt 1500)) {
    $script:hasCursor = $false
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 1; $fade.To = 0
    $fade.Duration = [TimeSpan]::FromMilliseconds(240)
    $cursorLayer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
  }
  if (-not $script:hasCursor -and $cursorLayer.Opacity -eq 0) {
    $cursorLayer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $cursorLayer.Opacity = 1
    $cursorLayer.Visibility = [System.Windows.Visibility]::Collapsed
  }

  # 光标位置变化就写出去：外部采样不用再发 probe（连发会互相覆盖掉真实命令）
  try {
    $cur = "$([Math]::Round($cursorTranslate.X,1)),$([Math]::Round($cursorTranslate.Y,1))"
    if ($cur -ne $script:lastCursorPub) {
      $script:lastCursorPub = $cur
      [System.IO.File]::WriteAllText("$CommandFile.cursor", $cur)
      # 滑行时说明框跟着指针走，贴边也要及时翻到另一侧
      if ($script:hasCursor) { try { Update-CursorLabelPlacement } catch { } }
    }
  } catch { }

  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{}) | Out-Null
  if (($now - $script:lastCommandAt).TotalMilliseconds -gt $IdleTimeoutMs) { break }
  if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 16
}

try { [System.IO.File]::WriteAllText("$CommandFile.drawn", [string]$script:drawCount) } catch { }
try { [System.IO.File]::Delete("$CommandFile.ready") } catch { }
$window.Close()

@{ ok = $true; mode = 'ego-cursor'; reducedMotion = [bool]$ReducedMotion; lastCommandSeq = $script:lastSeq; drawCount = $script:drawCount } | ConvertTo-Json -Compress
