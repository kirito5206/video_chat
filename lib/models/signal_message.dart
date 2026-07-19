/// 信令消息类型枚举
enum SignalType {
  /// 加入房间
  join,

  /// 离开房间
  leave,

  /// WebRTC Offer
  offer,

  /// WebRTC Answer
  answer,

  /// ICE Candidate
  candidate,

  /// 呼叫请求（对方振铃）
  call,

  /// 接受呼叫
  accept,

  /// 拒绝呼叫
  reject,

  /// 挂断
  hangup,

  /// 用户已准备好（进入房间）
  ready,
}

/// 信令消息基类
/// 服务端和客户端共用此格式进行通信
///
/// JSON 格式示例：
/// ```json
/// {
///   "type": "offer",
///   "from": "user_a",
///   "to": "user_b",
///   "roomId": "room_123",
///   "data": { "sdp": "..." }
/// }
/// ```
class SignalMessage {
  final String type;
  final String? from;
  final String? to;
  final String? roomId;
  final Map<String, dynamic>? data;

  SignalMessage({
    required this.type,
    this.from,
    this.to,
    this.roomId,
    this.data,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      type: json['type'] as String,
      from: json['from'] as String?,
      to: json['to'] as String?,
      roomId: json['roomId'] as String?,
      data: json['data'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (roomId != null) 'roomId': roomId,
    if (data != null) 'data': data,
  };

  @override
  String toString() =>
      'SignalMessage(type: $type, from: $from, to: $to, roomId: $roomId)';
}
