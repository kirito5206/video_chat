import 'package:flutter_test/flutter_test.dart';
import 'package:video_chat/services/server_discovery_service.dart';

void main() {
  test('scans the phone /24 first', () {
    final hosts = ServerDiscoveryService.hostsToScan('10.220.63.88', 20);

    expect(hosts.first, '10.220.63.1');
    expect(hosts[86], '10.220.63.87');
    expect(hosts[87], '10.220.63.89');
  });

  test('covers hosts outside the phone /24 when Wi-Fi uses /20', () {
    final hosts = ServerDiscoveryService.hostsToScan('10.220.50.5', 20);

    expect(hosts, contains('10.220.63.242'));
    expect(hosts, isNot(contains('10.220.64.1')));
    expect(hosts, isNot(contains('10.220.50.5')));
  });

  test('rejects malformed addresses and prefix lengths', () {
    expect(ServerDiscoveryService.hostsToScan('192.168.1', 24), isEmpty);
    expect(ServerDiscoveryService.hostsToScan('192.168.1.2', 31), isEmpty);
  });
}
