import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_chat/services/server_discovery_service.dart';

void main() {
  test('accepts a valid discovery reply and uses its advertised LAN IP', () {
    final result = ServerDiscoveryService.parseDiscoveryDatagram(
      utf8.encode(
        '{"type":"videochat-discovery","ip":"10.8.0.1","port":8765}',
      ),
      '192.168.1.20',
    );

    expect(result?.ip, '10.8.0.1');
    expect(result?.port, 8765);
  });

  test('rejects malformed, unrelated, or non-LAN discovery replies', () {
    expect(
      ServerDiscoveryService.parseDiscoveryDatagram(
        utf8.encode('{"type":"other","port":8765}'),
        '192.168.1.20',
      ),
      isNull,
    );
    expect(
      ServerDiscoveryService.parseDiscoveryDatagram(
        utf8.encode('{"type":"videochat-discovery","port":70000}'),
        '192.168.1.20',
      ),
      isNull,
    );
    expect(
      ServerDiscoveryService.parseDiscoveryDatagram(
        utf8.encode('{"type":"videochat-discovery","port":8765}'),
        '8.8.8.8',
      ),
      isNull,
    );
  });

  test('falls back to the packet source when advertised IP is invalid', () {
    final result = ServerDiscoveryService.parseDiscoveryDatagram(
      utf8.encode(
        '{"type":"videochat-discovery","ip":"198.18.0.1","port":8765}',
      ),
      '192.168.1.20',
    );

    expect(result?.ip, '192.168.1.20');
    expect(result?.port, 8765);
  });
}
