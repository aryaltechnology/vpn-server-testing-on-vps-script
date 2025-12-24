import 'dart:io';
import 'dart:async';
import 'dart:convert';

class TestResult {
  final bool success;
  final int speedMbps;
  final double pingMs;
  TestResult(this.success, this.speedMbps, this.pingMs);
}

class VpnManager {
  static const _ns = 'vpnns'; // your network namespace

  /// Connects to OpenVPN inside namespace and tests speed/ping
  static Future<TestResult> connectAndTest({
    required String configContent,
    required String ip,
    String username = '',
    String password = '',
  }) async {
    await _cleanupFiles();
    await _killOpenVpn();

    final configFile = File('temp.ovpn');
    final authFile = File('vpn_auth.txt');

    try {
      // 1️⃣ Write files
      await configFile.writeAsString(configContent);
      await authFile.writeAsString(username.isNotEmpty ? '$username\n$password' : 'vpn\nvpn');

      final openvpnPath = await _resolveOpenVpnPath();

      // 2️⃣ Build namespace OpenVPN command
      final args = [
        'ip',
        'netns',
        'exec',
        _ns,
        'nohup', // detach so SSH never dies
        openvpnPath,
        '--config',
        'temp.ovpn',
        '--client',
        '--nobind',
        '--persist-tun',
        '--connect-retry-max', '1',
        '--auth-user-pass', 'vpn_auth.txt',
        '--verb', '3',
      ];

      print('🔌 Starting OpenVPN in namespace...');
      final process = await Process.start('sudo', args);

      // 3️⃣ Wait for initialization
      bool connected = false;
      process.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains('Initialization Sequence Completed')) {
          connected = true;
          print('✅ VPN tunnel established');
        }
        if (data.contains('AUTH_FAILED')) {
          print('❌ AUTH_FAILED');
        }
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        print('[OVPN ERR] ${data.trim()}');
      });

      for (int i = 0; i < 30; i++) {
        if (connected) break;
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!connected) {
        print('❌ VPN did not connect');
        await _killOpenVpn();
        return TestResult(false, 0, 0);
      }

      // 4️⃣ Check VPN exit IP inside namespace
      final exitIp = await _nsCmd(['curl', '-s', 'https://api.ipify.org']);
      print('🌍 VPN Exit IP: $exitIp');

      // 5️⃣ Speed test inside namespace
      print('🚀 Speed test...');
      final speed = await _speedTest();

      // 6️⃣ Ping test
      print('📶 Ping test...');
      final ping = await _ping(ip);
      print('✅ Ping: ${ping.toStringAsFixed(2)} ms');

      // 7️⃣ Cleanup
      await _killOpenVpn();
      await _cleanupFiles();

      return TestResult(true, speed, ping);
    } catch (e) {
      print('⚠️ Exception: $e');
      await _killOpenVpn();
      await _cleanupFiles();
      return TestResult(false, 0, 0);
    }
  }

  // ---------------- Helpers ----------------

  static Future<String> _nsCmd(List<String> cmd) async {
    final res = await Process.run('sudo', ['ip', 'netns', 'exec', _ns, ...cmd]);
    return res.stdout.toString().trim();
  }

  static Future<int> _speedTest() async {
    final stopwatch = Stopwatch()..start();
    int bytesReceived = 0;

    final proc = await Process.start('sudo', [
      'ip',
      'netns',
      'exec',
      _ns,
      'curl',
      '-s',
      'https://proof.ovh.net/files/1Mb.dat'
    ]);

    await for (final chunk in proc.stdout) {
      bytesReceived += chunk.length;
    }

    stopwatch.stop();
    double seconds = stopwatch.elapsedMilliseconds / 1000;
    if (seconds < 0.1) seconds = 0.1;

    final speedMbps = ((bytesReceived * 8) / (seconds * 1000000)).round();
    print('✅ Speed: $speedMbps Mbps');
    return speedMbps;
  }

  static Future<double> _ping(String ip) async {
    final output = await _nsCmd(['ping', '-c', '3', ip]);
    final match = RegExp(r' = [0-9.]+/([0-9.]+)/').firstMatch(output);
    return match != null ? double.parse(match.group(1)!) : double.infinity;
  }

  static Future<String> _resolveOpenVpnPath() async {
    const paths = ['/usr/sbin/openvpn', '/usr/bin/openvpn', '/usr/local/sbin/openvpn'];
    for (final p in paths) {
      if (await File(p).exists()) return p;
    }
    return 'openvpn';
  }

  static Future<void> _killOpenVpn() async {
    try {
      await Process.run('sudo', ['ip', 'netns', 'exec', _ns, 'pkill', 'openvpn']);
    } catch (_) {}
  }

  static Future<void> _cleanupFiles() async {
    try {
      if (await File('temp.ovpn').exists()) await File('temp.ovpn').delete();
      if (await File('vpn_auth.txt').exists()) await File('vpn_auth.txt').delete();
    } catch (_) {}
  }
}
