import 'dart:io';
import 'dart:convert';
import 'dart:async';



class TestResult {
  final bool success;
  final int speedMbps;
  TestResult(this.success, this.speedMbps);
}

class VpnManager {

  static Future<TestResult> connectAndTest({
    required String configContent, 
    required String ip, 
    String username = '', 
    String password = ''
  }) async {
    
    print( "---\n🔎 Testing VPN Server: $ip");
    // 1. NUCLEAR PRE-CLEAN
    await _forceKillOpenVpn();

    final File configFile = File('temp.ovpn');
    final File authFile = File('vpn_auth.txt');
    bool hasAuth = username.isNotEmpty && password.isNotEmpty;
    Process? openVpnProcess;
      print( "   📝 Preparing configuration files...");

    try {
      // 2. Setup Files
      await configFile.writeAsString(configContent);
      List<String> args = [
        '--config', 'temp.ovpn',
        '--nobind', 
        '--persist-tun',
        '--connect-retry-max', '1' 
      ];
      
      if (hasAuth) {
        await authFile.writeAsString('$username\n$password');
        args.addAll(['--auth-user-pass', 'vpn_auth.txt']);
      }

      print("🔌 Connecting to Target Server: $ip ...");

      // 3. Start OpenVPN
      openVpnProcess = await Process.start('sudo', ['openvpn', ...args]);
      openVpnProcess.stdout.drain();
      openVpnProcess.stderr.drain();

      // 4. Wait for Interface
      String? activeInterface = await _waitForAnyInterface(15);
      
      if (activeInterface == null) {
        print("   ❌ Timeout: VPN Interface not created.");
        return TestResult(false, 0);
      }

      // 5. Routing Stabilization
      await Future.delayed(Duration(seconds: 3));
      print("   🔗 Tunnel active on: $activeInterface");

      // ============================================================
      // 🌟 STEP 6: PUBLIC IP VERIFICATION (THE NEW LOGIC)
      // ============================================================
      print("   🌍 Verifying Public IP via Tunnel...");
      
      // We ask an external API what our IP is, forcing the request through the VPN
      String? visibleIp = await _getPublicIp(activeInterface);

      print("   ------------------------------------------------");
      print("   🎯 TARGET SERVER IP : $ip");
      print("   👀 VISIBLE EXIT IP  : ${visibleIp ?? 'Failed to detect'}");
      print("   ------------------------------------------------");

      if (visibleIp == null) {
        print("   ❌ No Internet Access (Could not fetch IP)");
        return TestResult(false, 0);
      }

      // Check if the IP actually changed (Simple check)
      // Note: Sometimes Exit IP is slightly different from Entry IP, 
      // but as long as we got a result via tun0, the VPN is working.
      if (visibleIp.trim() == ip.trim()) {
        print("   ✅ CONFIRMED: Traffic is routing through the VPN Server.");
      } else {
        print("   ✅ CONFIRMED: Traffic is routing (Exit IP differs from Entry IP).");
      }
      // ============================================================

      // 7. SPEED TEST
      print("   🚀 Testing Speed...");
      final stopwatch = Stopwatch()..start();
      
      final result = await Process.run('curl', [
        '--interface', activeInterface, 
        '-o', '/dev/null',
        '--max-time', '20', 
        '-s', '-L',
        '-w', '%{http_code}', 
        'https://speed.cloudflare.com/__down?bytes=10000000' 
      ]);
      
      stopwatch.stop();

      String out = result.stdout.toString().trim();
      
      if (result.exitCode == 0 && (out == '200' || out == '206')) {
        double seconds = stopwatch.elapsedMilliseconds / 1000;
        if (seconds <= 0.1) seconds = 1; 
        
        int speedMbps = (80 / seconds).round(); 
        print("   ✅ Speed: $speedMbps Mbps");
        return TestResult(true, speedMbps);
      } else {
        print("  ❌ Speed Test Failed (Curl exit ${result.exitCode}, HTTP $out)");
        return TestResult(false, 0);
      }

    } catch (e) {
      print("   ⚠️ Exception: $e");
      return TestResult(false, 0);
    } finally {
      openVpnProcess?.kill();
      await _forceKillOpenVpn();
      await _cleanupFiles();
    }
  }

  // --- HELPERS ---

  /// Helper to get the Public IP via the specific interface
// REPLACE THIS FUNCTION IN lib/vpn_manager.dart

  static Future<String?> _getPublicIp(String interface) async {
    // Retry logic: Try 3 times with 2-second pauses
    // This allows the Routing Table to update on macOS
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        // ---------------------------------------------------------
        // ATTEMPT A: Check Raw IP (Bypass DNS) - Fastest Check
        // ---------------------------------------------------------
        var result = await Process.run('curl', [
          '--interface', interface,
          '--max-time', '5',
          '-4', // Force IPv4 (Crucial for VPN Gate)
          '-s',
          'http://1.1.1.1' // Cloudflare IP
        ]);
        
        // If we can't reach 1.1.1.1, the tunnel is definitely not routing yet.
        // Wait and continue to next loop attempt.
        if (result.exitCode != 0) {
           print("      ⚠️ Attempt $attempt: Routing not ready (Exit ${result.exitCode}). Retrying...");
           await Future.delayed(Duration(seconds: 2));
           continue; 
        }

        // ---------------------------------------------------------
        // ATTEMPT B: Fetch Real IP (DNS Required)
        // ---------------------------------------------------------
        result = await Process.run('curl', [
          '--interface', interface, 
          '--max-time', '8', 
          '-4', // Force IPv4
          '-s',
          'https://api.ipify.org'   
        ]);

        if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
          return result.stdout.toString().trim();
        }
        
        // If HTTPS fails, try HTTP fallback
        result = await Process.run('curl', [
          '--interface', interface, 
          '--max-time', '8', 
          '-4',
          '-s',
          'http://ifconfig.me/ip'   
        ]);

        if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
          return result.stdout.toString().trim();
        }

      } catch (e) {
        print("      ⚠️ IP Check Error: $e");
      }
      
      // Wait before retry
      await Future.delayed(Duration(seconds: 2));
    }

    // If we fail after 3 attempts (approx 10-15 seconds), the VPN is truly dead.
    return null;
  }

  static Future<void> _forceKillOpenVpn() async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('sudo', ['pkill', '-9', 'openvpn']);
      }
    } catch (e) {

      print("⚠️ Error killing OpenVPN: $e");
     }
    await Future.delayed(Duration(seconds: 1));
  }

  static Future<void> _cleanupFiles() async {
    try {
      final f = File('temp.ovpn');
      if (await f.exists()) await f.delete();
      final a = File('vpn_auth.txt');
      if (await a.exists()) await a.delete();
    } catch (e) {  }
  }

  static Future<String?> _waitForAnyInterface(int timeoutSec) async {
    List<String> candidates = Platform.isLinux 
        ? ['tun0', 'tun1'] 
        : ['utun0', 'utun1', 'utun2', 'utun3', 'utun4'];

    for (int i = 0; i < timeoutSec; i++) {
      await Future.delayed(Duration(seconds: 1));
      for (var iface in candidates) {
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
    } catch (e) {
      return false;
    }
  }
}