<#
.SYNOPSIS
    Desktop UI for the AirPlayPC receiver.
.DESCRIPTION
    A small WPF front-end over the UxPlay engine: start/stop the receiver, pick
    quality and latency mode, see live status. No dependencies beyond Windows
    and UxPlay itself. Double-click "AirPlayPC.cmd" to launch without a console.

    Visual direction is deliberately tvOS: near-black, wide-spaced, one large
    focal status element you can read from across the room, and controls that
    recede until touched. Selection is a soft lifted thumb that slides, not a
    filled pill.

    The status language says only what can actually be observed. The poll
    timer reads the engine's TCP sockets (RTSP is one established connection,
    the mirror video data channel is a second) and the engine's own log lines,
    so the hero can honestly say Discoverable / iPhone connected / Mirroring -
    and, after 12 s of RTSP with no video, name the documented stall and the
    phone-side reset that clears it.

    The engine is launched inside a powershell.exe wrapper console - the engine
    needs a real console (without one it stalls silently before GStreamer
    initialises), and the wrapper tees the engine's stdout+stderr into the
    session log, which no stalled session ever had before. The console is
    HIDDEN (a hidden console is still a real console - verified live): no
    window of this app's machinery ever appears in the taskbar. PIN mode
    included - the UI generates a fixed PIN, passes it as "-pin nnnn", and
    displays it itself.

    The framed view (frame-mirror.ps1) is part of the app's lifecycle: it
    opens with the UI when the "iPhone frame" switch is on, the switch works
    mid-session in both directions, and closing this window always closes the
    frame too.
.PARAMETER SelfTest
    Build the window, force a real layout pass, assert the segmented-control
    geometry and the reserved sub-status height, run every state animation,
    then exit without showing it. Never shows a dialog, so it is safe in a
    non-interactive shell. Exit code 0 means the XAML, the templates and the
    wiring are all sound.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# PresentationFramework first, before anything that can fail: "AirPlayPC.cmd"
# launches with -WindowStyle Hidden, so a MessageBox is the only channel an
# error has to reach the user at all.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# powershell.exe 5.1's manifest declares no DPI awareness, so DWM bitmap-
# stretches the whole window on any display above 100% scaling - hairlines and
# 34px Light type are exactly what that ruins. Opt in before the first window
# exists, including the error dialogs below. System awareness only: WPF on .NET
# Framework cannot rescale per-monitor without a host app.config switch we
# cannot set from here, and declaring per-monitor would stop the OS
# compensating without giving WPF the ability to take over.
#
# The Add-Type is inside the guard, not above it. It compiles C# at runtime, so
# it can fail on a locked-down %TEMP% or a blocked compiler, and it throws
# outright on a second run in the same session ("the type name already exists").
# $ErrorActionPreference is already 'Stop' and this sits ahead of the main try,
# so an unguarded failure here would kill the app before it can report anything.
# Crisp type is worth having; it is not worth failing to start over.
try {
    Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    [void][Native.Win]::SetProcessDPIAware()
} catch { }

# Explicit AppUserModelID, before any window exists: without it the taskbar
# treats this window as powershell.exe (grouping and pinning pin PowerShell,
# with its icon). The installer stamps the same ID on its shortcuts. Guarded
# like the DPI call: identity is polish, never worth failing startup over.
try {
    if (-not ('Native.Shell' -as [type])) {
        Add-Type -Namespace Native -Name Shell -MemberDefinition @'
[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
'@
    }
    [void][Native.Shell]::SetCurrentProcessExplicitAppUserModelID('shreyanshucodes.screen-mirroring-iphone-windows')
} catch { }

# Everything below runs inside one try. Without it, any pre-window failure under
# the hidden-console launcher is 100% silent: the app simply never appears and
# there is nothing to report.
$script:ExitCode = 0
try {

    . (Join-Path $PSScriptRoot 'uxplay-common.ps1')

    # --- Single instance ---------------------------------------------------
    # A double-clicked launcher launched twice used to stack a second,
    # identical window on the first - two pollers, two possible engines, and a
    # conflict prompt against yourself. Second launch now surfaces the window
    # that already exists and leaves. (Skipped under -SelfTest, which must be
    # runnable while the real UI is open.)
    if (-not $SelfTest) {
        $script:uiMutexCreated = $false
        $script:uiMutex = New-Object System.Threading.Mutex($true, 'Local\PCAirPlay-UI', ([ref]$script:uiMutexCreated))
        if (-not $script:uiMutexCreated) {
            [void](Show-PCAirPlayUiWindow)
            exit 0
        }
    }

    # --- Locate the engine -------------------------------------------------
    $script:ux = Find-UxPlay
    $engineReady = ($script:ux -and $script:ux.Kind -eq 'Cli')
    if (-not $engineReady) {
        # Three states, three different truths. 'GuiOnly' is the 2.x Qt6 app: it
        # IS installed and it IS a receiver, it just exposes no command line for
        # us to drive. Saying "not installed" there sends the user off to
        # reinstall the thing they already have.
        if ($script:ux) {
            $problem = Get-UxPlayIncompatibleMessage -UxPlay $script:ux
        } else {
            $problem = "UxPlay is not installed.`n`nRun setup.ps1 as Administrator first."
        }
        if (-not $SelfTest) {
            [System.Windows.MessageBox]::Show($problem, 'AirPlayPC', 'OK', 'Error') | Out-Null
            exit 1
        }
        # -SelfTest must never block on a modal box in a non-interactive shell,
        # and its job - validating the XAML and the wiring - needs no engine.
        Write-Host 'SelfTest: no usable engine - validating XAML and wiring only.'
        Write-Host $problem
    } else {
        Initialize-UxPlayEnvironment -UxPlay $script:ux
    }
    $installedVersion = if ($script:ux) { $script:ux.Version } else { $null }

    # --- UI ----------------------------------------------------------------
    # Palette (tvOS-derived, dark only - this window sits next to a mirrored
    # phone screen and must not be the brightest thing on the desktop):
    #   #F5F5F7 primary text   #8E8E93 secondary   #5A5A5F tertiary
    #   #0A84FF accent, used only for "live" and for keyboard focus
    #
    # Sizes are tuned to keep the whole window under 640px. The constraint is
    # display scaling, not resolution: a 1366x768 laptop at 125% has only ~545
    # DIPs of work area, and ResizeMode is CanMinimize with no system chrome, so
    # an over-tall window has no way back on screen. Add_Loaded scales the shell
    # down if even this does not fit.
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iPhone Mirror for Windows" Width="524" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Display, Segoe UI Variable Text, Segoe UI"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>

    <!-- Row label: quiet, left column of every settings row. -->
    <Style x:Key="RowLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- Recessed segmented track. -->
    <Style x:Key="Track" TargetType="Border">
      <Setter Property="Background" Value="#3D000000"/>
      <Setter Property="BorderBrush" Value="#12FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="11"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Width" Value="228"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- The raised thumb that slides between segments. Position and width are
         set in code (Sync-Segments) because they depend on measured width. -->
    <Style x:Key="Thumb" TargetType="Border">
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#26FFFFFF"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#2EFFFFFF" Offset="0"/>
            <GradientStop Color="#17FFFFFF" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.5" Color="#000000"/>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Segment: label only. The thumb behind it carries the selection. -->
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#8E8E93"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="8" Background="#00000000"
                    BorderThickness="1" BorderBrush="#00000000">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsEnabled" Value="True"/>
                  <Condition Property="IsMouseOver" Value="True"/>
                </MultiTrigger.Conditions>
                <Setter Property="Foreground" Value="#D5D5DA"/>
              </MultiTrigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="#F5F5F7"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#0A84FF"/>
              </Trigger>
              <!-- Last, so it beats IsChecked. Locked while the receiver runs:
                   the pointer has to stop saying "clickable", and the selected
                   label has to stop looking like live primary text. -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#55555A"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- iOS-style switch. Two stacked tracks: the "on" one fades in, so no
         colour animation is ever run against a possibly-frozen brush. -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="27" Background="#00000000">
              <Border x:Name="trackOff" CornerRadius="13.5" Background="#1AFFFFFF"
                      BorderThickness="1" BorderBrush="#14FFFFFF"/>
              <Border x:Name="trackOn" CornerRadius="13.5" Background="#0A84FF" Opacity="0"/>
              <Border x:Name="knob" Width="21" Height="21" CornerRadius="10.5"
                      Background="#F7F7F9" HorizontalAlignment="Left" Margin="3,0,0,0">
                <Border.RenderTransform>
                  <TranslateTransform X="0"/>
                </Border.RenderTransform>
                <Border.Effect>
                  <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.45" Color="#000000"/>
                </Border.Effect>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="CheckBox.Checked">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="knob"
                                     Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                     To="19" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction>
                        <CubicEase EasingMode="EaseOut"/>
                      </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="trackOn"
                                     Storyboard.TargetProperty="Opacity"
                                     To="1" Duration="0:0:0.22"/>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="CheckBox.Unchecked">
                <BeginStoryboard>
                  <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="knob"
                                     Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                     To="0" Duration="0:0:0.22">
                      <DoubleAnimation.EasingFunction>
                        <CubicEase EasingMode="EaseOut"/>
                      </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="trackOn"
                                     Storyboard.TargetProperty="Opacity"
                                     To="0" Duration="0:0:0.22"/>
                  </Storyboard>
                </BeginStoryboard>
              </EventTrigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="trackOff" Property="BorderBrush" Value="#0A84FF"/>
              </Trigger>
              <!-- Disabled: grey the knob rather than fade the control. The
                   card is already at 40% while live, and a second opacity on
                   top of that would push the switch below readable. -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="knob" Property="Background" Value="#8E8E93"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Name field: no chrome until focused. -->
    <Style x:Key="NameInput" TargetType="TextBox">
      <Setter Property="Foreground" Value="#F5F5F7"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="TextAlignment" Value="Right"/>
      <Setter Property="CaretBrush" Value="#0A84FF"/>
      <Setter Property="SelectionBrush" Value="#0A84FF"/>
      <!-- The cap is what makes the sub-status reservation below deterministic:
           at 24 characters the running message cannot exceed three lines even
           in all-caps W (measured), so no accepted name can resize the window.
           A Windows computer name is at most 15 characters anyway. -->
      <Setter Property="MaxLength" Value="24"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" CornerRadius="9" Background="#00000000"
                    BorderThickness="1" BorderBrush="#00000000" Padding="10,5">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsEnabled" Value="True"/>
                  <Condition Property="IsMouseOver" Value="True"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="bd" Property="Background" Value="#0DFFFFFF"/>
              </MultiTrigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#16FFFFFF"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#660A84FF"/>
              </Trigger>
              <!-- Locked while running. The stock disabled visual has nothing
                   to dim here - this template draws no chrome at rest - so the
                   field would otherwise look editable and eat keystrokes in
                   silence. The I-beam going away is the honest signal. -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#6E6E73"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Window buttons. The focus ring is a sibling overlay, not a thickness
         change on the fill: a border that grows on focus resizes the button,
         and under SizeToContent the window with it. -->
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bd" CornerRadius="8" Background="#00000000"/>
              <Border x:Name="ring" CornerRadius="8" BorderThickness="1.5"
                      BorderBrush="#00000000"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#18FFFFFF"/>
                <Setter Property="Foreground" Value="#F5F5F7"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="ring" Property="BorderBrush" Value="#0A84FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Primary button text. This MUST be a Style setter, not a local value on
         the Button and not a local value on the template's border: local values
         outrank ControlTemplate triggers, so the "Stop" state could not repaint
         the label and it rendered near-black on near-black. Style setters sit
         below template triggers, which is exactly what the Tag trigger needs. -->
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#08080A"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <!-- Row divider. -->
    <Style x:Key="Row" TargetType="Border">
      <Setter Property="BorderBrush" Value="#10FFFFFF"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Margin" Value="18,0,0,0"/>
    </Style>

  </Window.Resources>

  <!-- Shell: rounded, hairline-edged, sitting on a large soft shadow.
       The margin is the shadow's canvas: it must cover BlurRadius +
       ShadowDepth, or the blur clips at the window rectangle and reads as a
       hard-cut box on the desktop (user-reported). Window width grows by the
       same amount so the card itself keeps its size. -->
  <Border x:Name="Shell" CornerRadius="22" BorderBrush="#1FFFFFFF" BorderThickness="1" Margin="36">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#13151A" Offset="0"/>
        <GradientStop Color="#0A0B0D" Offset="0.45"/>
        <GradientStop Color="#050506" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect>
      <DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.6" Color="#000000"/>
    </Border.Effect>

    <StackPanel Margin="26,8,26,18">

      <!-- Title bar (drag handle) -->
      <Grid x:Name="TitleBar" Height="30" Background="#00000000">
        <TextBlock Text="iPhone Mirror for Windows" Foreground="#8E8E93" FontSize="12"
                   FontWeight="SemiBold" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="MinBtn" Style="{StaticResource WinBtn}" Content="&#x2500;"
                  AutomationProperties.Name="Minimize" ToolTip="Minimize"/>
          <Button x:Name="CloseBtn" Style="{StaticResource WinBtn}" Content="&#x2715;"
                  AutomationProperties.Name="Close" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- HERO: the one thing you glance at from across the room. -->
      <Grid Margin="0,8,0,12">
        <!-- Glow behind the mark. Opacity is animated; 0 when idle. -->
        <Ellipse x:Name="Halo" Width="220" Height="220" Opacity="0"
                 HorizontalAlignment="Center" VerticalAlignment="Top"
                 Margin="0,-80,0,0" IsHitTestVisible="False">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#4D0A84FF" Offset="0"/>
              <GradientStop Color="#1E0A84FF" Offset="0.45"/>
              <GradientStop Color="#000A84FF" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>

        <StackPanel x:Name="HeroBlock" HorizontalAlignment="Center">
          <!-- Viewbox, so trimming the mark is one number and the two stacked
               canvases stay in register. -->
          <Viewbox Width="46" Height="46" HorizontalAlignment="Center">
            <Grid Width="52" Height="52">
              <!-- Idle mark -->
              <Canvas x:Name="GlyphIdle" Width="52" Height="52">
                <Path Stroke="#6E6E73" StrokeThickness="2.4" StrokeStartLineCap="Round"
                      StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Data="M 19,36 H 7 A 5,5 0 0 1 2,31 V 8 A 5,5 0 0 1 7,3 H 45 A 5,5 0 0 1 50,8 V 31 A 5,5 0 0 1 45,36 H 33"/>
                <Path Fill="#6E6E73" Data="M 26,30 L 42,50 L 10,50 Z"/>
              </Canvas>
              <!-- Live mark, faded in on start -->
              <Canvas x:Name="GlyphLive" Width="52" Height="52" Opacity="0">
                <Canvas.Effect>
                  <DropShadowEffect BlurRadius="22" ShadowDepth="0" Color="#0A84FF" Opacity="0.95"/>
                </Canvas.Effect>
                <Path Stroke="#FFFFFF" StrokeThickness="2.4" StrokeStartLineCap="Round"
                      StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Data="M 19,36 H 7 A 5,5 0 0 1 2,31 V 8 A 5,5 0 0 1 7,3 H 45 A 5,5 0 0 1 50,8 V 31 A 5,5 0 0 1 45,36 H 33"/>
                <Path Fill="#FFFFFF" Data="M 26,30 L 42,50 L 10,50 Z"/>
              </Canvas>
            </Grid>
          </Viewbox>

          <TextBlock x:Name="StatusText" Text="Ready" Foreground="#F5F5F7"
                     FontSize="34" FontWeight="Light" TextAlignment="Center"
                     Margin="0,10,0,0"/>
          <!-- MinHeight reserves every line the running message can need: the
               worst case is the stall instruction (3 lines at MaxWidth) plus
               the PIN line, which rides every running state = 4 x LineHeight.
               Without it the window grows the instant the text does -
               resizing out from under the pointer that just clicked Start. -->
          <TextBlock x:Name="SubStatusText" Foreground="#8E8E93" FontSize="13"
                     TextAlignment="Center" TextWrapping="Wrap" MaxWidth="340"
                     Margin="0,6,0,0" LineHeight="19" MinHeight="76"
                     Text="Press Start, then pick this PC from Screen Mirroring"/>
        </StackPanel>
      </Grid>

      <!-- SETTINGS: recede while live (the whole card dims and disables). -->
      <Border x:Name="SettingsCard" CornerRadius="18" Background="#0BFFFFFF"
              BorderBrush="#14FFFFFF" BorderThickness="1">
        <StackPanel>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,8,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="108"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Name" Style="{StaticResource RowLabel}"/>
              <TextBox x:Name="NameBox" Grid.Column="1" Style="{StaticResource NameInput}"
                       VerticalAlignment="Center" AutomationProperties.Name="Device name"/>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="108"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Mode" Style="{StaticResource RowLabel}"/>
              <Border Grid.Column="1" Style="{StaticResource Track}">
                <Grid x:Name="ModeGrid">
                  <Border x:Name="ModeThumb" Style="{StaticResource Thumb}"/>
                  <UniformGrid Columns="2">
                    <RadioButton x:Name="ModeLow" Style="{StaticResource Segment}" GroupName="mode"
                                 Content="Low latency" IsChecked="True"/>
                    <RadioButton x:Name="ModeSync" Style="{StaticResource Segment}" GroupName="mode"
                                 Content="A/V sync"/>
                  </UniformGrid>
                </Grid>
              </Border>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="108"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Resolution" Style="{StaticResource RowLabel}"/>
              <Border Grid.Column="1" Style="{StaticResource Track}">
                <Grid x:Name="ResGrid">
                  <Border x:Name="ResThumb" Style="{StaticResource Thumb}"/>
                  <UniformGrid Columns="2">
                    <RadioButton x:Name="Res1440" Style="{StaticResource Segment}" GroupName="res"
                                 Content="1440p" IsChecked="True"/>
                    <RadioButton x:Name="Res1080" Style="{StaticResource Segment}" GroupName="res"
                                 Content="1080p"/>
                  </UniformGrid>
                </Grid>
              </Border>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="108"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Frame rate" Style="{StaticResource RowLabel}"/>
              <Border Grid.Column="1" Style="{StaticResource Track}">
                <Grid x:Name="FpsGrid">
                  <Border x:Name="FpsThumb" Style="{StaticResource Thumb}"/>
                  <UniformGrid Columns="2">
                    <RadioButton x:Name="Fps60" Style="{StaticResource Segment}" GroupName="fps"
                                 Content="60 fps" IsChecked="True"/>
                    <RadioButton x:Name="Fps30" Style="{StaticResource Segment}" GroupName="fps"
                                 Content="30 fps"/>
                  </UniformGrid>
                </Grid>
              </Border>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Fullscreen" Style="{StaticResource RowLabel}"/>
              <CheckBox x:Name="FullscreenCheck" Grid.Column="1" Style="{StaticResource Switch}"
                        AutomationProperties.Name="Fullscreen"/>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0"
                  ToolTip="Wraps the mirror in an iPhone-style frame - bezel, rounded corners, side buttons. The frame opens with this app and closes with it; the switch works any time, even mid-session.">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="iPhone frame" Style="{StaticResource RowLabel}"/>
              <!-- Defaults ON, but the value is set in Add_Loaded, not here: a
                   switch checked from XAML misses its template's Checked
                   storyboard (the template is not applied yet at parse time)
                   and renders as OFF while being on. -->
              <CheckBox x:Name="FrameCheck" Grid.Column="1" Style="{StaticResource Switch}"
                        AutomationProperties.Name="iPhone frame"/>
            </Grid>
          </Border>

          <Border Style="{StaticResource Row}">
            <Grid Height="44" Margin="0,0,18,0"
                  ToolTip="Turn this on only if people in a Teams/Meet/Zoom call see a black rectangle where the iPhone should be. It swaps the Direct3D sink for OpenGL, which window capture can read. The mirror looks fine locally either way, so this can only be caught by asking someone on the call.">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Share-safe video" Style="{StaticResource RowLabel}"/>
              <CheckBox x:Name="ShareSafeCheck" Grid.Column="1" Style="{StaticResource Switch}"
                        AutomationProperties.Name="Share-safe video"/>
            </Grid>
          </Border>

          <Grid Height="44" Margin="18,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Require PIN" Style="{StaticResource RowLabel}"/>
            <CheckBox x:Name="PinCheck" Grid.Column="1" Style="{StaticResource Switch}"
                      AutomationProperties.Name="Require PIN"/>
          </Grid>

        </StackPanel>
      </Border>

      <!-- PRIMARY ACTION. Bright and solid to start; once live it steps back to
           a quiet outline, because the hero already shouts the state. -->
      <Button x:Name="StartBtn" Style="{StaticResource PrimaryBtn}" Height="46" FontSize="15"
              Cursor="Hand" IsDefault="True" FocusVisualStyle="{x:Null}" Margin="0,14,0,0">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="14" BorderThickness="1" BorderBrush="#00000000"
                    RenderTransformOrigin="0.5,0.5">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#FFFFFF" Offset="0"/>
                  <GradientStop Color="#E4E4E9" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect>
                <DropShadowEffect BlurRadius="26" ShadowDepth="0" Color="#FFFFFF" Opacity="0.16"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsEnabled" Value="True"/>
                  <Condition Property="IsMouseOver" Value="True"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="bd" Property="Opacity" Value="0.93"/>
              </MultiTrigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#0A84FF"/>
              </Trigger>
              <!-- Running: swap the whole brush. Gradient stops cannot be
                   targeted by name from a trigger - they are not in the
                   template's namescope. -->
              <Trigger Property="Tag" Value="running">
                <Setter TargetName="bd" Property="Background" Value="#00000000"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#33FFFFFF"/>
                <Setter TargetName="bd" Property="Effect" Value="{x:Null}"/>
                <Setter Property="Foreground" Value="#F5F5F7"/>
                <Setter Property="FontWeight" Value="Normal"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
        <TextBlock x:Name="StartBtnText" Text="Start"/>
      </Button>

      <!-- Footer -->
      <Grid Margin="4,10,4,0">
        <TextBlock x:Name="IpText" Foreground="#55555A" FontSize="11.5"
                   VerticalAlignment="Center"/>
        <Button x:Name="DoctorBtn" HorizontalAlignment="Right" Cursor="Hand" Margin="0,0,-7,0"
                Background="Transparent" BorderThickness="0" FocusVisualStyle="{x:Null}"
                AutomationProperties.Name="Run diagnostics">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border Background="#00000000" Padding="7,4">
                <TextBlock x:Name="txt" Text="Diagnostics" Foreground="#55555A" FontSize="11.5"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="txt" Property="Foreground" Value="#F5F5F7"/>
                </Trigger>
                <Trigger Property="IsKeyboardFocused" Value="True">
                  <Setter TargetName="txt" Property="Foreground" Value="#0A84FF"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Grid>

    </StackPanel>
  </Border>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # A hashtable index assignment adds the key even when the value is $null, so
    # $ui.Count counts loop iterations, not bindings. Collect the misses and name
    # them all: otherwise a renamed x:Name surfaces much later as an unrelated
    # "property cannot be found on this object".
    $ui = @{}
    $missing = @()
    foreach ($n in 'Shell','TitleBar','MinBtn','CloseBtn','Halo','GlyphIdle','GlyphLive',
                   'HeroBlock','StatusText','SubStatusText','SettingsCard',
                   'NameBox','ModeGrid','ModeThumb','ModeLow','ModeSync',
                   'ResGrid','ResThumb','Res1440','Res1080',
                   'FpsGrid','FpsThumb','Fps60','Fps30',
                   'FullscreenCheck','FrameCheck','ShareSafeCheck','PinCheck','StartBtn','StartBtnText','IpText','DoctorBtn') {
        $ui[$n] = $window.FindName($n)
        if ($null -eq $ui[$n]) { $missing += $n }
    }
    if ($missing.Count -gt 0) { throw "XAML elements did not bind: $($missing -join ', ')" }
    $boundCount = $ui.Count

    # The window icon is what the TASKBAR shows - without it every launch
    # wears powershell.exe's icon. Shipped next to the script; a checkout
    # without the .ico still runs, just generically dressed.
    $script:appIconPath = Join-Path $PSScriptRoot 'pcairplay.ico'
    if (Test-Path -LiteralPath $script:appIconPath) {
        try {
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                (New-Object System.Uri $script:appIconPath), 'None', 'OnLoad')
        } catch { }
    }

    $ui.NameBox.Text = $env:COMPUTERNAME

    # --- Footer ------------------------------------------------------------
    # 'unset' is a sentinel, not laziness: with $null, the no-network-at-startup
    # case would compare $null to $null, skip the first render, and leave the
    # label permanently blank - which is the bug this replaces.
    $script:lastIp  = 'unset'
    $script:ipTicks = 0

    function Update-IpFooter {
        $ip = Get-LanIPAddress
        if ($ip -eq $script:lastIp) { return }
        $script:lastIp = $ip
        $suffix = ''
        if ($installedVersion) { $suffix = "   UxPlay $installedVersion" }
        if ($ip) {
            $ui.IpText.Text = "This PC: $ip$suffix"
        } else {
            $ui.IpText.Text = "No network detected$suffix"
        }
    }

    Update-IpFooter

    # --- Settings persistence ----------------------------------------------
    # The UI used to reset name/resolution/fps/toggles on every launch - the
    # one thing every session repeated by hand. Saved on close and on Start
    # (the crash-safe moment that captures what is actually in use), restored
    # in Add_Loaded - NOT here: a switch checked before its template applies
    # misses the Checked storyboard and renders OFF while being on.

    function Get-UiSettingsPath { Join-Path (Get-PCAirPlayLogDirectory) 'ui-settings.json' }

    function Save-UiSettings {
        param([string]$Path = (Get-UiSettingsPath))
        try {
            $dir = Split-Path $Path -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }
            [pscustomobject]@{
                Name       = $ui.NameBox.Text
                Resolution = if ($ui.Res1080.IsChecked) { '1080' } else { '1440' }
                Fps        = if ($ui.Fps30.IsChecked) { '30' } else { '60' }
                Sync       = [bool]$ui.ModeSync.IsChecked
                Fullscreen = [bool]$ui.FullscreenCheck.IsChecked
                ShareSafe  = [bool]$ui.ShareSafeCheck.IsChecked
                Pin        = [bool]$ui.PinCheck.IsChecked
                Frame      = [bool]$ui.FrameCheck.IsChecked
            } | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
        } catch { }
    }

    function Restore-UiSettings {
        # Best-effort with per-field validation: a hand-edited or truncated
        # file falls back to defaults field by field, never to a dialog.
        param([string]$Path = (Get-UiSettingsPath))
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $get = { param($k) $p = $j.PSObject.Properties[$k]; if ($p) { $p.Value } else { $null } }
            $name = [string](& $get 'Name')
            if ($name -and -not (Resolve-UxPlayDeviceName -Name $name).Error) { $ui.NameBox.Text = $name }
            switch ([string](& $get 'Resolution')) {
                '1080' { $ui.Res1080.IsChecked = $true }
                '1440' { $ui.Res1440.IsChecked = $true }
            }
            switch ([string](& $get 'Fps')) {
                '30' { $ui.Fps30.IsChecked = $true }
                '60' { $ui.Fps60.IsChecked = $true }
            }
            if ((& $get 'Sync') -eq $true) { $ui.ModeSync.IsChecked = $true } else { $ui.ModeLow.IsChecked = $true }
            $ui.FullscreenCheck.IsChecked = ((& $get 'Fullscreen') -eq $true)
            $ui.ShareSafeCheck.IsChecked  = ((& $get 'ShareSafe') -eq $true)
            $ui.PinCheck.IsChecked        = ((& $get 'Pin') -eq $true)
            $fr = & $get 'Frame'
            if ($null -ne $fr) { $ui.FrameCheck.IsChecked = ($fr -eq $true) }
        } catch { }
    }

    # --- Framed view (frame-mirror.ps1) ------------------------------------
    # The frame is part of this app's session now: it opens with the UI (when
    # the switch is on), the switch works mid-session in both directions, and
    # closing the UI always closes the frame - it used to survive alone, which
    # read as a leak. Close is by WM_CLOSE via Close-FramedMirrorWindow, never
    # by PID: while attached, the engine's video window is OWNED by the
    # frame's bezel, and killing the owner kills the live mirror with it.

    $script:frameLaunchedAt     = $null
    $script:suppressFrameEvents = $false

    function Start-FramedMirror {
        # Idempotent: the frame is single-instance behind a named mutex, and
        # -Quiet makes a lost race exit silently instead of raising a modal.
        # Everything is -WindowStyle Hidden: no console may ever flash.
        if (Test-FramedMirrorRunning) { return }
        $frame = Join-Path $PSScriptRoot 'frame-mirror.ps1'
        if (-not (Test-Path -LiteralPath $frame)) { return }
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$frame`"", '-Quiet')
        $script:frameLaunchedAt = Get-Date
    }

    # --- Motion helpers ----------------------------------------------------
    # Everything animated here is driven from code against transforms/brushes
    # this script created, so nothing is ever animated against a frozen
    # Freezable.

    function New-Ease {
        param([string]$Mode = 'EaseOut')
        $e = New-Object System.Windows.Media.Animation.CubicEase
        $e.EasingMode = $Mode
        $e
    }

    function New-DoubleAnim {
        param([double]$To, [int]$Ms, [double]$From = [double]::NaN)
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        if (-not [double]::IsNaN($From)) { $a.From = $From }
        $a.To = $To
        $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
        $a.EasingFunction = New-Ease
        $a
    }

    function Start-Fade {
        param($Element, [double]$To, [int]$Ms = 280, [double]$From = [double]::NaN)
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty,
                                (New-DoubleAnim -To $To -Ms $Ms -From $From))
    }

    # --- Segmented controls ------------------------------------------------
    # The thumb is a sibling of the radio buttons, not part of their template, so
    # one thumb can slide across the whole track. Width/position depend on
    # measured layout, so they are computed here rather than expressed in XAML.
    $script:Segments = @()

    function Add-Segment {
        param($Grid, $Thumb, $Buttons)
        $tx = New-Object System.Windows.Media.TranslateTransform
        $Thumb.RenderTransform = $tx
        $script:Segments += [pscustomobject]@{ Grid = $Grid; Thumb = $Thumb; Buttons = @($Buttons); Tx = $tx }
        $Grid.Add_SizeChanged({ Sync-Segments })
        foreach ($b in @($Buttons)) { $b.Add_Checked({ Sync-Segments -Animate }) }
    }

    function Sync-Segments {
        param([switch]$Animate)
        foreach ($s in $script:Segments) {
            $n = $s.Buttons.Count
            if ($n -lt 1) { continue }
            $w = $s.Grid.ActualWidth / $n
            if ($w -le 0) { continue }
            $s.Thumb.Width = $w
            $idx = 0
            for ($i = 0; $i -lt $n; $i++) { if ($s.Buttons[$i].IsChecked) { $idx = $i } }
            $target = $idx * $w
            if ($Animate) {
                $s.Tx.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty,
                                     (New-DoubleAnim -To $target -Ms 260))
            } else {
                $s.Tx.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
                $s.Tx.X = $target
            }
        }
    }

    Add-Segment -Grid $ui.ModeGrid -Thumb $ui.ModeThumb -Buttons @($ui.ModeLow, $ui.ModeSync)
    Add-Segment -Grid $ui.ResGrid  -Thumb $ui.ResThumb  -Buttons @($ui.Res1440, $ui.Res1080)
    Add-Segment -Grid $ui.FpsGrid  -Thumb $ui.FpsThumb  -Buttons @($ui.Fps60, $ui.Fps30)

    # Primary button lift on hover / press.
    $script:btnScale = New-Object System.Windows.Media.ScaleTransform
    $ui.StartBtn.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $ui.StartBtn.RenderTransform = $script:btnScale

    function Set-BtnScale {
        param([double]$To, [int]$Ms)
        foreach ($p in @([System.Windows.Media.ScaleTransform]::ScaleXProperty,
                         [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
            $script:btnScale.BeginAnimation($p, (New-DoubleAnim -To $To -Ms $Ms))
        }
    }
    $ui.StartBtn.Add_MouseEnter({ Set-BtnScale -To 1.015 -Ms 160 })
    $ui.StartBtn.Add_MouseLeave({ Set-BtnScale -To 1.0   -Ms 220 })
    $ui.StartBtn.Add_PreviewMouseLeftButtonDown({ Set-BtnScale -To 0.985 -Ms 90 })
    $ui.StartBtn.Add_PreviewMouseLeftButtonUp({ Set-BtnScale -To 1.015 -Ms 160 })

    # Hero entrance / state-change transition.
    $script:heroLift = New-Object System.Windows.Media.TranslateTransform
    $ui.HeroBlock.RenderTransform = $script:heroLift

    function Invoke-HeroTransition {
        $script:heroLift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,
                                        (New-DoubleAnim -From 9 -To 0 -Ms 340))
        Start-Fade -Element $ui.HeroBlock -To 1 -From 0.25 -Ms 340
    }

    # --- Receiver control --------------------------------------------------
    $script:proc      = $null    # the powershell.exe wrapper that tees engine output
    $script:enginePid = $null    # the uxplay.exe child; resolved by the poll timer
    $script:logPath   = $null
    $script:isSelfTest = [bool]$SelfTest   # handlers consult it: -SelfTest must never launch/close a real frame

    # Session-state machine inputs (see Resolve-SessionState).
    $script:logReadPos     = 0
    $script:videoSeen      = $false
    $script:clientDesc     = $null
    $script:connectedSince = $null
    $script:liveStateKey   = ''
    $script:bonjourDeaf    = $false
    $script:externalEngine = $false   # a uxplay.exe this UI did not start
    $script:pinCode        = $null    # fixed 4-digit PIN, generated per session
    try { $script:bonjourDeaf = ((Get-BonjourSocketState).State -eq 'Deaf') } catch { }

    # Other AirPlay receivers on this PC are the practical hazard: they hold the
    # port and advertise a second entry in the iPhone's mirroring list, so the
    # wrong one gets picked. Find them, but never kill anything without a
    # prompt. Get-CompetingReceiverProcess covers the vendor's own 2.x GUI too,
    # which is the one the installer puts in the Start Menu.
    function Resolve-Conflicts {
        # Include stray uxplay engines: a leftover from an earlier run holds the
        # port and advertises too, but is invisible without a console window.
        # $script:proc is the WRAPPER (powershell.exe); the engine to spare is
        # its uxplay child, tracked separately.
        $mine = @()
        if ($script:enginePid -and (Test-Running)) { $mine = @($script:enginePid) }
        $comp = @(Get-CompetingReceiverProcess -ExcludeId $mine) +
                @(Get-UxPlayEngineProcess -ExcludeId $mine)
        if ($comp.Count -eq 0) { return $true }

        $names = ($comp | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
        $answer = [System.Windows.MessageBox]::Show(
            "Another AirPlay receiver is already running on this PC:`n`n    $names`n`n" +
            "It holds the AirPlay port and shows up as a second device in the iPhone's " +
            "mirroring list, so you may pick the wrong one.`n`nClose it now?",
            'AirPlayPC - conflict', 'YesNoCancel', 'Warning')

        if ($answer -eq 'Cancel') { return $false }
        if ($answer -eq 'Yes') {
            foreach ($c in $comp) { try { $c.Kill() } catch {} }
            Start-Sleep -Milliseconds 600
        }
        return $true
    }

    function Test-Running {
        $script:proc -and -not $script:proc.HasExited
    }

    function Get-DeviceName {
        <#
            One normalisation, used both for the engine argument and for the
            on-screen instruction, so the UI can never name a device the
            receiver did not advertise. Resolve-UxPlayDeviceName is shared with
            start-airplay.ps1 - this used to be a private second implementation,
            and it had no leading-'-' guard, so a name of "-Demo" reached the
            engine and produced the '"-n" had no argument' error that the CLI
            path rejects up front.

            Returns the cleaned name only; Test-DeviceName is what surfaces a
            rejection, because this is called from paint paths that must not
            put a modal dialog on screen.
        #>
        (Resolve-UxPlayDeviceName -Name $ui.NameBox.Text).Name
    }

    function Test-DeviceName {
        # $true if the current box contents can be advertised. Called on the
        # Start path only.
        $r = Resolve-UxPlayDeviceName -Name $ui.NameBox.Text
        if (-not $r.Error) { return $true }
        [System.Windows.MessageBox]::Show($r.Error, 'AirPlayPC - name', 'OK', 'Warning') | Out-Null
        $false
    }

    function Get-EngineArgument {
        <#
            The argument TOKENS, built by the SAME function start-airplay.ps1
            uses, so the two entry points cannot drift again. Kept as a token
            array rather than a hand-joined command line so quoting stays one
            function's problem instead of being smeared through construction.

            Note -RefreshRate is deliberately NOT wired to the fps choice. This
            UI used to emit "-s ${res}@${fps}", which made "30 fps" also ask the
            phone for a 30 Hz display mode - a different request from capping
            the stream at 30 fps.
        #>
        # No option above 1440p ON PURPOSE. "-s is only an advertisement, so
        # bigger cannot hurt" was disproven live: at -s 3840x2160 the phone
        # held the RTSP connection and never opened the data connection - the
        # dreaded "connected but no picture", twice, before the cause was
        # found. See CLAUDE.md before re-adding anything larger.
        $res = if ($ui.Res1080.IsChecked) { '1920x1080' } else { '2560x1440' }
        $fps = if ($ui.Fps30.IsChecked)  { 30 } else { 60 }

        # The PIN is generated HERE, not read back from the engine: with a
        # fixed "-pin nnnn" the UI knows the code and can display it, which is
        # what lets the engine's console stay hidden. 1000-9999 on purpose - a
        # leading zero invites a display/comparison mismatch. One code per
        # session; Start-Receiver clears it so every Start gets a fresh one.
        if ($ui.PinCheck.IsChecked -and -not $script:pinCode) {
            $script:pinCode = [string](Get-Random -Minimum 1000 -Maximum 10000)
        }

        $built = Build-UxPlayArgs -Name (Get-DeviceName) -Resolution $res -RefreshRate 60 `
            -Fps $fps -PluginDir $script:ux.PluginDir `
            -Sync:([bool]$ui.ModeSync.IsChecked) `
            -Fullscreen:([bool]$ui.FullscreenCheck.IsChecked) `
            -Pin:([bool]$ui.PinCheck.IsChecked) `
            -PinCode $(if ($ui.PinCheck.IsChecked -and $script:pinCode) { $script:pinCode } else { '' }) `
            -ShareSafe:([bool]$ui.ShareSafeCheck.IsChecked)
        # Notes used to be dropped here, which made a share-safe request that
        # silently fell back to D3D11 invisible in the UI - the one failure mode
        # share-safe exists to fix, reported as if it had worked.
        $script:lastNotes = @($built.Notes)
        $built.Args
    }

    function ConvertTo-CommandLine {
        <#
            Join tokens into one command line under CommandLineToArgvW rules.

            Start-Process must be handed a single string here: Windows
            PowerShell 5.1 joins an -ArgumentList array with spaces and adds NO
            quoting at all, so a name like "Demo PC" would arrive as two
            arguments. Quoting by hand is therefore mandatory - and it has to be
            done properly, because a run of backslashes immediately before the
            closing quote escapes that quote and absorbs the rest of the line.
        #>
        param([string[]]$Tokens)
        $out = foreach ($t in $Tokens) {
            $s = [string]$t
            if ($s -eq '') {
                '""'
            } elseif ($s -notmatch '[\s"]') {
                $s
            } else {
                $e = $s -replace '(\\*)"', '$1$1\"'
                $e = $e -replace '(\\+)$', '$1$1'
                '"' + $e + '"'
            }
        }
        $out -join ' '
    }

    function New-EngineWrapperCommand {
        <#
            The Start-Process argument array for the engine's wrapper console.

            The engine runs as a CHILD of powershell.exe and inherits its real
            console (the same shape as start-airplay.ps1's logged launch, which
            is verified not to be the no-console stall), while the wrapper tees
            engine stdout+stderr into the session log and relays the engine's
            exit code. -EncodedCommand so no quoting rules stack: the inner
            script needs only PowerShell single-quote escaping, whatever the
            device name contains.
        #>
        param(
            [Parameter(Mandatory)][string]$Exe,
            [Parameter(Mandatory)][string[]]$Tokens,
            [string]$LogPath
        )
        $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
        $run = "& $(& $q $Exe) @($(@($Tokens | ForEach-Object { & $q $_ }) -join ', '))"
        $inner = "`$Host.UI.RawUI.WindowTitle = 'AirPlayPC engine'; `$ErrorActionPreference = 'Continue'; "
        if ($LogPath) {
            # 2>&1 through Tee, exactly like the CLI: stderr arrives reformatted
            # as NativeCommandError noise, which is documented and benign.
            $inner += "$run 2>&1 | Tee-Object -FilePath $(& $q $LogPath) -Append; exit `$LASTEXITCODE"
        } else {
            $inner += "$run; exit `$LASTEXITCODE"
        }
        @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
          [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner)))
    }

    function Resolve-SessionState {
        <#
            Pure classification: socket counts + log markers -> what the hero
            says. Kept free of WPF and process state so -SelfTest can assert
            every branch without a live engine.

            Established counts are the ENGINE's TCP connections: RTSP is one,
            the mirror video data channel is a second - so 2+ means video even
            before the log says so (the log can lag behind: the engine's stdout
            is block-buffered through the wrapper pipe). One connection held
            beyond 12 s with no video evidence is the documented stall - RTSP
            up, data connection never opened - and the phone-side reset is the
            only known way out, so the UI says exactly that.

            A $null Headline/Detail means "use Update-Status's defaults".
        #>
        param(
            [int]$Established,
            [bool]$VideoSeen,
            [double]$ConnectedSeconds,
            [string]$ClientDesc,
            [bool]$BonjourDeaf
        )
        $who = if ($ClientDesc) { $ClientDesc } else { 'The iPhone' }
        if ($Established -le 0) {
            if ($BonjourDeaf) {
                return [pscustomobject]@{ Key = 'deaf'; Headline = 'Not discoverable'
                    Detail = 'Bonjour has no network socket, so iPhones cannot see this PC. Run Diagnostics for the fix.' }
            }
            return [pscustomobject]@{ Key = 'idle'; Headline = $null; Detail = $null }
        }
        if ($VideoSeen -or $Established -ge 2) {
            return [pscustomobject]@{ Key = 'mirroring'; Headline = 'Mirroring'
                Detail = "$who is connected and video is live." }
        }
        if ($ConnectedSeconds -gt 12) {
            return [pscustomobject]@{ Key = 'stalled'; Headline = 'Connected, no video'
                Detail = "$who is linked but video never started. On the phone: stop Screen Mirroring, then start it again." }
        }
        [pscustomobject]@{ Key = 'connecting'; Headline = 'iPhone connected'; Detail = 'Starting the video stream...' }
    }

    function Read-EngineLogTail {
        # Scan only the NEW bytes of the session log for the engine's milestone
        # lines. Best-effort and possibly late (block buffering through the
        # wrapper pipe) - the socket counts are the primary signal; these add
        # certainty plus the client's name. The file is UTF-16LE throughout
        # (Set-Content -Encoding Unicode header, Tee-Object appends in kind),
        # so byte offsets stay 2-byte aligned.
        if (-not $script:logPath) { return }
        try {
            $fs = [System.IO.File]::Open($script:logPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -gt $script:logReadPos) {
                    [void]$fs.Seek($script:logReadPos, [System.IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] ([int]($fs.Length - $script:logReadPos))
                    $n = $fs.Read($buf, 0, $buf.Length)
                    $script:logReadPos += $n
                    $text = [System.Text.Encoding]::Unicode.GetString($buf, 0, $n)
                    if ($text -match 'Begin streaming to GStreamer video pipeline|raop_rtp_mirror starting mirroring') {
                        $script:videoSeen = $true
                    }
                    if (-not $script:clientDesc -and $text -match 'connection request from (.+?) with deviceID') {
                        $script:clientDesc = $Matches[1].Trim()
                    }
                }
            } finally { $fs.Dispose() }
        } catch { }
    }

    function Update-SessionState {
        if (-not (Test-Running)) { return }
        if (-not $script:enginePid) {
            # The wrapper's uxplay child. Resolved here, on the timer, rather
            # than blocking the Start click on a slow spawn.
            $c = @(Get-CimInstance Win32_Process -Filter "Name='uxplay.exe' AND ParentProcessId=$($script:proc.Id)" -ErrorAction SilentlyContinue)
            if ($c.Count -gt 0) { $script:enginePid = [int]$c[0].ProcessId }
        }
        $est = 0
        if ($script:enginePid) {
            $est = @(Get-NetTCPConnection -State Established -OwningProcess $script:enginePid -ErrorAction SilentlyContinue).Count
        }
        Read-EngineLogTail
        if ($est -gt 0) {
            if (-not $script:connectedSince) { $script:connectedSince = Get-Date }
        } else {
            # Markers are per-connection evidence: a finished mirror must not
            # make the NEXT connection's stall read as "Mirroring".
            $script:connectedSince = $null
            $script:videoSeen      = $false
            $script:clientDesc     = $null
        }
        $secs = 0.0
        if ($script:connectedSince) { $secs = ((Get-Date) - $script:connectedSince).TotalSeconds }
        $s = Resolve-SessionState -Established $est -VideoSeen $script:videoSeen `
            -ConnectedSeconds $secs -ClientDesc $script:clientDesc -BonjourDeaf $script:bonjourDeaf
        if ($s.Key -ne $script:liveStateKey) {
            $script:liveStateKey = $s.Key
            Update-Status -Headline $s.Headline -Detail $s.Detail
        }
    }

    $script:LockedControls = 'NameBox','ModeLow','ModeSync','Res1440','Res1080',
                             'Fps60','Fps30','FullscreenCheck','ShareSafeCheck','PinCheck'

    function Update-Status {
        param([string]$Headline, [string]$Detail)

        if (Test-Running) {
            $ui.StartBtn.Tag = 'running'
            $ui.StartBtnText.Text = 'Stop'
            # "Discoverable" is the DEFAULT, claimed only when nothing stronger
            # is observed. The poll timer feeds real states through
            # Resolve-SessionState (sockets + engine log), so "iPhone
            # connected" / "Mirroring" / the stall warning arrive as explicit
            # Headline/Detail rather than being asserted here.
            if (-not $Headline) { $Headline = 'Discoverable' }
            if (-not $Detail) {
                $Detail = "Control Center > Screen Mirroring > '$(Get-DeviceName)'"
            }
            # The engine runs with a fixed "-pin nnnn" this UI generated, so
            # the code can be SHOWN - the engine's console (which used to
            # display a random one) stays hidden now. Appended to EVERY
            # running state, not only the idle default: it used to vanish the
            # moment the hero advanced to "iPhone connected" / "Mirroring"
            # (user-reported), exactly when a second phone joining via
            # -nohold takeover still needs it.
            if ($ui.PinCheck.IsChecked -and $script:pinCode) {
                $Detail += "`nPIN: $($script:pinCode)"
            }
            foreach ($k in $script:LockedControls) { $ui[$k].IsEnabled = $false }
            # The one live switch follows the SESSION: a fullscreen engine has
            # no window the frame can wrap (adopting it builds a monitor-wide
            # chassis), so the frame switch sleeps for exactly those sessions
            # and wakes again on Stop.
            $ui.FrameCheck.IsEnabled = -not [bool]$ui.FullscreenCheck.IsChecked
            # Settings recede while live: dimmed *and* disabled, so "locked"
            # reads at a glance instead of only on click.
            Start-Fade -Element $ui.SettingsCard -To 0.4 -Ms 320
            Start-Fade -Element $ui.GlyphLive -To 1 -Ms 420
            Start-Fade -Element $ui.GlyphIdle -To 0 -Ms 300
            Start-Halo
        } else {
            $ui.StartBtn.Tag = ''
            $ui.StartBtnText.Text = 'Start'
            if (-not $Headline) { $Headline = 'Ready' }
            if (-not $Detail -and $script:bonjourDeaf) {
                # Say it BEFORE Start is pressed: a deaf Bonjour makes the
                # receiver start perfectly and stay invisible to every iPhone.
                $Detail = 'Heads-up: Bonjour has no network socket - iPhones cannot see this PC. Run Diagnostics for the fix.'
            }
            if (-not $Detail -and $script:externalEngine) {
                # An engine from start-airplay.ps1 (or a leftover) mirrors
                # happily while this window says "Ready" - name it, or the
                # mismatch reads as a broken UI.
                $Detail = 'A receiver started outside this app is running. It keeps working; this window does not control it.'
            }
            if (-not $Detail)   { $Detail = 'Press Start, then pick this PC from Screen Mirroring' }
            foreach ($k in $script:LockedControls) { $ui[$k].IsEnabled = $true }
            $ui.FrameCheck.IsEnabled = $true
            Start-Fade -Element $ui.SettingsCard -To 1 -Ms 320
            Start-Fade -Element $ui.GlyphLive -To 0 -Ms 300
            Start-Fade -Element $ui.GlyphIdle -To 1 -Ms 420
            Stop-Halo
        }

        $ui.StatusText.Text = $Headline
        $ui.SubStatusText.Text = $Detail
        Invoke-HeroTransition
    }

    function Start-Halo {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 0.45
        $a.To = 1.0
        $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(2.6))
        $a.AutoReverse = $true
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $a.EasingFunction = New-Ease -Mode 'EaseInOut'
        $ui.Halo.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }

    function Stop-Halo {
        # A plain To-animation replaces the repeating one and holds at the end.
        Start-Fade -Element $ui.Halo -To 0 -Ms 420
    }

    function Start-Receiver {
        # Find-UxPlay ran once at startup and is never revalidated. An upgrade,
        # an uninstall, or an ESET quarantine since then leaves a path that no
        # longer resolves; re-resolve and re-point the environment, or throw a
        # sentence the user can act on instead of a raw Win32 string.
        $exe = $null
        if ($script:ux -and $script:ux.Exe) { $exe = $script:ux.Exe }
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            $found = Find-UxPlay
            if (-not $found) {
                throw "The UxPlay engine is gone - uninstalled, moved by an upgrade, or quarantined by antivirus.`n`nRe-run setup.ps1, then restart this app."
            }
            if ($found.Kind -ne 'Cli') { throw (Get-UxPlayIncompatibleMessage -UxPlay $found) }
            $script:ux = $found
            # Without this, PATH and GST_PLUGIN_PATH still point at the old
            # install and the mirror window comes up black.
            Initialize-UxPlayEnvironment -UxPlay $script:ux
            $exe = $found.Exe
        }

        # A real console is required: without one the engine stalls silently
        # before GStreamer initialises. The engine runs as a child of a
        # powershell.exe WRAPPER console (see New-EngineWrapperCommand): it
        # inherits the wrapper's real console, and the wrapper tees the
        # engine's stdout+stderr into the session log - the piece every stalled
        # session was missing. -WindowStyle Hidden: a HIDDEN console is still a
        # real console (verified live - the engine reaches "Initialized server
        # socket(s)" under it), so nothing has to appear in the taskbar. The
        # PIN no longer needs the console either: it is fixed by -pin nnnn and
        # displayed in this window. Do NOT switch to -RedirectStandard*: that
        # suppresses the console entirely and, in PS 5.1, also nulls .ExitCode.
        $script:lastNotes = @()
        $script:pinCode = $null   # fresh PIN per session (Get-EngineArgument regenerates)
        $argTokens = @(Get-EngineArgument)
        $cmdline = ConvertTo-CommandLine $argTokens
        # Before Start-Process: if the sink fell back, say so while the user is
        # still looking at the button they just pressed.
        foreach ($note in $script:lastNotes) {
            [System.Windows.MessageBox]::Show($note, 'AirPlayPC', 'OK', 'Information') | Out-Null
        }

        # The log path is chosen BEFORE launch so the wrapper can append the
        # engine's output under the session-record header. UTF-16LE throughout:
        # Tee-Object writes Unicode in PS 5.1, so the header must match or the
        # file reads back as "u x p l a y". Best-effort: a UI that cannot write
        # a log must still start the receiver.
        $script:logPath = $null
        try {
            $script:logPath = New-PCAirPlayLogPath -Prefix 'airplay-ui'
            @(
                "engine  : $exe"
                "version : $(if ($script:ux.Version) { $script:ux.Version } else { 'unknown' })"
                "plugins : $($script:ux.PluginDir)"
                "lan ip  : $(Get-LanIPAddress)"
                "argv    : $cmdline"
                "started : $(Get-Date -Format 's')"
                "note    : engine output follows, teed by the wrapper console."
                '---'
            ) | Set-Content -LiteralPath $script:logPath -Encoding Unicode
        } catch { $script:logPath = $null }

        $script:proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
            -ArgumentList (New-EngineWrapperCommand -Exe $exe -Tokens $argTokens -LogPath $script:logPath)

        # The framed view rides along with Start: it is the app's face for a
        # mirror session, and forgetting to open it separately used to read as
        # "the mockup is gone". Best-effort - a frame that fails to appear
        # must not fail the receiver. The fullscreen guard is a belt over the
        # switch exclusivity: a fullscreen session must never open the frame.
        if ($ui.FrameCheck.IsChecked -and -not $ui.FullscreenCheck.IsChecked) {
            try { Start-FramedMirror } catch { }
        }

        # Fresh session, fresh state machine.
        $script:enginePid      = $null
        $script:logReadPos     = 0
        $script:videoSeen      = $false
        $script:clientDesc     = $null
        $script:connectedSince = $null
        $script:liveStateKey   = ''
    }

    function Write-SessionEnd {
        # Appended when the engine goes away, so the record shows how it ended
        # rather than only that it started. Must run AFTER the wrapper exits:
        # while its Tee pipeline is alive it holds the log without write
        # sharing, so an early append would throw and be swallowed.
        param([string]$How)
        if (-not $script:logPath) { return }
        try {
            $code = $null
            # The wrapper relays the engine's exit code via 'exit $LASTEXITCODE'.
            try { if ($script:proc) { $code = $script:proc.ExitCode } } catch { }
            @(
                '---'
                "engine pid : $(if ($script:enginePid) { $script:enginePid } else { 'never resolved' })"
                "ended   : $(Get-Date -Format 's')  ($How)"
                "exit    : $(if ($null -ne $code) { $code } else { 'unknown' })"
            ) | Add-Content -LiteralPath $script:logPath -Encoding Unicode
        } catch { }
        $script:logPath = $null
    }

    function Stop-Receiver {
        if (Test-Running) {
            # Kill the ENGINE first: its exit ends the wrapper's Tee pipeline,
            # which flushes and closes the log so the session footer can be
            # appended. Killing only the wrapper can orphan the engine - still
            # mirroring, still advertising, with nothing left tracking it.
            $engineIds = @()
            if ($script:enginePid) { $engineIds = @($script:enginePid) }
            else {
                $engineIds = @(Get-CimInstance Win32_Process -Filter "Name='uxplay.exe' AND ParentProcessId=$($script:proc.Id)" -ErrorAction SilentlyContinue |
                               Select-Object -ExpandProperty ProcessId)
            }
            foreach ($id in $engineIds) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
            try { $script:proc.WaitForExit(3000) | Out-Null } catch { }
            if (-not $script:proc.HasExited) {
                try { $script:proc.Kill(); $script:proc.WaitForExit(2000) | Out-Null } catch { }
            }
        }
        Write-SessionEnd -How 'stopped from the UI'
        $script:proc = $null
        $script:enginePid = $null
    }

    # --- Handlers ----------------------------------------------------------
    # Every handler is wrapped. $ErrorActionPreference is 'Stop', and an
    # exception raised inside a WPF handler is not swallowed: it unwinds out of
    # the dispatcher, tears the window down, SKIPS Add_Closing - so the engine
    # is orphaned, still holding its port and still advertising - and under the
    # hidden-console launcher prints its message to nowhere.

    $ui.StartBtn.Add_Click({
        try {
            if (Test-Running) {
                Stop-Receiver
            } else {
                # Before the conflict prompt, so a bad name is not reported only
                # after the user has been asked to close another app.
                if (-not (Test-DeviceName)) { return }
                if (-not (Resolve-Conflicts)) { return }
                Start-Receiver
                # The crash-safe save moment, and the one that records what is
                # actually in use rather than what was merely clicked through.
                try { Save-UiSettings } catch { }
            }
        } catch {
            # Never blanket-null $script:proc here: if the engine did launch and
            # something after it threw, nulling it orphans a live uxplay.exe the
            # UI can no longer stop. Reset only when it is actually dead.
            $alive = $false
            try { $alive = ($script:proc -and -not $script:proc.HasExited) } catch { $alive = $false }
            if (-not $alive) { $script:proc = $null }
            [System.Windows.MessageBox]::Show(
                "Could not start the receiver:`n`n$($_.Exception.Message)",
                'AirPlayPC', 'OK', 'Error') | Out-Null
        }
        # Outside the try, so a display failure cannot be mistaken for a launch
        # failure and the UI always resyncs to the real process state.
        try { Update-Status } catch { }
    })

    $ui.DoctorBtn.Add_Click({
        try {
            # The one deliberate console in the app: diagnostics ARE console
            # output, and the user explicitly asked for them by clicking.
            $doctor = Join-Path $PSScriptRoot 'doctor.ps1'
            Start-Process powershell -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',"`"$doctor`""
        } catch {
            [System.Windows.MessageBox]::Show(
                "Could not launch diagnostics:`n`n$($_.Exception.Message)",
                'AirPlayPC', 'OK', 'Error') | Out-Null
        }
    })

    # The frame switch is LIVE - deliberately not in LockedControls: checking
    # it opens the framed view even mid-session (it adopts the already-playing
    # video window within seconds), unchecking closes it, and the mirror
    # survives either way - the frame's own Closing handler restores the video
    # window, which is why close is a WM_CLOSE and never a kill.
    #
    # Fullscreen and the frame are MUTUALLY EXCLUSIVE: -fs sizes the video
    # window to the whole monitor, and a chassis wrapped around THAT is a
    # monitor-wide landscape "iPhone" with the portrait mirror floating inside
    # (shipped once, user-reported). Checking either switch clears the other -
    # deliberately ahead of the suppress/self-test guards, so a restored
    # legacy settings file with both on reconciles too; the frame's own
    # Unchecked handler is what closes a live framed view.
    $ui.FullscreenCheck.Add_Checked({
        try { if ($ui.FrameCheck.IsChecked) { $ui.FrameCheck.IsChecked = $false } } catch { }
    })
    $ui.FrameCheck.Add_Checked({
        try { if ($ui.FullscreenCheck.IsChecked) { $ui.FullscreenCheck.IsChecked = $false } } catch { }
        if ($script:suppressFrameEvents -or $script:isSelfTest) { return }
        try { Start-FramedMirror } catch { }
    })
    $ui.FrameCheck.Add_Unchecked({
        if ($script:suppressFrameEvents -or $script:isSelfTest) { return }
        try { [void](Close-FramedMirrorWindow -TimeoutMs 600) } catch { }
    })

    # Chrome handlers stay silent. DragMove legitimately throws "Can only call
    # DragMove when primary mouse button is down" on a fast release or a
    # double-click, and that must not raise a dialog.
    $ui.MinBtn.Add_Click({ try { $window.WindowState = 'Minimized' } catch {} })
    $ui.CloseBtn.Add_Click({ try { $window.Close() } catch {} })
    $ui.TitleBar.Add_MouseLeftButtonDown({
        # DragMove is a modal move loop that still dispatches timer ticks, so
        # the poll's heavy ~12 s tick (IP + Bonjour CIM queries, 100-500 ms on
        # this thread) landing mid-drag froze the window under the cursor
        # (user-reported). Pause the poll for the duration of the drag.
        try { $timer.Stop() } catch {}
        try { $window.DragMove() } catch {}
        finally { try { $timer.Start() } catch {} }
    })

    # Keyboard: Esc closes. Enter fires the primary action through StartBtn's
    # IsDefault - handling Enter here as well would fire it twice.
    $window.Add_KeyDown({
        param($s, $e)
        try {
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $e.Handled = $true
                $window.Close()
            }
        } catch { }
    })

    $window.Add_Loaded({
        try {
            # Defaults-then-saved-state runs HERE, not at build time: the
            # switch templates are live now, so a restored "on" actually plays
            # its Checked storyboard instead of drawing an off-looking switch
            # that is secretly on. suppressFrameEvents keeps the restore from
            # opening/closing the frame as a side effect - the deliberate
            # launch follows, once, after the state is final.
            $script:suppressFrameEvents = $true
            $ui.FrameCheck.IsChecked = $true      # default: the framed view is the app's face
            if (-not $script:isSelfTest) { Restore-UiSettings }
            $script:suppressFrameEvents = $false
            if ($ui.FrameCheck.IsChecked -and -not $script:isSelfTest) {
                try { Start-FramedMirror } catch { }
            }

            Sync-Segments
            $ui.StartBtn.Focus() | Out-Null
            Invoke-HeroTransition

            # ResizeMode is CanMinimize and there is no system chrome, so a
            # window taller than the work area has no way back on screen. This
            # bites at display scaling rather than resolution: a 1366x768 laptop
            # at 125% has only ~545 DIPs of work area.
            $wa = [System.Windows.SystemParameters]::WorkArea
            if ($window.ActualHeight -gt $wa.Height) {
                $f = [Math]::Max(0.7, ($wa.Height - 12) / $window.ActualHeight)
                $window.Content.LayoutTransform =
                    New-Object System.Windows.Media.ScaleTransform $f, $f
                $window.UpdateLayout()
                $window.Top = $wa.Top + [Math]::Max(0, ($wa.Height - $window.ActualHeight) / 2)
            }
        } catch { }
    })

    # This window's whole job is to be started and then minimised, so don't
    # leave a Forever storyboard compositing behind a minimised window.
    $window.Add_StateChanged({
        try {
            if ($window.WindowState -eq 'Minimized') {
                Stop-Halo
                # Minimise-to-tray via ShowInTaskbar, NOT $window.Hide():
                # this window runs under ShowDialog, and hiding a dialog
                # window ends its loop - the app would simply exit (the same
                # trap the frame's test harness documents).
                if ($script:notifyIcon) { $window.ShowInTaskbar = $false }
            } else {
                $window.ShowInTaskbar = $true
                if (Test-Running) { Start-Halo }
            }
        } catch { }
    })

    # --- Tray icon ----------------------------------------------------------
    # Minimise sends the app to the tray; a left-click brings it back; Exit
    # runs the normal close (engine and frame go with it - the one rule).
    # Skipped under -SelfTest so an unattended run never strands a tray icon,
    # and skipped without the .ico - polish must never block startup.
    $script:notifyIcon = $null
    $script:trayRestore = {
        try {
            $window.ShowInTaskbar = $true
            $window.WindowState = 'Normal'
            [void]$window.Activate()
        } catch { }
    }
    if (-not $SelfTest -and (Test-Path -LiteralPath $script:appIconPath)) {
        try {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
            $script:notifyIcon.Icon = New-Object System.Drawing.Icon $script:appIconPath
            $script:notifyIcon.Text = 'iPhone Mirror for Windows'
            $script:notifyIcon.Visible = $true

            $script:notifyIcon.add_MouseClick({
                param($s, $e)
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $script:trayRestore }
            })

            $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
            $trayOpen = $trayMenu.Items.Add('Open iPhone Mirror')
            $trayOpen.Font = New-Object System.Drawing.Font $trayOpen.Font, ([System.Drawing.FontStyle]::Bold)
            $trayOpen.add_Click({ & $script:trayRestore })
            [void]$trayMenu.Items.Add('-')
            $trayExit = $trayMenu.Items.Add('Exit')
            $trayExit.add_Click({ try { $window.Close() } catch { } })
            $script:notifyIcon.ContextMenuStrip = $trayMenu
        } catch {
            if ($script:notifyIcon) { try { $script:notifyIcon.Dispose() } catch { }; $script:notifyIcon = $null }
        }
    }

    $window.Add_Closing({
        # Closing the app stops mirroring AND closes the framed view - one
        # predictable rule: nothing of the app stays behind. The frame goes
        # via WM_CLOSE (its Closing handler restores the video window first);
        # it used to survive the UI and sit there as an orphaned chassis.
        try { Stop-Receiver } catch { }
        try { Save-UiSettings } catch { }
        try { [void](Close-FramedMirrorWindow) } catch { }
        try { $timer.Stop() } catch { }
    })

    # --- Poll: engine alive? network back? ---------------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1.5)
    $timer.Add_Tick({
        try {
            # Before the early return below, or the exit tick skips it.
            # Get-LanIPAddress costs 50-350 ms on the UI thread, hence ~12 s.
            $script:ipTicks++
            if ($script:ipTicks -ge 8) {
                $script:ipTicks = 0
                Update-IpFooter
                # Same ~12 s cadence: Bonjour can go deaf mid-session (an Apple
                # Devices helper steals the 5353 socket whenever the service
                # restarts under it - see Get-BonjourSocketState).
                try { $script:bonjourDeaf = ((Get-BonjourSocketState).State -eq 'Deaf') } catch { }

                # An engine this UI did not start (start-airplay.ps1, or a
                # leftover) mirrors happily while the hero says "Ready" - that
                # mismatch used to read as a broken UI, so name it.
                if (-not (Test-Running)) {
                    $ext = (@(Get-UxPlayEngineProcess).Count -gt 0)
                    if ($ext -ne $script:externalEngine) {
                        $script:externalEngine = $ext
                        Update-Status
                    }
                } elseif ($script:externalEngine) {
                    $script:externalEngine = $false
                }

                # If the frame was closed by hand (its window has its own X),
                # the switch must follow reality rather than claim it is on.
                # The grace period covers a frame still compiling its way up.
                if ($ui.FrameCheck.IsChecked -and -not (Test-FramedMirrorRunning)) {
                    $grace = $script:frameLaunchedAt -and (((Get-Date) - $script:frameLaunchedAt).TotalSeconds -lt 20)
                    if (-not $grace) {
                        $script:suppressFrameEvents = $true
                        $ui.FrameCheck.IsChecked = $false
                        $script:suppressFrameEvents = $false
                    }
                }
            }

            if ($script:proc -and $script:proc.HasExited) {
                # Read the code BEFORE dropping the handle. With the console
                # gone this is the only evidence a crashed engine leaves, and it
                # used to be discarded.
                $code = $script:proc.ExitCode
                Write-SessionEnd -How 'exited on its own'
                # A killed wrapper orphans its engine child, which keeps
                # mirroring and advertising with nothing left tracking it.
                if ($script:enginePid) {
                    $orphan = Get-Process -Id $script:enginePid -ErrorAction SilentlyContinue
                    if ($orphan -and $orphan.ProcessName -eq 'uxplay') {
                        try { $orphan.Kill() } catch { }
                    }
                }
                $script:proc = $null
                $script:enginePid = $null
                if ($null -ne $code -and $code -ne 0) {
                    # Deliberately no log path in this string: -SelfTest asserts
                    # the sub-status cannot grow the window, and a full path is
                    # unbounded. The record is in %LOCALAPPDATA%\pcairplay.
                    Update-Status -Headline 'Stopped' -Detail "The engine exited with code $code. Run .\start-airplay.ps1 in a console to see what it printed."
                } else {
                    Update-Status -Headline 'Stopped' -Detail 'The receiver exited on its own - run Diagnostics if that was unexpected.'
                }
                return
            }

            # Live session state: engine sockets + engine log -> hero text.
            Update-SessionState
        } catch {
            # A throw here would fire again every 1.5 s. Report once, in the
            # card rather than a dialog, and stop polling.
            try { $timer.Stop() } catch { }
            try {
                $ui.StatusText.Text = 'Stopped'
                $ui.SubStatusText.Text = "Status polling failed: $($_.Exception.Message)"
            } catch { }
        }
    })
    $timer.Start()

    Update-Status

    if ($SelfTest) {
        $timer.Stop()

        # The shipped icon must actually apply - a bad .ico regenerated by
        # tools/make-icon.ps1 would otherwise surface as a silent fallback to
        # the PowerShell taskbar icon.
        if ((Test-Path -LiteralPath $script:appIconPath) -and -not $window.Icon) {
            throw 'pcairplay.ico exists but the window icon was not applied.'
        }

        # Select the second segment BEFORE layout, so the SizeChanged handler
        # has a non-default position to place the thumb at and places it without
        # an animation - the result is then readable without pumping the
        # dispatcher.
        $ui.ModeSync.IsChecked = $true

        # Lay the tree out for real. Measuring the Window is a no-op while it has
        # no HWND, so measure its content: that is what applies every
        # ControlTemplate and runs every layout-driven handler. Deliberately NOT
        # wrapped in try/catch - a handler that throws during layout is exactly
        # what this test exists to catch.
        $w = $window.Width
        $root = $window.Content
        $root.Measure((New-Object System.Windows.Size $w, 4000))
        $measured = $root.DesiredSize.Height
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $w, $measured))
        $root.UpdateLayout()

        if ($measured -le 0) { throw 'Window content measured to zero height.' }

        # Segmented-control geometry, end to end. Checking the POSITION and not
        # just the width is what proves the handler pipeline ran: a handler that
        # never fires leaves the thumb at x=0 at full track width, and the
        # control still renders perfectly happily.
        if ($ui.ModeGrid.ActualWidth -le 0) { throw 'Segmented control never got laid out.' }
        $expectW = $ui.ModeGrid.ActualWidth / 2
        if ([Math]::Abs($ui.ModeThumb.Width - $expectW) -gt 0.5) {
            throw "Segment thumb width $($ui.ModeThumb.Width), expected $expectW."
        }
        if ([Math]::Abs($ui.ModeThumb.RenderTransform.X - $expectW) -gt 0.5) {
            throw "Segment thumb at x=$($ui.ModeThumb.RenderTransform.X), expected $expectW."
        }

        # The sub-status line must not change the window height when it grows.
        # That growth is the window resizing out from under the pointer that has
        # just pressed Start. Assert the genuine worst case the field can
        # produce, not a sample: MaxLength characters of the widest glyph, plus
        # the PIN line. Anything narrower is covered by construction.
        $widest = 'W' * $ui.NameBox.MaxLength
        $ui.SubStatusText.Text = "Control Center > Screen Mirroring > '$widest'`nPIN: 8888"
        $root.UpdateLayout()
        $grown = $root.DesiredSize.Height
        $ui.SubStatusText.Text = 'Press Start, then pick this PC from Screen Mirroring'
        $root.UpdateLayout()
        if ([Math]::Abs($grown - $measured) -gt 0.5) {
            throw "Worst-case sub-status resizes the window: $measured -> $grown."
        }

        # Drive the remaining animated paths. A parse check alone would not catch
        # a frozen transform or a bad Storyboard target name; both only throw
        # when they actually run, and they throw synchronously here.
        $ui.Res1080.IsChecked = $true
        $ui.Fps30.IsChecked = $true
        $ui.FullscreenCheck.IsChecked = $true    # switch Checked storyboard
        $ui.PinCheck.IsChecked = $true
        $ui.ShareSafeCheck.IsChecked = $true
        $ui.ShareSafeCheck.IsChecked = $false
        $ui.FullscreenCheck.IsChecked = $false   # switch Unchecked storyboard
        Sync-Segments -Animate
        Update-Status -Headline 'Discoverable' -Detail 'selftest'
        Update-Status
        $ui.StartBtn.Tag = 'running'; $ui.StartBtn.Tag = ''
        # Back to defaults, so the command line printed below is the one a
        # freshly opened window would actually launch.
        $ui.ModeLow.IsChecked = $true
        $ui.Res1440.IsChecked = $true
        $ui.Fps60.IsChecked = $true
        $ui.PinCheck.IsChecked = $false
        $ui.ShareSafeCheck.IsChecked = $false
        $root.UpdateLayout()

        # --- argv assertions ---------------------------------------------
        # This block used to print the command line and assert nothing about it,
        # which is how the UI's argv drifted from start-airplay.ps1 unnoticed.
        #
        # The regression that actually shipped: "-s ${res}@${fps}" wired the fps
        # choice into the display REFRESH RATE. Pick 30 fps and assert the '@r'
        # half is still 60.
        $ui.Fps30.IsChecked = $true
        $a = @(Get-EngineArgument)
        $sIdx = [Array]::IndexOf($a, '-s')
        if ($sIdx -lt 0) { throw 'argv has no -s.' }
        if ($a[$sIdx + 1] -ne '2560x1440@60') {
            throw "-s is '$($a[$sIdx + 1])', expected '2560x1440@60' - refresh rate must not follow -Fps."
        }
        # Every segment choice must reach -s. There is deliberately nothing
        # above 1440p: advertising 3840x2160 made the phone hold the RTSP
        # connection and never open the data connection (observed live twice,
        # iOS 26.5.2).
        if ($null -ne $window.FindName('Res4K')) { throw 'Res4K is back - read the resolution comment first.' }
        $ui.Res1080.IsChecked = $true
        $a2 = @(Get-EngineArgument)
        if ($a2[[Array]::IndexOf($a2, '-s') + 1] -ne '1920x1080@60') { throw '1080p did not reach -s.' }
        $ui.Res1440.IsChecked = $true
        $fIdx = [Array]::IndexOf($a, '-fps')
        if ($fIdx -lt 0 -or [string]$a[$fIdx + 1] -ne '30') {
            throw "-fps is '$($a[$fIdx + 1])', expected 30."
        }
        $ui.Fps60.IsChecked = $true

        # Share-safe must reach the engine as a sink swap, not be silently
        # dropped the way it was when the UI built its own argv.
        $ui.ShareSafeCheck.IsChecked = $true
        $vs = @(Get-EngineArgument)
        $vIdx = [Array]::IndexOf($vs, '-vs')
        if ($script:ux -and $script:ux.PluginDir -and
            (Test-Path -LiteralPath (Join-Path $script:ux.PluginDir 'libgstopengl.dll'))) {
            if ($vIdx -lt 0 -or $vs[$vIdx + 1] -ne 'glimagesink') {
                throw "Share-safe did not select glimagesink (got '$(if ($vIdx -ge 0) { $vs[$vIdx + 1] } else { 'no -vs' })')."
            }
        }
        $ui.ShareSafeCheck.IsChecked = $false

        # PIN mode: the argv must carry the FIXED code this UI displays - a
        # bare -pin makes the engine invent a random one the UI cannot know,
        # which is exactly the "go read the console" experience this replaces.
        $ui.PinCheck.IsChecked = $true
        $pa = @(Get-EngineArgument)
        $pIdx = [Array]::IndexOf($pa, '-pin')
        if ($pIdx -lt 0) { throw 'PIN mode did not reach the argv.' }
        if ([string]$pa[$pIdx + 1] -notmatch '^\d{4}$') {
            throw "-pin carries '$($pa[$pIdx + 1])' instead of a fixed 4-digit code."
        }
        if ([string]$pa[$pIdx + 1] -ne $script:pinCode) {
            throw 'The PIN in the argv is not the PIN the UI would display.'
        }
        if ([Array]::IndexOf($pa, '-reg') -lt 0) {
            throw '-reg is missing - the phone would be re-challenged on every connection.'
        }

        # The PIN must survive state changes. It used to ride only the idle
        # "Discoverable" default and vanished the moment the hero advanced to
        # "iPhone connected" / "Mirroring" (user-reported) - the exact moment
        # a second phone joining via -nohold takeover still needs it. A fake
        # live proc drives Update-Status down its running branch.
        $script:proc = [pscustomobject]@{ HasExited = $false }
        try {
            Update-Status -Headline 'Mirroring' -Detail 'The iPhone is connected and video is live.'
            if ($ui.SubStatusText.Text -notmatch "PIN: $($script:pinCode)") {
                throw 'The PIN left the sub-status when the state advanced to Mirroring.'
            }
        } finally { $script:proc = $null }
        Update-Status
        $ui.PinCheck.IsChecked = $false
        $script:pinCode = $null

        # The frame switch is the one deliberately-live control: locking it
        # would make "open/close the framed view mid-session" impossible.
        if ($script:LockedControls -contains 'FrameCheck') {
            throw 'FrameCheck is in LockedControls - the frame switch must stay usable while running.'
        }

        # Fullscreen and the frame are mutually exclusive - both on wraps the
        # fullscreen video window in a monitor-wide chassis (shipped once).
        $ui.FrameCheck.IsChecked = $true
        $ui.FullscreenCheck.IsChecked = $true
        if ($ui.FrameCheck.IsChecked) { throw 'Checking Fullscreen did not switch the frame off.' }
        $ui.FrameCheck.IsChecked = $true
        if ($ui.FullscreenCheck.IsChecked) { throw 'Checking the frame did not switch fullscreen off.' }
        # Mid-session the frame switch stays live EXCEPT in a fullscreen
        # session, where flipping it on would adopt the fullscreen window.
        $ui.FrameCheck.IsChecked = $false
        $ui.FullscreenCheck.IsChecked = $true
        $script:proc = [pscustomobject]@{ HasExited = $false }
        try {
            Update-Status
            if ($ui.FrameCheck.IsEnabled) { throw 'The frame switch stayed live during a fullscreen session.' }
        } finally { $script:proc = $null }
        $ui.FullscreenCheck.IsChecked = $false
        Update-Status
        if (-not $ui.FrameCheck.IsEnabled) { throw 'The frame switch did not wake up after the fullscreen session.' }
        $ui.FrameCheck.IsChecked = $true

        # A name that looks like an option must be rejected, not passed through.
        # Resolve-UxPlayDeviceName is asserted directly: Test-DeviceName raises a
        # modal dialog, which cannot run unattended.
        if (-not (Resolve-UxPlayDeviceName -Name '-Demo').Error) {
            throw 'A device name starting with "-" was accepted.'
        }
        if ((Resolve-UxPlayDeviceName -Name 'Demo\').Name -ne 'Demo') {
            throw 'Trailing backslash was not stripped from the device name.'
        }
        $root.UpdateLayout()

        # --- session-state machine ---------------------------------------
        # Pure inputs -> the exact states the hero shows; no engine needed.
        $st = Resolve-SessionState -Established 0 -VideoSeen $false -ConnectedSeconds 0 -ClientDesc $null -BonjourDeaf $false
        if ($st.Key -ne 'idle') { throw "0 connections classified as '$($st.Key)', expected idle." }
        $st = Resolve-SessionState -Established 0 -VideoSeen $false -ConnectedSeconds 0 -ClientDesc $null -BonjourDeaf $true
        if ($st.Key -ne 'deaf' -or $st.Headline -ne 'Not discoverable') { throw 'A deaf Bonjour did not surface as Not discoverable.' }
        $st = Resolve-SessionState -Established 1 -VideoSeen $false -ConnectedSeconds 3 -ClientDesc $null -BonjourDeaf $false
        if ($st.Key -ne 'connecting') { throw "RTSP-only at 3s classified as '$($st.Key)', expected connecting." }
        $st = Resolve-SessionState -Established 1 -VideoSeen $false -ConnectedSeconds 20 -ClientDesc 'iPhone (iPhone16,1)' -BonjourDeaf $false
        if ($st.Key -ne 'stalled') { throw "RTSP-only at 20s classified as '$($st.Key)' - the stall state is the point of this machine." }
        $st = Resolve-SessionState -Established 1 -VideoSeen $true -ConnectedSeconds 20 -ClientDesc $null -BonjourDeaf $false
        if ($st.Key -ne 'mirroring') { throw 'VideoSeen did not classify as mirroring.' }
        $st = Resolve-SessionState -Established 2 -VideoSeen $false -ConnectedSeconds 1 -ClientDesc $null -BonjourDeaf $false
        if ($st.Key -ne 'mirroring') { throw 'A second (data) connection did not classify as mirroring.' }

        # Every state's detail must fit the reserved sub-status block: growing
        # the window mid-session is the regression MinHeight exists to prevent.
        $stateProbes = @(
            (Resolve-SessionState -Established 1 -VideoSeen $false -ConnectedSeconds 20 -ClientDesc 'iPhone (iPhone16,1)' -BonjourDeaf $false).Detail
            (Resolve-SessionState -Established 1 -VideoSeen $true -ConnectedSeconds 9 -ClientDesc 'iPhone (iPhone16,1)' -BonjourDeaf $false).Detail
            (Resolve-SessionState -Established 0 -VideoSeen $false -ConnectedSeconds 0 -ClientDesc $null -BonjourDeaf $true).Detail
            'Heads-up: Bonjour has no network socket - iPhones cannot see this PC. Run Diagnostics for the fix.'
            'A receiver started outside this app is running. It keeps working; this window does not control it.'
            # The PIN line rides every running state, so the true worst case
            # is the longest state detail PLUS the PIN line.
            ((Resolve-SessionState -Established 1 -VideoSeen $false -ConnectedSeconds 20 -ClientDesc 'iPhone (iPhone16,1)' -BonjourDeaf $false).Detail + "`nPIN: 8888")
        )
        foreach ($probe in $stateProbes) {
            $ui.SubStatusText.Text = $probe
            $root.UpdateLayout()
            if ($root.DesiredSize.Height - $measured -gt 0.5) {
                throw "Session-state text resizes the window: '$probe'"
            }
        }
        $ui.SubStatusText.Text = 'Press Start, then pick this PC from Screen Mirroring'
        $root.UpdateLayout()

        # --- wrapper launch ----------------------------------------------
        # Decode what Start-Receiver would actually hand powershell.exe: the
        # engine path, every token, the tee target and the exit-code relay must
        # all survive the encoding - including embedded quotes.
        $wl = @(New-EngineWrapperCommand -Exe 'C:\x\uxplay.exe' -Tokens @('-n', 'Demo PC', '-nh') -LogPath "C:\t\o'brien.log")
        if ($wl[-2] -ne '-EncodedCommand') { throw 'Wrapper launch is not using -EncodedCommand.' }
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($wl[-1]))
        foreach ($frag in @("& 'C:\x\uxplay.exe' @('-n', 'Demo PC', '-nh')",
                            "Tee-Object -FilePath 'C:\t\o''brien.log' -Append",
                            'exit $LASTEXITCODE')) {
            if (-not $decoded.Contains($frag)) { throw "Wrapper command lost '$frag':`n$decoded" }
        }

        # --- settings round-trip -----------------------------------------
        # What Save writes, Restore must apply - and an invalid saved name
        # must fall back rather than smuggle a rejected value past the Start
        # path's validation. Runs against a temp file: -SelfTest must never
        # touch the real settings.
        $tmpS = Join-Path $env:TEMP "pcairplay-ui-selftest-$PID.json"
        try {
            $ui.NameBox.Text = 'RoundTrip'
            $ui.Res1080.IsChecked = $true
            $ui.Fps30.IsChecked = $true
            $ui.ModeSync.IsChecked = $true
            $ui.ShareSafeCheck.IsChecked = $true
            $ui.FrameCheck.IsChecked = $false
            Save-UiSettings -Path $tmpS
            $ui.NameBox.Text = 'Overwritten'
            $ui.Res1440.IsChecked = $true
            $ui.Fps60.IsChecked = $true
            $ui.ModeLow.IsChecked = $true
            $ui.ShareSafeCheck.IsChecked = $false
            $ui.FrameCheck.IsChecked = $true
            Restore-UiSettings -Path $tmpS
            if ($ui.NameBox.Text -ne 'RoundTrip' -or -not $ui.Res1080.IsChecked -or
                -not $ui.Fps30.IsChecked -or -not $ui.ModeSync.IsChecked -or
                -not $ui.ShareSafeCheck.IsChecked -or $ui.FrameCheck.IsChecked) {
                throw 'UI settings did not survive a save/restore round-trip.'
            }
            Set-Content -LiteralPath $tmpS -Value '{"Name":"-Demo","Resolution":"1080"}' -Encoding UTF8
            $ui.NameBox.Text = 'Kept'
            Restore-UiSettings -Path $tmpS
            if ($ui.NameBox.Text -ne 'Kept') { throw 'An invalid saved name was applied instead of rejected.' }
        } finally {
            Remove-Item -LiteralPath $tmpS -Force -ErrorAction SilentlyContinue
        }
        # Back to defaults, so the command line printed below is the one a
        # freshly opened window would actually launch.
        $ui.NameBox.Text = $env:COMPUTERNAME
        $ui.ModeLow.IsChecked = $true
        $ui.Res1440.IsChecked = $true
        $ui.Fps60.IsChecked = $true
        $ui.FullscreenCheck.IsChecked = $false
        $ui.ShareSafeCheck.IsChecked = $false
        $ui.PinCheck.IsChecked = $false
        $ui.FrameCheck.IsChecked = $true

        # Print the command line the engine would actually get, so a quoting
        # regression is visible without launching anything.
        $cmdline = ConvertTo-CommandLine (Get-EngineArgument)
        $engine  = if ($script:ux -and $script:ux.Exe) { $script:ux.Exe } else { '(none)' }
        $wa      = [System.Windows.SystemParameters]::WorkArea

        Write-Host ("SelfTest OK: XAML parsed, all {0} elements bound, templates applied" -f $boundCount)
        Write-Host ("  window      {0:N0}x{1:N0}   (work area {2:N0}x{3:N0})" -f $w, $measured, $wa.Width, $wa.Height)
        Write-Host ("  seg thumb   {0:N1}px at x={1:N1}" -f $ui.ModeThumb.Width, $ui.ModeThumb.RenderTransform.X)
        Write-Host ("  sub-status  idle {0:N0}px / worst case {1:N0}px - no resize on Start" -f $measured, $grown)
        Write-Host ("  engine      {0}" -f $engine)
        Write-Host ("  command     {0}" -f $cmdline)
        exit 0
    }

    # ShowDialog in try/finally: cleanup must not depend on Add_Closing, which an
    # abnormal dispatcher unwind skips entirely. Stop-Receiver is idempotent, so
    # running it from both paths is harmless.
    try {
        $window.ShowDialog() | Out-Null
    } finally {
        try { Stop-Receiver } catch { }
        try { [void](Close-FramedMirrorWindow) } catch { }
        try { $timer.Stop() } catch { }
        # Explorer keeps a dead tray icon until it is hovered; dispose, don't
        # rely on process exit.
        try { if ($script:notifyIcon) { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() } } catch { }
    }

} catch {
    $script:ExitCode = 1
    $detail = $_.Exception.Message
    if ($SelfTest) {
        # Must stay non-modal: -SelfTest runs unattended.
        Write-Host "SelfTest FAILED: $detail"
        Write-Host $_.ScriptStackTrace
    } else {
        [System.Windows.MessageBox]::Show(
            "AirPlayPC hit an unexpected error and has to close:`n`n$detail",
            'AirPlayPC', 'OK', 'Error') | Out-Null
    }
}

exit $script:ExitCode
