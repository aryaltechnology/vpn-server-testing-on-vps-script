import 'dart:convert';

class VpnServerModel {
  String? id;
  String serverName;
  String? provider;
  String protocol;
  String ipAddress;
  bool isFree;
  String? flagUrl;
  Map<String, dynamic> config;
  String status;
  String city;
  String country;
  String serverType;
  
  // ✅ Credentials
  String username;
  String password;

  // Connection Metrics
  int ping;
  int downloadSpeed;

  VpnServerModel({
    this.id,
    required this.serverName,
    this.provider,
    this.protocol = 'OpenVPN',
    required this.ipAddress,
    this.isFree = false,
    this.flagUrl,
    required this.config,
    this.status = 'active',
    this.city = '',
    this.country = '',
    this.serverType = 'FREE',
    this.username = '', // Default empty
    this.password = '', // Default empty
    this.ping = 0,
    this.downloadSpeed = 0,
  });

  factory VpnServerModel.fromJson(Map<String, dynamic> json) {
    // Ensure the config field is decoded properly if it's a string
      var configData = json['config'];

    
        // If the config field is a string, decode it into a Map
        if (configData is String) {
          if (configData == "" || configData.isEmpty) {
            configData = "{}";
          }
          configData = jsonDecode(configData); // Decode the string into a Map
        }
        if (json['provider'] == 'vpngate' &&
            configData['openvpnConfig'] is String) {
          try {
            String base64Config = configData['openvpnConfig']
                .trim(); // Remove extra spaces
            base64Config = base64.normalize(base64Config); // Fix padding issues
            configData['openvpnConfig'] =
                utf8.decode(base64.decode(base64Config));
          } catch (e) {
            throw FormatException("Failed to decode OpenVPN config: $e");
          }
        }
      

    return VpnServerModel(
      id: json['_id'], 
      serverName: json['serverName'] ?? '',
      provider: json['provider'],
      protocol: json['protocol'] ?? 'OpenVPN',
      ipAddress: json['ipAddress'] ?? '',
      isFree: json['isFree'] ?? false,
      flagUrl: json['flagUrl'],
      config: configData ?? {},
      status: json['status'] ?? 'active',
      city: json['city'] ?? '',
      country: json['country'] ?? '',
      serverType: json['serverType'] ?? 'FREE',
      
      // ✅ Map Credentials
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      
      // Flatten connection info
      downloadSpeed: json['connectionInfo']?['bandwidth']?['download'] ?? 0,
      ping: 0, 
    );
  }

  /// Prepare object for BULK UPDATE endpoint
  Map<String, dynamic> toUpdateJson() {
    return {
      "id": id,
      "serverType": serverType,
      "status": status,
      "connectionInfo": {
        "bandwidth": {
          "download": downloadSpeed,
          "upload": downloadSpeed
        }
      },
    };
  }
}