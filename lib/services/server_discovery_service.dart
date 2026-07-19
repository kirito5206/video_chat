import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Finds port 8765 on the phone's current Wi-Fi /24 subnet.
class ServerDiscoveryService {
  static const int signalPort = 8765;
  static const MethodChannel _networkChannel =
      MethodChannel('video_chat/network_discovery');

  int _scanGeneration = 0;

  Future<void> start(void Function(String ip, int port) onFound) async {
    final generation = ++_scanGeneration;
    final wifiIp = await _getWifiIpv4();
    if (generation != _scanGeneration) return;

    final prefix = subnetPrefixFor(wifiIp);
    if (prefix == null) {
      debugPrint('未获取到手机 Wi-Fi IPv4 地址，无法扫描服务器');
      return;
    }

    for (var firstHost = 1; firstHost <= 254; firstHost += 64) {
      if (generation != _scanGeneration) return;
      final lastHost = (firstHost + 63).clamp(1, 254);
      await Future.wait([
        for (var host = firstHost; host <= lastHost; host++)
          if ('$prefix$host' != wifiIp)
            _probeHost('$prefix$host', generation, onFound),
      ]);
    }
  }

  Future<void> _probeHost(
    String host,
    int generation,
    void Function(String ip, int port) onFound,
  ) async {
    try {
      final socket = await Socket.connect(
        host,
        signalPort,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      if (generation == _scanGeneration) onFound(host, signalPort);
    } on OSError {
      // This address is not the signaling server.
    }
  }

  Future<String?> _getWifiIpv4() async {
    if (Platform.isAndroid) {
      try {
        return await _networkChannel.invokeMethod<String>('getWifiIpv4');
      } on PlatformException catch (error) {
        debugPrint('获取 Android Wi-Fi IP 失败: $error');
        return null;
      }
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (!name.contains('wifi') && !name.contains('wlan')) continue;
        for (final address in interface.addresses) {
          if (subnetPrefixFor(address.address) != null) return address.address;
        }
      }
    } on OSError catch (error) {
      debugPrint('获取 Wi-Fi IP 失败: $error');
    }
    return null;
  }

  @visibleForTesting
  static String? subnetPrefixFor(String? ip) {
    if (ip == null) return null;
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return null;
    final octets = parts.cast<int>();
    if (octets.any((part) => part < 0 || part > 255)) return null;
    final isPrivate = octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
    if (!isPrivate) return null;
    return '${octets[0]}.${octets[1]}.${octets[2]}.';
  }

  Future<void> stop() async {
    _scanGeneration++;
  }
}
