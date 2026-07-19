import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';
import '../models/signal_message.dart';

/// 通话状态枚举
enum CallState {
  /// 空闲
  idle,

  /// 正在连接信令服务器
  connecting,

  /// 已连接信令，等待进入房间
  connected,

  /// 在房间内，等待对方
  inRoom,

  /// 通话中（P2P 连接已建立）
  onCall,
}

/// 通话 ViewModel - 编排信令和 WebRTC 的交互流程
///
/// 这是整个应用的核心状态管理器，负责：
/// 1. 信令服务生命周期管理
/// 2. WebRTC 媒体和连接管理
/// 3. 完整呼叫流程的状态机
class CallViewModel extends ChangeNotifier {
  final Logger _logger = Logger();
  final SignalingService _signaling = SignalingService();
  WebRTCService? _webrtc;

  // ─── 公开属性 ─────────────────────────────────────

  CallState _state = CallState.idle;
  CallState get state => _state;

  String? _currentUserId;
  String? get currentUserId => _currentUserId;

  String? _roomId;
  String? get roomId => _roomId;

  String? _remoteUserId;
  String? get remoteUserId => _remoteUserId;

  /// 是否已决定由本端发起连接（确定性单方发起，避免双方同时发造成 glare）
  bool _negotiationStarted = false;
  /// 本端是否为发起方
  bool _isInitiator = false;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  /// 调试日志（屏幕可见，用于排查"进房后连不上对方"等问题）
  final List<String> _debugLog = [];
  List<String> get debugLog => List.unmodifiable(_debugLog);

  void _logDebug(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    _debugLog.add('$ts $msg');
    if (_debugLog.length > 200) _debugLog.removeAt(0);
    // 不触发整页重建（调试面板自行监听 debugLog 时再刷新）
  }

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isVideoOff = false;
  bool get isVideoOff => _isVideoOff;

  bool _isLocalRendererInit = false;
  bool get isLocalRendererInit => _isLocalRendererInit;

  SignalingService get signaling => _signaling;
  WebRTCService? get webrtc => _webrtc;

  // ─── 初始化与连接 ─────────────────────────────────

  /// 初始化并连接到信令服务器
  Future<void> connect(String serverUrl, {String? userId}) async {
    try {
      setState(CallState.connecting);
      setStatus('正在连接服务器...');

      _currentUserId = userId ?? 'user_${DateTime.now().millisecondsSinceEpoch}';

      await _signaling.connect(serverUrl, userId: _currentUserId);

      // 注册信令回调
      _setupSignalingCallbacks();

      _logDebug('已连接信令服务器: $serverUrl (userId=$_currentUserId)');
      setState(CallState.connected);
      setStatus('已连接服务器');
    } catch (e) {
      setStatus('连接失败: $e');
      setState(CallState.idle);
      rethrow;
    }
  }

  /// 配置信令回调 - 将信令事件映射到 WebRTC 操作
  void _setupSignalingCallbacks() {
    // 监听所有消息，处理 WebRTC 相关的信令
    _signaling.onMessage.listen(_handleSignalMessage);

    _signaling.onUserJoined = (userId) {
      _logger.i('用户加入: $userId');
      _onPeerDiscovered(userId);
    };

    _signaling.onUserLeft = (userId) {
      _logger.i('用户离开: $userId');
      if (_remoteUserId == userId) {
        endCall();
        setStatus('$userId 已离开房间');
      }
    };

    _signaling.onHangup = () {
      _logger.i('对方挂断了');
      endCall();
    };
  }

  // ─── 房间操作 ─────────────────────────────────────

  /// 创建或加入房间
  Future<void> joinOrCreateRoom(String roomId) async {
    _roomId = roomId.trim();
    _remoteUserId = null;
    _negotiationStarted = false;
    _isInitiator = false;

    // 初始化 WebRTC 服务
    _webrtc = WebRTCService(signaling: _signaling);
    // 把 WebRTC 层的关键事件也汇入调试日志
    _webrtc!.onLog = _logDebug;
    // 远端流到达 → 切到"通话中"状态（让 UI 显示对方画面）
    _webrtc!.onRemoteTrack = (_) {
      if (_state != CallState.onCall) {
        _logDebug('通话已连接（收到对方画面）');
        setState(CallState.onCall);
        setStatus('通话已连接');
      }
    };
    await _webrtc!.initializeRenderers();
    _isLocalRendererInit = true;

    // 打开本地媒体设备
    try {
      await _webrtc!.openLocalMedia();
      _logDebug('本地摄像头/麦克风已开启');
    } catch (e) {
      setStatus('无法访问摄像头/麦克风: $e');
      _logger.e('打开媒体设备失败: $e');
      _logDebug('打开本地媒体失败: $e');
    }

    // 通过信令加入房间
    _logDebug('发送 join 房间=$roomId userId=$_currentUserId');
    _signaling.joinRoom(_currentUserId!, roomId);

    setState(CallState.inRoom);
    setStatus('已进入房间 $_roomId，等待对方加入...');
  }

  /// 离开当前房间
  void leaveRoom() {
    endCall();
    _signaling.leaveRoom();
    setState(CallState.connected);
    setStatus('已离开房间');
  }

  /// 主动断开信令连接（回到空闲态，可再次连接）
  /// 首页「断开」按钮调用；对应 SignalingService.disconnect()。
  Future<void> disconnect() async {
    _logDebug('手动断开信令连接');
    // 若仍在房间/通话中，先结束通话并通知对方
    if (_state != CallState.idle && _state != CallState.connected) {
      _signaling.hangup();
    }
    await _webrtc?.closeConnection();
    _webrtc?.dispose();
    _webrtc = null;
    _signaling.disconnect();
    _currentUserId = null;
    _roomId = null;
    _remoteUserId = null;
    _negotiationStarted = false;
    _isInitiator = false;
    setState(CallState.idle);
    setStatus('已断开连接');
  }

  // ─── 连接控制 ─────────────────────────────────────

  /// 主动发起 P2P 连接（后进房者调用）。
  /// 底层仍走 WebRTC 的 offer/answer 协商，但对用户不可见、无需手动操作。
  Future<void> _initiatePeerConnection() async {
    if (_webrtc == null || _state != CallState.inRoom) return;
    // 已有 PeerConnection 则跳过，避免 8s 兜底重试把正在建立中的连接关掉重建，
    // 否则会打断协商、导致 ICE 永远连不上（无画面）。
    if (_webrtc!.hasConnection) {
      _logDebug('已存在 P2P 连接，跳过重复发起');
      return;
    }

    setStatus('正在与对方建立连接...');

    try {
      _logDebug('发送 OFFER 给 ${_remoteUserId ?? _roomId}');
      // 优先发给对端 userId；兜底广播给房间
      await _webrtc!.createAndSendOffer(_remoteUserId ?? _roomId!);
    } catch (e) {
      _logger.e('建立连接失败: $e');
      setStatus('连接失败: $e');
    }
  }

  /// 挂断
  void endCall() async {
    _logDebug('通话结束/挂断');
    if (_state != CallState.idle && _state != CallState.connected) {
      _signaling.hangup();
    }
    await _webrtc?.closeConnection();
    _remoteUserId = null;
    setState(CallState.inRoom);
    setStatus('通话结束');
  }

  /// 发现对端（通过入房回执的 members 或对方加入广播）。
  /// 用 userId 字典序确定性地决定唯一发起方，避免双方同时发起(glare)或都不发起。
  void _onPeerDiscovered(String peerId) {
    _logDebug('发现信号: $peerId');
    if (peerId == _currentUserId || peerId == 'server' || peerId.isEmpty) {
      return;
    }
    _remoteUserId ??= peerId;

    if (_state != CallState.inRoom || _negotiationStarted) return;

    // userId 较小的一方为发起方（稳定且唯一），另一方等待对方 offer 并自动应答
    final amInitiator = (_currentUserId ?? '').compareTo(peerId) < 0;
    _logDebug('发现对端 $peerId，本端为${amInitiator ? '发起方' : '接听方'}');
    if (amInitiator) {
      _negotiationStarted = true;
      _isInitiator = true;
      setStatus('发现对方 $peerId，本端为发起方，正在建立连接...');
      // 给对端一点准备时间，然后发起
      Future.delayed(const Duration(milliseconds: 600), () {
        if (_state == CallState.inRoom && _negotiationStarted && _isInitiator) {
          _initiatePeerConnection();
          // 兜底重试：若 8s 仍未连通，再尝试一次
          Future.delayed(const Duration(seconds: 8), () {
            if (_state == CallState.inRoom && _negotiationStarted && _isInitiator) {
              _logger.w('连接未在预期内建立，重试一次');
              _initiatePeerConnection();
            }
          });
        }
      });
    } else {
      setStatus('发现对方 $peerId，本端为接听方，等待对方发起...');
    }
  }

  // ─── 媒体控制 ─────────────────────────────────────

  /// 切换静音
  void toggleMute() {
    _isMuted = !_isMuted;
    _webrtc?.toggleMuteAudio(_isMuted);
    notifyListeners();
  }

  /// 切换摄像头开关
  void toggleVideo() {
    _isVideoOff = !_isVideoOff;
    _webrtc?.toggleMuteVideo(_isVideoOff);
    notifyListeners();
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    await _webrtc?.switchCamera();
  }

  // ─── 内部方法 ─────────────────────────────────────

  /// 处理信令消息中的 WebRTC 协商
  Future<void> _handleSignalMessage(SignalMessage msg) async {
    switch (msg.type) {
      case 'join':
        // 自己的入房回执：data.members 含房间内当前成员。
        // 发现对端后交给 _onPeerDiscovered 决定由谁发起连接（确定性单方发起）。
        if (msg.data != null && msg.data!['members'] != null) {
          final members = List<String>.from(msg.data!['members'] as List);
          _logDebug('收到 join 回执 members=${members.join(',')}');
          for (final m in members) {
            _onPeerDiscovered(m);
          }
        }
        break;

      case 'offer':
        // 收到远程 Offer → 自动应答（无需手动"接听"），并标记通话中
        if (_webrtc != null && msg.data != null) {
          _logDebug('收到 OFFER 来自 ${msg.from}');
          _remoteUserId = msg.from;
          await _webrtc!.receiveOfferAndAnswer(msg.from!, msg.data!);
          setState(CallState.onCall); // 已自动应答，直接进入通话中
          setStatus('已与 ${msg.from} 建立连接');
        }
        break;

      case 'answer':
        // 收到远程 Answer → 设置为远端描述
        if (_webrtc != null && msg.data != null) {
          _logDebug('收到 ANSWER 来自 ${msg.from}');
          await _webrtc!.receiveAnswer(msg.data!);
          setState(CallState.onCall);
        }
        break;

      case 'candidate':
        // 收到 ICE Candidate → 添加到 PeerConnection
        if (_webrtc != null && msg.data != null) {
          _logDebug('收到 CANDIDATE 来自 ${msg.from}');
          await _webrtc!.receiveCandidate(msg.data!);
        }
        break;

      default:
        break;
    }
  }

  void setState(CallState newState) {
    _state = newState;
    notifyListeners();
  }

  void setStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _webrtc?.dispose();
    _signaling.dispose();
    super.dispose();
  }
}
