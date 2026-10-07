import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'disabled subscription DNS uses encrypted defaults without system DNS',
    () {
      final dns = resolveDnsConfig(
        {'enable': false},
        const Dns(),
        overrideDns: false,
        appendSystemDns: false,
      );
      expect(dns['enable'], true);
      expect(dns['respect-rules'], true);
      expect(dns['nameserver'], contains('https://doh.pub/dns-query'));
      expect(dns['nameserver'], isNot(contains('system://')));
      expect(dns['nameserver-policy'], isNot(contains('www.baidu.com')));
    },
  );

  test('subscription DNS is kept when override is disabled', () {
    final dns = resolveDnsConfig(
      {
        'enable': true,
        'nameserver': ['https://example.com/dns-query'],
      },
      const Dns(),
      overrideDns: false,
      appendSystemDns: false,
    );
    expect(dns['nameserver'], ['https://example.com/dns-query']);
  });

  test('system DNS is used only when explicitly selected', () {
    final dns = resolveDnsConfig(
      {'enable': false},
      const Dns(),
      overrideDns: true,
      appendSystemDns: true,
    );
    expect(dns['nameserver'], contains('system://'));
  });

  test('legacy Android settings are migrated once to protective defaults', () {
    const legacy = Config(
      themeProps: defaultThemeProps,
      overrideDns: false,
      networkProps: NetworkProps(appendSystemDns: true),
      vpnProps: VpnProps(dnsHijacking: false, allowBypass: true),
    );
    final protected = enableDnsProtection(legacy);
    expect(protected.overrideDns, true);
    expect(protected.networkProps.appendSystemDns, false);
    expect(protected.vpnProps.dnsHijacking, true);
    expect(protected.vpnProps.allowBypass, false);
  });
}
