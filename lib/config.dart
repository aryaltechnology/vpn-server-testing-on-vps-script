import 'package:dotenv/dotenv.dart';

class Config {
  static final DotEnv _env = DotEnv(includePlatformEnvironment: true)..load();

  // API Config
  static String get baseUrl => _env['BACKEND_URL'] ?? 'http://localhost:3000';
  static String get apiKey => _env['API_KEY'] ?? '';
  
  // Logic Thresholds (Mbps)
  static double get homeThreshold => double.tryParse(_env['HOME_THRESHOLD'] ?? '20.0')!;
  static double get goldenThreshold => double.tryParse(_env['GOLDEN_THRESHOLD'] ?? '5.0')!;
  
  // VPS Settings
  static int get listenerPort => int.tryParse(_env['PORT'] ?? '8080')!;
}