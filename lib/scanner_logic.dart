import 'dart:convert';
import 'dart:math';
import 'api_service.dart';
import 'vpn_manager.dart';
import 'server_model.dart';
import 'config.dart';

class ScannerLogic {
  static bool isScanning = false;
  static bool stopScanning = false;

  // ⚡ BATCH SIZE: Fetch 50 servers at a time
  static const int BATCH_SIZE = 40;

  static Future<void> startScan() async {
    if (isScanning) {
      print("🔒 Service is already running.");
      return;
    }

    stopScanning = false;
    isScanning = true;
    print("\n🏁 STARTED: Infinite Batch Ratio Mode");

    // 🔄 1. THE INFINITE LOOP
    while (isScanning) {
      if (stopScanning) {
        print("🛑 Stop signal received. Exiting loop.");
        break;
      }

      try {
        // 🔄 2. FETCH BATCH (50 Servers)
        List<VpnServerModel> batch = await ApiService.fetchNextBatch(limit: BATCH_SIZE);

        if (batch.isEmpty) {
          print("💤 No pending servers. Sleeping for 60 seconds...");
          await Future.delayed(Duration(seconds: 60));
          continue;
        }

        print("\n📦 Processing Batch of ${batch.length} servers...");
        
        // 🔄 3. PROCESS THIS BATCH
        await _processAndGradeBatch(batch);

      } catch (e) {
        print("💥 Loop Error: $e");
        print("   Restarting loop in 10 seconds...");
        await Future.delayed(Duration(seconds: 10));
      }
    }

    isScanning = false;
    print("🏁 SERVICE STOPPED.");
  }

  // --- BATCH PROCESSOR ---
  static Future<void> _processAndGradeBatch(List<VpnServerModel> servers) async {
    Map<VpnServerModel, TestResult> successfulTests = {};
    List<String> deleteIds = [];

    // A. TEST PHASE (Loop through the 50)
    for (var i = 0; i < servers.length; i++) {
      if (stopScanning) break;

      var server = servers[i];
      print("👉 [${i + 1}/${servers.length}] Testing ${server.ipAddress}...");

      try {
        // 1. CONFIG PARSING (YOUR EXACT LOGIC)
        Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
        String patchedConfigFile = openvpnConfig['openvpnConfig'] ?? "";

        // Validation
        if (patchedConfigFile.isEmpty) {
          if (server.id != null) {
             // ⚡ CHANGE: Don't delete now. Just add to list.
             deleteIds.add(server.id!);
          }
          print("   ⚠️ No config found. Added to Bulk Delete list.");
          continue;
        }

        // Cipher Patching
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

        // 2. RUN TEST
        TestResult result = await VpnManager.connectAndTest(
          configContent: patchedConfigFile,
          ip: server.ipAddress,
          username: server.username,
          password: server.password,
        );

        if (result.success) {
          successfulTests[server] = result;
          print("   ✅ Connected (Speed: ${result.speedMbps} Mbps) - Waiting for grading...");
        } else {
          // Failed -> Add to delete list
          if (server.id != null) {
            // ⚡ CHANGE: Don't delete now. Just add to list.
            deleteIds.add(server.id!);
          }
          print("   🗑️ Connection Failed. Added to Bulk Delete list.");
        }

      } catch (innerError) {
        print("   💥 Error processing ${server.ipAddress}: $innerError");
      }
    }

    // --- B. GRADING PHASE ---
    if (successfulTests.isNotEmpty) {
      print("📊 Grading ${successfulTests.length} survivors...");
      List<VpnServerModel> rankedServers = _applyRatioGrading(successfulTests);
      
      // --- C. UPDATE PHASE (BULK) ---
      print("📤 Sending Bulk Update...");
      await ApiService.sendBulkUpdate(rankedServers);
    }

    // --- D. DELETE PHASE (BULK) ---
    // ⚡ CHANGE: We send ONE request here to delete all dead servers in this batch
    if (deleteIds.isNotEmpty) {
      print("🗑 Sending Bulk Delete for ${deleteIds.length} servers...");
      await ApiService.sendBulkDelete(deleteIds);
    }
    
    print("✅ Batch Complete.\n");
  }

  // --- YOUR GRADING LOGIC (Relative 20/30/50 Rule) ---
  static List<VpnServerModel> _applyRatioGrading(Map<VpnServerModel, TestResult> resultsMap) {
    var activeServers = resultsMap.keys.toList();
    var results = resultsMap.values.toList();

    // 1. Find Min/Max
    int minSpeed = results.map((r) => r.speedMbps).reduce(min);
    int maxSpeed = results.map((r) => r.speedMbps).reduce(max);
    double minPing = results.map((r) => r.pingMs).reduce(min);
    double maxPing = results.map((r) => r.pingMs).reduce(max);

    // 2. Score Calculation
    double speedWeight = 0.7;
    double pingWeight = 0.3;

    double calculateScore(TestResult r) {
      double normalizedSpeed = (maxSpeed == minSpeed) 
          ? 1.0 
          : (r.speedMbps - minSpeed) / (maxSpeed - minSpeed);
          
      double normalizedPing = (maxPing == minPing) 
          ? 1.0 
          : (maxPing - r.pingMs) / (maxPing - minPing);

      return (normalizedSpeed * speedWeight) + (normalizedPing * pingWeight);
    }

    // 3. Sort Descending
    activeServers.sort((a, b) {
      double scoreA = calculateScore(resultsMap[a]!);
      double scoreB = calculateScore(resultsMap[b]!);
      return scoreB.compareTo(scoreA); 
    });

    // 4. Assign Roles
    int total = activeServers.length;
    int homeCount = (total * 0.2).round();    // 20%
    int goldenCount = (total * 0.3).round();  // 30%
    // Rest are Free

    if (total > 0 && homeCount == 0) homeCount = 1;

    for (int i = 0; i < total; i++) {
      var s = activeServers[i];
      var result = resultsMap[s]!;

      s.downloadSpeed = result.speedMbps;
      s.ping = result.pingMs.toInt();
      s.status = "active";

      if (i < homeCount) {
        s.serverType = "HOME";
      } else if (i < (homeCount + goldenCount)) {
        s.serverType = "GOLDEN";
      } else {
        s.serverType = "FREE";
      }
      
      print("   🏆 ${s.ipAddress} -> ${s.serverType} (${result.speedMbps} Mbps)");
    }

    return activeServers;
  }
}




// import 'dart:convert';

// import 'api_service.dart';
// import 'vpn_manager.dart';
// import 'server_model.dart';
// import 'config.dart';

// ////////
// class ScannerLogic {
//   static bool isScanning = false;

//   static Future<void> startScan() async {
//     if (isScanning) {
//       print("🔒 Scan already running. Ignoring request.");
//       return;
//     }

//     isScanning = true;
//     print("\n🏁 STARTED: Full Server Scan");

//     try {
//       // 1. Fetch all servers
//       List<VpnServerModel> servers = await ApiService.fetchAllServers();
//       print("📋 Loaded ${servers.length} servers.");

//       List<VpnServerModel> updatesBuffer = [];  
//       List<String> deletesBuffer = [];
//       Map<VpnServerModel, TestResult> testResults = {};

      

//       // 2. Loop through servers
//       for (var server in servers.toList()) {
//         try {
//           // Patch ciphers as before
//           Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
//           String patchedConfigFile = openvpnConfig['openvpnConfig'];
//            if (patchedConfigFile.isEmpty) {
//             if (server.id != null) {
//               await ApiService.deleteServer(server.id!);
//             }
//             continue;
//           }

//           if (patchedConfigFile.contains('cipher AES-128-CBC') &&
//               !patchedConfigFile.contains('data-ciphers')) {
//             patchedConfigFile = patchedConfigFile.replaceAll(
//               'cipher AES-128-CBC',
//               '''cipher AES-128-CBC
// data-ciphers AES-128-CBC
// data-ciphers-fallback AES-128-CBC''',
//             );
//           }

//           if (patchedConfigFile.contains('cipher AES-256-CBC') &&
//               !patchedConfigFile.contains('data-ciphers')) {
//             patchedConfigFile = patchedConfigFile.replaceAll(
//               'cipher AES-256-CBC',
//               '''cipher AES-256-CBC
// data-ciphers AES-256-CBC
// data-ciphers-fallback AES-256-CBC''',
//             );
//           }

//           if (patchedConfigFile.isEmpty) {
//             if (server.id != null) {
//               await ApiService.deleteServer(server.id!);
//             } 
//             print("   ⚠️ No config found for ${server.ipAddress}. Marking delete.");
//             continue;
//           }

//           // Test server
//           TestResult result = await VpnManager.connectAndTest(
//             configContent: patchedConfigFile,
//             ip: server.ipAddress,
//             username: server.username,
//             password: server.password,
//           );

//           if (result.success) {
//             testResults[server] = result;
//           } else {
//             // Delete failed servers immediately
//             if (server.id != null) {
//               await ApiService.deleteServer(server.id!);
//             }
//           }
//         } catch (innerError) {
//           print("   💥 Error processing ${server.ipAddress}: $innerError");
//         }
//       }

//       // 3. Categorize servers based on speed+ping
//       if (testResults.isNotEmpty) {
//         List<VpnServerModel> activeServers = testResults.keys.toList();

//         // Find min/max for normalization
//         int minSpeed = testResults.values.map((r) => r.speedMbps).reduce((a, b) => a < b ? a : b);
//         int maxSpeed = testResults.values.map((r) => r.speedMbps).reduce((a, b) => a > b ? a : b);
//         double minPing = testResults.values.map((r) => r.pingMs).reduce((a, b) => a < b ? a : b);
//         double maxPing = testResults.values.map((r) => r.pingMs).reduce((a, b) => a > b ? a : b);

//         // Calculate score
//         double speedWeight = 0.7;
//         double pingWeight = 0.3;

//         double calculateScore(TestResult r) {
//           double normalizedSpeed = maxSpeed == minSpeed ? 1.0 : (r.speedMbps - minSpeed) / (maxSpeed - minSpeed);
//           double normalizedPing = maxPing == minPing ? 1.0 : (maxPing - r.pingMs) / (maxPing - minPing);
//           return (normalizedSpeed * speedWeight) + (normalizedPing * pingWeight);
//         }

//         // Sort by score descending
//         activeServers.sort((a, b) => calculateScore(testResults[b]!).compareTo(calculateScore(testResults[a]!)));

//         // Assign categories in ratio 2:3:5
//         int total = activeServers.length;
//         int homeCount = (total * 0.2).round();    // 20%
//         int goldenCount = (total * 0.3).round();  // 30%
//         int freeCount = total - homeCount - goldenCount; // remaining 50%

//         for (int i = 0; i < activeServers.length; i++) {
//           var s = activeServers[i];
//           if (i < homeCount) s.serverType = "HOME";
//           else if (i < homeCount + goldenCount) s.serverType = "GOLDEN";
//           else s.serverType = "FREE";

//           s.status = "active";
//           updatesBuffer.add(s);
//         }
//       }

//       // 4. Flush updates
//       if (updatesBuffer.isNotEmpty) await ApiService.sendBulkUpdate(updatesBuffer);
//       if (deletesBuffer.isNotEmpty) await ApiService.sendBulkDelete(deletesBuffer);

//     } catch (e) {
//       print("💥 Critical Scan Setup Error: $e");
//     } finally {
//       isScanning = false;
//       print("🏁 FINISHED: Scan Complete.\n");
//     }
//   }
// }
