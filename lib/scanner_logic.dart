import 'dart:convert';
import 'dart:math';
import 'api_service.dart';
import 'vpn_manager.dart';
import 'server_model.dart';
import 'config.dart';

class ScannerLogic {
  static bool isScanning = false;
  static bool stopScanning = false;

  // ⚡ BATCH SIZE
  static const int BATCH_SIZE = 40;

  // 🧠 DYNAMIC BRAIN
  static double _globalAvgSpeed = 8.0;

  // 🛡️ 1. ABSOLUTE FLOORS (Quality)
  static const int FLOOR_HOME = 15;
  static const int FLOOR_GOLDEN = 5;

  // 💰 2. DYNAMIC MULTIPLIERS (Trend)
  static const double MULTIPLIER_HOME = 2.0; 
  static const double MULTIPLIER_GOLDEN = 1.0; 

  // 🔒 3. SCARCITY CAPS (The Hard Limit per batch)
  // Max 5% of batch can be Home (e.g., 2 servers out of 40)
  // Max 10% of batch can be Golden (e.g., 4 servers out of 40)
  static const double CAP_HOME_PERCENT = 0.05;
  static const double CAP_GOLDEN_PERCENT = 0.10;

  static Future<void> startScan() async {
    if (isScanning) {
      print("🔒 Service is already running.");
      return;
    }

    stopScanning = false;
    isScanning = true;
    print("\n🏁 STARTED: Triple-Lock Scarcity Mode");
    print("🧠 Initial Global Average: ${_globalAvgSpeed.toStringAsFixed(2)} Mbps");

    while (isScanning) {
      if (stopScanning) break;

      try {
        List<VpnServerModel> batch = await ApiService.fetchNextBatch(limit: BATCH_SIZE);

        if (batch.isEmpty) {
          print("💤 No pending servers. Sleeping for 60 seconds...");
          await Future.delayed(Duration(seconds: 60));
          continue;
        }

        print("\n📦 Processing Batch of ${batch.length} servers...");
        await _processAndGradeBatch(batch);

      } catch (e) {
        print("💥 Loop Error: $e");
        await Future.delayed(Duration(seconds: 10));
      }
    }

    isScanning = false;
    print("🏁 SERVICE STOPPED.");
  }

  static Future<void> _processAndGradeBatch(List<VpnServerModel> servers) async {
    Map<VpnServerModel, TestResult> successfulTests = {};
    List<String> deleteIds = [];
    List<int> speedSamples = [];

    // A. TEST PHASE
    for (var i = 0; i < servers.length; i++) {
      if (stopScanning) break;

      var server = servers[i];
      print("👉 [${i + 1}/${servers.length}] Testing ${server.ipAddress}...");

      try {
        // Config Parsing (Your Exact Logic)
        Map<String, dynamic> openvpnConfig = jsonDecode(jsonEncode(server.config));
        String patchedConfigFile = openvpnConfig['openvpnConfig'] ?? "";

        if (patchedConfigFile.isEmpty) {
          if (server.id != null) deleteIds.add(server.id!);
          print("   ⚠️ No config found. Added to delete list.");
          continue;
        }

        if (patchedConfigFile.contains('cipher AES-128-CBC') && !patchedConfigFile.contains('data-ciphers')) {
          patchedConfigFile = patchedConfigFile.replaceAll('cipher AES-128-CBC', 'cipher AES-128-CBC\ndata-ciphers AES-128-CBC\ndata-ciphers-fallback AES-128-CBC');
        }
        if (patchedConfigFile.contains('cipher AES-256-CBC') && !patchedConfigFile.contains('data-ciphers')) {
          patchedConfigFile = patchedConfigFile.replaceAll('cipher AES-256-CBC', 'cipher AES-256-CBC\ndata-ciphers AES-256-CBC\ndata-ciphers-fallback AES-256-CBC');
        }

        TestResult result = await VpnManager.connectAndTest(
          configContent: patchedConfigFile,
          ip: server.ipAddress,
          username: server.username,
          password: server.password,
        );

        if (result.success) {
          successfulTests[server] = result;
          speedSamples.add(result.speedMbps);
          print("   ✅ Connected (${result.speedMbps} Mbps) - Pending Grading");
        } else {
          if (server.id != null) deleteIds.add(server.id!);
          print("   🗑️ Connection Failed.");
        }

      } catch (innerError) {
        print("   💥 Error processing: $innerError");
      }
    }

    // B. LEARNING PHASE
    if (speedSamples.isNotEmpty) {
      double batchAvg = speedSamples.reduce((a, b) => a + b) / speedSamples.length;
      _globalAvgSpeed = (_globalAvgSpeed * 0.9) + (batchAvg * 0.1);
      print("🧠 GLOBAL UPDATE: New Benchmark = ${_globalAvgSpeed.toStringAsFixed(2)} Mbps");
    }

    // C. TRIPLE-LOCK GRADING PHASE
    if (successfulTests.isNotEmpty) {
      print("📊 Grading ${successfulTests.length} survivors...");
      List<VpnServerModel> rankedServers = _applyTripleLockGrading(successfulTests);
      
      print("📤 Sending Bulk Update...");
      await ApiService.sendBulkUpdate(rankedServers);
    }

    // D. DELETE PHASE
    if (deleteIds.isNotEmpty) {
      print("🗑 Cleaning ${deleteIds.length} Dead Servers...");
      await ApiService.sendBulkDelete(deleteIds);
    }
    
    print("✅ Batch Complete.\n");
  }

  // --- TRIPLE LOCK GRADING LOGIC ---
  static List<VpnServerModel> _applyTripleLockGrading(Map<VpnServerModel, TestResult> resultsMap) {
    List<VpnServerModel> allServers = resultsMap.keys.toList();
    
    // Temporary lists for sorting
    List<VpnServerModel> homeCandidates = [];
    List<VpnServerModel> goldenCandidates = [];
    List<VpnServerModel> freeCandidates = [];

    // 1. QUALIFICATION ROUND (Apply Floors & Dynamic Multipliers)
    for (var s in allServers) {
      var result = resultsMap[s]!;
      int speed = result.speedMbps;

      // Update basic stats
      s.downloadSpeed = speed;
      s.ping = result.pingMs.toInt();
      s.status = "active";
      s.score = min((speed / 100.0) * 80 + (100 / (result.pingMs + 1)) * 20, 100.0).toInt();

      // Check Quality
      bool qualifiesHome = (speed >= FLOOR_HOME) && (speed >= _globalAvgSpeed * MULTIPLIER_HOME);
      bool qualifiesGolden = (speed >= FLOOR_GOLDEN) && (speed >= _globalAvgSpeed * MULTIPLIER_GOLDEN);

      if (qualifiesHome) {
        homeCandidates.add(s);
      } else if (qualifiesGolden) {
        goldenCandidates.add(s);
      } else {
        freeCandidates.add(s);
      }
    }

    // 2. SORTING ROUND (Best speeds first)
    homeCandidates.sort((a, b) => b.downloadSpeed.compareTo(a.downloadSpeed));
    goldenCandidates.sort((a, b) => b.downloadSpeed.compareTo(a.downloadSpeed));

    // 3. CAP ROUND (Enforce Scarcity)
    int maxHome = (allServers.length * CAP_HOME_PERCENT).round();
    if (maxHome < 1 && allServers.length >= 5) maxHome = 1; // Allow 1 if batch is decent

    int maxGolden = (allServers.length * CAP_GOLDEN_PERCENT).round();
    if (maxGolden < 1 && allServers.length >= 3) maxGolden = 1;

    // -- Process HOME Caps --
    List<VpnServerModel> finalHome = [];
    if (homeCandidates.length > maxHome) {
      // Keep top X, demote the rest to Golden
      finalHome = homeCandidates.sublist(0, maxHome);
      List<VpnServerModel> demoted = homeCandidates.sublist(maxHome);
      goldenCandidates.addAll(demoted); // Add demoted to Golden pool
      // Re-sort Golden because we just added new ones
      goldenCandidates.sort((a, b) => b.downloadSpeed.compareTo(a.downloadSpeed));
    } else {
      finalHome = homeCandidates;
    }

    // -- Process GOLDEN Caps --
    List<VpnServerModel> finalGolden = [];
    if (goldenCandidates.length > maxGolden) {
      // Keep top Y, demote the rest to Free
      finalGolden = goldenCandidates.sublist(0, maxGolden);
      List<VpnServerModel> demoted = goldenCandidates.sublist(maxGolden);
      freeCandidates.addAll(demoted);
    } else {
      finalGolden = goldenCandidates;
    }

    // 4. FINAL ASSIGNMENT
    List<VpnServerModel> resultList = [];

    for (var s in finalHome) {
      s.serverType = "HOME";
      s.isFree = false;
      print("   🏆 ${s.ipAddress} -> HOME (${s.downloadSpeed} Mbps)");
      resultList.add(s);
    }
    for (var s in finalGolden) {
      s.serverType = "GOLDEN";
      s.isFree = false;
      print("   🥇 ${s.ipAddress} -> GOLDEN (${s.downloadSpeed} Mbps)");
      resultList.add(s);
    }
    for (var s in freeCandidates) {
      s.serverType = "FREE";
      s.isFree = true;
      print("   🆓 ${s.ipAddress} -> FREE (${s.downloadSpeed} Mbps)");
      resultList.add(s);
    }

    return resultList;
  }
}