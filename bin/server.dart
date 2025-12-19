import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:vpn_server_auto_test_vps/config.dart';
import 'package:vpn_server_auto_test_vps/scanner_logic.dart';


void main() async {
  final app = Router();

  // 1. Status Check
  app.get('/', (Request r) => Response.ok('VPS Tester Online'));

  // 2. Trigger Endpoint
  app.post('/start-scan', (Request request) {
    if (ScannerLogic.isScanning) {

    
      return Response.ok('{"status": "busy", "message": "Scan already running"}');
    }
    
    // Fire and forget (don't wait for it to finish)
    ScannerLogic.startScan();
    
    return Response.ok('{"status": "started", "message": "Scan initiated"}');
  });

  // 3. Start Server
  final handler = Pipeline().addMiddleware(logRequests()).addHandler(app);
  
  final server = await io.serve(handler, InternetAddress.anyIPv4, Config.listenerPort);
  print('🚀 VPS Tester Service listening on port ${server.port}');
}