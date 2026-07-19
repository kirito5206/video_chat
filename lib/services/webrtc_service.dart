import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';

import 'signaling_service.dart';

/// WebRTC 服务 - 核心 P2P 音视频引擎
///
/// 架构要点：
/// 1. 本地媒体采集 → RTCPeerConnection → 远端渲染
/// 2. 通过 SignalingService 完成信令交换（SDP Offer/Answer + ICE）
/// 3. 支持 STUN/TURN 服务器配置（穿透 NAT）
///
/// 关键流程：
/// 呼叫方: getUserMedia → createOffer → setLocalDescription → [发送 offer]
///                                              ↓ [收到 answer]
///                                    setRemoteDescription → ICE 收集完成 → 连接建立
///
/// 被叫方: [收到 offer] → setRemoteDescription → createAnswer → setLocalDescription
///                                                        ↓ [发送 answer]
///                                          呼叫方 setRemoteDescription → 连接建立
class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final Logger _logger = Logger();

  /// 信令服务引用
  final SignalingService signaling;

  /// 本地视频渲染器
  final localRenderer = RTCVideoRenderer();

  /// 远程视频渲染器
  final remoteRenderer = RTCVideoRenderer();

  /// RTC 配置（flutter_webrtc 使用 Map 格式）
  ///
  /// - iceServers：Google 公共 STUN，生产环境需配置自己的 TURN
  /// - sdpSemantics：使用现代的 unified-plan（addTrack/onTrack 依赖它）
  static const Map<String, dynamic> rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'iceTransportPolicy': 'all',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'sdpSemantics': 'unified-plan',
  };

  /// 连接状态
  ValueNotifier<RTCIceConnectionState> connectionState =
      ValueNotifier(RTCIceConnectionState.RTCIceConnectionStateNew);

  /// 是否已存在 PeerConnection（用于防止重复发起/重建连接）
  bool get hasConnection => _peerConnection != null;

  /// 远端描述是否已设置（用于 trickle ICE 下缓存过早到达的 candidate）
  bool _remoteDescSet = false;

  /// 远端描述就绪前到达的 ICE candidate 缓存（避免被静默丢弃）
  final List<Map<String, dynamic>> _pendingCandidates = [];

  /// 数据通道（用于文本/文件传输）
  RTCDataChannel? _dataChannel;

  /// 远程流到达回调（用于 UI 状态切换为"通话中"）
  ///
  /// 在收到第一个远端轨道（onTrack）时触发，参数 streamId。
  /// 由 CallViewModel 注入，用于把 CallState 切到 onCall。
  void Function(String streamId)? onRemoteTrack;

  /// 调试日志回调（由 CallViewModel 注入，汇入屏幕可见的调试面板）
  void Function(String)? onLog;

  /// 数据通道消息流
  final _dataChannelMessages =
      StreamController<String>.broadcast();
  Stream<String> get onDataChannelMessage =>
      _dataChannelMessages.stream;

  WebRTCService({required this.signaling});

  /// 初始化渲染器（必须在 Widget mount 后调用）
  Future<void> initializeRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _logger.i('视频渲染器初始化完成');
  }

  /// 打开本地摄像头/麦克风
  ///
  /// [facingMode] 前置('user') 或 后置('environment')
  Future<void> openLocalMedia({
    String facingMode = 'user',
    bool audio = true,
    bool video = true,
  }) async {
    final constraints = <String, dynamic>{
      'audio': audio,
      'video': {
        'facingMode': facingMode,
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(constraints);
      localRenderer.srcObject = _localStream;
      _logger.i('本地媒体流开启成功');
    } catch (e) {
      _logger.e('打开本地设备失败: $e');
      rethrow;
    }
  }

  /// 关闭本地媒体流
  void closeLocalMedia() {
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    _localStream?.dispose();
    _localStream = null;
    localRenderer.srcObject = null;
    _logger.i('本地媒体流已关闭');
  }

  /// 切换前后摄像头
  Future<void> switchCamera() async {
    if (_localStream == null) return;
    final videoTrack = _localStream!
        .getVideoTracks()
        .firstWhere((t) => t.kind == 'video');
    await Helper.switchCamera(videoTrack);
    _logger.i('已切换摄像头');
  }

  /// 静音/取消静音
  void toggleMuteAudio(bool muted) {
    _localStream?.getAudioTracks().forEach((t) {
      t.enabled = !muted;
    });
  }

  /// 开启/关闭视频
  void toggleMuteVideo(bool muted) {
    _localStream?.getVideoTracks().forEach((t) {
      t.enabled = !muted;
    });
  }

  // ─── P2P 连接管理 ────────────────────────────────

  /// 创建 P2P 连接并发起呼叫（Caller 端）
  ///
  /// 流程：
  /// 1. 创建 RTCPeerConnection
  /// 2. 添加本地媒体流
  /// 3. 创建 DataChannel（可选）
  /// 4. 创建 SDP Offer
  /// 5. 设置本地描述并**立即**通过信令发送（trickle ICE，不等 ICE 收集）
  Future<void> createAndSendOffer(String targetUserId) async {
    await _createPeerConnection();
    await _attachLocalStream();

    // Caller 主动创建数据通道
    await _createDataChannel();

    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    // 关键修复：立即发送 offer，ICE candidate 走 trickle 在 onIceCandidate 中
    // 后续逐个补发。若先等满 ICE 收集（最长 10s）再发，期间产生的 candidate
    // 会被广播给房间，但对方尚未建连（要等收到 offer 才建连），导致 candidate
    // 被丢弃、ICE 无法建立媒体通道 —— 表现为"已连接但无画面"。
    final target = signaling.currentRoomId ?? targetUserId;
    signaling.sendOffer(target, offer.toMap());
    _logger.i('Offer 已发送（目标房间 $target）');
    onLog?.call('已发送 OFFER → 房间 $target');
  }

  /// 接收远程 Offer 并返回 Answer（Callee 端）
  ///
  /// 当收到对方的 call + offer 后调用此方法
  Future<void> receiveOfferAndAnswer(
    String callerId,
    Map<String, dynamic> offerSdp,
  ) async {
    _logger.i('收到来自 $callerId 的 Offer，准备回应...');
    onLog?.call('收到 OFFER，准备 ANSWER');

    await _createPeerConnection();
    await _attachLocalStream();

    // 设置远程 Offer
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp['sdp'], offerSdp['type']),
    );
    // 远端描述就绪，先把此前缓存的 candidate 补加进去（trickle ICE）
    await _flushPendingCandidates();

    // 创建 Answer
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // 关键修复：立即发送 answer（trickle ICE），candidate 由 onIceCandidate 补发。
    // 理由同 createAndSendOffer：不能等满 ICE 收集再发，否则本端 candidate 会
    // 在对方建连前被丢弃，导致媒体通道建立失败、无画面。
    final target = signaling.currentRoomId ?? callerId;
    signaling.sendAnswer(target, answer.toMap());
    _logger.i('Answer 已发送（目标房间 $target）');
    onLog?.call('已发送 ANSWER → 房间 $target');
  }

  /// 接收远程 Answer（Caller 端收到 Callee 的响应后调用）
  Future<void> receiveAnswer(Map<String, dynamic> answerSdp) async {
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(answerSdp['sdp'], answerSdp['type']),
    );
    _logger.i('已设置远程 Answer 描述');
    await _flushPendingCandidates();
  }

  /// 接收并添加 ICE Candidate
  ///
  /// trickle ICE 下 candidate 可能早于 setRemoteDescription 到达。此时直接
  /// addCandidate 会抛异常被丢弃，导致 ICE 找不到可用路径、画面永远连不上。
  /// 因此：远端描述就绪则立即加入，否则缓存，待 setRemoteDescription 成功后 flush。
  Future<void> receiveCandidate(Map<String, dynamic> candidateData) async {
    if (_peerConnection == null) return;
    if (!_remoteDescSet) {
      _pendingCandidates.add(candidateData);
      _logger.d('远端描述未就绪，缓存 candidate（待 flush）');
      return;
    }
    try {
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      _logger.w('添加 ICE candidate 失败（已忽略）: $e');
    }
  }

  /// 远端描述设置完成后，把缓存的 candidate 补加进去（trickle ICE 关键补丁）
  Future<void> _flushPendingCandidates() async {
    if (_peerConnection == null) return;
    _remoteDescSet = true;
    if (_pendingCandidates.isEmpty) return;
    _logger.i('flush 缓存的 ${_pendingCandidates.length} 个 candidate');
    for (final c in _pendingCandidates) {
      try {
        final candidate = RTCIceCandidate(
          c['candidate'],
          c['sdpMid'],
          c['sdpMLineIndex'],
        );
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        _logger.w('flush candidate 失败（已忽略）: $e');
      }
    }
    _pendingCandidates.clear();
  }

  // ─── 内部方法 ─────────────────────────────────────

  /// 创建 RTCPeerConnection 并注册事件监听
  Future<void> _createPeerConnection() async {
    // 清理旧连接
    await closeConnection();

    _peerConnection = await createPeerConnection(rtcConfig);
    // 重置 trickle ICE 缓存状态（每个新连接重新来过）
    _remoteDescSet = false;
    _pendingCandidates.clear();

    // 监听 ICE 连接状态变化
    _peerConnection!.onIceConnectionState = (state) {
      _logger.i('ICE 连接状态: $state');
      onLog?.call('ICE 状态: $state');
      connectionState.value = state;
    };

    // 收集到 ICE Candidate 时通过信令发送
    _peerConnection!.onIceCandidate = (candidate) {
      _logger.d('ICE Candidate: ${candidate.candidate}');
      onLog?.call('发送 CANDIDATE');
      if (signaling.currentRoomId != null &&
          signaling.currentUserId != null) {
        // 发送给房间内的对方
        signaling.sendCandidate(
          signaling.currentRoomId!, // P2P 场景下发给房间即可
          candidate.toMap(),
        );
      }
    };

    // 接收到远程流
    _peerConnection!.onTrack = (event) async {
      _logger.i('收到远程轨道: ${event.track.kind}');
      onLog?.call('收到远程轨道 ${event.track.kind}');
      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams[0];
      } else {
        // 兜底：部分 flutter_webrtc 版本 event.streams 为空，需手动建流承载远端轨，
        // 否则远程画面永远空白（"已连接但无画面"的典型原因之一）。
        stream = await createLocalMediaStream('remote-stream');
        stream.addTrack(event.track);
        _logger.w('event.streams 为空，已手动建流承载远端轨');
      }
      remoteRenderer.srcObject = stream;
      onRemoteTrack?.call(stream.id);
    };

    // 接收 DataChannel（被叫方接收呼叫方创建的 channel）
    _peerConnection!.onDataChannel = (channel) {
      _setupDataChannel(channel);
    };

    _logger.i('RTCPeerConnection 已创建');
  }

  /// 将本地媒体流添加到 PeerConnection（unified-plan 用 addTrack）
  Future<void> _attachLocalStream() async {
    if (_localStream != null && _peerConnection != null) {
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      _logger.i('本地流已添加到连接');
    }
  }

  /// 创建数据通道（用于文本聊天、文件传输等辅助功能）
  Future<void> _createDataChannel() async {
    final dc = await _peerConnection!.createDataChannel(
      'chat',
      RTCDataChannelInit()..ordered = true,
    );
    _setupDataChannel(dc);
  }

  /// 配置数据通道事件
  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      _logger.i('DataChannel 状态: $state');
    };
    channel.onMessage = (data) {
      if (data.isBinary) {
        _logger.d('收到二进制数据: ${data.binary.length} bytes');
      } else {
        _logger.d('收到文本: ${data.text}');
        _dataChannelMessages.add(data.text);
      }
    };
  }

  /// 通过 DataChannel 发送文本消息
  void sendDataChannelMessage(String text) {
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(text));
    } else {
      _logger.w('DataChannel 未就绪，消息未发送');
    }
  }

  /// 关闭 P2P 连接并释放资源
  Future<void> closeConnection() async {
    _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
    remoteRenderer.srcObject = null;
    connectionState.value = RTCIceConnectionState.RTCIceConnectionStateNew;
    _logger.i('P2P 连接已关闭');
  }

  /// 释放所有资源（包括渲染器）
  Future<void> dispose() async {
    await closeConnection();
    closeLocalMedia();
    localRenderer.dispose();
    remoteRenderer.dispose();
    _dataChannelMessages.close();
  }
}
