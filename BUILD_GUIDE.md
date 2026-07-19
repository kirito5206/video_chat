# video_chat 双端应用出包与使用说明

视频通话软件，基于 Flutter + flutter_webrtc，支持：
- **电脑桌面端（Windows）**：原生 exe，自带摄像头/麦克风，可与手机或另一台电脑通话。
- **手机端（Android）**：原生 APK，自带摄像头/麦克风，可与电脑或另一部手机通话。
- **网页端（web_client.html）**：无需安装，浏览器打开即可看画面（受限于 http 非安全上下文，手机网页端只能收不能发）。

> 三端共用同一套信令服务器（WebSocket），只要在同一局域网、填同一个房间号即可互通。

---

## 一、已构建好的产物

| 平台 | 产物路径 | 大小 | 说明 |
|------|----------|------|------|
| Windows 桌面 | `build/windows/x64/runner/Release/video_chat.exe` | — | 连同同目录的 `*.dll` 和 `data/` 一起拷贝使用 |
| Android 手机 | `build/app/outputs/flutter-apk/app-release.apk` | ~81MB | 安装到安卓手机 |

> ⚠️ Windows 的 `video_chat.exe` **不能单独拷贝**，必须连同它所在 `Release/` 目录下的所有 `.dll` 和 `data/` 文件夹一起复制，否则启动会缺库。

---

## 二、前置：启动信令与网页服务

通话前必须先把**信令服务器**跑起来（所有端都靠它做握手）。推荐用一键脚本：

```bat
start_web.bat
```

它会同时：
1. 启动 Python 信令服务器（默认 `0.0.0.0:8765`）
2. 启动静态网页服务（默认 `0.0.0.0:8000`，用于 web_client.html）
3. 打开浏览器到 `http://localhost:8000/web_client.html`

本机局域网 IP（手机/其他电脑连你用这个）：
```
ipconfig 里 IPv4 地址，例如 10.220.63.242
```
手机端 App 里填的信号服务器地址就是 `ws://10.220.63.242:8765`。

> 若 Windows 防火墙弹窗，请允许 `python` / 端口 `8765`、`8000` 通过专用网络。

手动启动（不用脚本）：
```bat
:: 信令服务器
python server/signaling_server.py
:: 网页服务（另开一个终端）
python -m http.server 8000 --bind 0.0.0.0
```

---

## 三、桌面端（Windows）使用

1. 把 `build/windows/x64/runner/Release/` 整个文件夹拷贝到目标电脑。
2. 双击 `video_chat.exe`。
3. 填写：
   - **UserID**：本机唯一标识，如 `pcA`
   - **信令服务器**：`ws://10.220.63.242:8765`（换成你跑信令服务器的那台机器 IP）
   - **房间号**：如 `room_001`
4. 点「加入房间」，再点「呼叫」即可与同房间其他端通话。
5. 界面：对方画面大窗铺满，本地画面为右下角小窗；点小窗右上角 **×** 可关闭小窗，点「切换大小窗」按钮在小窗/全屏间切换。

> 首次运行若杀毒软件拦截，属误报（未签名 exe），允许运行即可。

---

## 四、手机端（Android）使用

1. 把 `app-release.apk` 传到安卓手机，点击安装（若提示“未知来源”，按系统指引允许本次安装）。
2. 打开 App，填写：
   - **UserID**：如 `phoneB`（不要和桌面端相同）
   - **信令服务器**：`ws://10.220.63.242:8765`（电脑端局域网 IP）
   - **房间号**：与电脑端同一房间，如 `room_001`
3. 点「加入房间」→「呼叫」，即可看到电脑端画面；手机端摄像头也会发给对方（APK 不受 http 限制，可双向通话）。
4. 手机端界面交互与网页端一致：点画面唤出图标按钮；`⇆` 在「横向平列 ↔ 远程全屏 ↔ 本地全屏」间循环；`⛶` 把当前聚焦窗口横屏全屏；小窗 `×` 关闭、再点 `⇆` 唤出。

> APK 已内置 `CAMERA / RECORD_AUDIO / INTERNET` 权限与明文流量许可，可在 `http/ws` 下直接使用。

---

## 五、三方互通速查

| 组合 | 可行性 | 备注 |
|------|--------|------|
| 桌面 ↔ 桌面 | ✅ | 双向音视频 |
| 桌面 ↔ 手机(App) | ✅ | 双向音视频 |
| 手机(App) ↔ 手机(App) | ✅ | 双向音视频 |
| 网页 ↔ 任意端 | ⚠️ 单向 | 手机用 http 打开网页时摄像头被禁，只能收不能发；电脑用 `http://localhost:8000` 打开可双向 |
| 跨公网 | ❌ | 当前仅 STUN 无 TURN，对称 NAT 下不通，需自建 TURN 中继 |

---

## 六、重新构建命令（含已知坑）

### 环境变量坑（必须）
本机存在一些被注入的**超大环境变量**（如 `ACC_PRODUCT_CONFIG_V3`，值约 300KB），会导致 MSBuild / Gradle 子进程继承后崩溃（报“环境变量名或值太长”）。**构建前务必去掉它**：

```bat
set ACC_PRODUCT_CONFIG_V3=
:: 或直接在该命令前加 env -u ACC_PRODUCT_CONFIG_V3 （Git Bash）
env -u ACC_PRODUCT_CONFIG_V3 flutter build windows --release
env -u ACC_PRODUCT_CONFIG_V3 flutter build apk --release
```

### 中文代码页坑（Windows 桌面必加）
中文 Windows（代码页 936）下，flutter_webrtc 1.5.2 的源码含非 GBK 字符，触发 `C4819` 并被当作错误（`C2220`），编译失败。需给 MSVC 传 `/utf-8`：

```bat
set CL=/utf-8
flutter build windows --release
```

### 依赖版本（已固定）
`pubspec.yaml` 中 `flutter_webrtc: ^1.0.0`（实际 1.5.2）。**不要用 0.10.x**：旧版用了已被 Flutter 3.44 删除的 `PluginRegistry.Registrar` v1 嵌入 API，APK 编译会报“找不到符号”。

### 完整重编流程
```bat
cd E:\dev\video_chat

:: Windows 桌面
env -u ACC_PRODUCT_CONFIG_V3 cmd /C "set CL=/utf-8 && flutter build windows --release"

:: Android APK
env -u ACC_PRODUCT_CONFIG_V3 flutter build apk --release
```

产物分别位于：
- `build/windows/x64/runner/Release/video_chat.exe`
- `build/app/outputs/flutter-apk/app-release.apk`

---

## 七、其他说明

- **未签名**：APK 为 debug 风格 release（无上架签名），可正常安装自用；若要上架应用商店需另行配置签名。
- **TURN 中继**：当前仅 STUN，仅限同一局域网/可直连网络。跨公网需自建 TURN（如 coturn）并在 `lib/services/webrtc_service.dart` 的 `RTCConfiguration` 里加入 `iceServers`。
- **iOS / macOS / Linux 壳**：尚未生成，如需可运行 `flutter create --platforms=ios,macos,linux .` 后各自构建。
