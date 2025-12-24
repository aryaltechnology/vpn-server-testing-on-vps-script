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
  static const _ns = 'vpnns'; // network namespace name

  /// Connects to OpenVPN using config content and tests speed/ping.
  static Future<TestResult> connectAndTest({
    required String configContent,
    required String ip,
    String username = '',
    String password = '',
  }) async {
    await _killOpenVpn(); // make sure no leftover VPN is running

    final configFile = File('temp.ovpn');
    final authFile = File('vpn_auth.txt');

    Process? vpnProcess;
    bool connected = false;

    try {
      // 1️⃣ Write config & auth
      await configFile.writeAsString(configContent);
      await authFile.writeAsString(
          username.isNotEmpty ? '$username\n$password' : 'vpn\nvpn');

      final openvpn = await _resolveOpenVpnPath();

      final args = [
        'ip',
        'netns',
        'exec',
        _ns,
        openvpn,
        '--config',
        'temp.ovpn',
        '--client',
        '--nobind',
        '--persist-tun',
        '--connect-retry-max',
        '1',
        '--script-security',
        '2',
        '--auth-user-pass',
        'vpn_auth.txt',
        '--verb',
        '3',
      ];

      print('🔌 Starting OpenVPN in namespace...');
      vpnProcess = await Process.start('sudo', args);

      // 2️⃣ Listen stdout/stderr for connection status
      vpnProcess.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains('Initialization Sequence Completed')) {
          connected = true;
          print('✅ VPN tunnel established');
        }
        if (data.contains('AUTH_FAILED')) {
          print('❌ AUTH FAILED');
        }
      });

      vpnProcess.stderr.transform(utf8.decoder).listen((data) {
        print('[OVPN ERR] ${data.trim()}');
      });

      // 3️⃣ Wait for OpenVPN to connect
      for (int i = 0; i < 30; i++) {
        if (connected) break;
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!connected) {
        print('❌ VPN did not connect');
        return TestResult(false, 0, 0);
      }

      // 4️⃣ Check VPN exit IP
      print('🌍 Checking exit IP...');
      final exitIp = await _nsCmd(['curl', '-s', 'https://api.ipify.org']);
      print('✅ Exit IP: $exitIp');

      // 5️⃣ Speed test
      print('🚀 Speed test (HTTP Download)...');
      final speed = await _speedTest();

      // 6️⃣ Ping test
      print('📶 Ping test...');
      final ping = await _ping(ip);
      print('✅ Ping: ${ping.toStringAsFixed(2)} ms');

      return TestResult(true, speed, ping);
    } catch (e) {
      print('⚠️ Exception: $e');
      return TestResult(false, 0, 0);
    } finally {
      vpnProcess?.kill();
      await _killOpenVpn();
      await _cleanupFiles();
    }
  }

  // ---------------- Helpers ----------------

  /// Runs a command inside the namespace and returns stdout
  static Future<String> _nsCmd(List<String> cmd) async {
    final res = await Process.run('sudo', ['ip', 'netns', 'exec', _ns, ...cmd]);
    return res.stdout.toString().trim();
  }

  /// Simple HTTP speed test (downloads 1MB file)
  static Future<int> _speedTest() async {
    int bytesReceived = 0;
    final stopwatch = Stopwatch()..start();

    final proc = await Process.start('sudo', [
      'ip',
      'netns',
      'exec',
      _ns,
      'curl',
      '-L',
      '-s',
      'https://proof.ovh.net/files/1Mb.dat'
    ]);

    await for (final chunk in proc.stdout) {
      bytesReceived += chunk.length;
    }

    stopwatch.stop();
    double seconds = stopwatch.elapsedMilliseconds / 1000;
    if (seconds < 0.1) seconds = 0.1;
    int speedMbps = ((bytesReceived * 8) / (seconds * 1000000)).round();
    print('✅ Speed: $speedMbps Mbps');
    return speedMbps;
  }

  /// Ping test inside namespace
  static Future<double> _ping(String ip) async {
    final res = await _nsCmd(['ping', '-c', '3', ip]);
    final match = RegExp(r' = [0-9.]+/([0-9.]+)/').firstMatch(res);
    return match != null ? double.parse(match.group(1)!) : double.infinity;
  }

  /// Resolve OpenVPN binary path
  static Future<String> _resolveOpenVpnPath() async {
    const paths = [
      '/usr/sbin/openvpn',
      '/usr/bin/openvpn',
      '/usr/local/sbin/openvpn',
    ];
    for (final p in paths) {
      if (await File(p).exists()) return p;
    }
    return 'openvpn';
  }

  /// Kill OpenVPN inside namespace
  static Future<void> _killOpenVpn() async {
    try {
      await Process.run(
          'sudo', ['ip', 'netns', 'exec', _ns, 'pkill', 'openvpn']);
    } catch (_) {}
  }

  /// Cleanup temporary files
  static Future<void> _cleanupFiles() async {
    try {
      if (await File('temp.ovpn').exists()) await File('temp.ovpn').delete();
      if (await File('vpn_auth.txt').exists()) await File('vpn_auth.txt').delete();
    } catch (_) {}
  }
}
