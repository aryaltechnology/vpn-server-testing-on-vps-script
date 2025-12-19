import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'server_model.dart';

class ApiService {
  // Headers with Auth
  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'x-api-key': '${Config.apiKey}', // Assuming Bearer token
    // If you use x-api-key, change it here:
    // 'x-api-key': Config.apiKey
  };

  /// 1. Fetch ALL servers to test
  static Future<List<VpnServerModel>> fetchAllServers() async {
    print(
      "🔍 Fetching all VPN servers to test changed.. url = ${Config.baseUrl}api/v1/vpnServer?provider=vpngate",
    );
    final uri = Uri.parse('${Config.baseUrl}api/v1/vpnServer?provider=vpngate');
    print("🌐 Fetching servers from: $uri");

    try {
      final response = await http.get(uri, headers: _headers);
      print(  "📥 Response Status: ${response.statusCode}");
    

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Assuming your API returns { status: 200, data: [...] } or just [...]
        // Adjust logic based on your specific response wrapper
        List list = (data is Map && data.containsKey('data'))
            ? data['data']
            : data;

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

  /// 2. Bulk Update (For Home/Golden/Free/Speed)
  static Future<void> sendBulkUpdate(List<VpnServerModel> servers) async {
    if (servers.isEmpty) return;

    final uri = Uri.parse('${Config.baseUrl}api/v1/vpnServer/bulk-update');

    // Prepare the 'updates' array as per your controller
    final updates = servers.map((s) => s.toUpdateJson()).toList();

    try {
      final response = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({"updates": updates}),
      );

      if (response.statusCode == 200) {
        print("📤 Bulk Update Sent (${servers.length} items).");
      } else {
        print("⚠️ Bulk Update Failed: ${response.body}");
      }
    } catch (e) {
      print("⚠️ Bulk Update Error: $e");
    }
  }

  /// 3. Bulk Delete (For Dead Servers)
  static Future<void> sendBulkDelete(List<String> ids) async {
    if (ids.isEmpty) return;

    final uri = Uri.parse('${Config.baseUrl}api/v1/vpnServer/bulk-delete');

    try {
      final response = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({"ids": ids}),
      );

      if (response.statusCode == 200) {
        print("🗑 Bulk Delete Sent (${ids.length} items).");
      } else {
        print("⚠️ Bulk Delete Failed: ${response.body}");
      }
    } catch (e) {
      print("⚠️ Bulk Delete Error: $e");
    }
  }
}
