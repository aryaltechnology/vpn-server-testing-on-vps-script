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
  // Use Cloudflare for speed (Reliable & Anycast)
  static const String _speedTestHost = 'speed.cloudflare.com';
  // 1MB file is safer for slow VPNs to avoid timeout
  static const String _speedTestPath = '/__down?bytes=1048576'; 
  
  static const String _ipCheckHost = 'api.ipify.org';

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
    
    // 🌟 STEP 0: Resolve IPs Manually (IPv4 Only)
    String? speedTestIp;
    String? ipCheckIp;
    
    try {
      // Resolve Speed Test
      var addresses = await InternetAddress.lookup(_speedTestHost, type: InternetAddressType.IPv4);
      if (addresses.isNotEmpty) {
        speedTestIp = addresses.first.address;
        print("   🎯 Target: Speed Test ($_speedTestHost -> $speedTestIp)");
      }
      
      // Resolve IP Check
      addresses = await InternetAddress.lookup(_ipCheckHost, type: InternetAddressType.IPv4);
      if (addresses.isNotEmpty) {
        ipCheckIp = addresses.first.address;
        print("   🎯 Target: IP Check ($_ipCheckHost -> $ipCheckIp)");
      }
    } catch (e) {
      print("   ⚠️ DNS Resolution failed: $e");
    }

    try {
      await configFile.writeAsString(configContent);

      List<String> args = [
        '--config', 'temp.ovpn',
        '--client',
        '--pull',
        '--nobind',
        '--persist-tun',
        '--connect-retry-max', '1',
        '--script-security', '2',
        
        // 🛡️ TUNING
        '--mssfix', '1200', 
        '--tun-mtu', '1500',
        '--resolv-retry', 'infinite',
        
        // 🛡️ SAFE ROUTING (Split Tunnel)
        '--pull-filter', 'ignore', 'redirect-gateway', 
        '--pull-filter', 'ignore', 'ifconfig-ipv6', 
        '--pull-filter', 'ignore', 'route-ipv6', 
        
        // ✅ EXPLICIT ROUTES (Force these IPs into the tunnel)
        // 1. Connectivity Check (1.1.1.1)
        '--route', '1.1.1.1', '255.255.255.255', 'vpn_gateway',
        
        // 2. The Resolved Service IPs
        if (speedTestIp != null) 
          '--route', speedTestIp!, '255.255.255.255', 'vpn_gateway',
        if (ipCheckIp != null)
          '--route', ipCheckIp!, '255.255.255.255', 'vpn_gateway',
      ];

      if (hasAuth) {
        await authFile.writeAsString('$username\n$password');
      } else {
        await authFile.writeAsString('vpn\nvpn');
      }
      args.addAll(['--auth-user-pass', 'vpn_auth.txt']);

      print("🔌 Connecting to Target Server: $ip ...");

      String openVpnPath = await _resolveOpenVpnPath();
      openVpnProcess = await Process.start('sudo', [openVpnPath, ...args]);

      // Listen for connection success
      bool ovpnConnected = false;
      bool authFailed = false;

      openVpnProcess.stdout.transform(utf8.decoder).listen((data) {
        if (data.contains('Initialization Sequence Completed')) {
          ovpnConnected = true;
          print("   [OVPN] Tunnel established");
        }
        if (data.contains('AUTH_FAILED')) authFailed = true;
      });

      // 5. Wait for interface
      String? activeInterface = await _waitForAnyInterface(15); 
      if (activeInterface == null || authFailed) {
        print("   ❌ VPN connection failed (auth or interface)");
        return TestResult(false, 0, 0);
      }

      print("   🔗 Interface detected: $activeInterface");

      // 6. Wait for IP (Linux/Docker)
      if (Platform.isLinux) {
        if (!await _waitForIpAddress(activeInterface, 25)) {
          print("   ❌ Linux: tun interface has NO IP");
          return TestResult(false, 0, 0);
        }
      } else {
        await Future.delayed(const Duration(seconds: 3));
      }

      // 7. Wait for OpenVPN Init
      bool connected = false;
      for (int i = 0; i < 30; i++) {
        if (ovpnConnected) {
          connected = true;
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!connected) {
        print("   ❌ OpenVPN did not complete initialization");
        return TestResult(false, 0, 0);
      }

      // 8. VERIFY CONNECTIVITY (The Fix)
      print("   🌍 Verifying Internet Access...");
      
      // We check via the explicitly routed IP (1.1.1.1) first
      // This is the most reliable check because we manually added the route.
      bool hasRoute = await _verifyTunnelRouting(activeInterface);
      
      if (!hasRoute) {
        print("   ❌ Connected but traffic blocked (Routing failed)");
        return TestResult(false, 0, 0);
      }
      
      // Optional: Check Public IP (using the resolved IP to avoid DNS mismatch)
      if (ipCheckIp != null) {
        String? visibleIp = await _getPublicIp(activeInterface, ipCheckIp!, _ipCheckHost);
        print("   ✅ Connected! Exit IP: ${visibleIp ?? 'Hidden'}");
      }

      // 9. Speed Test (Using Fixed IP + Host Header)
      print("  🚀 Testing Speed...");
      if (speedTestIp == null) {
         print("   ⚠️ Speed test skipped (DNS failed)");
         return TestResult(true, 0, 0); // Consider success connection-wise
      }

      final speed = await testSpeed(activeInterface, speedTestIp!, _speedTestHost, _speedTestPath); 

      // 10. Ping
      print("  📶 Testing Ping...");
      final pingMs = await testPing(speedTestIp!, activeInterface);
      print("  ✅ Ping: ${pingMs.toStringAsFixed(2)} ms");

      return TestResult(true, speed, pingMs);
      
    } catch (e) {
      print("   ⚠️ Exception: $e");
      return TestResult(false, 0, 0);
    } finally {
      openVpnProcess?.kill();
      await _forceKillOpenVpn();
      await _cleanupFiles();
    }
  }

  // ---------------- Logic Helpers ----------------

  static Future<bool> _verifyTunnelRouting(String interface) async {
    for (int i = 0; i < 3; i++) {
      try {
        final res = await Process.run('curl', [
          if (Platform.isLinux) ...['--interface', interface], // Bind on Linux
          '--max-time', '5',
          '-s', '-o', '/dev/null',
          '-w', '%{http_code}',
          'http://1.1.1.1' 
        ]);
        if (res.exitCode == 0 && (res.stdout.toString() == '200' || res.stdout.toString() == '301')) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  static Future<String?> _getPublicIp(String interface, String ip, String host) async {
    try {
      final res = await Process.run('curl', [
        if (Platform.isLinux) ...['--interface', interface],
        '--max-time', '8', 
        '-s', 
        '-H', 'Host: $host', // ⚡ MAGIC FIX: Tell server we want api.ipify.org
        'http://$ip'         // ⚡ Connect directly to IP
      ]);
      
      if (res.exitCode == 0 && res.stdout.toString().isNotEmpty) {
        return res.stdout.toString().trim();
      }
    } catch (_) {}
    return null;
  }

  static Future<int> testSpeed(String interface, String ip, String host, String path) async {
    try {
      final stopwatch = Stopwatch()..start();
      
      final result = await Process.run('curl', [
        if (Platform.isLinux) ...['--interface', interface],
        '-o', '/dev/null',
        '--max-time', '45', 
        '--connect-timeout', '10',
        '-s', '-L', '-k',
        '-H', 'Host: $host', // ⚡ Force Host Header
        '-w', '%{http_code}',
        'http://$ip$path'    // ⚡ Connect to IP directly
      ]);
      
      stopwatch.stop();

      String out = result.stdout.toString().trim();
      
      if (result.exitCode == 0 && (out == '200' || out == '206')) {
        double seconds = stopwatch.elapsedMilliseconds / 1000;
        if (seconds <= 0.1) seconds = 0.1; 
        
        // 1MB = 8 Megabits
        int speedMbps = (8 / seconds).round(); 
        
        print("  ✅ Speed: $speedMbps Mbps");
        return speedMbps;
      } else {
        print("  ⚠️ Speed test failed (Code ${result.exitCode}, HTTP $out)");
        return 0;
      }
    } catch (e) {
      print("  ⚠️ Speed exception: $e");
      return 0;
    }
  }

  static Future<double> testPing(String targetIp, String interface) async {
    try {
      final result = await Process.run('curl', [
        if (Platform.isLinux) ...['--interface', interface],
        '-o', '/dev/null',
        '-s',
        '--connect-timeout', '5',
        '-w', '%{time_connect}',
        'http://$targetIp'
      ]);

      if (result.exitCode == 0) {
        double timeSeconds = double.tryParse(result.stdout.toString().trim()) ?? 0.0;
        return timeSeconds * 1000;
      }
      return 999.0;
    } catch (_) {
      return 999.0;
    }
  }

  // ---------------- System Helpers (Unchanged) ----------------
  static Future<String> _resolveOpenVpnPath() async {
    final paths = ['/opt/homebrew/sbin/openvpn', '/usr/local/sbin/openvpn', '/usr/sbin/openvpn', '/usr/bin/openvpn', '/sbin/openvpn'];
    for (final p in paths) if (await File(p).exists()) return p;
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

  static Future<String?> _waitForAnyInterface(int timeout) async {
    final candidates = Platform.isLinux ? ['tun0', 'tun1'] : ['utun0', 'utun1', 'utun2', 'utun3', 'utun4'];
    for (int i = 0; i < timeout; i++) {
      await Future.delayed(const Duration(seconds: 1));
      for (final iface in candidates) if (await _checkInterfaceExists(iface)) return iface;
    }
    return null;
  }

  static Future<bool> _checkInterfaceExists(String iface) async {
    try {
      final cmd = Platform.isMacOS ? 'ifconfig' : 'ip';
      final args = Platform.isMacOS ? [iface] : ['link', 'show', iface];
      final res = await Process.run(cmd, args);
      return res.exitCode == 0;
    } catch (_) { return false; }
  }

  static Future<void> _forceKillOpenVpn() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('sudo', ['pkill', 'openvpn']).timeout(const Duration(seconds: 2), onTimeout: () => ProcessResult(0,0,"",""));
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
}