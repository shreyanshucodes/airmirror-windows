<#
.SYNOPSIS
    Wraps the live UxPlay mirror window in an iPhone-style device frame -
    black chassis, rounded screen corners, side buttons.

.DESCRIPTION
    UxPlay's video window is a bare GStreamer output with a title bar. This
    script dresses it up to look like the iOS Simulator, without touching the
    engine: it finds the video window, strips its borders, and glues two WPF
    windows around it.

    Three top-level windows, bottom to top:

      1. The BEZEL (WPF, per-pixel transparent): chassis, titanium rim, side
         buttons, drop shadow, and the "waiting" placeholder.
      2. The VIDEO window (UxPlay's own, foreign process): caption and thick
         frame stripped, positioned into the bezel's screen slot.
      3. The OVERLAY (WPF, transparent): the perimeter ring mask drawn OVER
         the video - and, because it covers the video, also the frame's INPUT
         surface: mouse wheel resizes, left-drag moves, right-click opens the
         scale menu. It carries a 1/255-alpha sheet, because a layered window
         hit-tests per pixel and a fully transparent hole would send the wheel
         to the ENGINE's window (which ignores it) - that is why resize
         "worked" only until the first attach. Clicks cost nothing to steal:
         UxPlay does not forward touches to the phone.
         (A fake Dynamic Island used to be drawn here; removed - the real one
         arrives inside the mirrored image, and two pills look wrong.)

    Why not one window: a WPF window with AllowsTransparency=True is a layered
    window, and layered windows do not render child HWNDs at all - a reparented
    video window would simply be invisible. So nothing is reparented. Instead
    the stack is glued with OWNERSHIP (GWLP_HWNDPARENT): the video is owned by
    the bezel and the overlay is owned by the video, so Windows itself keeps
    the z-order video-above-bezel and overlay-above-video no matter which of
    them gets activated. Position is synced from the bezel's LocationChanged.

    The script runs before, during, and after the engine: it polls for the
    video window (which only exists while an iPhone is mirroring), attaches
    when it appears, and returns to the placeholder when it goes away. On
    close it restores the video window's original style, owner and position.

    Drag anywhere on the frame to move. Mouse wheel resizes. Esc closes.
    Right-click for scale presets.

.PARAMETER SelfTest
    Build both windows, assert element binding and layout math, exit without
    showing anything. Exit 0 on success. Run after any edit here.

.PARAMETER Quiet
    Exit silently when another instance already holds the single-instance
    mutex, instead of raising the "already running" MessageBox. The UI passes
    this: it launches the frame opportunistically, and a race with an
    already-running frame is a non-event there, not news worth a modal.

.NOTES
    Screen-sharing this into a call: share the WHOLE SCREEN. Window capture
    would have to capture three separate windows, and the d3d11 sink can
    present through a hardware overlay that window capture reads as black
    (see -ShareSafe in start-airplay.ps1). Desktop capture composites all of
    it correctly, frame and all.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Quiet
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

# For the mutex name, the window title and the log directory - the UI's
# frame-coupling helpers (Test-FramedMirrorRunning, Close-FramedMirrorWindow)
# key on exactly these, so they must have one definition. This file runs under
# StrictMode 3: anything called from uxplay-common.ps1 here must stay
# strict-clean.
. (Join-Path $PSScriptRoot 'uxplay-common.ps1')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing, System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class FrameNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int idx);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int idx, IntPtr val);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int ew, int eh);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr rgn, bool redraw);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    public const int SW_RESTORE        = 9;
    public const int SW_SHOWNOACTIVATE = 4;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public const int GWL_STYLE       = -16;
    public const int GWL_EXSTYLE     = -20;
    public const int GWLP_HWNDPARENT = -8;

    public const long WS_CAPTION     = 0x00C00000L;
    public const long WS_THICKFRAME  = 0x00040000L;
    public const long WS_SYSMENU     = 0x00080000L;
    public const long WS_MINIMIZEBOX = 0x00020000L;
    public const long WS_MAXIMIZEBOX = 0x00010000L;

    public const long WS_EX_TRANSPARENT = 0x00000020L;
    public const long WS_EX_LAYERED     = 0x00080000L;
    public const long WS_EX_NOACTIVATE  = 0x08000000L;

    public const uint SWP_NOSIZE       = 0x0001;
    public const uint SWP_NOMOVE       = 0x0002;
    public const uint SWP_NOZORDER     = 0x0004;
    public const uint SWP_NOACTIVATE   = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;

    // The engine's video window: belongs to a uxplay PID, visible, real size,
    // and not a console. GStreamer's d3d11 sink registers class "GSTD3D11",
    // so a GST* class wins outright; anything else is kept as a fallback in
    // case a different sink (glimagesink) is in use.
    public static IntPtr FindVideoWindow(uint[] pids)
    {
        IntPtr best = IntPtr.Zero, fallback = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr lp)
        {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            bool ours = false;
            foreach (uint p in pids) if (p == pid) { ours = true; break; }
            if (!ours) return true;

            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            string cls = sb.ToString();
            if (cls == "ConsoleWindowClass") return true;
            if (cls.StartsWith("CASCADIA")) return true;

            // A minimized window's rect is a 160x28 stub parked at -32000, so
            // the size filter must not run on it - the engine's window is
            // routinely minimized at session start, and rejecting it here is
            // exactly the "frame only works after I maximize it" bug.
            RECT r; GetWindowRect(h, out r);
            if (!IsIconic(h) && (r.Right - r.Left < 60 || r.Bottom - r.Top < 60)) return true;

            if (cls.StartsWith("GST", StringComparison.OrdinalIgnoreCase)) { best = h; return false; }
            if (fallback == IntPtr.Zero) fallback = h;
            return true;
        }, IntPtr.Zero);
        return best != IntPtr.Zero ? best : fallback;
    }
}
"@

# ---------------------------------------------------------------------------
# XAML - the bezel and the overlay. All sizes are placeholders; Update-Layout
# writes the real ones, so the frame can rescale and follow the stream aspect.
# ---------------------------------------------------------------------------

$bezelXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AirPlayPC - Framed Mirror"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="True" SizeToContent="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Grid x:Name="Root" Background="#01000000">
    <Canvas x:Name="ButtonCanvas">
      <Rectangle x:Name="BtnAction"  Width="3.5" RadiusX="1.75" RadiusY="1.75" Fill="#48484D"/>
      <Rectangle x:Name="BtnVolUp"   Width="3.5" RadiusX="1.75" RadiusY="1.75" Fill="#48484D"/>
      <Rectangle x:Name="BtnVolDown" Width="3.5" RadiusX="1.75" RadiusY="1.75" Fill="#48484D"/>
      <Rectangle x:Name="BtnPower"   Width="3.5" RadiusX="1.75" RadiusY="1.75" Fill="#48484D"/>
    </Canvas>
    <Border x:Name="Chassis" Background="#000000" BorderThickness="2.25"
            HorizontalAlignment="Left" VerticalAlignment="Top">
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#5C5C62" Offset="0"/>
          <GradientStop Color="#3A3A3F" Offset="0.25"/>
          <GradientStop Color="#2E2E33" Offset="0.75"/>
          <GradientStop Color="#4A4A50" Offset="1"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="36" ShadowDepth="10"
                          Direction="270" Opacity="0.55"/>
      </Border.Effect>
      <Grid>
        <StackPanel x:Name="PlaceholderPanel" HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock x:Name="WaitTitle" Text="Waiting for the mirror"
                     Foreground="#8E8E93" FontFamily="Segoe UI Semibold" FontSize="15"
                     HorizontalAlignment="Center"/>
          <TextBlock x:Name="WaitDetail" Text="Start the receiver, then mirror from the iPhone"
                     Foreground="#55555A" FontFamily="Segoe UI" FontSize="11.5"
                     Margin="0,7,0,0" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="240"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$overlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AirPlayPC - Frame Overlay"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False"
        UseLayoutRounding="True">
  <!-- The 1/255-alpha background is the INPUT SHEET: a layered window
       hit-tests per pixel, so without it only the ring mask would catch the
       mouse and wheel-resize over the video would go to the engine window. -->
  <Canvas x:Name="OverlayRoot" Background="#01000000">
    <Path x:Name="ScreenMask" Fill="#000000"/>
  </Canvas>
</Window>
'@

# ---------------------------------------------------------------------------
# Build the windows and bind every named element up front, airplay-ui style:
# a renamed x:Name should fail here, not as a null-reference three edits later.
# ---------------------------------------------------------------------------

function New-FrameWindows {
    $bezel   = [System.Windows.Markup.XamlReader]::Parse($bezelXaml)
    $overlay = [System.Windows.Markup.XamlReader]::Parse($overlayXaml)

    $ui = @{}
    $missing = @()
    foreach ($n in 'Root','ButtonCanvas','BtnAction','BtnVolUp','BtnVolDown','BtnPower',
                   'Chassis','PlaceholderPanel','WaitTitle','WaitDetail') {
        $ui[$n] = $bezel.FindName($n)
        if ($null -eq $ui[$n]) { $missing += $n }
    }
    foreach ($n in 'OverlayRoot','ScreenMask') {
        $ui[$n] = $overlay.FindName($n)
        if ($null -eq $ui[$n]) { $missing += $n }
    }
    if ($missing.Count -gt 0) { throw "XAML elements did not bind: $($missing -join ', ')" }

    # The bezel is taskbar-visible; without an explicit icon it wears
    # powershell.exe's. A checkout without the .ico degrades silently.
    $icoPath = Join-Path $PSScriptRoot 'pcairplay.ico'
    if (Test-Path -LiteralPath $icoPath) {
        try {
            $bezel.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                (New-Object System.Uri $icoPath), 'None', 'OnLoad')
        } catch { }
    }

    [pscustomobject]@{ Bezel = $bezel; Overlay = $overlay; UI = $ui }
}

# ---------------------------------------------------------------------------
# Layout. Everything derives from the video size in DIPs and the stream
# aspect, using iPhone 15/16 Pro proportions (logical 393 x 852, screen
# radius ~55, front bezel ~3% of the display width) expressed as ratios of
# the SHORT side.
# ---------------------------------------------------------------------------

$script:Aspect  = 9.0 / 19.5      # until a stream tells us otherwise
# Big by default - the mockup is a presentation surface, and when it is shared
# into a call the viewers get the mockup's pixels, not the stream's: a small
# mockup throws away everything a high -s bought. ~80% of the work area,
# clamped so laptops stay sane. Mouse wheel still rescales at will.
$script:VidH    = [Math]::Max(700.0, [Math]::Min(1150.0,
                      [System.Windows.SystemParameters]::WorkArea.Height * 0.80))
$script:Zoom    = 1.0
$script:Margin  = 40.0            # shadow + button clearance around the chassis

function Get-FrameMetrics {
    param([double]$Aspect, [double]$VidH)

    $vidW  = [Math]::Round($VidH * $Aspect, 1)
    $short = [Math]::Min($vidW, $VidH)

    # The visible black border is Bezel + Inset, so both stay small: a real
    # iPhone 15/16 Pro front bezel is ~3.2% of the display's short side, and
    # the old 4.2% + 1.4% here read as a fat frame that also cropped the
    # image. MaskR must stay ABOVE the stream's baked corner radius
    # (~0.140 * short on Face-ID iPhones) or the black corner crescents
    # return; near the arc tangents it is the inset doing the covering, so
    # that never drops below 2.5.
    $bezel = [Math]::Max(8.0, [Math]::Round(0.031 * $short, 1))
    $maskR = [Math]::Round(0.148 * $short, 1)
    $inset = [Math]::Max(2.5, [Math]::Round(0.007 * $short, 1))
    # Concentric corners: the chassis corner arc shares its center with the
    # mask hole's (OuterR = Bezel + Inset + MaskR), so the border reads the
    # same width at 45 degrees as along the straight edges. The old fixed
    # ScreenR sat ~0.024 * short off concentric - exactly the "corners look
    # thick / don't nest" complaint.
    $screenR = $maskR + $inset
    $m       = $script:Margin

    [pscustomobject]@{
        VidW      = $vidW;  VidH = $VidH
        Bezel     = $bezel; ScreenR = $screenR; OuterR = $screenR + $bezel
        Margin    = $m
        ChassisW  = $vidW + 2 * $bezel
        ChassisH  = $VidH + 2 * $bezel
        WinW      = $vidW + 2 * $bezel + 2 * $m
        WinH      = $VidH + 2 * $bezel + 2 * $m
        Portrait  = ($VidH -gt $vidW)
        # The stream itself bakes the phone's display shape in: rounded-corner
        # content with black filling the rest of the rectangle. The mask is a
        # full perimeter ring whose hole hugs the video edge (Inset) and is a
        # touch rounder than the baked curve, so all of that black lands
        # under it.
        Inset     = $inset
        MaskR     = $maskR
        Rim       = 2.25    # must match the Chassis BorderThickness in XAML
    }
}

function New-ScreenMaskGeometry {
    param($M)
    # The mask is CHASSIS-shaped, not video-shaped. A square outer boundary
    # pokes out past the chassis' rounded corners (the chassis curve cuts
    # ~0.29*OuterR deep at 45 degrees, the video rectangle sits only one bezel
    # inside), which showed as hard black squares on the desktop. So: outer
    # boundary = the chassis outline inset by the rim (keeping the titanium
    # edge visible), hole = the visible screen. Both rounded.
    $rim   = $M.Rim
    $outer = New-Object System.Windows.Media.RectangleGeometry (
        New-Object System.Windows.Rect $rim, $rim, ($M.ChassisW - 2 * $rim), ($M.ChassisH - 2 * $rim)),
        ($M.OuterR - $rim), ($M.OuterR - $rim)
    $edge  = $M.Bezel + $M.Inset
    $inner = New-Object System.Windows.Media.RectangleGeometry (
        New-Object System.Windows.Rect $edge, $edge, ($M.ChassisW - 2 * $edge), ($M.ChassisH - 2 * $edge)),
        $M.MaskR, $M.MaskR
    New-Object System.Windows.Media.CombinedGeometry ([System.Windows.Media.GeometryCombineMode]::Exclude), $outer, $inner
}

function Update-Layout {
    param($W, $M)   # $W = New-FrameWindows result, $M = Get-FrameMetrics result

    $ui = $W.UI

    $W.Bezel.Width  = $M.WinW
    $W.Bezel.Height = $M.WinH

    $ui.Chassis.Margin       = New-Object System.Windows.Thickness $M.Margin
    $ui.Chassis.Width        = $M.ChassisW
    $ui.Chassis.Height       = $M.ChassisH
    $ui.Chassis.CornerRadius = New-Object System.Windows.CornerRadius $M.OuterR

    # Side buttons: drawn UNDER the chassis, poking out ~2.5 DIPs. Portrait
    # positions are iPhone-ish ratios of the chassis height; in landscape they
    # would sit on the wrong edges, so they are simply hidden.
    $btns = @($ui.BtnAction, $ui.BtnVolUp, $ui.BtnVolDown, $ui.BtnPower)
    if ($M.Portrait) {
        $poke  = 2.5
        $leftX  = $M.Margin - $poke
        $rightX = $M.Margin + $M.ChassisW + $poke - 3.5
        $spec = @(
            @{ B = $ui.BtnAction;  X = $leftX;  Y = 0.185; H = 0.042 }
            @{ B = $ui.BtnVolUp;   X = $leftX;  Y = 0.265; H = 0.073 }
            @{ B = $ui.BtnVolDown; X = $leftX;  Y = 0.352; H = 0.073 }
            @{ B = $ui.BtnPower;   X = $rightX; Y = 0.290; H = 0.115 }
        )
        foreach ($s in $spec) {
            $s.B.Visibility = 'Visible'
            $s.B.Height = [Math]::Round($s.H * $M.ChassisH, 1)
            [System.Windows.Controls.Canvas]::SetLeft($s.B, $s.X)
            [System.Windows.Controls.Canvas]::SetTop($s.B, $M.Margin + [Math]::Round($s.Y * $M.ChassisH, 1))
        }
    } else {
        foreach ($b in $btns) { $b.Visibility = 'Collapsed' }
    }

    # Overlay: sized like the CHASSIS; one rounded ring from rim to screen.
    # No fake Dynamic Island: the real one arrives inside the mirrored image.
    $W.Overlay.Width  = $M.ChassisW
    $W.Overlay.Height = $M.ChassisH
    $ui.ScreenMask.Data = New-ScreenMaskGeometry -M $M
    [System.Windows.Controls.Canvas]::SetLeft($ui.ScreenMask, 0)
    [System.Windows.Controls.Canvas]::SetTop($ui.ScreenMask, 0)
}

# ---------------------------------------------------------------------------
# Position/zoom persistence. The UI now opens and closes this frame with
# itself, which makes "drag it to the right spot again every session" a real
# cost - so the spot and the wheel zoom survive. Strict-clean JSON access:
# under StrictMode 3, touching a property a hand-edited file lost throws.
# ---------------------------------------------------------------------------

function Get-FrameSettingsPath { Join-Path (Get-PCAirPlayLogDirectory) 'frame-settings.json' }

function Save-FrameSettings {
    param(
        [Parameter(Mandatory)][double]$Zoom,
        [Parameter(Mandatory)][double]$Left,
        [Parameter(Mandatory)][double]$Top,
        [string]$Path = (Get-FrameSettingsPath)
    )
    try {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [pscustomobject]@{ Zoom = $Zoom; Left = $Left; Top = $Top } |
            ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch { }
}

function Restore-FrameSettings {
    <#
        Saved values, validated; any field can come back $null and the caller
        falls back to the defaults (work-area zoom, centered position).
    #>
    param([string]$Path = (Get-FrameSettingsPath))
    $out = @{ Zoom = $null; Left = $null; Top = $null }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $out }
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($k in @('Zoom', 'Left', 'Top')) {
            $p = $j.PSObject.Properties[$k]
            if ($p -and $null -ne $p.Value) {
                try { $out[$k] = [double]$p.Value } catch { }
            }
        }
    } catch { }
    if ($null -ne $out.Zoom) {
        # Same clamp as the wheel, so a stale or edited file cannot produce a
        # chassis that is unusably tiny or larger than any screen.
        $out.Zoom = [Math]::Max(0.35, [Math]::Min(1.8, $out.Zoom))
    }
    $out
}

# ---------------------------------------------------------------------------
# Self-test: no engine, no Show - build, bind, and assert the layout math.
# ---------------------------------------------------------------------------

if ($SelfTest) {
    try {
        $w = New-FrameWindows

        # Portrait (iPhone 15 Pro stream, 1179x2556): mask covers the full
        # perimeter with a hole rounder than the stream's baked shape.
        $mp = Get-FrameMetrics -Aspect (1179 / 2556) -VidH 820
        Update-Layout -W $w -M $mp
        if (-not $mp.Portrait) { throw 'Portrait aspect not detected as portrait.' }
        if ($null -eq $w.UI.ScreenMask.Data) { throw 'Screen mask has no geometry.' }
        $b = $w.UI.ScreenMask.Data.Bounds
        # Chassis-shaped, rim inset: covers the whole bezel face but must never
        # exceed the chassis - a square outer boundary is exactly the black
        # corner-overhang bug this mask exists to prevent.
        if ([Math]::Abs($b.Left - $mp.Rim) -gt 0.1 -or
            [Math]::Abs($b.Right - ($mp.ChassisW - $mp.Rim)) -gt 0.1 -or
            [Math]::Abs($b.Bottom - ($mp.ChassisH - $mp.Rim)) -gt 0.1) {
            throw "Screen mask bounds $b do not match the rim-inset chassis $($mp.ChassisW)x$($mp.ChassisH)."
        }
        # Border geometry is two-sided: thin enough not to eat the image
        # (Bezel + Inset IS the visible black border), round enough to keep
        # the stream's baked black corners (~0.140 * short) under the ring,
        # and concentric so the corners read as thick as the edges.
        $short = [Math]::Min($mp.VidW, $mp.VidH)
        if (($mp.Bezel + $mp.Inset) -gt 0.04 * $short) {
            throw "Visible border $($mp.Bezel + $mp.Inset) exceeds 4% of the short side ($short) - the fat-frame look."
        }
        if ($mp.MaskR -lt 0.145 * $short) {
            throw 'Mask hole radius fell below the baked corner radius - black crescents would show.'
        }
        if ($mp.Inset -lt 2.0) {
            throw 'Mask inset too thin to cover the baked corners near their tangents.'
        }
        if ([Math]::Abs($mp.OuterR - ($mp.Bezel + $mp.Inset + $mp.MaskR)) -gt 0.1) {
            throw 'Chassis corner is not concentric with the mask hole corner.'
        }
        if ($w.UI.BtnPower.Visibility -ne 'Visible') { throw 'Power button hidden in portrait.' }
        # The overlay is the frame's input surface (wheel resize, drag): its
        # canvas needs a nonzero-alpha background, or per-pixel hit testing
        # makes everything but the ring click-through and the wheel goes to
        # the engine window again.
        if ($w.UI.OverlayRoot.Background.Color.A -lt 1) { throw 'Overlay input sheet lost its hit-testable background.' }

        # Landscape (rotated phone): the side buttons must disappear.
        $ml = Get-FrameMetrics -Aspect (2556 / 1179) -VidH 420
        Update-Layout -W $w -M $ml
        if ($ml.Portrait) { throw 'Landscape aspect detected as portrait.' }
        if ($w.UI.BtnPower.Visibility -eq 'Visible') { throw 'Buttons shown in landscape.' }

        # The UI's Close-FramedMirrorWindow finds this window by EXACT title;
        # a retitled bezel would silently orphan the frame on every UI close.
        if ($w.Bezel.Title -ne (Get-FramedMirrorWindowTitle)) {
            throw "Bezel title '$($w.Bezel.Title)' does not match Get-FramedMirrorWindowTitle."
        }

        # Settings round-trip through a temp file: what Save writes, Restore
        # must read back validated (and the zoom clamp must hold).
        $tmp = Join-Path $env:TEMP "pcairplay-frame-selftest-$PID.json"
        try {
            Save-FrameSettings -Zoom 1.25 -Left 123.5 -Top -42 -Path $tmp
            $r = Restore-FrameSettings -Path $tmp
            if ($r.Zoom -ne 1.25 -or $r.Left -ne 123.5 -or $r.Top -ne -42) {
                throw "Settings round-trip lost data: $($r | ConvertTo-Json -Compress)"
            }
            Save-FrameSettings -Zoom 99 -Left 0 -Top 0 -Path $tmp
            if ((Restore-FrameSettings -Path $tmp).Zoom -ne 1.8) {
                throw 'An out-of-range saved zoom was not clamped.'
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }

        Write-Host 'SelfTest OK: both windows parsed, all 12 elements bound'
        Write-Host ("  portrait    video {0}x{1}, chassis {2}x{3}, mask r={4} inset {5}" -f
            $mp.VidW, $mp.VidH, $mp.ChassisW, $mp.ChassisH, $mp.MaskR, $mp.Inset)
        Write-Host ("  landscape   video {0}x{1} - buttons collapsed" -f $ml.VidW, $ml.VidH)
        exit 0
    } catch {
        Write-Host "SelfTest FAILED: $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Live mode.
# ---------------------------------------------------------------------------

# Exactly one frame per session: two instances both adopt the same video
# window and fight over it - MoveWindow against MoveWindow, and the chassis
# flip-flops between two aspects as each applies its own measurement (seen
# live 2026-07-20, alternating 0.394/0.459 ticks in frame-debug.log after a
# double launch). The mutex is held for the process lifetime; its name is
# shared via uxplay-common.ps1 because the UI probes it to know whether a
# frame exists at all.
$script:MutexCreated = $false
$script:SingleInstance = New-Object System.Threading.Mutex($true, (Get-FramedMirrorMutexName), ([ref]$script:MutexCreated))
if (-not $script:MutexCreated) {
    if (-not $Quiet) {
        [System.Windows.MessageBox]::Show(
            'The framed mirror is already running - look for its window (it may be behind others).',
            'AirPlayPC', 'OK', 'Information') | Out-Null
    }
    exit 0
}

$w  = New-FrameWindows
$ui = $w.UI

$script:Attached   = $false
$script:VideoHwnd  = [IntPtr]::Zero
$script:SavedStyle = [IntPtr]::Zero
$script:SavedRect  = New-Object FrameNative+RECT
$script:DpiScale   = 1.0
$script:LastRgn    = ''
$script:Candidate  = [IntPtr]::Zero
$script:CandSize   = ''
$script:CandStable = 0
$script:TicksSinceAttach = 0
$script:RestoreTries = 0            # failed SW_RESTOREs on an iconic candidate
$script:BlockedHwnd  = [IntPtr]::Zero   # a window that refused adoption (elevated engine)
$script:PhoneSince   = $null        # first sighting of an established engine connection
$script:MeasureStable = 0           # consecutive aspect measurements that changed nothing
$script:NetLast      = $null        # last Get-NetTCPConnection sample (a CIM call - time-gated)
$script:DebugLog = Join-Path (Get-PCAirPlayLogDirectory) 'frame-debug.log'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $script:DebugLog)
# Append-only forever is a slow leak; one .old generation is plenty of history.
try {
    if ((Test-Path -LiteralPath $script:DebugLog) -and (Get-Item -LiteralPath $script:DebugLog).Length -gt 512KB) {
        Move-Item -LiteralPath $script:DebugLog -Destination "$($script:DebugLog).old" -Force
    }
} catch { }

function Write-FrameLog {
    # One line per EVENT (zoom step, video resize, attach/detach), not per
    # tick. The 2026-07-20 wheel report was undiagnosable because only the
    # aspect measurements left a trace; now the log tells which of
    # zoom -> layout -> MoveWindow actually happened, and what Windows said.
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:DebugLog -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
    } catch { }
}

function Test-FullscreenVideoWindow {
    # A fullscreen mirror (-fs / the UI's Fullscreen switch) must never be
    # adopted: the chassis would be sized to the MONITOR's landscape aspect
    # with the portrait video floating inside it - a monitor-wide "iPhone"
    # (shipped once, user-reported). The UI refuses the combination up front;
    # this guard covers a CLI launch (start-airplay.ps1 -Fullscreen) with the
    # frame running alongside. Fingerprint of d3d11videosink's fullscreen
    # mode: the caption is gone AND the window covers its whole monitor. The
    # windowed engine window always keeps WS_CAPTION until Attach-Video
    # strips it, and by then it is no longer a candidate.
    param([IntPtr]$Hwnd)
    $style = [long][FrameNative]::GetWindowLongPtr($Hwnd, [FrameNative]::GWL_STYLE)
    if (($style -band [FrameNative]::WS_CAPTION) -eq [FrameNative]::WS_CAPTION) { return $false }
    $r = New-Object FrameNative+RECT
    if (-not [FrameNative]::GetWindowRect($Hwnd, [ref]$r)) { return $false }
    $mon = [System.Windows.Forms.Screen]::FromHandle($Hwnd).Bounds
    ($r.Left -le $mon.Left -and $r.Top -le $mon.Top -and
     $r.Right -ge $mon.Right -and $r.Bottom -ge $mon.Bottom)
}

function Get-BezelHwnd   { (New-Object System.Windows.Interop.WindowInteropHelper $w.Bezel).Handle }
function Get-OverlayHwnd { (New-Object System.Windows.Interop.WindowInteropHelper $w.Overlay).Handle }

function Sync-Position {
    # The video slot's top-left corner, in physical pixels. Window.Left/Top are
    # DIPs; MoveWindow wants pixels; the bezel's DPI transform converts.
    if (-not $script:Attached -or -not [FrameNative]::IsWindow($script:VideoHwnd)) { return }
    $m = Get-FrameMetrics -Aspect $script:Aspect -VidH ($script:VidH * $script:Zoom)
    $s = $script:DpiScale
    $x  = [int](($w.Bezel.Left + $m.Margin + $m.Bezel) * $s)
    $y  = [int](($w.Bezel.Top  + $m.Margin + $m.Bezel) * $s)
    $vw = [int]($m.VidW * $s)
    $vh = [int]($m.VidH * $s)
    $sizeChanged = ($script:LastRgn -ne "$vw x $vh")
    $moved = [FrameNative]::MoveWindow($script:VideoHwnd, $x, $y, $vw, $vh, $true)

    if ($sizeChanged) {
        # A resize (wheel zoom, aspect correction) must actually LAND on the
        # engine's window. Verify by reading the rect back; on a mismatch retry
        # once via SetWindowPos, and log what Windows said either way - a
        # silently refused resize (UIPI, a wedged sink thread) is otherwise
        # invisible: the chassis rescales and the video just... stays.
        $err = 0
        if (-not $moved) { $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }
        $rb = New-Object FrameNative+RECT
        [void][FrameNative]::GetWindowRect($script:VideoHwnd, [ref]$rb)
        $rw = $rb.Right - $rb.Left; $rh = $rb.Bottom - $rb.Top
        if ($rw -ne $vw -or $rh -ne $vh) {
            [void][FrameNative]::SetWindowPos($script:VideoHwnd, [IntPtr]::Zero, $x, $y, $vw, $vh,
                ([FrameNative]::SWP_NOZORDER -bor [FrameNative]::SWP_NOACTIVATE))
            [void][FrameNative]::GetWindowRect($script:VideoHwnd, [ref]$rb)
            $rw = $rb.Right - $rb.Left; $rh = $rb.Bottom - $rb.Top
        }
        Write-FrameLog ("sync: video -> {0}x{1} moveok={2} err={3} readback={4}x{5}" -f
            $vw, $vh, $moved, $err, $rw, $rh)

        # Clip the video window itself to rounded corners: its rectangle
        # overhangs the chassis' rounded outline at the corners, and its
        # content there is the stream's baked black. Radius = the screen
        # hole's, with slack; the clipped edge lands under the overlay ring,
        # so GDI-region jaggies are never seen.
        $script:LastRgn = "$vw x $vh"
        $d = [int](2 * ($m.MaskR + $m.Inset + 2) * $s)
        [void][FrameNative]::SetWindowRgn($script:VideoHwnd,
            [FrameNative]::CreateRoundRectRgn(0, 0, $vw + 1, $vh + 1, $d, $d), $true)
    }

    # The overlay is chassis-sized, so it sits at the chassis origin (margin),
    # not at the screen slot.
    $w.Overlay.Left = $w.Bezel.Left + $m.Margin
    $w.Overlay.Top  = $w.Bezel.Top  + $m.Margin
}

function Set-FrameLayout {
    $m = Get-FrameMetrics -Aspect $script:Aspect -VidH ($script:VidH * $script:Zoom)
    Update-Layout -W $w -M $m
    Sync-Position
}

function Measure-StreamAspect {
    <#
        The engine window's own shape is NOT the stream's shape: the window is
        born at the requested -s size and is not reliably resized to the video
        caps, so the sink letterboxes and every window-rect heuristic lies.
        The pixels don't: capture the video area from screen, find the
        non-black content box, and call it letterboxed when one dimension is
        full while the other is not. Returns the content aspect, or $null when
        there is nothing confident to say (no bars, all-dark frame, tiny rect).
    #>
    if (-not $script:Attached -or -not [FrameNative]::IsWindow($script:VideoHwnd)) { return $null }
    $r = New-Object FrameNative+RECT
    if (-not [FrameNative]::GetWindowRect($script:VideoHwnd, [ref]$r)) { return $null }
    $wpx = $r.Right - $r.Left; $hpx = $r.Bottom - $r.Top
    if ($wpx -lt 80 -or $hpx -lt 80) { return $null }

    $bmp = New-Object System.Drawing.Bitmap $wpx, $hpx
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $wpx, $hpx))
    $g.Dispose()
    $bd     = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $wpx, $hpx),
                            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $bd.Stride
    $bytes  = New-Object byte[] ($stride * $hpx)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($bd); $bmp.Dispose()

    # Scan INSIDE our own mask ring, or the measurement eats itself: the ring
    # blacks out ~Inset px on every edge, which shaved the measured "full"
    # dimension to ~0.96 and made the one-dimensional letterbox test reject
    # every real letterbox as "shrunk both ways".
    $m2   = Get-FrameMetrics -Aspect $script:Aspect -VidH ($script:VidH * $script:Zoom)
    $edge = [int][Math]::Ceiling($m2.Inset * $script:DpiScale) + 2
    $scanW = $wpx - 2 * $edge; $scanH = $hpx - 2 * $edge
    if ($scanW -lt 40 -or $scanH -lt 40) { return $null }

    # 96x96 sample grid: <1% granularity, ~9k reads, a few ms.
    $minX = $wpx; $maxX = -1; $minY = $hpx; $maxY = -1
    for ($iy = 0; $iy -lt 96; $iy++) {
        $y = $edge + [int](($scanH - 1) * $iy / 95)
        $rowOff = $y * $stride
        for ($ix = 0; $ix -lt 96; $ix++) {
            $x = $edge + [int](($scanW - 1) * $ix / 95)
            $o = $rowOff + $x * 4
            if ($bytes[$o] -gt 10 -or $bytes[$o + 1] -gt 10 -or $bytes[$o + 2] -gt 10) {
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -le $minX -or $maxY -le $minY) { return $null }
    $cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1

    # Letterboxing is one-dimensional: one axis full, the other cut. Anything
    # else (all-dark content, an overlapping window) is not evidence.
    # 0.985, not 0.97: the sample grid hits the exact scan edges, so a truly
    # full axis measures ~1.0 - but a THIN letterbox does not. Advertised
    # 2560x1440 vs a real 1179x2556 stream leaves the window at ~0.486 against
    # content 0.461: pillars of ~2.4% per side measured 0.976 "full" at the old
    # threshold, so the mismatch was read as no-bars and never corrected - fat
    # black pillars inside the chassis, and the stream's baked corner curve
    # pushed inward where it cannot nest with the mask ring.
    $fullW = ($cw / $scanW) -ge 0.985
    $fullH = ($ch / $scanH) -ge 0.985
    if ($fullW -and $fullH) { return $null }             # no bars - nothing to fix
    if (-not $fullW -and -not $fullH) { return $null }   # shrunk both ways - don't trust it
    # The full dimension really runs to the window edge under the mask; the
    # cut dimension's measured extent is exact (the bars are outside it).
    if ($fullW) { $cw = $wpx } else { $ch = $hpx }
    $aspect = $cw / $ch
    if ($aspect -lt 0.3 -or $aspect -gt 3.5) { return $null }
    $aspect
}

function Attach-Video {
    param([IntPtr]$Hwnd)

    $rect = New-Object FrameNative+RECT
    [void][FrameNative]::GetWindowRect($Hwnd, [ref]$rect)
    $client = New-Object FrameNative+RECT
    [void][FrameNative]::GetClientRect($Hwnd, [ref]$client)
    $cw = $client.Right - $client.Left
    $ch = $client.Bottom - $client.Top
    if ($cw -lt 1 -or $ch -lt 1) { return }

    $script:SavedRect  = $rect
    $script:SavedStyle = [FrameNative]::GetWindowLongPtr($Hwnd, [FrameNative]::GWL_STYLE)

    $strip = [FrameNative]::WS_CAPTION -bor [FrameNative]::WS_THICKFRAME -bor
             [FrameNative]::WS_SYSMENU -bor [FrameNative]::WS_MINIMIZEBOX -bor
             [FrameNative]::WS_MAXIMIZEBOX
    $newStyle = $script:SavedStyle.ToInt64() -band (-bnot $strip)
    [void][FrameNative]::SetWindowLongPtr($Hwnd, [FrameNative]::GWL_STYLE, [IntPtr]$newStyle)

    # Ownership chain: video above bezel, overlay above video - Windows then
    # maintains the sandwich on every activation, no z-order babysitting.
    $bezelH = Get-BezelHwnd
    [void][FrameNative]::SetWindowLongPtr($Hwnd, [FrameNative]::GWLP_HWNDPARENT, $bezelH)
    if ([FrameNative]::GetWindowLongPtr($Hwnd, [FrameNative]::GWLP_HWNDPARENT) -ne $bezelH) {
        # UIPI: an ELEVATED engine's window silently refuses everything this
        # frame does to it. This happened in normal use (UI launched
        # "as administrator" starts an elevated engine) - without this check
        # the frame half-adopts the window and shows an empty chassis with no
        # explanation. Remember the handle so the finder stops re-trying it.
        [void][FrameNative]::SetWindowLongPtr($Hwnd, [FrameNative]::GWL_STYLE, $script:SavedStyle)
        $script:BlockedHwnd = $Hwnd
        $ui.WaitDetail.Text = 'The mirror window rejected the frame - the engine is running as administrator. Close it and start the receiver normally (never elevated).'
        Write-FrameLog ("attach REFUSED (owner set did not stick - elevated engine?) hwnd=0x{0:X}" -f $Hwnd.ToInt64())
        return
    }
    (New-Object System.Windows.Interop.WindowInteropHelper $w.Overlay).Owner = $Hwnd

    [void][FrameNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, 0, 0,
        [FrameNative]::SWP_NOMOVE -bor [FrameNative]::SWP_NOSIZE -bor
        [FrameNative]::SWP_NOZORDER -bor [FrameNative]::SWP_FRAMECHANGED -bor
        [FrameNative]::SWP_NOACTIVATE)

    $script:VideoHwnd = $Hwnd
    $script:Aspect    = $cw / $ch
    $script:Attached  = $true
    $script:TicksSinceAttach = 0
    $script:MeasureStable = 0
    $script:RestoreTries = 0
    $script:PhoneSince   = $null
    Write-FrameLog ("attach: hwnd=0x{0:X} client {1}x{2} aspect {3}" -f
        $Hwnd.ToInt64(), $cw, $ch, [Math]::Round($script:Aspect, 4))

    $ui.PlaceholderPanel.Visibility = 'Collapsed'
    Set-FrameLayout
    $w.Overlay.Show()

    # No-activate, so the overlay never steals focus - but NOT click-through:
    # the overlay is the frame's input surface (wheel resize, drag, scale
    # menu). Stealing the mouse from the video costs nothing, because UxPlay
    # does not forward touches to the phone; with WS_EX_TRANSPARENT here, the
    # wheel went to the ENGINE window and resize only worked before the first
    # attach.
    $oh = Get-OverlayHwnd
    $ex = [FrameNative]::GetWindowLongPtr($oh, [FrameNative]::GWL_EXSTYLE).ToInt64()
    $ex = $ex -bor [FrameNative]::WS_EX_LAYERED -bor [FrameNative]::WS_EX_NOACTIVATE
    [void][FrameNative]::SetWindowLongPtr($oh, [FrameNative]::GWL_EXSTYLE, [IntPtr]$ex)
}

function Detach-Video {
    param([switch]$Restore)
    Write-FrameLog ("detach: restore={0} window alive={1}" -f
        [bool]$Restore, [FrameNative]::IsWindow($script:VideoHwnd))
    if ($Restore -and [FrameNative]::IsWindow($script:VideoHwnd)) {
        $h = $script:VideoHwnd
        [void][FrameNative]::SetWindowRgn($h, [IntPtr]::Zero, $true)
        [void][FrameNative]::SetWindowLongPtr($h, [FrameNative]::GWL_STYLE, $script:SavedStyle)
        [void][FrameNative]::SetWindowLongPtr($h, [FrameNative]::GWLP_HWNDPARENT, [IntPtr]::Zero)
        [void][FrameNative]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0,
            [FrameNative]::SWP_NOMOVE -bor [FrameNative]::SWP_NOSIZE -bor
            [FrameNative]::SWP_NOZORDER -bor [FrameNative]::SWP_FRAMECHANGED -bor
            [FrameNative]::SWP_NOACTIVATE)
        $r = $script:SavedRect
        [void][FrameNative]::MoveWindow($h, $r.Left, $r.Top, $r.Right - $r.Left, $r.Bottom - $r.Top, $true)
    }
    $script:VideoHwnd = [IntPtr]::Zero
    $script:Attached  = $false
    $script:LastRgn   = ''
    $script:MeasureStable = 0
    $w.Overlay.Hide()
    $ui.PlaceholderPanel.Visibility = 'Visible'
}

# --- interactions ----------------------------------------------------------
# Registered on BOTH windows. While attached, the overlay covers the video and
# is the only window under the cursor there (it is deliberately hit-testable -
# see the XAML comment); while waiting, the bezel is. DragMove cannot be used
# from the overlay (it would move the overlay, and position flows bezel ->
# overlay, never back), so the overlay drags the bezel by hand via cursor
# deltas and mouse capture.

function Set-FrameZoom {
    param([int]$Delta)
    $old = $script:Zoom
    $script:Zoom = [Math]::Max(0.35, [Math]::Min(1.8,
        $script:Zoom * $(if ($Delta -gt 0) { 1.06 } else { 1 / 1.06 })))
    if ($old -ne $script:Zoom) {
        Write-FrameLog ("zoom: {0} -> {1} attached={2}" -f
            [Math]::Round($old, 3), [Math]::Round($script:Zoom, 3), $script:Attached)
    }
    Set-FrameLayout
}

$script:OverlayDrag = $null

$ui.Root.Add_MouseLeftButtonDown({ try { $w.Bezel.DragMove() } catch { } })
$w.Bezel.Add_LocationChanged({ Sync-Position })
$w.Bezel.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $w.Bezel.Close() }
})
$w.Bezel.Add_MouseWheel({ param($s, $e) Set-FrameZoom -Delta $e.Delta })
$w.Overlay.Add_MouseWheel({ param($s, $e) Set-FrameZoom -Delta $e.Delta })

$w.Overlay.Add_MouseLeftButtonDown({
    try {
        $p = New-Object FrameNative+POINT
        [void][FrameNative]::GetCursorPos([ref]$p)
        $script:OverlayDrag = @{ X = $p.X; Y = $p.Y; L = $w.Bezel.Left; T = $w.Bezel.Top }
        [void]$w.Overlay.CaptureMouse()
    } catch { $script:OverlayDrag = $null }
})
$w.Overlay.Add_MouseMove({
    if (-not $script:OverlayDrag) { return }
    try {
        $p = New-Object FrameNative+POINT
        [void][FrameNative]::GetCursorPos([ref]$p)
        # Cursor deltas are physical pixels; Window.Left/Top are DIPs.
        $w.Bezel.Left = $script:OverlayDrag.L + ($p.X - $script:OverlayDrag.X) / $script:DpiScale
        $w.Bezel.Top  = $script:OverlayDrag.T + ($p.Y - $script:OverlayDrag.Y) / $script:DpiScale
    } catch { }
})
$w.Overlay.Add_MouseLeftButtonUp({
    $script:OverlayDrag = $null
    try { $w.Overlay.ReleaseMouseCapture() } catch { }
})

$menu = New-Object System.Windows.Controls.ContextMenu
foreach ($pct in 60, 80, 100, 125) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = "Scale $pct%"
    $item.Tag = $pct / 100.0
    $item.Add_Click({ param($s, $e) $script:Zoom = [double]$s.Tag; Set-FrameLayout })
    [void]$menu.Items.Add($item)
}
$close = New-Object System.Windows.Controls.MenuItem
$close.Header = 'Close frame (mirror window survives)'
$close.Add_Click({ $w.Bezel.Close() })
[void]$menu.Items.Add($close)
$ui.Root.ContextMenu = $menu
# Same menu on the overlay: while attached, right-clicks land there.
$ui.OverlayRoot.ContextMenu = $menu

# --- the poll loop ---------------------------------------------------------

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)

function Invoke-FrameTick {
    try {
        if ($script:Attached) {
            if (-not [FrameNative]::IsWindow($script:VideoHwnd)) { Detach-Video; return }
            Sync-Position   # re-glue after any external move
            # Self-heal: the overlay is the ring mask AND the input surface
            # (wheel, drag). If it ever goes missing while attached - e.g.
            # Windows tore it down with a dying owner before the detach ran -
            # wheel-over-the-video dies silently while wheel-over-the-bezel
            # still works, which reads as "resize only resizes the frame".
            if (-not $w.Overlay.IsVisible) {
                $w.Overlay.Show()
                Write-FrameLog 'overlay was hidden while attached - reshown'
            }
            # Periodically check the pixels for letterbox bars: the slot then
            # reshapes to the CONTENT aspect, which both fixes the chassis
            # shape and makes the sink stop drawing bars at all. This is also
            # what tracks a rotated phone.
            $script:TicksSinceAttach++
            # Adaptive cadence: a measurement is a full-window screen grab
            # (GPU readback + a multi-MB bitmap copy + a 9k-pixel scan on the
            # dispatcher thread), so after three consecutive measurements that
            # changed nothing the period stretches ~5 s -> ~10 s. Any
            # correction snaps it back, so a rotated phone is still caught
            # within seconds. Skipped mid-drag: a hitch while the hand is
            # moving is the one moment it would actually be felt.
            $measurePeriod = if ($script:MeasureStable -ge 3) { 14 } else { 7 }
            if ($script:TicksSinceAttach % $measurePeriod -eq 2 -and -not $script:OverlayDrag) {
                # Own try/catch with a log line: the tick's blanket catch{}
                # already hid one measurement bug from us completely.
                try {
                    $meas = Measure-StreamAspect
                    Add-Content -LiteralPath $script:DebugLog -Value ("{0} measure: got={1} current={2}" -f
                        (Get-Date -Format 'HH:mm:ss'), $meas, [Math]::Round($script:Aspect, 4))
                    if ($meas -and ([Math]::Abs($meas - $script:Aspect) / $script:Aspect) -gt 0.03) {
                        $script:Aspect = $meas
                        $script:MeasureStable = 0
                        Set-FrameLayout
                    } else {
                        $script:MeasureStable++
                    }
                } catch {
                    Add-Content -LiteralPath $script:DebugLog -Value ("{0} measure EX: {1}" -f
                        (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
                }
            }
            return
        }

        # Not attached: find a candidate, then WAIT until the engine stops
        # resizing it. The window is born at the REQUESTED -s size (landscape)
        # and only takes the stream's real shape when video caps arrive -
        # attaching on first sight locks that wrong aspect into the chassis.
        # It stays hidden while settling so the bare window never flashes.
        if ($script:Candidate -ne [IntPtr]::Zero -and [FrameNative]::IsWindow($script:Candidate)) {
            if ([FrameNative]::IsIconic($script:Candidate)) {
                # SW_RESTORE on another process's window is refused - silently,
                # from script - when that process is ELEVATED and this one is
                # not (UIPI). Without the counter the frame spins here forever
                # while the video plays minimized, which reads as "mockup shows,
                # no image".
                [void][FrameNative]::ShowWindow($script:Candidate, [FrameNative]::SW_RESTORE)
                $script:RestoreTries++
                if ($script:RestoreTries -gt 4) {
                    $script:BlockedHwnd = $script:Candidate
                    $script:Candidate = [IntPtr]::Zero; $script:CandSize = ''; $script:CandStable = 0
                    $script:RestoreTries = 0
                    $ui.WaitDetail.Text = 'The mirror window will not respond - the engine is probably running as administrator. Close it and start the receiver normally (never elevated).'
                }
                return
            }
            $script:RestoreTries = 0
            if (Test-FullscreenVideoWindow -Hwnd $script:Candidate) {
                # Went fullscreen while settling. Un-hide it (it was hidden
                # for the settle) and blacklist it instead of adopting.
                [void][FrameNative]::ShowWindow($script:Candidate, [FrameNative]::SW_SHOWNOACTIVATE)
                $script:BlockedHwnd = $script:Candidate
                $script:Candidate = [IntPtr]::Zero; $script:CandSize = ''; $script:CandStable = 0
                $ui.WaitDetail.Text = 'The mirror is running fullscreen, so the iPhone frame does not apply. Restart the receiver with Fullscreen off to use the frame.'
                Write-FrameLog 'candidate went fullscreen while settling - not adopting'
                return
            }
            $r = New-Object FrameNative+RECT
            [void][FrameNative]::GetWindowRect($script:Candidate, [ref]$r)
            $size = "$($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
            if ($size -eq $script:CandSize) { $script:CandStable++ } else {
                $script:CandSize = $size; $script:CandStable = 0
            }
            # 5 stable samples at the fast (150 ms) cadence = ~750 ms of
            # holding one size. Stricter in wall-clock terms than the old
            # 2-of-700ms and still under a second: the engine window is born
            # at the requested -s (landscape) and only takes the stream's
            # shape when caps arrive, so attaching on first sight locks the
            # wrong aspect into the chassis.
            if ($script:CandStable -ge 5) {
                [void][FrameNative]::ShowWindow($script:Candidate, [FrameNative]::SW_SHOWNOACTIVATE)
                Attach-Video -Hwnd $script:Candidate
                $script:Candidate = [IntPtr]::Zero; $script:CandSize = ''; $script:CandStable = 0
            } else {
                [void][FrameNative]::ShowWindow($script:Candidate, 0)   # SW_HIDE while settling
            }
            return
        }
        $script:Candidate = [IntPtr]::Zero; $script:CandSize = ''; $script:CandStable = 0
        if ($script:BlockedHwnd -ne [IntPtr]::Zero -and -not [FrameNative]::IsWindow($script:BlockedHwnd)) {
            $script:BlockedHwnd = [IntPtr]::Zero    # the elevated window is gone; try fresh
        }

        $procs = @(Get-Process -Name uxplay -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) {
            $script:PhoneSince = $null
            $ui.WaitDetail.Text = "Engine not running - press Start in AirPlayPC first"
            return
        }

        $hwnd = [FrameNative]::FindVideoWindow([uint32[]]($procs.Id))
        if ($hwnd -ne [IntPtr]::Zero -and $hwnd -eq $script:BlockedHwnd) {
            return    # already told the user why; keep that message on screen
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            if (Test-FullscreenVideoWindow -Hwnd $hwnd) {
                # Never hide or adopt a fullscreen mirror - blacklist it and
                # say why, the same channel the elevated-engine case uses.
                $script:BlockedHwnd = $hwnd
                $ui.WaitDetail.Text = 'The mirror is running fullscreen, so the iPhone frame does not apply. Restart the receiver with Fullscreen off to use the frame.'
                Write-FrameLog ("candidate: hwnd=0x{0:X} is fullscreen - not adopting" -f $hwnd.ToInt64())
                return
            }
            $script:Candidate = $hwnd
            # Hide it in the SAME tick it is first seen: every visible
            # millisecond of the bare window is the "separate window appears
            # for a second, then jumps into the frame" complaint. Iconic
            # windows are left to the restore path above. If the engine is
            # elevated this hide is silently refused, which is fine - the
            # settle loop and blacklist handle that case.
            if (-not [FrameNative]::IsIconic($hwnd)) {
                [void][FrameNative]::ShowWindow($hwnd, 0)   # SW_HIDE
            }
            Write-FrameLog ("candidate: hwnd=0x{0:X} hidden while settling" -f $hwnd.ToInt64())
            return
        }

        # No window yet. An engine holding an ESTABLISHED connection with no
        # video window for this long is the documented stall (RTSP up, data
        # connection never opened) - saying "Receiver is up" while the phone
        # claims to be mirroring reads as a broken frame, so name it and give
        # the phone-side reset that clears it. Time-gated to ~3 s because it
        # is a CIM call and the tick can be running at the fast cadence.
        if (-not $script:NetLast -or ((Get-Date) - $script:NetLast).TotalSeconds -ge 3) {
            $script:NetLast = Get-Date
            $ids = @($procs | Select-Object -ExpandProperty Id)
            $est = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                     Where-Object { $ids -contains $_.OwningProcess }).Count
            if ($est -gt 0) {
                if (-not $script:PhoneSince) { $script:PhoneSince = Get-Date }
            } else { $script:PhoneSince = $null }
        }
        if ($script:PhoneSince -and ((Get-Date) - $script:PhoneSince).TotalSeconds -gt 12) {
            $ui.WaitDetail.Text = 'iPhone is connected but no video is arriving - on the phone, stop Screen Mirroring and start it again'
        } else {
            $ui.WaitDetail.Text = "Receiver is up - mirror from the iPhone and the video lands here"
        }
    } catch { }   # a transient race (window died mid-tick) must not kill the timer
}

$timer.Add_Tick({
    Invoke-FrameTick
    # Adaptive cadence. 700 ms is fine for an attached session or an idle
    # receiver, but it WAS the "separate window appears for a second, then
    # jumps into the frame" flash: the video window sat bare on the desktop
    # for up to two ticks before being hidden and adopted. While a window is
    # imminent (established engine connection, no video yet) or mid-adoption,
    # tick at 150 ms - the bare window now vanishes within ~a screen refresh
    # and lands already dressed inside the chassis.
    $ms = 700
    if (-not $script:Attached -and $script:BlockedHwnd -eq [IntPtr]::Zero -and
        ($script:Candidate -ne [IntPtr]::Zero -or $script:PhoneSince)) { $ms = 150 }
    if ($timer.Interval.TotalMilliseconds -ne $ms) {
        $timer.Interval = [TimeSpan]::FromMilliseconds($ms)
    }
})

$w.Bezel.Add_Closing({
    $timer.Stop()
    Save-FrameSettings -Zoom $script:Zoom -Left $w.Bezel.Left -Top $w.Bezel.Top
    # A candidate mid-stabilization is hidden - closing now must not leave the
    # engine's window invisible forever.
    if ($script:Candidate -ne [IntPtr]::Zero -and [FrameNative]::IsWindow($script:Candidate)) {
        [void][FrameNative]::ShowWindow($script:Candidate, [FrameNative]::SW_SHOWNOACTIVATE)
    }
    Detach-Video -Restore
    $w.Overlay.Close()
})

# --- go --------------------------------------------------------------------

$w.Bezel.Add_SourceInitialized({
    $src = [System.Windows.PresentationSource]::FromVisual($w.Bezel)
    if ($src) { $script:DpiScale = $src.CompositionTarget.TransformToDevice.M11 }
})

$saved = Restore-FrameSettings
if ($null -ne $saved.Zoom) { $script:Zoom = $saved.Zoom }

Set-FrameLayout
$wa = [System.Windows.SystemParameters]::WorkArea
$w.Bezel.Left = $wa.Left + ($wa.Width  - $w.Bezel.Width)  / 2
$w.Bezel.Top  = $wa.Top  + ($wa.Height - $w.Bezel.Height) / 2

# A saved position beats centering - but only while it still lands a usable
# amount of chassis on SOME monitor. A monitor unplugged since the save must
# not strand the frame off every screen with no mouse able to reach it.
if ($null -ne $saved.Left -and $null -ne $saved.Top) {
    $vsL = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vsT = [System.Windows.SystemParameters]::VirtualScreenTop
    $vsR = $vsL + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vsB = $vsT + [System.Windows.SystemParameters]::VirtualScreenHeight
    if ($saved.Left -gt ($vsL - $w.Bezel.Width + 120) -and $saved.Left -lt ($vsR - 120) -and
        $saved.Top  -gt ($vsT - 40) -and $saved.Top -lt ($vsB - 120)) {
        $w.Bezel.Left = $saved.Left
        $w.Bezel.Top  = $saved.Top
    }
}

$timer.Start()
[void]$w.Bezel.ShowDialog()
