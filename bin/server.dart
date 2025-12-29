import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:vpn_server_auto_test_vps/config.dart';
import 'package:vpn_server_auto_test_vps/scanner_logic.dart';


void main() async {
  final app = Router();

  // 1. Health Check
  app.get('/', (Request r) {
    return Response.ok('{"status": "online", "scanning": ${ScannerLogic.isScanning}}',
  
        headers: {'Content-Type': 'application/json'});
  });

  // 2. Manual Trigger (Optional now, but good for restart)
  app.post('/start-scan', (Request request) {
    final incomingKey = request.headers['x-secret-key'];
    if (incomingKey != Config.secretToken) {
      return Response.forbidden('{"error": "Unauthorized"}');
    }

    if (ScannerLogic.isScanning) {
      return Response.ok('{"status": "busy", "message": "Scan already running"}');
    }
    
    // Fire manual scan
    ScannerLogic.startScan();
    return Response.ok('{"status": "started", "message": "Manual scan initiated"}');
  });

  // 3. Stop Trigger (Emergency Stop)
  app.post('/stop-scan', (Request request) {
    final incomingKey = request.headers['x-secret-key'];
    if (incomingKey != Config.secretToken) {
      return Response.forbidden('{"error": "Unauthorized"}');
    }
    
    // ScannerLogic.stopScanning = true;
    return Response.ok('{"status": "stopping", "message": "Stopping scan loop..."}');
  });

  // 4. Start HTTP Server
  final handler = Pipeline().addMiddleware(logRequests()).addHandler(app);
  final server = await io.serve(handler, InternetAddress.anyIPv4, Config.listenerPort);
  print('🚀 VPS Tester HTTP Service listening on port ${server.port}');

  // ====================================================
  // 🚀 AUTO-START LOGIC (DAEMON MODE)
  // ====================================================
  print("🤖 Daemon Mode Enabled: Starting Infinite Loop automatically...");
  
  // We call this WITHOUT 'await' so the HTTP server keeps running while the loop runs
  ScannerLogic.startScan(); 
}