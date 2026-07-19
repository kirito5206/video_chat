import 'package:flutter/foundation.dart';

/// 房间信息模型
@immutable
class RoomInfo {
  final String roomId;
  final List<String> participants;

  const RoomInfo({
    required this.roomId,
    this.participants = const [],
  });

  RoomInfo copyWith({
    String? roomId,
    List<String>? participants,
  }) {
    return RoomInfo(
      roomId: roomId ?? this.roomId,
      participants: participants ?? this.participants,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomInfo && roomId == other.roomId;

  @override
  int get hashCode => roomId.hashCode;

  @override
  String toString() => 'RoomInfo(roomId: $roomId, participants: $participants)';
}

/// 用户信息模型
@immutable
class UserInfo {
  final String userId;
  final String displayName;

  const UserInfo({
    required this.userId,
    this.displayName = '',
  });
}
