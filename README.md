<div align="center">

  <img src="assets/hero-banner.jpg" alt="AirMirror for Windows" width="100%" style="border-radius: 12px; box-shadow: 0 12px 32px rgba(0,0,0,0.5);">

  <br/><br/>

  <p align="center">
    <img src="assets/icon.png" alt="AirMirror Logo" width="96" height="96" style="border-radius: 22px;">
  </p>

  # AirMirror
  ### Native Apple AirPlay Receiver for Windows 10 & 11 • Mirror iPhone to PC

  <p align="center">
    <b>Transform your Windows PC into a studio-grade Apple AirPlay display.</b><br/>
    Zero iOS apps. Zero subscriptions. Zero cables. Just seamless, low-latency 60 FPS screen mirroring.
  </p>

  <p align="center">
    <a href="https://github.com/shreyanshucodes/screen-mirroring-iphone-windows/releases"><img src="https://img.shields.io/badge/Download-Latest_Release-0ea5e9?style=for-the-badge&logo=windows&logoColor=white" alt="Download AirMirror"></a>
    <a href="#-quick-start-3-steps"><img src="https://img.shields.io/badge/Get_Started-1--Click_Launch-22c55e?style=for-the-badge&logo=rocket&logoColor=white" alt="Get Started"></a>
    <a href="https://github.com/shreyanshucodes/screen-mirroring-iphone-windows/stargazers"><img src="https://img.shields.io/github/stars/shreyanshucodes/screen-mirroring-iphone-windows?style=for-the-badge&color=eab308&logo=github" alt="Stars"></a>
  </p>

  <p align="center">
    <img src="https://img.shields.io/badge/AirPlay-Native%20Protocol-000000?style=flat-square&logo=apple&logoColor=white" alt="AirPlay">
    <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?style=flat-square&logo=windows&logoColor=white" alt="OS">
    <img src="https://img.shields.io/badge/Performance-1080p%20%40%2060FPS-7c3aed?style=flat-square" alt="60 FPS">
    <img src="https://img.shields.io/badge/Latency-%3C%2050ms-10b981?style=flat-square" alt="Latency">
    <img src="https://img.shields.io/badge/Audio-WASAPI%20Stereo-f97316?style=flat-square&logo=apple-music&logoColor=white" alt="Audio">
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License">
  </p>

</div>

---

## 🌟 What is AirMirror?

**AirMirror** is a lightweight, open-source **Apple AirPlay receiver for Windows**. It allows you to wirelessly mirror your iPhone, iPad, or Mac screen onto any Windows 10 or 11 PC with ultra-low latency, crisp 1080p resolution, and real-time digital audio pass-through.

```
┌──────────────────┐       Wi-Fi (AirPlay)       ┌────────────────────────┐
│  iPhone / iPad   │ ──────────────────────────► │  Windows 10 / 11 PC    │
│ (Control Center) │    1080p @ 60 FPS • <50ms   │  (AirMirror GUI App)   │
└──────────────────┘                             └────────────────────────┘
```

---

## ✨ Features That Stand Out

| Feature | Description |
| :--- | :--- |
| ⚡ **<50ms Low Latency** | Optimized streaming pipeline for mobile gaming, live product demos, and real-time presentations. |
| 🎨 **Minimalist Desktop GUI** | Sleek Apple dark matte aesthetic. Start and stop mirroring with one click without opening a terminal. |
| 📱 **Zero iPhone App Required** | Connects natively using iOS **Control Center ➔ Screen Mirroring**. Works with all iOS & iPadOS devices. |
| 🎧 **Digital WASAPI Audio** | High-fidelity stereo audio streamed directly to your PC speakers or headphones. |
| 🔒 **PIN Security** | Enforce an optional 4-digit pairing passcode to prevent unauthorized devices from connecting. |
| 💼 **Zoom & Teams Safe-Share** | Built-in capture-safe mode (`-ShareSafe`) prevents black screen bugs when window-sharing on Microsoft Teams, Zoom, or OBS. |
| 🎬 **A/V Sync Mode** | Dedicated video mode for buffer alignment and smooth movie playback. |

---

## 🚀 Quick Start (3 Steps)

### Step 1: Pre-requisites
Ensure **Apple Bonjour** is running on your PC (enables wireless mDNS discovery).
* If you have **iTunes** or **Apple Devices** installed, you already have it!
* Or download [Apple Bonjour Print Services for Windows](https://support.apple.com/kb/DL999).

### Step 2: One-Time Setup
Run `setup.ps1` once as Administrator to configure Windows Firewall rules:
```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

### Step 3: Launch AirMirror!
* 🌟 **Desktop Shortcut:** Double-click **`AirMirror for Windows`** on your Desktop.
* ⚡ **Zero-Console Launcher:** Double-click **`Launch-iPhone-Mirror.vbs`** (opens silently with zero terminal flash).

On your iPhone:
1. Swipe down from the top-right corner to open **Control Center**.
2. Tap **Screen Mirroring** (two overlapping rectangles).
3. Select **`AirMirror`** (or your PC name). **Enjoy your mirror!**

---

## 📊 Comparison Matrix

| Feature | **AirMirror** | Paid Commercial Apps (AirServer / Reflector) | USB Cable |
| :--- | :---: | :---: | :---: |
| **Price** | **100% Free & Open-Source** | $20 – $40 / year | $29+ cable cost |
| **iOS Companion App** | **None (Native AirPlay)** | Requires helper app | Driver dependent |
| **Wireless Freedom** | **Yes (Wi-Fi)** | Yes | ❌ Tethered |
| **Framerate** | **Up to 60 FPS** | 30 - 60 FPS | 60 FPS |
| **Audio** | **WASAPI Digital Stereo** | Included | Often muted |
| **Privacy** | **100% Local (Zero Telemetry)** | Cloud tracking | Local |

---

## 🎛️ CLI Options

Power users can also run AirMirror via command-line switches:

```powershell
# Custom PC name & PIN security
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Name "AirMirror PC" -PIN -Fullscreen

# Cinema Sync Mode (A/V lip-sync for video playback)
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Sync

# Low Bandwidth Mode (30 FPS cap)
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Fps 30
```

### ⌨️ In-Session Hotkeys
* **`Alt + Enter`** — Toggle fullscreen mode.
* **`Ctrl + C`** — Stop session and close.

---

## 🛠️ Diagnostics

If your PC isn't appearing on your iPhone:
1. Confirm both devices are connected to the **same Wi-Fi network**.
2. Run `.\doctor.ps1` or click **"Diagnostics"** in the AirMirror GUI to check Bonjour and Firewall rules.

---

## 📜 Credits & License

Powered by [UxPlay](https://github.com/FDH2/UxPlay) and GPL/MIT open-source ecosystem. Wrapper scripts are licensed under [MIT License](LICENSE).

<div align="center">
  <sub>Built with ❤️ by <a href="https://github.com/shreyanshucodes">Shreyanshu Srivastava</a></sub>
</div>
