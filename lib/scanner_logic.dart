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
      // 1. Fetch
      List<VpnServerModel> servers = await ApiService.fetchAllServers();
      print("📋 Loaded ${servers.length} servers.");

      List<VpnServerModel> updatesBuffer = [];
      List<String> deletesBuffer = [];

      // 2. Loop One-by-One
      for (var server in servers) {
        
        // 🛡️ ERROR BOUNDARY: We put try/catch INSIDE the loop.
        // If one server crashes the logic, we catch it and continue to the next.
        try {
          
             Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
      String patchedConfigFile = openvpnConfig['openvpnConfig'];

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
          if (patchedConfigFile == null || patchedConfigFile.isEmpty) {
            if (server.id != null) deletesBuffer.add(server.id!);
            print("   ⚠️ No config found for ${server.ipAddress}. Marking delete.");
            continue;
          }

          // Test (Pass credentials)
          TestResult result = await VpnManager.connectAndTest(
            configContent: patchedConfigFile, 
            ip: server.ipAddress,
            username: server.username,
            password: server.password
          );

          if (result.success) {
            // DECISION LOGIC
            if (result.speedMbps >= Config.homeThreshold) {
              server.serverType = "HOME";
            } else if (result.speedMbps >= Config.goldenThreshold) {
              server.serverType = "GOLDEN";
            } else {
              server.serverType = "FREE";
            }
            
            server.downloadSpeed = result.speedMbps;
            server.status = "active";
            
            updatesBuffer.add(server);
          } else {
            // Failed -> Mark for Delete
            if (server.id != null) {
              deletesBuffer.add(server.id!);
              print("   🗑️ Marked ${server.ipAddress} for deletion.");
            }
          }

          // 3. Batch Updates (Every 10 items)
          if (updatesBuffer.length >= 10) {
            await ApiService.sendBulkUpdate(List.from(updatesBuffer));
            updatesBuffer.clear();
          }
          if (deletesBuffer.length >= 10) {
            await ApiService.sendBulkDelete(List.from(deletesBuffer));
            deletesBuffer.clear();
          }

        } catch (innerError) {
          // 🛑 This catches errors for THIS specific server so the loop doesn't die
          print("   💥 Error processing ${server.ipAddress}: $innerError");
          // Continue to next server...
        }
      }

      // 4. Final Flush (After loop ends)
      if (updatesBuffer.isNotEmpty) await ApiService.sendBulkUpdate(updatesBuffer);
      if (deletesBuffer.isNotEmpty) await ApiService.sendBulkDelete(deletesBuffer);

    } catch (e) {
      // This catches errors in Fetching or Initialization
      print("💥 Critical Scan Setup Error: $e");
    } finally {
      isScanning = false;
      print("🏁 FINISHED: Scan Complete.\n");
    }
  }
}
