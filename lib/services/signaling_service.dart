import 'dart:async';
import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/signal_message.dart';

/// WebSocket 信令服务
///
/// 职责：
/// 1. 与信令服务器建立/维护 WebSocket 连接
/// 2. 发送和接收信令消息（JSON 格式）
/// 3. 消息分发：根据 type 路由到对应处理器
///
/// 使用示例：
/// ```dart
/// final signaling = SignalingService();
/// signaling.connect('ws://localhost:8765');
/// signaling.onMessage.listen((msg) => handle(msg));
/// ```
class SignalingService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final Logger _logger = Logger();

  /// 是否已连接
  bool get isConnected => _channel != null && _channel!.closeCode == null;

  /// 当前用户ID（加入房间时设置）
  String? currentUserId;

  /// 当前房间号
  String? currentRoomId;

  /// 消息流 - 外部监听此流接收服务端推送的消息
  final _messageController = StreamController<SignalMessage>.broadcast();
  Stream<SignalMessage> get onMessage => _messageController.stream;

  /// 心跳定时器（保活，防止空闲被服务端或中间代理关闭）
  Timer? _pingTimer;

  /// 连接状态变化流
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  /// 状态变更回调
  Function(String)? onUserJoined;
  Function(String)? onUserLeft;
  Function(String, Map<String, dynamic>)? onCallReceived;
  Function()? onCallAccepted;
  Function(String)? onCallRejected;
  Function()? onHangup;

  /// 连接到信令服务器
  ///
  /// [url] WebSocket 地址，如 'ws://192.168.1.100:8765'
  /// [userId] 连接后立即发送注册消息，避免服务端 10 秒注册超时关闭连接
  ///          （web 版在 WebSocket.onopen 中立刻发送 {userId}，原生端需对齐）。
  Future<void> connect(String url, {String? userId}) async {
    if (isConnected) {
      _logger.w('已连接，跳过重复连接');
      return;
    }

    try {
      _logger.i('正在连接信令服务器: $url');
      _channel = WebSocketChannel.connect(Uri.parse(url));
      await _channel!.ready;

      // 监听消息
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          _logger.e('WebSocket 错误: $error');
          _connectionController.add(false);
        },
        onDone: () {
          _logger.i('WebSocket 连接关闭');
          _connectionController.add(false);
        },
      );

      // 立即发送注册消息：服务端 handle_connection 第一步会等待首条带 userId
      // 的消息，10 秒超时则关闭连接。原生端连上后若不马上注册，用户填房间号
      // 的间隙一旦超过 10 秒，连接就会被关掉，后续 join 永远发不出去（典型
      // 表现：两端都"已进入房间"却永远"等待对方加入"）。
      if (userId != null) {
        currentUserId = userId;
        send(SignalMessage(type: 'register', from: userId));
        _logger.i('已发送注册消息: $userId');
      }

      // 心跳保活：每 20 秒发一次 ping，防止空闲被服务端/代理关闭
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (isConnected) {
          send(SignalMessage(type: 'ping'));
        }
      });

      _connectionController.add(true);
      _logger.i('信令服务器连接成功');
    } catch (e) {
      _logger.e('连接信令服务器失败: $e');
      _connectionController.add(false);
      rethrow;
    }
  }

  /// 断开连接
  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    currentUserId = null;
    currentRoomId = null;
    _logger.i('已断开信令连接');
  }

  // ─── 房间操作 ─────────────────────────────────────

  /// 加入房间
  void joinRoom(String userId, String roomId) {
    currentUserId = userId;
    currentRoomId = roomId;
    send(SignalMessage(type: 'join', from: userId, roomId: roomId));
    _logger.i('$userId 加入房间 $roomId');
  }

  /// 离开房间
  void leaveRoom() {
    if (currentUserId != null && currentRoomId != null) {
      send(SignalMessage(
        type: 'leave',
        from: currentUserId,
        roomId: currentRoomId,
      ));
      _logger.i('$currentUserId 离开房间 $currentRoomId');
    }
    currentUserId = null;
    currentRoomId = null;
  }

  // ─── WebRTC 信令操作 ──────────────────────────────

  /// 发送 Offer（呼叫方发起）
  void sendOffer(String targetUserId, Map<String, dynamic> sdp) {
    send(SignalMessage(
      type: 'offer',
      from: currentUserId,
      to: targetUserId,
      roomId: currentRoomId,
      // sdp 已是 {type, sdp} 字典（来自 localDesc.toMap()），使用单包格式，
      // 与服务端/Web 端约定一致：线上 data = {type, sdp}。
      data: sdp,
    ));
  }

  /// 发送 Answer（被叫方响应）
  void sendAnswer(String targetUserId, Map<String, dynamic> sdp) {
    send(SignalMessage(
      type: 'answer',
      from: currentUserId,
      to: targetUserId,
      roomId: currentRoomId,
      // sdp 已是 {type, sdp} 字典，单包格式（data = {type, sdp}）。
      data: sdp,
    ));
  }

  /// 发送 ICE Candidate
  void sendCandidate(String targetUserId, Map<String, dynamic> candidate) {
    send(SignalMessage(
      type: 'candidate',
      from: currentUserId,
      to: targetUserId,
      roomId: currentRoomId,
      data: candidate,
    ));
  }

  // ─── 呼叫控制 ─────────────────────────────────────

  /// 发起呼叫
  void call(String targetUserId) {
    send(SignalMessage(
      type: 'call',
      from: currentUserId,
      to: targetUserId,
      roomId: currentRoomId,
    ));
    _logger.i('呼叫 $targetUserId');
  }

  /// 接受呼叫
  void acceptCall(String callerId) {
    send(SignalMessage(
      type: 'accept',
      from: currentUserId,
      to: callerId,
      roomId: currentRoomId,
    ));
  }

  /// 拒绝呼叫
  void rejectCall(String callerId) {
    send(SignalMessage(
      type: 'reject',
      from: currentUserId,
      to: callerId,
      roomId: currentRoomId,
    ));
  }

  /// 挂断
  void hangup([String? targetUserId]) {
    send(SignalMessage(
      type: 'hangup',
      from: currentUserId,
      to: targetUserId ?? currentRoomId, // 广播给房间内所有人
      roomId: currentRoomId,
    ));
  }

  // ─── 内部方法 ─────────────────────────────────────

  /// 发送消息到底层 WebSocket
  void send(SignalMessage message) {
    if (!isConnected) {
      _logger.e('未连接，无法发送消息: $message');
      return;
    }
    final jsonStr = jsonEncode(message.toJson());
    _logger.d('发送: $jsonStr');
    _channel!.sink.add(jsonStr);
  }

  /// 处理收到的消息
  void _onMessage(dynamic message) {
    try {
      final json = jsonDecode(message as String) as Map<String, dynamic>;
      final signal = SignalMessage.fromJson(json);
      _logger.d('收到: ${signal.type} 来自 ${signal.from}');

      // 分发到对应的处理回调
      switch (signal.type) {
        case 'join':
          onUserJoined?.call(signal.from!);
          break;
        case 'leave':
          onUserLeft?.call(signal.from!);
          break;
        case 'call':
          onCallReceived?.call(signal.from!, signal.data ?? {});
          break;
        case 'accept':
          onCallAccepted?.call();
          break;
        case 'reject':
          onCallRejected?.call(signal.from!);
          break;
        case 'hangup':
          onHangup?.call();
          break;
        default:
          // offer / answer / candidate 直接转发给 WebRTC 层
          break;
      }

      // 所有消息都推送到主消息流
      _messageController.add(signal);
    } catch (e) {
      _logger.e('解析消息失败: $e');
    }
  }

  void dispose() {
    _pingTimer?.cancel();
    _subscription?.cancel();
    _messageController.close();
    _connectionController.close();
    _channel?.sink.close();
  }
}
