import 'dart:io';
import 'dart:async';
import 'dart:convert';

class TestResult {
  final bool success;
  final int speedMbps;
  final double pingMs; // Added ping in milliseconds
  TestResult(this.success, this.speedMbps, this.pingMs);
}

class VpnManager {
  static Future<TestResult> connectAndTest({
    required String configContent,
    required String ip,
    String username = '',
    String password = '',
  }) async {
    // 1. PRE CLEAN
    await _forceKillOpenVpn();

    final File configFile = File('temp.ovpn');
    final File authFile = File('vpn_auth.txt');

    bool hasAuth = username.isNotEmpty && password.isNotEmpty;
    Process? openVpnProcess;
    bool ovpnConnected = false;
    bool authFailed = false;

    try {
      // 2. Write config & auth
      await configFile.writeAsString(configContent);

      List<String> args = [
        '--config', 'temp.ovpn',
        '--client',
        '--pull',
        '--nobind',
        '--persist-tun',
        '--connect-retry-max', '1',
        '--script-security', '2',
        '--redirect-gateway', 'def1',
      ];

      if (hasAuth) {
        await authFile.writeAsString('$username\n$password');
      } else {
        await authFile.writeAsString('vpn\nvpn');
      }
      args.addAll(['--auth-user-pass', 'vpn_auth.txt']);

      print("🔌 Connecting to Target Server: $ip ...");

      String openVpnPath = await _resolveOpenVpnPath();
      print("   🛠 Using OpenVPN at: $openVpnPath");

      // 3. Start OpenVPN
      openVpnProcess = await Process.start('sudo', [openVpnPath, ...args]);

      // 4. Listen logs
      openVpnProcess.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains('Initialization Sequence Completed')) {
          ovpnConnected = true;
          print("   [OVPN] Tunnel established");
        }

        if (data.contains('AUTH_FAILED')) {
          authFailed = true;
          print("   [OVPN] AUTH_FAILED detected");
        }

        if (data.contains('Exiting') || data.contains('Error')) {
          print("   [OVPN] ${data.trim()}");
        }
      });

      openVpnProcess.stderr.transform(utf8.decoder).listen((data) {
        print("   [OVPN ERR] ${data.trim()}");
      });

      // 5. Wait for interface creation
      String? activeInterface = await _waitForAnyInterface(15);
      if (activeInterface == null || authFailed) {
        print("   ❌ VPN connection failed (auth or interface)");
        return TestResult(false, 0,0);
      }

      print("   🔗 Interface detected: $activeInterface");

      // 6. Wait for IP
      if (Platform.isLinux) {
        bool hasIp = await _waitForIpAddress(activeInterface, 20);
        if (!hasIp) {
          print("   ❌ Linux: tun interface has NO IP");
          return TestResult(false, 0,0);
        }
      } else {
        await Future.delayed(const Duration(seconds: 3));
      }

      // 7. WAIT for OpenVPN initialization
      bool connected = false;
      for (int i = 0; i < 20; i++) {
        if (ovpnConnected) {
          connected = true;
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!connected) {
        print("   ❌ OpenVPN did not complete initialization");
        return TestResult(false, 0,0);
      }

      print("   🌍 Verifying Internet Access...");
      String? visibleIp = await _getPublicIp(activeInterface);
      if (visibleIp == null) {
        print("   ❌ Connected but no internet access");
        return TestResult(false, 0,0);
      }

      print("   ✅ Connected! Exit IP: $visibleIp");

      // 8. Speed test (macOS fix: do NOT bind to interface)
    // ---------------- Reliable speed test (10 MB) ----------------
      print("  🚀 Testing Speed (HTTP Download, 10 MB)...");

      // Hetzner provides smaller test files too: 10 MB
      final url = 'https://proof.ovh.net/files/1Mb.dat';
      final speed = await testSpeed(url);
       // 9. Ping test
      print("  📶 Testing Ping to target IP...");
      final pingMs = await testPing(ip);
      //log
      print("  ✅ Ping: ${pingMs.toStringAsFixed(2)} ms");
      return TestResult(true, speed,pingMs);
      
    } catch (e) {
      print("   ⚠️ Exception: $e");
      return TestResult(false, 0,0);
    } finally {
      openVpnProcess?.kill();
      await _forceKillOpenVpn();
      await _cleanupFiles();
    }
  }

  // ---------------- Ping Test ----------------
  static Future<double> testPing(String ip, {int count = 3}) async {
    try {
      final result = await Process.run(
        'ping',
        Platform.isMacOS ? ['-c', '$count', ip] : ['-n', '$count', ip],
      );

      if (result.exitCode != 0) return double.infinity;

      final output = result.stdout.toString();
      final regex = RegExp(r'avg = ([0-9.]+)ms| = [0-9.]+/([0-9.]+)/[0-9.]+/[0-9.]+ ms');
      final match = regex.firstMatch(output);
      if (match != null) {
        final avg = match.group(1) ?? match.group(2);
        if (avg != null) return double.tryParse(avg) ?? double.infinity;
      }
      return double.infinity;
    } catch (_) {
      return double.infinity;
    }
  }

static Future<int> testSpeed(String testUrl) async {
  final client = HttpClient();
  int bytesReceived = 0;

  try {
    final stopwatch = Stopwatch()..start();
    final request = await client.getUrl(Uri.parse(testUrl));
    final response = await request.close();

    await for (final chunk in response) {
      bytesReceived += chunk.length;
    }

    stopwatch.stop();
    double seconds = stopwatch.elapsedMilliseconds / 1000;
    if (seconds < 0.1) seconds = 0.1;

    int speedMbps = ((bytesReceived * 8) / (seconds * 1000000)).round();
    print("  ✅ Speed: $speedMbps Mbps");
    return speedMbps;
  } catch (e) {
    print("  ⚠️ Speed test failed: $e");
    return 0;
  } finally {
    client.close();
  }
}






  // ---------------- HELPERS ----------------
  static Future<String> _resolveOpenVpnPath() async {
    final paths = [
      '/opt/homebrew/sbin/openvpn',
      '/usr/local/sbin/openvpn',
      '/usr/sbin/openvpn',
      '/usr/bin/openvpn',
      '/sbin/openvpn',
    ];
    for (final p in paths) {
      if (await File(p).exists()) return p;
    }
    return 'openvpn';
  }

  static Future<bool> _waitForIpAddress(String iface, int timeout) async {
    for (int i = 0; i < timeout; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final res = await Process.run('ifconfig', [iface]);
      if (res.stdout.toString().contains('inet ')) return true;
    }
    return false;
  }

  static Future<String?> _getPublicIp(String iface) async {
    for (int i = 0; i < 3; i++) {
      try {
        final args = Platform.isMacOS
            ? ['-s', '-4', 'https://api.ipify.org']
            : ['--interface', iface, '--max-time', '6', '-4', '-s', 'https://api.ipify.org'];

        final res = await Process.run('curl', args);
        if (res.exitCode == 0 && res.stdout.toString().isNotEmpty) {
          return res.stdout.toString().trim();
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  static Future<void> _forceKillOpenVpn() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('sudo', ['pkill', 'openvpn'])
            .timeout(const Duration(seconds: 2), onTimeout: () => ProcessResult(0, 0, '', ''));
      }
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
  }

  static Future<void> _cleanupFiles() async {
    try {
      if (await File('temp.ovpn').exists()) await File('temp.ovpn').delete();
      if (await File('vpn_auth.txt').exists()) await File('vpn_auth.txt').delete();
    } catch (_) {}
  }

  static Future<String?> _waitForAnyInterface(int timeout) async {
    final candidates = Platform.isLinux ? ['tun0', 'tun1'] : ['utun0', 'utun1', 'utun2', 'utun3', 'utun4', 'utun5'];
    for (int i = 0; i < timeout; i++) {
      await Future.delayed(const Duration(seconds: 1));
      for (final iface in candidates) {
        if (await _checkInterfaceExists(iface)) return iface;
      }
    }
    return null;
  }

  static Future<bool> _checkInterfaceExists(String iface) async {
    try {
      final cmd = Platform.isMacOS ? 'ifconfig' : 'ip';
      final args = Platform.isMacOS ? [iface] : ['link', 'show', iface];
      final res = await Process.run(cmd, args);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
