Add-Type -Namespace DwmUtil -Name Native -MemberDefinition @"
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")]
public static extern IntPtr GetDC(IntPtr hwnd);
[DllImport("user32.dll")]
public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
[DllImport("gdi32.dll")]
public static extern int GetDeviceCaps(IntPtr hdc, int index);
[DllImport("user32.dll")]
public static extern bool LockWorkStation();
"@

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class LidAwareForm : Form
{
    public static readonly Guid GUID_LIDSWITCH_STATE_CHANGE = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
    private const int WM_POWERBROADCAST = 0x0218;
    private const int PBT_POWERSETTINGCHANGE = 0x8013;

    public bool LidIsOpen = true;
    public event EventHandler LidStateChanged;

    [DllImport("user32.dll")]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Guid g = GUID_LIDSWITCH_STATE_CHANGE;
        RegisterPowerSettingNotification(this.Handle, ref g, 0);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE)
        {
            Guid settingGuid = Marshal.PtrToStructure<Guid>(m.LParam);
            if (settingGuid == GUID_LIDSWITCH_STATE_CHANGE)
            {
                int value = Marshal.ReadInt32(m.LParam, 20);
                LidIsOpen = (value != 0);
                if (LidStateChanged != null) LidStateChanged(this, EventArgs.Empty);
            }
        }
        base.WndProc(ref m);
    }
}

public static class IdleUtil
{
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static int GetIdleSeconds()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        uint idleMs = (uint)Environment.TickCount - lii.dwTime;
        return (int)(idleMs / 1000);
    }
}

public static class InputUtil
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [DllImport("user32.dll")]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    // SetCursorPos does NOT reliably reset Windows' real input-idle timer when
    // called from within an active WinForms message loop (verified empirically:
    // it works fine from plain sequential script code, but silently fails to
    // register as real input once a Timer.Tick handler is driving it under
    // Application.Run() -- which is exactly this app's context). SendInput is
    // the API actually meant for synthesizing recognized input and reliably
    // resets the idle timer in both contexts.
    public static void MoveRelative(int dx, int dy)
    {
        INPUT[] inputs = new INPUT[1];
        inputs[0].type = 0; // INPUT_MOUSE
        inputs[0].mi.dx = dx;
        inputs[0].mi.dy = dy;
        inputs[0].mi.dwFlags = 0x0001; // MOUSEEVENTF_MOVE (relative)
        SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703+)
    [void][DwmUtil.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch {
    [void][DwmUtil.Native]::SetProcessDPIAware()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$InstallDir = Join-Path $env:LOCALAPPDATA "StatusKeeper"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$InstalledExePath = Join-Path $InstallDir "StatusKeeper.exe"
$LogPath = Join-Path $InstallDir "status-keeper.log"
$ConfigPath = Join-Path $InstallDir "interval.txt"
$DistanceConfigPath = Join-Path $InstallDir "distance.txt"
$LidLockConfigPath = Join-Path $InstallDir "lidlock.txt"
$AppVersion = "1.1.0.0"
$MinIntervalSeconds = 20
$DefaultIntervalSeconds = 60
$MinDistanceMm = 1
$MaxDistanceMm = 50
$DefaultDistanceMm = 1
$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$UninstallKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\StatusKeeper"

function Write-Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Register-AddRemovePrograms {
    if (-not (Test-Path $UninstallKeyPath)) {
        New-Item -Path $UninstallKeyPath -Force | Out-Null
    }
    $sizeKb = 0
    if (Test-Path $InstalledExePath) { $sizeKb = [int]((Get-Item $InstalledExePath).Length / 1KB) }
    Set-ItemProperty -Path $UninstallKeyPath -Name "DisplayName" -Value "Status Keeper" -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "DisplayVersion" -Value $AppVersion -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "Publisher" -Value "Status Keeper" -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "DisplayIcon" -Value $InstalledExePath -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "InstallLocation" -Value $InstallDir -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "UninstallString" -Value "`"$InstalledExePath`" /uninstall" -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "NoModify" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "NoRepair" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $UninstallKeyPath -Name "EstimatedSize" -Value $sizeKb -Type DWord -Force
}

function Unregister-Everything {
    try { Remove-ItemProperty -Path $RunKeyPath -Name "StatusKeeper" -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -Path $UninstallKeyPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# Invoked via the Windows "Uninstall" button (Settings > Apps), which runs
# "<installed exe>" /uninstall. Runs standalone, outside the single-instance
# mutex, so it works even while the tray app is already running elsewhere.
if ($args -contains "/uninstall") {
    $selfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Get-CimInstance Win32_Process -Filter "Name = 'StatusKeeper.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ne $selfPath) } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Milliseconds 300
    Unregister-Everything
    Write-Log "Uninstalled via /uninstall (Windows Apps & Features)"
    try { Remove-Item -Path $ConfigPath -Force -ErrorAction SilentlyContinue } catch {}
    [System.Windows.Forms.MessageBox]::Show(
        "Status Keeper has been uninstalled and will no longer start at login.`n`nIf this was run from its installed location, delete this folder too once it closes:`n$InstallDir",
        "Status Keeper - Uninstalled",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit
}

$mutex = New-Object System.Threading.Mutex($false, "Global\StatusKeeperApp_SingleInstance")
if (-not $mutex.WaitOne(0)) {
    exit
}

# Self-install: if not already running from the installed copy, copy self there.
# First-ever install asks for explicit consent before touching auto-start or the
# registry; a later run of a newer version (installed copy already exists) just
# updates silently, since the user already agreed once.
try {
    $ownExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $isRealExe = $ownExePath -and (Test-Path $ownExePath) -and ($ownExePath -like "*.exe") -and
                 ($ownExePath -notlike "*powershell.exe") -and ($ownExePath -notlike "*pwsh.exe")
    $alreadyInstalled = Test-Path $InstalledExePath

    if ($isRealExe -and (-not $alreadyInstalled)) {
        $consent = [System.Windows.Forms.MessageBox]::Show(
            "Status Keeper will:`n`n - Copy itself to $InstallDir`n - Start automatically at login`n - Run in the background and move your mouse cursor slightly every so often to keep your status active`n`nContinue and install?",
            "Status Keeper - First Run",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($consent -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log "Install declined by user on first run"
            exit
        }
        Write-Log "Install consent given on first run"
    }

    if ($isRealExe -and ($ownExePath -ne $InstalledExePath)) {
        Copy-Item -Path $ownExePath -Destination $InstalledExePath -Force
        Set-ItemProperty -Path $RunKeyPath -Name "StatusKeeper" -Value "`"$InstalledExePath`"" -Force
        Register-AddRemovePrograms
        Write-Log "Installed to $InstalledExePath, registered auto-start and Apps & Features entry (run from $ownExePath)"
    }
} catch {
    Write-Log "Self-install step failed: $($_.Exception.Message)"
}

function Get-SavedIntervalSeconds {
    if (Test-Path $ConfigPath) {
        $raw = (Get-Content $ConfigPath -Raw -ErrorAction SilentlyContinue).Trim()
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge $MinIntervalSeconds) {
            return $val
        }
    }
    return $DefaultIntervalSeconds
}

function Save-IntervalSeconds([int]$sec) {
    $sec | Out-File -FilePath $ConfigPath -Encoding utf8 -NoNewline
}

function Get-SavedDistanceMm {
    if (Test-Path $DistanceConfigPath) {
        $raw = (Get-Content $DistanceConfigPath -Raw -ErrorAction SilentlyContinue).Trim()
        $val = 0.0
        if ([double]::TryParse($raw, [ref]$val) -and $val -ge $MinDistanceMm -and $val -le $MaxDistanceMm) {
            return $val
        }
    }
    return $DefaultDistanceMm
}

function Save-DistanceMm([double]$mm) {
    $mm | Out-File -FilePath $DistanceConfigPath -Encoding utf8 -NoNewline
}

function Get-SavedLidLockEnabled {
    if (Test-Path $LidLockConfigPath) {
        return ((Get-Content $LidLockConfigPath -Raw -ErrorAction SilentlyContinue).Trim() -eq "1")
    }
    return $false
}

function Save-LidLockEnabled([bool]$enabled) {
    $(if ($enabled) { "1" } else { "0" }) | Out-File -FilePath $LidLockConfigPath -Encoding utf8 -NoNewline
}

function Get-PixelsPerMm {
    try {
        $hdc = [DwmUtil.Native]::GetDC([IntPtr]::Zero)
        $horzSizeMm = [DwmUtil.Native]::GetDeviceCaps($hdc, 4)   # HORZSIZE
        $horzResPx = [DwmUtil.Native]::GetDeviceCaps($hdc, 8)    # HORZRES
        [DwmUtil.Native]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null
        if ($horzSizeMm -gt 0 -and $horzResPx -gt 0) {
            return [double]$horzResPx / [double]$horzSizeMm
        }
    } catch {}
    return 96.0 / 25.4   # fallback: assume standard 96 DPI if physical size can't be read
}

Write-Log "Started (PID $PID)"

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.Dispose()
    $brush.Dispose()
    $hIcon = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($hIcon)
}

function Set-RoundedRegion($ctrl, [int]$radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $w = $ctrl.Width
    $h = $ctrl.Height
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $ctrl.Region = New-Object System.Drawing.Region($path)
}

function Test-SystemUsesLightTheme {
    try {
        $val = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction Stop
        return [bool]$val.AppsUseLightTheme
    } catch {
        return $true
    }
}
$script:IsDarkTheme = -not (Test-SystemUsesLightTheme)
Write-Log "detected theme: $(if ($script:IsDarkTheme) { 'Dark' } else { 'Light' })"

if ($script:IsDarkTheme) {
    $accentColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $accentHoverColor = [System.Drawing.Color]::FromArgb(30, 144, 235)
    $secondaryColor = [System.Drawing.Color]::FromArgb(59, 59, 59)
    $secondaryHoverColor = [System.Drawing.Color]::FromArgb(74, 74, 74)
    $bgColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $dividerColor = [System.Drawing.Color]::FromArgb(61, 61, 61)
    $textColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $logBackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
    $logTextColor = [System.Drawing.Color]::FromArgb(212, 212, 212)
    $activeColor = [System.Drawing.Color]::FromArgb(108, 203, 95)
    $pausedColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
} else {
    $accentColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $accentHoverColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $secondaryColor = [System.Drawing.Color]::FromArgb(225, 225, 225)
    $secondaryHoverColor = [System.Drawing.Color]::FromArgb(208, 208, 208)
    $bgColor = [System.Drawing.Color]::FromArgb(243, 243, 243)
    $dividerColor = [System.Drawing.Color]::FromArgb(224, 224, 224)
    $textColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
    $logBackColor = [System.Drawing.Color]::White
    $logTextColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
    $activeColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
    $pausedColor = [System.Drawing.Color]::Gray
}

$uiFont = New-Object System.Drawing.Font("Segoe UI", 9.5)
$script:RoundedButtons = New-Object System.Collections.ArrayList

function Style-PrimaryButton($btn) {
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $accentColor
    $btn.FlatAppearance.MouseOverBackColor = $accentHoverColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    [void]$script:RoundedButtons.Add($btn)
}

function Style-SecondaryButton($btn) {
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $secondaryColor
    $btn.FlatAppearance.MouseOverBackColor = $secondaryHoverColor
    $btn.ForeColor = $textColor
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    [void]$script:RoundedButtons.Add($btn)
}

$greenIcon = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$grayIcon = New-DotIcon ([System.Drawing.Color]::Gray)

$script:Paused = $false
$script:SnoozeUntil = $null
$snoozeTimer = New-Object System.Windows.Forms.Timer
$snoozeTimer.Add_Tick({
    $snoozeTimer.Stop()
    $script:SnoozeUntil = $null
    if ($script:Paused) {
        $script:Paused = $false
        Update-PauseUI
        Write-Log "snooze ended, auto-resumed"
    }
})

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $greenIcon
$notifyIcon.Text = "Status Keeper - Active"
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$pauseItem = $menu.Items.Add("Pause")

$snoozeMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Snooze")
[void]$menu.Items.Add($snoozeMenu)
$snoozePresets = [ordered]@{ "30 min" = 30; "1 hour" = 60; "2 hours" = 120 }
foreach ($label in $snoozePresets.Keys) {
    $minutes = $snoozePresets[$label]
    $snoozeItem = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $snoozeItem.Tag = $minutes
    $snoozeItem.Add_Click({ Start-Snooze $this.Tag })
    [void]$snoozeMenu.DropDownItems.Add($snoozeItem)
}

$intervalMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Interval")
[void]$menu.Items.Add($intervalMenu)

[void]$menu.Items.Add("-")
$uninstallItem = $menu.Items.Add("Uninstall")
$quitItem = $menu.Items.Add("Quit")
$notifyIcon.ContextMenuStrip = $menu

$intervalPresets = [ordered]@{ "20 sec" = 20; "30 sec" = 30; "1 min" = 60; "2 min" = 120; "5 min" = 300 }
foreach ($label in $intervalPresets.Keys) {
    $seconds = $intervalPresets[$label]
    $menuItem = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $menuItem.Tag = $seconds
    $menuItem.Add_Click({
        Set-Interval $this.Tag
    })
    [void]$intervalMenu.DropDownItems.Add($menuItem)
}

$currentIntervalSeconds = Get-SavedIntervalSeconds
$script:IdleThresholdSeconds = $currentIntervalSeconds
$PollIntervalMs = 5000   # fixed, frequent poll rate so a nudge is never more than ~5s late,
                         # regardless of how long the configured idle threshold is
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollIntervalMs
Write-Log "interval set to ${currentIntervalSeconds}s at startup"

$script:PixelsPerMm = Get-PixelsPerMm
$script:CurrentDistanceMm = Get-SavedDistanceMm
$script:NudgeDistancePx = [Math]::Max(1, [int][Math]::Round($script:CurrentDistanceMm * $script:PixelsPerMm))
Write-Log "nudge distance set to ${script:CurrentDistanceMm}mm (~$($script:NudgeDistancePx)px at $([Math]::Round($script:PixelsPerMm,2))px/mm) at startup"

# ---- Settings window ----
$settingsForm = New-Object LidAwareForm
$settingsForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$settingsForm.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$settingsForm.Text = "Status Keeper v$AppVersion"
$settingsForm.Size = New-Object System.Drawing.Size(400, 660)
$settingsForm.FormBorderStyle = 'FixedDialog'
$settingsForm.MaximizeBox = $false
$settingsForm.MinimizeBox = $false
$settingsForm.StartPosition = 'CenterScreen'
$settingsForm.TopMost = $true
$settingsForm.BackColor = $bgColor
$settingsForm.Font = $uiFont

# Force the native window handle to exist now, even while the form stays hidden,
# so lid-close detection (which needs a real HWND to register against) works
# from the moment the app starts, not only after the settings window is opened.
[void]$settingsForm.Handle

$script:LidLockEnabled = Get-SavedLidLockEnabled
$settingsForm.add_LidStateChanged({
    if ($settingsForm.LidIsOpen) {
        Write-Log "lid opened"
    } else {
        Write-Log "lid closed"
        if ($script:LidLockEnabled) {
            Write-Log "locking workstation (lock-on-lid-close enabled)"
            [DwmUtil.Native]::LockWorkStation() | Out-Null
        }
    }
})

$settingsForm.Add_Load({
    try {
        $pref = 2  # DWMWC_ROUND
        [DwmUtil.Native]::DwmSetWindowAttribute($settingsForm.Handle, 33, [ref]$pref, 4) | Out-Null
    } catch {}
    try {
        $darkVal = if ($script:IsDarkTheme) { 1 } else { 0 }
        [DwmUtil.Native]::DwmSetWindowAttribute($settingsForm.Handle, 20, [ref]$darkVal, 4) | Out-Null
    } catch {}
    # Re-apply rounded corners now that DPI auto-scaling has set final button sizes
    foreach ($btn in $script:RoundedButtons) {
        Set-RoundedRegion $btn 6
    }
})

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 20)
$statusLabel.Size = New-Object System.Drawing.Size(340, 24)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$settingsForm.Controls.Add($statusLabel)

$pauseBtn = New-Object System.Windows.Forms.Button
$pauseBtn.Location = New-Object System.Drawing.Point(20, 56)
$pauseBtn.Size = New-Object System.Drawing.Size(130, 34)
$settingsForm.Controls.Add($pauseBtn)
Style-PrimaryButton $pauseBtn

$divider1 = New-Object System.Windows.Forms.Panel
$divider1.Location = New-Object System.Drawing.Point(20, 104)
$divider1.Size = New-Object System.Drawing.Size(320, 1)
$divider1.BackColor = $dividerColor
$settingsForm.Controls.Add($divider1)

$intervalLabel = New-Object System.Windows.Forms.Label
$intervalLabel.Text = "Nudge interval:"
$intervalLabel.Location = New-Object System.Drawing.Point(20, 118)
$intervalLabel.Size = New-Object System.Drawing.Size(200, 20)
$intervalLabel.ForeColor = $textColor
$settingsForm.Controls.Add($intervalLabel)

$intervalCombo = New-Object System.Windows.Forms.ComboBox
$intervalCombo.DropDownStyle = 'DropDownList'
$intervalCombo.FlatStyle = 'Flat'
$intervalCombo.Location = New-Object System.Drawing.Point(20, 142)
$intervalCombo.Size = New-Object System.Drawing.Size(140, 30)
$intervalCombo.BackColor = $secondaryColor
$intervalCombo.ForeColor = $textColor
foreach ($label in $intervalPresets.Keys) { [void]$intervalCombo.Items.Add($label) }
[void]$intervalCombo.Items.Add("Custom...")
$settingsForm.Controls.Add($intervalCombo)

$customNumeric = New-Object System.Windows.Forms.NumericUpDown
$customNumeric.Location = New-Object System.Drawing.Point(170, 142)
$customNumeric.Size = New-Object System.Drawing.Size(70, 30)
$customNumeric.Minimum = $MinIntervalSeconds
$customNumeric.Maximum = 3600
$customNumeric.Value = $currentIntervalSeconds
$customNumeric.Visible = $false
$customNumeric.BackColor = $secondaryColor
$customNumeric.ForeColor = $textColor
$settingsForm.Controls.Add($customNumeric)

$intervalCombo.Add_SelectedIndexChanged({
    $customNumeric.Visible = ($intervalCombo.SelectedItem -eq "Custom...")
})

$distanceLabel = New-Object System.Windows.Forms.Label
$distanceLabel.Text = "Nudge distance (1-50mm):"
$distanceLabel.Location = New-Object System.Drawing.Point(20, 182)
$distanceLabel.Size = New-Object System.Drawing.Size(220, 20)
$distanceLabel.ForeColor = $textColor
$settingsForm.Controls.Add($distanceLabel)

$distanceNumeric = New-Object System.Windows.Forms.NumericUpDown
$distanceNumeric.Location = New-Object System.Drawing.Point(20, 206)
$distanceNumeric.Size = New-Object System.Drawing.Size(70, 30)
$distanceNumeric.Minimum = $MinDistanceMm
$distanceNumeric.Maximum = $MaxDistanceMm
$distanceNumeric.Value = [Math]::Min($MaxDistanceMm, [Math]::Max($MinDistanceMm, [int]$script:CurrentDistanceMm))
$distanceNumeric.BackColor = $secondaryColor
$distanceNumeric.ForeColor = $textColor
$settingsForm.Controls.Add($distanceNumeric)

$distanceReadoutLabel = New-Object System.Windows.Forms.Label
$distanceReadoutLabel.Location = New-Object System.Drawing.Point(100, 210)
$distanceReadoutLabel.Size = New-Object System.Drawing.Size(140, 20)
$distanceReadoutLabel.ForeColor = $textColor
$settingsForm.Controls.Add($distanceReadoutLabel)

function Update-DistanceReadout {
    $mm = [double]$distanceNumeric.Value
    $px = [Math]::Max(1, [int][Math]::Round($mm * $script:PixelsPerMm))
    $distanceReadoutLabel.Text = "= $([Math]::Round($mm / 10, 2)) cm (~$px px)"
}
$distanceNumeric.Add_ValueChanged({ Update-DistanceReadout })

$applyBtn = New-Object System.Windows.Forms.Button
$applyBtn.Text = "Apply"
$applyBtn.Location = New-Object System.Drawing.Point(250, 205)
$applyBtn.Size = New-Object System.Drawing.Size(90, 32)
$settingsForm.Controls.Add($applyBtn)
Style-PrimaryButton $applyBtn

$lidLockCheckbox = New-Object System.Windows.Forms.CheckBox
$lidLockCheckbox.Text = "Lock computer when lid closes"
$lidLockCheckbox.Location = New-Object System.Drawing.Point(20, 245)
$lidLockCheckbox.Size = New-Object System.Drawing.Size(300, 24)
$lidLockCheckbox.ForeColor = $textColor
$lidLockCheckbox.Checked = $script:LidLockEnabled
$settingsForm.Controls.Add($lidLockCheckbox)

$lidLockCheckbox.Add_CheckedChanged({
    $script:LidLockEnabled = $lidLockCheckbox.Checked
    Save-LidLockEnabled $script:LidLockEnabled
    Write-Log "lock-on-lid-close set to $($script:LidLockEnabled)"
})

$divider2 = New-Object System.Windows.Forms.Panel
$divider2.Location = New-Object System.Drawing.Point(20, 284)
$divider2.Size = New-Object System.Drawing.Size(320, 1)
$divider2.BackColor = $dividerColor
$settingsForm.Controls.Add($divider2)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Activity log:"
$logLabel.Location = New-Object System.Drawing.Point(20, 298)
$logLabel.Size = New-Object System.Drawing.Size(150, 20)
$logLabel.ForeColor = $textColor
$settingsForm.Controls.Add($logLabel)

$refreshLogBtn = New-Object System.Windows.Forms.Button
$refreshLogBtn.Text = "Refresh"
$refreshLogBtn.Location = New-Object System.Drawing.Point(185, 294)
$refreshLogBtn.Size = New-Object System.Drawing.Size(70, 26)
$settingsForm.Controls.Add($refreshLogBtn)
Style-SecondaryButton $refreshLogBtn

$openLogBtn = New-Object System.Windows.Forms.Button
$openLogBtn.Text = "Open Log File"
$openLogBtn.Location = New-Object System.Drawing.Point(260, 294)
$openLogBtn.Size = New-Object System.Drawing.Size(100, 26)
$settingsForm.Controls.Add($openLogBtn)
Style-SecondaryButton $openLogBtn

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(20, 324)
$logTextBox.Size = New-Object System.Drawing.Size(340, 200)
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.ScrollBars = 'Vertical'
$logTextBox.BackColor = $logBackColor
$logTextBox.ForeColor = $logTextColor
$logTextBox.BorderStyle = 'FixedSingle'
$logTextBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$settingsForm.Controls.Add($logTextBox)

$divider3 = New-Object System.Windows.Forms.Panel
$divider3.Location = New-Object System.Drawing.Point(20, 536)
$divider3.Size = New-Object System.Drawing.Size(320, 1)
$divider3.BackColor = $dividerColor
$settingsForm.Controls.Add($divider3)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = "Close"
$closeBtn.Location = New-Object System.Drawing.Point(20, 550)
$closeBtn.Size = New-Object System.Drawing.Size(150, 36)
$settingsForm.Controls.Add($closeBtn)
Style-SecondaryButton $closeBtn

$quitBtn = New-Object System.Windows.Forms.Button
$quitBtn.Text = "Quit Status Keeper"
$quitBtn.Location = New-Object System.Drawing.Point(190, 550)
$quitBtn.Size = New-Object System.Drawing.Size(150, 36)
$settingsForm.Controls.Add($quitBtn)
Style-SecondaryButton $quitBtn

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = "Status Keeper v$AppVersion"
$versionLabel.Location = New-Object System.Drawing.Point(20, 596)
$versionLabel.Size = New-Object System.Drawing.Size(340, 18)
$versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$versionLabel.ForeColor = $dividerColor
$versionLabel.TextAlign = 'MiddleCenter'
$settingsForm.Controls.Add($versionLabel)

function Update-LogView {
    if (Test-Path $LogPath) {
        $lines = Get-Content -Path $LogPath -Tail 200 -ErrorAction SilentlyContinue
        $logTextBox.Text = ($lines -join "`r`n")
        $logTextBox.SelectionStart = $logTextBox.Text.Length
        $logTextBox.ScrollToCaret()
    } else {
        $logTextBox.Text = "(no log yet)"
    }
}

$logRefreshTimer = New-Object System.Windows.Forms.Timer
$logRefreshTimer.Interval = 2000
$logRefreshTimer.Add_Tick({ Update-LogView })

function Hide-SettingsWindow {
    $logRefreshTimer.Stop()
    $settingsForm.Hide()
}

$refreshLogBtn.Add_Click({ Update-LogView })
$openLogBtn.Add_Click({
    try { Start-Process notepad.exe -ArgumentList "`"$LogPath`"" } catch {}
})

function Update-PauseUI {
    if ($script:Paused) {
        $pauseItem.Text = "Resume"
        $notifyIcon.Icon = $grayIcon
        if ($script:SnoozeUntil) {
            $untilStr = $script:SnoozeUntil.ToString('HH:mm')
            $notifyIcon.Text = "Status Keeper - Paused until $untilStr"
            $statusLabel.Text = "Status: Paused (resumes $untilStr)"
        } else {
            $notifyIcon.Text = "Status Keeper - Paused"
            $statusLabel.Text = "Status: Paused"
        }
        $statusLabel.ForeColor = $pausedColor
        $pauseBtn.Text = "Resume"
    } else {
        $pauseItem.Text = "Pause"
        $notifyIcon.Icon = $greenIcon
        $notifyIcon.Text = "Status Keeper - Active"
        $statusLabel.Text = "Status: Active"
        $statusLabel.ForeColor = $activeColor
        $pauseBtn.Text = "Pause"
    }
}

function Cancel-Snooze {
    $snoozeTimer.Stop()
    $script:SnoozeUntil = $null
}

function Invoke-TogglePause {
    $script:Paused = -not $script:Paused
    if (-not $script:Paused) {
        Cancel-Snooze
    }
    Update-PauseUI
    Write-Log $(if ($script:Paused) { "paused" } else { "resumed" })
}

function Start-Snooze([int]$minutes) {
    $snoozeTimer.Stop()
    $script:SnoozeUntil = (Get-Date).AddMinutes($minutes)
    $snoozeTimer.Interval = $minutes * 60 * 1000
    $snoozeTimer.Start()
    $script:Paused = $true
    Update-PauseUI
    Write-Log "snoozed for ${minutes} min (until $($script:SnoozeUntil.ToString('HH:mm')))"
}

function Sync-IntervalUI([int]$sec) {
    foreach ($mi in $intervalMenu.DropDownItems) { $mi.Checked = ($mi.Tag -eq $sec) }
    if ($intervalPresets.Values -contains $sec) {
        $intervalCombo.SelectedItem = ($intervalPresets.Keys | Where-Object { $intervalPresets[$_] -eq $sec } | Select-Object -First 1)
        $customNumeric.Visible = $false
    } else {
        $intervalCombo.SelectedItem = "Custom..."
        $customNumeric.Value = $sec
        $customNumeric.Visible = $true
    }
}

function Set-Interval([int]$sec) {
    $script:IdleThresholdSeconds = $sec
    Save-IntervalSeconds $sec
    Sync-IntervalUI $sec
    Write-Log "interval changed to ${sec}s"
}

function Set-Distance([double]$mm) {
    $script:CurrentDistanceMm = $mm
    $script:NudgeDistancePx = [Math]::Max(1, [int][Math]::Round($mm * $script:PixelsPerMm))
    Save-DistanceMm $mm
    $distanceNumeric.Value = [Math]::Min($MaxDistanceMm, [Math]::Max($MinDistanceMm, [int]$mm))
    Update-DistanceReadout
    Write-Log "nudge distance changed to ${mm}mm (~$($script:NudgeDistancePx)px)"
}

function Show-SettingsWindow {
    Update-PauseUI
    Sync-IntervalUI $script:IdleThresholdSeconds
    $distanceNumeric.Value = [Math]::Min($MaxDistanceMm, [Math]::Max($MinDistanceMm, [int]$script:CurrentDistanceMm))
    Update-DistanceReadout
    $lidLockCheckbox.Checked = $script:LidLockEnabled
    Update-LogView
    $logRefreshTimer.Start()
    $settingsForm.Show()
    $settingsForm.Activate()
}

function Invoke-Quit {
    Write-Log "quit"
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
    # SystemEvents subscriptions (e.g. PowerModeChanged) keep a background
    # thread alive even after Application.Exit(), which would otherwise leave
    # a lingering zombie process with no visible tray icon. Force a real exit.
    [System.Environment]::Exit(0)
}

function Invoke-Uninstall {
    try {
        Unregister-Everything
        Write-Log "uninstalled (auto-start and Apps & Features entry removed)"
    } catch {
        Write-Log "uninstall failed: $($_.Exception.Message)"
    }
    [System.Windows.Forms.MessageBox]::Show(
        "Auto-start has been removed. Status Keeper will close now and won't launch at login anymore.`n`nInstalled files are still at:`n$InstallDir`n(delete that folder manually if you want it fully gone).",
        "Status Keeper - Uninstalled",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Invoke-Quit
}

$pauseBtn.Add_Click({ Invoke-TogglePause })
$pauseItem.Add_Click({ Invoke-TogglePause })

$applyBtn.Add_Click({
    if ($intervalCombo.SelectedItem -eq "Custom...") {
        $sec = [int]$customNumeric.Value
    } elseif ($intervalCombo.SelectedItem) {
        $sec = $intervalPresets[$intervalCombo.SelectedItem.ToString()]
    } else {
        return
    }
    Set-Interval $sec
    Set-Distance ([double]$distanceNumeric.Value)
})

$closeBtn.Add_Click({ Hide-SettingsWindow })
$quitBtn.Add_Click({ Invoke-Quit })
$quitItem.Add_Click({ Invoke-Quit })
$uninstallItem.Add_Click({ Invoke-Uninstall })

$settingsForm.Add_FormClosing({
    param($s, $e)
    $e.Cancel = $true
    Hide-SettingsWindow
})

$notifyIcon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-SettingsWindow
    }
})

# Sync UI to the interval loaded at startup
Sync-IntervalUI $currentIntervalSeconds
Update-DistanceReadout
Update-PauseUI

$timer.Add_Tick({
    if (-not $script:Paused) {
        $idleSec = [IdleUtil]::GetIdleSeconds()
        if ($idleSec -ge $script:IdleThresholdSeconds) {
            $pos = [System.Windows.Forms.Cursor]::Position
            $screenBounds = [System.Windows.Forms.Screen]::FromPoint($pos).Bounds
            $dx = $script:NudgeDistancePx
            if ($pos.X + $dx -gt ($screenBounds.Right - 1)) { $dx = -$dx }
            [InputUtil]::MoveRelative($dx, 0)
            Start-Sleep -Milliseconds 50
            [InputUtil]::MoveRelative(-$dx, 0)
            Write-Log "nudge (${script:CurrentDistanceMm}mm / $($script:NudgeDistancePx)px, idle ${idleSec}s)"
        } else {
            Write-Log "tick skipped (user active, idle ${idleSec}s < $($script:IdleThresholdSeconds)s)"
        }
    } else {
        Write-Log "tick skipped (paused)"
    }
})

[Microsoft.Win32.SystemEvents]::add_PowerModeChanged({
    param($senderObj, $e)
    Write-Log "power mode changed: $($e.Mode)"
})

$timer.Start()
[System.Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
