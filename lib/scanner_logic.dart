import 'dart:convert';

import 'api_service.dart';
import 'vpn_manager.dart';
import 'server_model.dart';
import 'config.dart';


class ScannerLogic {
  static bool isScanning = false;

  static Future<void> startScan() async {
    if (isScanning) {
      print("🔒 Scan already running. Ignoring request.");
      return;
    }

    isScanning = true;
    print("\n🏁 STARTED: Full Server Scan");

    try {
      // 1. Fetch all servers
      List<VpnServerModel> servers = await ApiService.fetchAllServers();
      print("📋 Loaded ${servers.length} servers.");

      List<VpnServerModel> updatesBuffer = [];
      List<String> deletesBuffer = [];
      Map<VpnServerModel, TestResult> testResults = {};

      

      // 2. Loop through servers
      for (var server in servers.take(10).toList()) {
        try {
          // Patch ciphers as before
          Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
          String patchedConfigFile = openvpnConfig['openvpnConfig'];
           if (patchedConfigFile.isEmpty) {
            if (server.id != null) {
              await ApiService.deleteServer(server.id!);
            }
            continue;
          }

          if (patchedConfigFile.contains('cipher AES-128-CBC') &&
              !patchedConfigFile.contains('data-ciphers')) {
            patchedConfigFile = patchedConfigFile.replaceAll(
              'cipher AES-128-CBC',
              '''cipher AES-128-CBC
data-ciphers AES-128-CBC
data-ciphers-fallback AES-128-CBC''',
            );
          }

          if (patchedConfigFile.contains('cipher AES-256-CBC') &&
              !patchedConfigFile.contains('data-ciphers')) {
            patchedConfigFile = patchedConfigFile.replaceAll(
              'cipher AES-256-CBC',
              '''cipher AES-256-CBC
data-ciphers AES-256-CBC
data-ciphers-fallback AES-256-CBC''',
            );
          }

          if (patchedConfigFile.isEmpty) {
            if (server.id != null) {
              await ApiService.deleteServer(server.id!);
            } 
            print("   ⚠️ No config found for ${server.ipAddress}. Marking delete.");
            continue;
          }

          // Test server
          TestResult result = await VpnManager.connectAndTest(
            configContent: patchedConfigFile,
            ip: server.ipAddress,
            username: server.username,
            password: server.password,
          );

          if (result.success) {
            testResults[server] = result;
          } else {
            // Delete failed servers immediately
            if (server.id != null) {
              await ApiService.deleteServer(server.id!);
            }
          }
        } catch (innerError) {
          print("   💥 Error processing ${server.ipAddress}: $innerError");
        }
      }

      // 3. Categorize servers based on speed+ping
      if (testResults.isNotEmpty) {
        List<VpnServerModel> activeServers = testResults.keys.toList();

        // Find min/max for normalization
        int minSpeed = testResults.values.map((r) => r.speedMbps).reduce((a, b) => a < b ? a : b);
        int maxSpeed = testResults.values.map((r) => r.speedMbps).reduce((a, b) => a > b ? a : b);
        double minPing = testResults.values.map((r) => r.pingMs).reduce((a, b) => a < b ? a : b);
        double maxPing = testResults.values.map((r) => r.pingMs).reduce((a, b) => a > b ? a : b);

        // Calculate score
        double speedWeight = 0.7;
        double pingWeight = 0.3;

        double calculateScore(TestResult r) {
          double normalizedSpeed = maxSpeed == minSpeed ? 1.0 : (r.speedMbps - minSpeed) / (maxSpeed - minSpeed);
          double normalizedPing = maxPing == minPing ? 1.0 : (maxPing - r.pingMs) / (maxPing - minPing);
          return (normalizedSpeed * speedWeight) + (normalizedPing * pingWeight);
        }

        // Sort by score descending
        activeServers.sort((a, b) => calculateScore(testResults[b]!).compareTo(calculateScore(testResults[a]!)));

        // Assign categories in ratio 2:3:5
        int total = activeServers.length;
        int homeCount = (total * 0.2).round();    // 20%
        int goldenCount = (total * 0.3).round();  // 30%
        int freeCount = total - homeCount - goldenCount; // remaining 50%

        for (int i = 0; i < activeServers.length; i++) {
          var s = activeServers[i];
          if (i < homeCount) s.serverType = "HOME";
          else if (i < homeCount + goldenCount) s.serverType = "GOLDEN";
          else s.serverType = "FREE";

          s.status = "active";
          updatesBuffer.add(s);
        }
      }

      // 4. Flush updates
      if (updatesBuffer.isNotEmpty) await ApiService.sendBulkUpdate(updatesBuffer);
      if (deletesBuffer.isNotEmpty) await ApiService.sendBulkDelete(deletesBuffer);

    } catch (e) {
      print("💥 Critical Scan Setup Error: $e");
    } finally {
      isScanning = false;
      print("🏁 FINISHED: Scan Complete.\n");
    }
  }
}
