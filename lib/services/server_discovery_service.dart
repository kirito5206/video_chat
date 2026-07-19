import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DiscoveredServer {
  const DiscoveredServer(this.ip, this.port);

  final String ip;
  final int port;
}

/// Discovers the signaling server over UDP, with a TCP subnet scan as fallback.
class ServerDiscoveryService {
  static const int discoveryPort = 8766;
  static const int signalPort = 8765;
  static const String multicastAddress = '239.255.255.250';
  static const MethodChannel _networkChannel =
      MethodChannel('video_chat/network_discovery');

  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  Timer? _queryTimer;
  bool _running = false;

  Future<void> start(void Function(String ip, int port) onFound) async {
    if (_running) return;
    _running = true;

    await _acquireMulticastLock();
    await _startUdpDiscovery(onFound);
    unawaited(_scanLocalSubnets(onFound));
  }

  Future<void> _startUdpDiscovery(
    void Function(String ip, int port) onFound,
  ) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      if (!_running) {
        socket.close();
        return;
      }

      _udpSocket = socket;
      socket.broadcastEnabled = true;
      try {
        socket.joinMulticast(InternetAddress(multicastAddress));
      } on OSError catch (error) {
        debugPrint('加入局域网发现组播失败，将使用广播查询: $error');
      }

      _udpSubscription = socket.listen((event) {
        if (event != RawSocketEvent.read || !_running) return;
        final datagram = socket.receive();
        if (datagram == null) return;

        final server = parseDiscoveryDatagram(
          datagram.data,
          datagram.address.address,
        );
        if (server != null) onFound(server.ip, server.port);
      });

      await _sendDiscoveryQuery();
      _queryTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_sendDiscoveryQuery()),
      );
    } on OSError catch (error) {
      debugPrint('启动 UDP 局域网发现失败，将使用 TCP 扫描: $error');
    }
  }

  Future<void> _sendDiscoveryQuery() async {
    final socket = _udpSocket;
    if (!_running || socket == null) return;

    final query = utf8.encode('{"type":"videochat-discover-query"}');
    final destinations = <String>{'255.255.255.255'};
    for (final prefix in await _localIpv4Prefixes()) {
      destinations.add('${prefix}255');
    }
    for (final address in destinations) {
      try {
        socket.send(query, InternetAddress(address), discoveryPort);
      } on OSError catch (error) {
        debugPrint('发送局域网发现查询到 $address 失败: $error');
      }
    }
  }

  Future<void> _scanLocalSubnets(
    void Function(String ip, int port) onFound,
  ) async {
    final prefixes = await _localIpv4Prefixes();
    for (final prefix in prefixes) {
      for (var firstHost = 1; firstHost <= 254; firstHost += 64) {
        if (!_running) return;
        final lastHost = (firstHost + 63).clamp(1, 254);
        await Future.wait([
          for (var host = firstHost; host <= lastHost; host++)
            _probeHost('$prefix$host', onFound),
        ]);
      }
    }
  }

  Future<void> _probeHost(
    String host,
    void Function(String ip, int port) onFound,
  ) async {
    if (!_running) return;
    try {
      final socket = await Socket.connect(
        host,
        signalPort,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      if (_running) onFound(host, signalPort);
    } on OSError {
      // No signaling server on this address.
    }
  }

  Future<List<String>> _localIpv4Prefixes() async {
    final prefixes = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (!_isPrivateIpv4(ip)) continue;
          final lastDot = ip.lastIndexOf('.');
          if (lastDot > 0) prefixes.add(ip.substring(0, lastDot + 1));
        }
      }
    } on OSError catch (error) {
      debugPrint('获取本机局域网地址失败: $error');
    }
    return prefixes.toSet().toList();
  }

  @visibleForTesting
  static DiscoveredServer? parseDiscoveryDatagram(
    List<int> data,
    String senderIp,
  ) {
    try {
      final message = jsonDecode(utf8.decode(data));
      if (message is! Map || message['type'] != 'videochat-discovery') {
        return null;
      }
      final port = message['port'];
      if (port is! int || port < 1 || port > 65535) return null;

      final advertisedIp = message['ip'];
      if (advertisedIp is String && _isPrivateIpv4(advertisedIp)) {
        return DiscoveredServer(advertisedIp, port);
      }
      if (_isPrivateIpv4(senderIp)) return DiscoveredServer(senderIp, port);
      return null;
    } on FormatException {
      return null;
    }
  }

  static bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final octets = parts.cast<int>();
    if (octets.any((part) => part < 0 || part > 255)) return false;
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  Future<void> stop() async {
    _running = false;
    _queryTimer?.cancel();
    _queryTimer = null;
    await _udpSubscription?.cancel();
    _udpSubscription = null;
    _udpSocket?.close();
    _udpSocket = null;
    await _releaseMulticastLock();
  }

  Future<void> _acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod<void>('acquireMulticastLock');
    } on PlatformException catch (error) {
      debugPrint('获取 Android 组播锁失败: $error');
    }
  }

  Future<void> _releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod<void>('releaseMulticastLock');
    } on PlatformException catch (error) {
      debugPrint('释放 Android 组播锁失败: $error');
    }
  }
}
