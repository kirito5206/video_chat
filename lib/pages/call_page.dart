import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../viewmodels/call_viewmodel.dart';

/// 通话页面 - 视频通话主界面
///
/// 完整对齐 web_client.html 的交互：
/// 1. 默认「并排」(split, 左右各半)，与 web 的 grid 1fr 1fr 一致；
/// 2. 「大小窗」按钮循环：并排 ↔ 远程全屏(对方铺满, 自己画中画) ↔ 本地全屏；
/// 3. 聚焦态下未被聚焦的一方变为右下角小窗(PiP)，小窗右上角有「×」可关闭，
///    点「大小窗」可再把小窗唤回（对齐 web 的 pip-close / pip-hidden）；
/// 4. 移动端点一下画面浮现悬浮控制（大小窗 / 全屏），3 秒后自动隐藏（对齐 web 手机端 .viewctl）；
/// 5. 顶部保留 ICE 连接状态灯与调试入口，底部保留静音/摄像头/翻转/挂断。
class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> with WidgetsBindingObserver {
  /// 视图模式：'split' 并排(默认) | 'remote' 远程全屏 | 'local' 本地全屏
  /// 对齐 web_client.html 的 VIEW_ORDER=['split','remote','local']
  String _viewMode = 'split';

  /// 小窗(PiP)是否被「×」关闭（仅聚焦态有意义）
  bool _pipHidden = false;

  /// 移动端(安卓/iOS)才有前后摄像头，才需要「翻转」按钮
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 移动端悬浮控制：点画面弹出「大小窗 / 全屏」（参考 web 手机端的 .viewctl 浮层）
  bool _controlsVisible = false;
  Timer? _controlsTimer;
  bool _isFsMobile = false;

  void _onSwap() {
    // 对齐 web：小窗被关闭时点「大小窗」先唤回小窗，否则循环切换布局
    if (_pipHidden) {
      setState(() => _pipHidden = false);
      return;
    }
    const order = ['split', 'remote', 'local'];
    setState(() {
      _viewMode = order[(order.indexOf(_viewMode) + 1) % order.length];
    });
  }

  void _toggleMobileControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleFullscreen() {
    _isFsMobile = !_isFsMobile;
    if (_isFsMobile) {
      // 进入横屏全屏：隐藏系统栏 + 锁定横屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // 退出全屏：恢复系统栏 + 回到竖屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    }
    setState(() {});
    _scheduleHideControls();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  @override
  void dispose() {
    _controlsTimer?.cancel();
    if (_isFsMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) _showExitDialog();
      },
      child: Consumer<CallViewModel>(
        builder: (context, vm, _) => Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              // ─── 视频区（并排 / 远程全屏+小窗 / 本地全屏+小窗）──
              // 移动端点画面弹出悬浮控制（参考 web 手机端的 .viewctl 浮层）
              _isMobile
                  ? GestureDetector(
                      onTap: _toggleMobileControls,
                      onHorizontalDragEnd: (_) {
                        // 轻扫切换布局（对齐 web 手机端左右滑动）
                        _onSwap();
                        _scheduleHideControls();
                      },
                      child: _buildVideoArea(vm),
                    )
                  : _buildVideoArea(vm),

              // ─── 移动端悬浮控制（大小窗 / 全屏，点画面显示）──
              if (_isMobile && _controlsVisible)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 130,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _floatingBtn(
                        Icons.swap_horiz_rounded,
                        '大小窗',
                        () {
                          _onSwap();
                          _scheduleHideControls();
                        },
                      ),
                      const SizedBox(width: 28),
                      _floatingBtn(
                        _isFsMobile
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        '全屏',
                        _toggleFullscreen,
                      ),
                    ],
                  ),
                ),

              // ─── 顶部栏：返回 + ICE 状态 + 调试 ──
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => _showExitDialog(),
                        icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                      ),
                      const Spacer(),
                      _buildConnectionBadge(vm),
                      IconButton(
                        onPressed: () => _showDebugDialog(vm),
                        icon: const Icon(Icons.bug_report, color: Colors.white70),
                        tooltip: '调试日志',
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),

              // ─── 底部控制栏 ──────────────────
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildControlBar(vm),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 占位图（无流时显示）
  Widget _buildPlaceholder({required bool isRemote}) {
    return Container(
      color: isRemote ? const Color(0xFF1A1A2E) : Colors.transparent,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isRemote ? Icons.person_outline_rounded : Icons.videocam_off_rounded,
              size: 64,
              color: Colors.white24,
            ),
            const SizedBox(height: 12),
            Text(
              isRemote ? '等待对方加入...' : '摄像头未开启',
              style: const TextStyle(color: Colors.white54, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  /// 给视频叠加「远程 / 本地」标签（对齐 web 的 .vlabel）
  Widget _wrapLabel(Widget child, String label, {bool isRemote = true}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 10,
          left: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      ],
    );
  }

  /// 根据 _viewMode 构建视频区：并排 / 远程全屏 / 本地全屏
  /// 对齐 web_client.html 的「切换大小窗」(split↔remote↔local 循环)
  Widget _buildVideoArea(CallViewModel vm) {
    // 默认并排：左右各半，与 web 的 grid 1fr 1fr 一致
    if (_viewMode == 'split') {
      return Row(
        children: [
          Expanded(child: ClipRect(child: _wrapLabel(_remoteVideo(vm), '远程'))),
          const SizedBox(width: 2),
          Expanded(child: ClipRect(child: _wrapLabel(_localVideo(vm), '本地'))),
        ],
      );
    }
    final bool localFs = _viewMode == 'local';
    final Widget big = localFs ? _localVideo(vm) : _remoteVideo(vm);
    final Widget pip = localFs ? _remoteVideo(vm) : _localVideo(vm);
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(child: _wrapLabel(big, localFs ? '本地' : '远程')),
        ),
        // 聚焦态下，未被聚焦的一方变为右下角小窗(PiP)，带「×」可关闭
        if (!_pipHidden)
          Positioned(
            right: 16,
            bottom: 130,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 130,
                    height: 173,
                    child: ClipRect(
                      child: _wrapLabel(
                        pip,
                        localFs ? '远程' : '本地',
                        isRemote: !localFs,
                      ),
                    ),
                  ),
                ),
                // 小窗「×」关闭按钮（对齐 web 的 .pip-close）
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => setState(() => _pipHidden = true),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _remoteVideo(CallViewModel vm) {
    if (vm.webrtc == null || !vm.isLocalRendererInit) {
      return _buildPlaceholder(isRemote: true);
    }
    return RTCVideoView(
      vm.webrtc!.remoteRenderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }

  Widget _localVideo(CallViewModel vm) {
    if (vm.webrtc == null || !vm.isLocalRendererInit) {
      return _buildPlaceholder(isRemote: false);
    }
    return RTCVideoView(
      vm.webrtc!.localRenderer,
      mirror: true,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }

  /// ICE 连接状态徽章
  Widget _buildConnectionBadge(CallViewModel vm) {
    if (vm.webrtc == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: vm.webrtc!.connectionState,
      builder: (_, iceState, __) {
        final stateStr = iceState.toString().split('.').last;
        Color color;
        switch (iceState) {
          case RTCIceConnectionState.RTCIceConnectionStateConnected:
          case RTCIceConnectionState.RTCIceConnectionStateCompleted:
            color = Colors.green;
            break;
          case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          case RTCIceConnectionState.RTCIceConnectionStateFailed:
            color = Colors.red;
            break;
          case RTCIceConnectionState.RTCIceConnectionStateChecking:
          case RTCIceConnectionState.RTCIceConnectionStateNew:
            color = Colors.orange;
            break;
          default:
            color = Colors.grey;
        }
        return Tooltip(
          message: 'ICE: $stateStr',
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        );
      },
    );
  }

  /// 底部控制栏
  Widget _buildControlBar(CallViewModel vm) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildActionButton(
                    icon: vm.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    label: vm.isMuted ? '取消静音' : '静音',
                    isActive: !vm.isMuted,
                    onTap: () => vm.toggleMute(),
                  ),
                  _buildActionButton(
                    icon: vm.isVideoOff
                        ? Icons.videocam_off_rounded
                        : Icons.videocam_rounded,
                    label: vm.isVideoOff ? '开启视频' : '关闭视频',
                    isActive: !vm.isVideoOff,
                    onTap: () => vm.toggleVideo(),
                  ),
                  // 翻转仅移动端有前后摄像头
                  if (_isMobile)
                    _buildActionButton(
                      icon: Icons.cameraswitch_rounded,
                      label: '翻转',
                      isActive: true,
                      onTap: () => vm.switchCamera(),
                    ),
                  // 大小窗切换：桌面放控制栏；移动端改为悬浮按钮(参考 web 手机端)
                  if (!_isMobile)
                    _buildActionButton(
                      icon: Icons.swap_horiz_rounded,
                      label: '大小窗',
                      isActive: true,
                      onTap: _onSwap,
                    ),

                  // 挂断按钮
                  _buildHangupButton(vm),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 移动端悬浮圆形按钮（毛玻璃风格，对齐 web 手机端 .vc-btn）
  Widget _floatingBtn(IconData icon, String label, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      ],
    );
  }

  /// 通用圆形控制按钮
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: isActive ? Colors.white24 : Colors.red.withValues(alpha: 0.7),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }

  /// 挂断按钮
  Widget _buildHangupButton(CallViewModel vm) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.red,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => vm.endCall(),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Icon(Icons.call_end_rounded, color: Colors.white, size: 24),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text('挂断',
            style: TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }

  void _showDebugDialog(CallViewModel vm) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setStateDialog) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('调试日志')),
              TextButton(
                onPressed: () => setStateDialog(() {}),
                child: const Text('刷新'),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: ListView.builder(
              itemCount: vm.debugLog.length,
              itemBuilder: (_, i) {
                final idx = vm.debugLog.length - 1 - i;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    vm.debugLog[idx],
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _showExitDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开房间？'),
        content: const Text('离开后将结束当前通话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              context.read<CallViewModel>().leaveRoom();
              Navigator.pop(ctx); // 关闭对话框
              Navigator.pop(ctx); // 返回首页
            },
            child: const Text('离开'),
          ),
        ],
      ),
    );
  }
}
