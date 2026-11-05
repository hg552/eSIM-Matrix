import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/remote_gateway_service.dart';

/// The control API binds to whatever this returns, and it carries the Bearer
/// token. A carrier CGNAT bearer is numbered out of the same 100.64/10 block as
/// Tailscale, so picking by range alone can publish the API on mobile data.
void main() {
  ({String name, List<InternetAddress> addresses}) iface(
    String name,
    List<String> addresses,
  ) => (
    name: name,
    addresses: addresses.map((address) => InternetAddress(address)).toList(),
  );

  test('ignores a cellular CGNAT bearer that only looks like a tailnet', () {
    final picked = pickTailnetAddress([
      iface('rmnet_data0', ['100.80.14.7']),
    ]);

    expect(picked, isNull);
  });

  test('prefers the tailscale interface over a mobile bearer', () {
    final picked = pickTailnetAddress([
      iface('rmnet_data0', ['100.80.14.7']),
      iface('tailscale0', ['100.100.1.5']),
    ]);

    expect(picked?.address, '100.100.1.5');
  });

  test('falls back to the range on an ordinary interface (tun0 VPN)', () {
    final picked = pickTailnetAddress([
      iface('wlan0', ['192.168.1.20']),
      iface('tun0', ['100.64.0.9']),
    ]);

    expect(picked?.address, '100.64.0.9');
  });

  test('prefers a named tailnet interface over an unnamed range match', () {
    final picked = pickTailnetAddress([
      iface('tun0', ['100.64.0.9']),
      iface('tailscale0', ['100.100.0.2']),
    ]);

    expect(picked?.address, '100.100.0.2');
  });

  test('accepts the Tailscale IPv6 range', () {
    final picked = pickTailnetAddress([
      iface('tailscale0', ['fd7a:115c:a1e0::1']),
    ]);

    expect(picked?.address, 'fd7a:115c:a1e0::1');
  });

  test('returns nothing when the device is not on a tailnet', () {
    final picked = pickTailnetAddress([
      iface('wlan0', ['192.168.1.20']),
      iface('rmnet_data0', ['10.20.30.40']),
    ]);

    expect(picked, isNull);
  });

  test('prefers IPv4 when the interface carries both families', () {
    final picked = pickTailnetAddress([
      iface('tailscale0', ['fd7a:115c:a1e0::1', '100.100.1.5']),
    ]);

    expect(picked?.type, InternetAddressType.IPv4);
    expect(picked?.address, '100.100.1.5');
  });
}
