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
  static Future<TestResult> connectAndTest({
    required String configContent,
    required String ip,
    String username = '',
    String password = '',
  }) async {
    await _forceKillOpenVpn();

    final File configFile = File('temp.ovpn');
    final File authFile = File('vpn_auth.txt');

    bool hasAuth = username.isNotEmpty && password.isNotEmpty;
    Process? openVpnProcess;

    bool ovpnConnected = false;
    bool authFailed = false;

    try {
      // Write config & auth
      await configFile.writeAsString(configContent);

      await authFile.writeAsString(
        hasAuth ? '$username\n$password' : 'vpn\nvpn',
      );

      List<String> args = [
        '--config', 'temp.ovpn',
        '--client',
        '--pull',
        '--nobind',
        '--persist-tun',
        '--connect-retry-max', '1',
        '--script-security', '2',

        // 🚫 DO NOT REDIRECT GATEWAY (THIS BREAKS SSH)
        // '--redirect-gateway', 'def1',

        '--auth-user-pass', 'vpn_auth.txt',
        '--verb', '3',
      ];

      print("🔌 Connecting to VPN server: $ip");

      String openVpnPath = await _resolveOpenVpnPath();
      print("🛠 OpenVPN path: $openVpnPath");

      openVpnProcess = await Process.start(
        'sudo',
        [openVpnPath, ...args],
      );

      // Listen stdout
      openVpnProcess.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains('Initialization Sequence Completed')) {
          ovpnConnected = true;
          print("✅ VPN tunnel established");
        }

        if (data.contains('AUTH_FAILED')) {
          authFailed = true;
          print("❌ AUTH_FAILED");
        }

        if (data.contains('Exiting') || data.contains('ERROR')) {
          print("[OVPN] ${data.trim()}");
        }
      });

      openVpnProcess.stderr.transform(utf8.decoder).listen((data) {
        print("[OVPN ERR] ${data.trim()}");
      });

      // Wait for tunnel interface
      String? iface = await _waitForAnyInterface(15);
      if (iface == null || authFailed) {
        print("❌ VPN interface not created");
        return TestResult(false, 0, 0);
      }

      print("🔗 Interface detected: $iface");

      if (Platform.isLinux) {
        bool hasIp = await _waitForIpAddress(iface, 20);
        if (!hasIp) {
          print("❌ Interface has no IP");
          return TestResult(false, 0, 0);
        }
      } else {
        await Future.delayed(const Duration(seconds: 3));
      }

      // Wait for OpenVPN completion
      for (int i = 0; i < 20; i++) {
        if (ovpnConnected) break;
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!ovpnConnected) {
        print("❌ OpenVPN did not initialize");
        return TestResult(false, 0, 0);
      }

      // Verify internet via VPN tunnel
      print("🌍 Verifying VPN exit IP...");
      String? exitIp = await _getPublicIp(iface);
      if (exitIp == null) {
        print("❌ No internet over VPN");
        return TestResult(false, 0, 0);
      }

      print("✅ VPN Exit IP: $exitIp");

      // Speed test
      print("🚀 Speed test...");
      final speed = await testSpeed('https://proof.ovh.net/files/1Mb.dat');

      // Ping test
      print("📶 Ping test...");
      final pingMs = await testPing(ip);
      print("✅ Ping: ${pingMs.toStringAsFixed(2)} ms");

      return TestResult(true, speed, pingMs);
    } catch (e) {
      print("⚠️ Exception: $e");
      return TestResult(false, 0, 0);
    } finally {
      openVpnProcess?.kill();
      await _forceKillOpenVpn();
      await _cleanupFiles();
    }
  }

  // ---------------- SPEED ----------------
  static Future<int> testSpeed(String url) async {
    final client = HttpClient();
    int bytes = 0;

    try {
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();

      await for (final chunk in res) {
        bytes += chunk.length;
      }

      sw.stop();
      double seconds = sw.elapsedMilliseconds / 1000;
      if (seconds < 0.1) seconds = 0.1;

      int mbps = ((bytes * 8) / (seconds * 1000000)).round();
      print("✅ Speed: $mbps Mbps");
      return mbps;
    } catch (e) {
      print("⚠️ Speed failed: $e");
      return 0;
    } finally {
      client.close();
    }
  }

  // ---------------- PING ----------------
  static Future<double> testPing(String ip, {int count = 3}) async {
    try {
      final result = await Process.run(
        'ping',
        Platform.isMacOS ? ['-c', '$count', ip] : ['-c', '$count', ip],
      );

      if (result.exitCode != 0) return double.infinity;

      final output = result.stdout.toString();
      final regex = RegExp(r' = [0-9.]+/([0-9.]+)/');
      final match = regex.firstMatch(output);
      return match != null
          ? double.tryParse(match.group(1)!) ?? double.infinity
          : double.infinity;
    } catch (_) {
      return double.infinity;
    }
  }

  // ---------------- HELPERS ----------------
  static Future<String> _resolveOpenVpnPath() async {
    final paths = [
      '/opt/homebrew/sbin/openvpn',
      '/usr/local/sbin/openvpn',
      '/usr/sbin/openvpn',
      '/usr/bin/openvpn',
    ];
    for (final p in paths) {
      if (await File(p).exists()) return p;
    }
    return 'openvpn';
  }

  static Future<void> _forceKillOpenVpn() async {
    try {
      await Process.run(
        'sudo',
        ['pkill', 'openvpn'],
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => ProcessResult(0, 0, '', ''),
      );
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
  }

  static Future<void> _cleanupFiles() async {
    try {
      if (await File('temp.ovpn').exists()) {
        await File('temp.ovpn').delete();
      }
      if (await File('vpn_auth.txt').exists()) {
        await File('vpn_auth.txt').delete();
      }
    } catch (_) {}
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
        final args = Platform.isLinux
            ? ['--interface', iface, '-s', 'https://api.ipify.org']
            : ['-s', 'https://api.ipify.org'];

        final res = await Process.run('curl', args);
        if (res.exitCode == 0 && res.stdout.toString().isNotEmpty) {
          return res.stdout.toString().trim();
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  static Future<String?> _waitForAnyInterface(int timeout) async {
    final candidates = Platform.isLinux
        ? ['tun0', 'tun1']
        : ['utun0', 'utun1', 'utun2', 'utun3', 'utun4'];

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
      final res = await Process.run(
        Platform.isLinux ? 'ip' : 'ifconfig',
        Platform.isLinux ? ['link', 'show', iface] : [iface],
      );
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
