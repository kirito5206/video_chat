# VideoChat 安卓 APK 构建指南

> 本项目已具备完整可打包结构：`lib/`(Flutter 业务代码) + `android/`(原生工程壳，由 `flutter create` 生成)。
> `flutter analyze` 已通过 (No issues found)。

## 一、核心结论

出手机能装的 APK，**需要一台配好 Android 工具链的开发机**，但**不一定是 Android Studio 这个 IDE**。

| 你真正需要的 | 为什么 | 怎么获得 |
|---|---|---|
| **Android SDK** (platform + build-tools) | `flutter build apk` 底层调用 Gradle 编译原生层 | Android Studio 自带；或单独装 command-line tools |
| **JDK 17** | Gradle 编译需要 | Android Studio 自带；或单独装 |
| **Flutter SDK** | 把 Dart 代码编译成 APK | 本项目用 3.44.6，放 `E:\dev\flutter` |
| Gradle | 已随 `android/` 工程自带 wrapper，**无需单独装** | — |

> 最省事的办法就是**装 Android Studio**（SDK + JDK + 模拟器一站式），装完跑 `flutter doctor` 让 Flutter 自动识别。
> 不装 Android Studio 也行：单独装 Android SDK command-line tools + JDK，再设 `ANDROID_HOME` 环境变量指向 SDK 目录。

## 二、在开发机上操作步骤

1. 安装 **Android Studio**（勾选 Android SDK + 模拟器），或单独装 Android SDK + JDK 17。
2. 把本项目（整个 `E:\dev\video_chat` 或你 clone 的副本）放到开发机。
3. 配置环境变量（若未用 Android Studio 自动配置）：
   - `ANDROID_HOME` = 你的 SDK 路径（如 `C:\Users\你\AppData\Local\Android\Sdk`）
   - PATH 加上 `%ANDROID_HOME%\platform-tools`（用来自 `adb install`）
4. 验证环境：
   ```bash
   flutter doctor -v
   ```
   确保 "Android toolchain" 一项为勾选 ✓。
5. 构建 APK（二选一）：
   - **一键**：双击 `build_apk.bat`
   - **手动**：
     ```bash
     cd video_chat
     flutter pub get
     flutter build apk --release
     ```
6. 产物位置：
   ```
   build/app/outputs/flutter-apk/app-release.apk
   ```
7. 安装到手机：
   ```bash
   flutter install
   # 或手动：adb install build/app/outputs/flutter-apk/app-release.apk
   ```

## 三、手机端怎么用

1. 手机开启 **USB 调试**（设置→关于手机→连点版本号 7 次→开发者选项→USB 调试），USB 连电脑后 `adb install`。
2. 或在手机上用文件管理器直接打开 APK 安装（需允许"未知来源"）。
3. 打开 App，填信令服务器地址：
   - 同机/同局域网：`ws://<电脑局域网IP>:8765`（如 `ws://192.168.1.50:8765`）
   - 跨公网：需公网 IP/域名 + 端口映射 + TURN 兜底
4. 两人（或用 `web_client.html` 当一端）填**同一房间号**、不同 UserID，即可互通视频。

## 四、本沙箱为什么不能出 APK

- 无 Android SDK / JDK（装它们要数 GB，C 盘此前仅剩 31G，已迁 E 盘但仍未装）
- 非管理员，装 Android Studio 的某些组件受限
- 无显示器/无真机

沙箱已完成的职责：**代码可编译验证 + 生成 android 工程壳 + 打 APK 的脚本与文档**。出包这一步由你的开发机执行即可。
