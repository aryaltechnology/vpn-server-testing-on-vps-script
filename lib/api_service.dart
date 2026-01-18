import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'server_model.dart';



class ApiService {
  
  // Store the JWT Token in memory
  static String? _accessToken;

  // Dynamic Headers: Always includes API Key, adds Token if we have it
  static Map<String, String> get _headers {
    Map<String, String> h = {
      'Content-Type': 'application/json',
      'x-api-key': Config.apiKey, // Required by your middleware
    };
    if (_accessToken != null) {
      h['Authorization'] = 'Bearer $_accessToken'; // Required for protected routes
    }
    return h;
  }

  // ---------------------------------------------------------------------------
  // 🔐 AUTHENTICATION LOGIC
  // ---------------------------------------------------------------------------

  /// Logs in the user and saves the Access Token
  static Future<bool> login() async {
    final uri = Uri.parse('${Config.baseUrl}/api/v1/auth/login');
    print("🔐 Authenticating as ${Config.adminEmail}...");

    try {
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': Config.apiKey, // Middleware check
        },
        body: jsonEncode({
          "email": Config.adminEmail,
          "password": Config.adminPassword,
          "deviceId": Config.deviceId // ✅ Required by your login controller
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // Structure based on your Node Code:
        // {
        //    "error": false,
        //    "message": "User logged in successfully",
        //    "data": { "accessToken": "...", "refreshToken": "..." }
        // }

        if (data['data'] != null && data['data']['accessToken'] != null) {
          _accessToken = data['data']['accessToken'];
          print("✅ Authentication Successful.");
          return true;
        }
      } 
      
      print("❌ Login Failed (${response.statusCode}): ${response.body}");
      return false;

    } catch (e) {
      print("❌ Login Exception: $e");
      return false;
    }
  }

  /// Ensures we have a token. If not, tries to log in.
  static Future<bool> _ensureAuth() async {
    if (_accessToken != null) return true;
    return await login();
  }

  // ---------------------------------------------------------------------------
  // 📡 API METHODS
  // ---------------------------------------------------------------------------

  /// 1. Fetch ALL servers (filtered by provider=vpngate)
  static Future<List<VpnServerModel>> fetchAllServers() async {
    if (!await _ensureAuth()) return [];

    final uri = Uri.parse('${Config.baseUrl}/api/v1/vpnServer?provider=vpngate');
    print("🌐 Fetching servers from: $uri");
      
    try {
      var response = await http.get(uri, headers: Map.of(_headers)..remove('Authorization'));

      // 🔄 RETRY LOGIC: If 401, token might be expired. Login and try once more.
      if (response.statusCode == 401) {
        print("⚠️ Token expired or invalid. Re-authenticating...");
        if (await login()) {
          response = await http.get(uri, headers: _headers);
        }
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Handle wrapper: { status: 200, data: [...] }
        List list = (data is Map && data.containsKey('data')) ? data['data'] : data;
        return list.map((e) => VpnServerModel.fromJson(e)).toList();
      } else {
        print("❌ API Error (${response.statusCode}): ${response.body}");
        return [];
      }
    } catch (e) {
      print("❌ Connection Error: $e");
      return [];
    }
  }

  /// 2. Bulk Update
  static Future<void> sendBulkUpdate(List<VpnServerModel> servers) async {
    if (servers.isEmpty) return;
    if (!await _ensureAuth()) return;

    final uri = Uri.parse('${Config.baseUrl}/api/v1/vpnServer/bulk-update');
    final updates = servers.map((s) => s.toUpdateJson()).toList();

    try {
      var response = await http.post(uri, headers: _headers, body: jsonEncode({"updates": updates}));

      // Retry on 401
      if (response.statusCode == 401) {
        if (await login()) {
          response = await http.post(uri, headers: _headers, body: jsonEncode({"updates": updates}));
        }
      }

      if (response.statusCode == 200) {
        print("📤 Bulk Update Sent (${servers.length} items).");
      } else {
        print("⚠️ Bulk Update Failed: ${response.body}");
      }
    } catch (e) {
      print("⚠️ Bulk Update Error: $e");
    }
  }

  /// 3. Bulk Delete
  static Future<void> sendBulkDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    if (!await _ensureAuth()) return;

    final uri = Uri.parse('${Config.baseUrl}/api/v1/vpnServer/bulk-delete');

    try {
      var response = await http.post(uri, headers: _headers, body: jsonEncode({"ids": ids}));

      // Retry on 401
      if (response.statusCode == 401) {
        if (await login()) {
          response = await http.post(uri, headers: _headers, body: jsonEncode({"ids": ids}));
        }
      }

      if (response.statusCode == 200) {
        print("🗑 Bulk Delete Sent (${ids.length} items).");
      } else {
        print("⚠️ Bulk Delete Failed: ${response.body}");
      }
    } catch (e) {
      print("⚠️ Bulk Delete Error: $e");
    }
  }

  /// 4. Delete Single Server (Immediate deletion for failed connections)
  static Future<void> deleteServer(String id) async {
    if (!await _ensureAuth()) return;

    final uri = Uri.parse('${Config.baseUrl}/api/v1/vpnServer/$id');

    try {
      var response = await http.delete(uri, headers: _headers);

      // Retry on 401
      if (response.statusCode == 401) {
        if (await login()) {
          response = await http.delete(uri, headers: _headers);
        }
      }

      if (response.statusCode == 200) {
        print("🗑 Server Deleted: $id");
      } else {
        print("⚠️ Server Deletion Failed: ${response.body}");
      }
    } catch (e) {
      print("⚠️ Server Deletion Error: $e");
    }
  }



  // ---------------------------------------------------------
  // ⚡ NEW: FETCH BATCH (The Infinite Loop Logic)
  // ---------------------------------------------------------
 // ⚡ FIXED FETCH LOGIC
  static Future<List<VpnServerModel>> fetchNextBatch({int limit = 50}) async {
    if (!await _ensureAuth()) return [];

    // Base URL
    String url = '${Config.baseUrl}/api/v1/vpnServer/candidates-for-testing?limit=$limit';

    // 🚀 CRITICAL FIX: APPLY FILTER IF PREMIUM MODE
    if (Config.isPremiumTester) {
      print("💎 [GUARD MODE] Fetching ONLY HOME & GOLDEN candidates...");
        url += "&isPremiumScan=true"; // <--- Explicit flag
    } else {
      print("⛏️ [MINER MODE] Fetching standard pool...");
    }

    final uri = Uri.parse(url);
    print("🌐 Fetching batch from: $uri");

    try {
      var response = await http.get(uri, headers: _headers);
   

      if (response.statusCode == 401) {
        if (await login()) response = await http.get(uri, headers: _headers);
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List list = [];
        if (data is Map && data.containsKey('data')) list = data['data'];
        else if (data is List) list = data;

        return list.map((e) => VpnServerModel.fromJson(e)).toList();
      }
      return [];
    } catch (e) {
      print("❌ Connection Error: $e");
      return [];
    }
  }

}