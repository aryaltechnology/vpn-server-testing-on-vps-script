import 'dart:convert';
import 'dart:math';
import 'api_service.dart';
import 'vpn_manager.dart';
import 'server_model.dart';
import 'config.dart';

class ScannerLogic {
  static bool isScanning = false;
  static bool stopScanning = false;

  // ⚡ BATCH SIZE: Updated to 40 as requested
  static const int BATCH_SIZE = 40;

  // 🔒 SCARCITY CAPS
  // We only want very few Golden servers (approx 1 out of 40)
  static const double CAP_GOLDEN_PERCENT = 0.05; // 5% of 40 = 2 Servers

  static Future<void> startScan() async {
    if (isScanning) {
      print("🔒 Service is already running.");
      return;
    }

    stopScanning = false;
    isScanning = true;
    
    // Check Mode from Config
    if (Config.isPremiumTester) {
      print("\n💎 STARTED: Premium Guard Mode (Maintenance & Cleanup)");
    } else {
      print("\n⛏️ STARTED: Miner Mode (Golden Discovery)");
    }

    // 🔄 1. THE INFINITE LOOP
    while (isScanning) {
      if (stopScanning) {
        print("🛑 Stop signal received. Exiting loop.");
        break;
      }

      try {
        // 🔄 2. FETCH BATCH
        List<VpnServerModel> batch = await ApiService.fetchNextBatch(limit: BATCH_SIZE);

        if (batch.isEmpty) {
          print("💤 No pending servers. Sleeping for 60 seconds...");
          await Future.delayed(Duration(seconds: 60));
          continue;
        }

        print("\n📦 Processing Batch of ${batch.length} servers...");
        
        // 🔄 3. CHOOSE LOGIC BASED ON MODE
        if (Config.isPremiumTester) {
          await _processPremiumGuardBatch(batch);
        } else {
          await _processAndGradeBatch(batch);
        }

      } catch (e) {
        print("💥 Loop Error: $e");
        print("   Restarting loop in 10 seconds...");
        await Future.delayed(Duration(seconds: 10));
      }
    }

    isScanning = false;
    print("🏁 SERVICE STOPPED.");
  }

  // =================================================================
  // 💎 PREMIUM GUARD LOGIC (Immediate Action) - UNCHANGED
  // =================================================================
  static Future<void> _processPremiumGuardBatch(List<VpnServerModel> servers) async {
    for (var server in servers) {
      if (stopScanning) break;
      print("👉 Checking VIP ${server.serverName} ${server.city} ${server.ipAddress} (${server.serverType})...");

      // 1. Config Check
      String? configStr = _prepareConfig(server);
      if (configStr == null) {
        if (server.id != null) {
           print("   🗑️ Bad Config. Deleting VIP Immediately.");
           await ApiService.deleteServer(server.id!);
        }
        continue;
      }

      // 2. Test Connection
      try {
        TestResult result = await VpnManager.connectAndTest(
          configContent: configStr,
          ip: server.ipAddress,
          username: server.username,
          password: server.password,
        );

        if (result.success) {
          // ✅ ALIVE
          server.downloadSpeed = result.speedMbps;
          server.ping = result.pingMs.toInt();
          server.status = "active";
          
          double speedScore = min(result.speedMbps.toDouble(), 100.0);
          double timeScore = max(0, 100 - (result.connectTimeMs / 100));
          double pingScore = max(0, 100 - (result.pingMs / 5));
          server.score = ((speedScore * 0.5) + (timeScore * 0.3) + (pingScore * 0.2)).round();

          print("   ✅ Alive. Speed: ${result.speedMbps} Mbps.");
        } else {
          // ❌ DEAD
          if (server.id != null) {
             print("   🗑️ Failed to connect. Deleting VIP Immediately.");
             await ApiService.deleteServer(server.id!);
          }
        }
      } catch (e) {
        print("   ⚠️ Error: $e");
      }
    }
    print("💎 Guard Batch Complete.\n");
  }

  // =================================================================
  // ⛏️ MINER LOGIC (Ratio Grading)
  // =================================================================
  static Future<void> _processAndGradeBatch(List<VpnServerModel> servers) async {
    Map<VpnServerModel, TestResult> successfulTests = {};
    List<String> deleteIds = [];

    // A. TEST PHASE
    for (var i = 0; i < servers.length; i++) {
      if (stopScanning) break;
      var server = servers[i];
      print("👉 [${i + 1}/${servers.length}] Testing ${server.ipAddress}...");

      try {
        String? configStr = _prepareConfig(server);
        if (configStr == null) {
          if (server.id != null) deleteIds.add(server.id!);
          print("   ⚠️ No config found. Added to Bulk Delete list.");
          continue;
        }

        TestResult result = await VpnManager.connectAndTest(
          configContent: configStr,
          ip: server.ipAddress,
          username: server.username,
          password: server.password,
        );

        if (result.success) {
          successfulTests[server] = result;
          print("   ✅ Connected (Speed: ${result.speedMbps} Mbps, Time: ${result.connectTimeMs}ms)");
        } else {
          if (server.id != null) deleteIds.add(server.id!);
          print("   🗑️ Connection Failed. Added to Bulk Delete list.");
        }
      } catch (innerError) {
        print("   💥 Error processing ${server.ipAddress}: $innerError");
      }
    }

    // B. GRADING PHASE
    if (successfulTests.isNotEmpty) {
      print("📊 Grading ${successfulTests.length} survivors...");
      // Logic changed here to remove HOME
      List<VpnServerModel> rankedServers = _applyForcedRatioGrading(successfulTests);
      
      print("📤 Sending Bulk Update...");
      await ApiService.sendBulkUpdate(rankedServers);
    }

    // C. DELETE PHASE
    if (deleteIds.isNotEmpty) {
      print("🗑 Sending Bulk Delete for ${deleteIds.length} servers...");
      await ApiService.sendBulkDelete(deleteIds);
    }
    
    print("✅ Batch Complete.\n");
  }

  // --- MINER GRADING LOGIC (UPDATED: NO HOME SERVER) ---
  static List<VpnServerModel> _applyForcedRatioGrading(Map<VpnServerModel, TestResult> resultsMap) {
    List<VpnServerModel> allServers = resultsMap.keys.toList();
    
    // 1. CALCULATE WEIGHTED SCORE
    for (var s in allServers) {
      var result = resultsMap[s]!;
      
      s.downloadSpeed = result.speedMbps;
      s.ping = result.pingMs.toInt();
      s.status = "active";
      
      // Speed (50%), Time (30%), Ping (20%)
      double speedScore = min(result.speedMbps.toDouble(), 100.0);
      double timeScore = max(0, 100 - (result.connectTimeMs / 100));
      double pingScore = max(0, 100 - (result.pingMs / 5));

      s.score = ((speedScore * 0.5) + (timeScore * 0.3) + (pingScore * 0.2)).round();
    }

    // 2. SORT BY SCORE (DESCENDING)
    // This ensures Index 0 is the BEST server
    allServers.sort((a, b) => b.score.compareTo(a.score));

    // 3. CALCULATE CUTOFFS (Strict Ratio)
    int totalCount = allServers.length;
    
    // Calculate Golden count based on very low percentage
    int goldenCount = (totalCount * CAP_GOLDEN_PERCENT).round();

    // SAFETY: Ensure at least 1 Golden server if we have valid servers
    if (totalCount >= 1 && goldenCount == 0) goldenCount = 1;

    // 4. ASSIGN TYPES
    List<VpnServerModel> resultList = [];
    
    for (int i = 0; i < totalCount; i++) {
      var s = allServers[i];
      var res = resultsMap[s]!;

      // Top servers become GOLDEN, everyone else is FREE
      if (i < goldenCount) {
        s.serverType = "GOLDEN";
        s.isFree = false;
        print("   🥇 ${s.ipAddress} -> GOLDEN (Score: ${s.score} | ${res.speedMbps}Mbps)");
      } else {
        s.serverType = "FREE";
        s.isFree = true;
        print("   🆓 ${s.ipAddress} -> FREE (Score: ${s.score})");
      }
      resultList.add(s);
    }

    return resultList;
  }

  // --- CONFIG PARSER (UNCHANGED) ---
  static String? _prepareConfig(VpnServerModel server) {
    try {
      Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
      String patchedConfigFile = openvpnConfig['openvpnConfig'] ?? "";

      if (patchedConfigFile.isEmpty) return null;

      if (patchedConfigFile.contains('cipher AES-128-CBC') && !patchedConfigFile.contains('data-ciphers')) {
        patchedConfigFile = patchedConfigFile.replaceAll(
          'cipher AES-128-CBC',
          '''cipher AES-128-CBC\ndata-ciphers AES-128-CBC\ndata-ciphers-fallback AES-128-CBC''',
        );
      }

      if (patchedConfigFile.contains('cipher AES-256-CBC') && !patchedConfigFile.contains('data-ciphers')) {
        patchedConfigFile = patchedConfigFile.replaceAll(
          'cipher AES-256-CBC',
          '''cipher AES-256-CBC\ndata-ciphers AES-256-CBC\ndata-ciphers-fallback AES-256-CBC''',
        );
      }
      return patchedConfigFile;
    } catch (_) {
      return null;
    }
  }
}