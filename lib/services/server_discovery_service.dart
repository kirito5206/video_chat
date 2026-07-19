import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Finds port 8765 on the phone's current Wi-Fi subnet.
class ServerDiscoveryService {
  static const int signalPort = 8765;
  static const MethodChannel _networkChannel =
      MethodChannel('video_chat/network_discovery');

  int _scanGeneration = 0;

  Future<void> start(void Function(String ip, int port) onFound) async {
    final generation = ++_scanGeneration;
    final wifi = await _getWifiNetwork();
    if (generation != _scanGeneration) return;

    if (wifi == null) {
      debugPrint('未获取到手机 Wi-Fi IPv4 地址，无法扫描服务器');
      return;
    }

    final hosts = hostsToScan(wifi.address, wifi.prefixLength);
    for (var firstHost = 0; firstHost < hosts.length; firstHost += 128) {
      if (generation != _scanGeneration) return;
      await Future.wait(
        hosts
            .skip(firstHost)
            .take(128)
            .map((host) => _probeHost(host, generation, onFound)),
      );
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

  Future<({String address, int prefixLength})?> _getWifiNetwork() async {
    if (Platform.isAndroid) {
      try {
        final result = await _networkChannel
            .invokeMapMethod<String, dynamic>('getWifiNetwork');
        final address = result?['address'];
        final prefixLength = result?['prefixLength'];
        if (address is String && prefixLength is int) {
          return (address: address, prefixLength: prefixLength);
        }
        return null;
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
          if (_ipv4ToInt(address.address) != null) {
            return (address: address.address, prefixLength: 24);
          }
        }
      }
    } on OSError catch (error) {
      debugPrint('获取 Wi-Fi IP 失败: $error');
    }
    return null;
  }

  @visibleForTesting
  static List<String> hostsToScan(String ip, int prefixLength) {
    final ipValue = _ipv4ToInt(ip);
    if (ipValue == null || prefixLength < 1 || prefixLength > 30) return [];

    // Limit a pathological large subnet to the /20 block containing the phone.
    final scanPrefixLength = prefixLength < 20 ? 20 : prefixLength;
    final mask = (0xffffffff << (32 - scanPrefixLength)) & 0xffffffff;
    final network = ipValue & mask;
    final broadcast = network | (~mask & 0xffffffff);
    final current24 = ipValue & 0xffffff00;
    final hosts = <int>[];

    // The phone's own /24 goes first, so the usual case completes quickly.
    for (var value = current24 + 1; value < current24 + 255; value++) {
      if (value > network && value < broadcast && value != ipValue) {
        hosts.add(value);
      }
    }
    for (var value = network + 1; value < broadcast; value++) {
      if ((value & 0xffffff00) != current24 && value != ipValue) {
        hosts.add(value);
      }
    }
    return hosts.map(_intToIpv4).toList();
  }

  static int? _ipv4ToInt(String ip) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return null;
    final octets = parts.cast<int>();
    if (octets.any((part) => part < 0 || part > 255)) return null;
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
  }

  static String _intToIpv4(int value) {
    return '${(value >> 24) & 255}.${(value >> 16) & 255}.'
        '${(value >> 8) & 255}.${value & 255}';
  }

  Future<void> stop() async {
    _scanGeneration++;
  }
}
