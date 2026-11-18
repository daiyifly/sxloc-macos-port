# 随行定位 · macOS 移植版（蓝牙 + USB 双通道）

## 版本历史

| 版本 | 说明 |
| --- | --- |
| **v1.3.0**（2026-11-18） | 新增 **USB 开发者定位**通道，内置自包含 Python 3.14 + pymobiledevice3 11.55.0，支持 iOS 26 / iPhone 16 Pro。通过 GitHub Release 直接下载。 |
| v1.2.0 | 初版，仅蓝牙 iAP2 通道。 |

## USB 开发者定位（v1.3.0 新增）

iPhone 连不上 Mac 蓝牙时，可改用 USB 数据线定位——该通道走 `UserspaceRsdTunnel + DVT`，**不依赖蓝牙、不需要同一局域网、不需要 root**。内置实验身份与蓝牙通道共用。

**使用前置条件（iPhone 16 Pro / iOS 26）：**
1. 用**可传输数据的 USB 线**连接 Mac（非仅充电线）。
2. iPhone 解锁，弹窗点「信任此电脑」并输入锁屏密码。
3. 开启开发者模式：设置 → 隐私与安全性 → 开发者模式 → 开启 → 按提示重启 → 解锁后再确认启用。
   - 找不到入口时，可在 App 的 USB 设备页点「显示开发者模式入口」，手机会弹出入口。
4. 在 App「我的设备 → USB 开发者」点刷新选设备，选点地图并「应用定位」，用「停止模拟」结束。

> iOS 17.4 及以后（含 iOS 26）走 USB 隧道，无需手机与电脑同一局域网；iOS 17.0–17.3 才需要同局域网。

## 已编译产物

通过 GitHub Actions 真实编译。arm64 产物位于 `../releases/`，v1.3.0 发布在仓库 **Releases** 页（`macos-v1.3.0+1`）。

| 文件 | 架构 | 适用设备 |
| --- | --- | --- |
| `suixing-macos-arm64.dmg` | arm64 | Apple Silicon（M1/M2/M3/M4，含 MacBook Neo） |

编译链路全部验证通过：C# 核心本地 `dotnet build` 0 错误；云端 Flutter 3.50 + .NET 10 成功构建。DMG 含蓝牙 dylib + 自包含 Python USB 运行时，ad-hoc 签名完成。
Intel（x64）版本因免费账户下 `macos-15-intel` runner 排队超时未产出；如需 Intel 版，把仓库改为 public 后重跑 workflow。
校验：`sha256sum -c suixing-macos-arm64.dmg.sha256`。

本目录在 `yfl520/sxloc` 原项目基础上增加了 macOS 桌面版支持。原仓库当前只发布 Windows 与 Android 版，但其**核心引擎（协议 / 定位会话 / 蓝牙传输）本就是跨平台的 .NET 10 代码**，本次移植复用这套引擎，只替换 Windows 专属的 Bridge 层，并用 Flutter 的 macOS runner 承载原有界面。

## 已完成的工作

| 层 | 处理 |
| --- | --- |
| iAP2 协议 / 定位会话 / 蓝牙 RFCOMM（`Protocol/`、`Engine/`、`Transport/`） | 原生已支持 macOS（`MacBtRfcommTransport.cs` + `Native/MacBluetoothBridge.m`），直接复用 |
| JSON-RPC 核心进程 | 新增 `BridgeMac/`：去掉 Windows 自更新器、DPAPI（改本机 AES 加密）；USB 开发者通道移植为跨平台进程管理（去掉 Windows Job Object）；协议与 Windows 版完全一致 |
| USB 定位运行时 | `BridgeMac/UsbWorker/`（跨平台 worker.py）+ `scripts/prepare-usb-runtime-macos.sh`：下载自包含 Python 3.14.10（校验 SHA256）并安装 pymobiledevice3 11.55.0；app bundle 内 `core/usb/` 随附 |
| Flutter 界面 | 复用原界面，修正核心可执行文件路径、同意记录存储路径、关于页更新入口、平台文案；USB 标签页保留并补充 iOS 26 提示 |
| 打包 | `scripts/build-macos.sh`：编译 Obj-C 桥 → dotnet 发布核心 → 准备 USB 运行时 → flutter 构建 → 组装 .app（含 USB 运行时，逐个签名 native .so）→ 签名 → DMG |
| 身份材料 | 新增 `scripts/import-desktop-identity.sh`（校验官方 DiPlay APK 的 SHA-256 后提取身份） |
| 云端编译 | 新增 `.github/workflows/macos-flutter.yml`，支持在 fork 仓库手动触发，产出 arm64 / x64 两个 DMG |

## 如何构建（GitHub Actions 云端，推荐）

1. 把本仓库 push 到你自己的 GitHub 账号（或 fork 后合并这些改动）。
2. 进入仓库 **Actions** → **Build macOS Flutter app (sxloc port)** → **Run workflow**，可填写版本号与构建号。
3. 等待完成后，在本次 run 的 **Artifacts** 下载 `suixing-macos-arm64`（Apple Silicon）或 `suixing-macos-x64`（Intel）。
4. 解压得到 DMG，双击安装到「应用程序」。

> 工作流使用 ad-hoc 签名（`-`）。首次打开若被 Gatekeeper 拦截，右键 → 打开，或在「系统设置 → 隐私与安全性」中允许。若要做正式分发，把签名证书换成 Developer ID Application 并追加公证（`xcrun notarytool submit` + `xcrun stapler staple`）。

## 如何构建（本地 Mac）

需要 macOS 13+、Xcode 命令行工具、.NET 10 SDK、Flutter 3.50（stable）：

```bash
bash scripts/import-desktop-identity.sh          # 导入构建身份（联网下载官方 APK）
bash scripts/build-macos.sh arm64 dist/app.dmg   # Apple Silicon
bash scripts/build-macos.sh x64   dist/app.dmg   # Intel
```

## 使用前提与限制

- **蓝牙配对**：先在 macOS「系统设置 → 蓝牙」中把目标 iPhone 配对，再在应用「我的设备」中刷新选择。
- **身份认证**：内置的是 DiPlay v0.2.22 公开实验身份，证书匹配不代表设备一定接受；iOS 各版本效果需在真机验证。可在设置中导入自己的配套身份。
- **一期范围**：仅蓝牙 iAP2 通道。USB 开发者定位、应用内自动更新未移植（对应按钮/入口已隐藏或给出明确提示）。macOS 版通过 GitHub Releases 手动更新。
- **数据位置**：配置、收藏、导入身份保存在 `~/Library/Application Support/SuixingLoc`，密钥文件权限 0600。
- **SDK 版本**：Flutter 依赖 `material_ui 1.11.0` / `cupertino_ui 1.1.6`，云端固定 Flutter 3.50，与原项目 `pubspec.lock` 一致。

## 隐私与合规

本项目基于 `D1ngtalk/iap2loc`（GPL-3.0），保留原版权与署名。实验身份来自公开资源，不代表取得 Apple MFi 授权。请仅用于自有或获授权设备的开发、研究与测试，遵守所在地区法律与平台条款。

## 后续可选项

- USB 开发者通道：可用 macOS 版 `pymobiledevice3` + Python 运行时替代 Windows 的 CPython Job Object 方案。
- 快捷键改为 ⌘：当前快捷键绑定沿用 `Ctrl`，如需符合 macOS 习惯可把 `workspace.dart` 中的 `SingleActivator(..., control: true)` 改为 `meta: true`。
- 公证与正式签名：用于脱离 Gatekeeper 限制的公开发布。
