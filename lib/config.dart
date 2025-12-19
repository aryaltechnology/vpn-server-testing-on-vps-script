import 'package:dotenv/dotenv.dart';


class Config {
  static final DotEnv _env = DotEnv(includePlatformEnvironment: true)..load();

  static String get baseUrl => _env['BACKEND_URL'] ?? 'http://localhost:3000';
  static String get apiKey => _env['API_KEY'] ?? '';
  
  static String get adminEmail => _env['ADMIN_EMAIL'] ?? '';
  static String get adminPassword => _env['ADMIN_PASSWORD'] ?? '';
  
  // ✅ New Field
  static String get deviceId => _env['VPS_DEVICE_ID'] ?? 'vps-automated-tester';
  
  static double get homeThreshold => double.tryParse(_env['HOME_THRESHOLD'] ?? '20.0')!;
  static double get goldenThreshold => double.tryParse(_env['GOLDEN_THRESHOLD'] ?? '5.0')!;
  static int get listenerPort => int.tryParse(_env['PORT'] ?? '8080')!;
}