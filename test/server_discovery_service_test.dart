import 'package:flutter_test/flutter_test.dart';
import 'package:video_chat/services/server_discovery_service.dart';

void main() {
  test('builds the scan prefix from the phone Wi-Fi IP', () {
    expect(
      ServerDiscoveryService.subnetPrefixFor('10.220.63.88'),
      '10.220.63.',
    );
    expect(
      ServerDiscoveryService.subnetPrefixFor('192.168.31.5'),
      '192.168.31.',
    );
  });

  test('rejects missing, malformed, and public IP addresses', () {
    expect(ServerDiscoveryService.subnetPrefixFor(null), isNull);
    expect(ServerDiscoveryService.subnetPrefixFor('192.168.1'), isNull);
    expect(ServerDiscoveryService.subnetPrefixFor('8.8.8.8'), isNull);
  });
}
