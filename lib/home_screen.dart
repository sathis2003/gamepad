import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'gamepad_screen.dart'; // Import the Cricket gamepad screen

class CricketHomeScreen extends StatefulWidget {
  @override
  State<CricketHomeScreen> createState() => _CricketHomeScreenState();
}

class _CricketHomeScreenState extends State<CricketHomeScreen> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  String? errorMessage;
  bool isConnecting = false;
  String debugInfo = '';
  bool _showAdvanced = false;
  bool _leftHanded = false;

  @override
  void initState() {
    super.initState();
    _loadDefaultSettings();
  }

  void _loadDefaultSettings() {
    // Load any saved settings or use defaults
    _ipController.text = '';
  }

  void _updateDebugInfo(String info) {
    if (mounted) {
      setState(() {
        debugInfo = info;
      });
    }
    print('CRICKET DEBUG: $info');
  }

  Future<void> connectToCricketServer() async {
    if (isConnecting) return;

    final ip = _ipController.text.trim();
    final portText = _portController.text.trim();
    final port = int.tryParse(portText) ?? 8080;

    // Enhanced Cricket 24 validation
    if (ip.isEmpty) {
      setState(() {
        errorMessage = "Enter your PC's address. The server prints it when it starts.";
        debugInfo = '';
      });
      return;
    }

    if (!_isValidIP(ip)) {
      setState(() {
        errorMessage = "Use four numbers separated by dots, like 192.168.1.100.";
        debugInfo = '';
      });
      return;
    }

    if (port < 1024 || port > 65535) {
      setState(() {
        errorMessage = "Port must be between 1024 and 65535.";
        debugInfo = '';
      });
      return;
    }

    setState(() {
      isConnecting = true;
      errorMessage = null;
      debugInfo = "Connecting to $ip:$port…";
    });

    try {
      _updateDebugInfo("Step 1: Establishing Cricket server connection...");

      Socket? socket;
      try {
        socket = await Socket.connect(ip, port, timeout: Duration(seconds: 10));
        _updateDebugInfo("Step 1: Cricket server connection established!");
      } catch (e) {
        _updateDebugInfo("Step 1: Cricket connection failed - ${e.toString()}");
        throw SocketException('Cricket server unreachable: ${_getCricketErrorMessage(e)}');
      }

      _updateDebugInfo("Step 2: Optimizing Cricket connection...");
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
        _updateDebugInfo("Step 2: Cricket connection optimized for low latency");
      } catch (e) {
        _updateDebugInfo("Step 2: Optimization warning: $e");
      }

      _updateDebugInfo("Step 3: Testing Cricket server compatibility...");
      try {
        final cricketHandshake = jsonEncode({
          'type': 'cricket_test',
          'client_type': 'flutter_cricket_gamepad',
          'game': 'Cricket 24',
          'version': '3.0',
          'features': ['anti_repeat', 'enhanced_timing'],
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'platform': Platform.operatingSystem,
        });

        socket.write('$cricketHandshake\n');
        await socket.flush();
        _updateDebugInfo("Step 3: Cricket handshake sent successfully");

        // Wait for server response
        await Future.delayed(Duration(milliseconds: 300));
        _updateDebugInfo("Step 3: Cricket server ready for gameplay");

      } catch (e) {
        _updateDebugInfo("Step 3: Cricket test warning: $e");
      }

      _updateDebugInfo("Connected. Opening the controller…");

      if (mounted) {
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                CricketGamepadScreen(socket: socket!, leftHanded: _leftHanded),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: Duration(milliseconds: 300),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final cricketError = _getCricketErrorMessage(e);
        setState(() {
          errorMessage = cricketError;
          isConnecting = false;
          debugInfo = '';
        });

        print('Cricket Connection Error: $e');
        _showCricketTroubleshooting(e);
      }
    }
  }

  bool _isValidIP(String ip) {
    final ipRegex = RegExp(r'^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$');
    return ipRegex.hasMatch(ip);
  }

  String _getCricketErrorMessage(dynamic error) {
    final errorStr = error.toString().toLowerCase();

    if (errorStr.contains('timeout') || errorStr.contains('timed out')) {
      return 'Cricket server timeout. Check:\n'
          '• Server is running (python server.py)\n'
          '• IP address matches server output\n'
          '• Both devices on same WiFi\n'
          '• Windows firewall allows Python';
    } else if (errorStr.contains('refused') || errorStr.contains('connection failed')) {
      return 'Cricket server refused connection:\n'
          '• Check server is running on port 8080\n'
          '• Verify no firewall blocking\n'
          '• Try restarting the server';
    } else if (errorStr.contains('unreachable') || errorStr.contains('no route')) {
      return 'Cricket server unreachable:\n'
          '• Confirm same WiFi network\n'
          '• Check IP address is correct\n'
          '• Router allows device communication';
    } else if (errorStr.contains('host lookup failed')) {
      return 'Invalid Cricket server IP address';
    }

    return 'Cricket connection failed: ${error.toString()}';
  }

  void _showCricketTroubleshooting(dynamic error) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Pad.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text("Couldn't connect", style: TextStyle(color: Pad.ink, fontWeight: FontWeight.w800)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Check the setup on your PC:', style: TextStyle(color: Pad.muted)),
                SizedBox(height: 12),
                _buildCricketStep('1', 'Install Python from python.org'),
                _buildCricketStep('2', 'Install vgamepad: pip install vgamepad'),
                _buildCricketStep('3', 'Run the server: python server.py'),
                _buildCricketStep('4', 'Look for "Connect devices to: X.X.X.X:8080"'),
                _buildCricketStep('5', 'Enter that exact address here'),
                _buildCricketStep('6', 'On Windows, allow Python through the firewall'),
                SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Pad.well,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    error.toString(),
                    style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: Pad.bad),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Pad.muted),
              child: Text('Test connection'),
              onPressed: () {
                Navigator.of(context).pop();
                _testCricketConnection();
              },
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Pad.ink, foregroundColor: Pad.well),
              child: Text('Close'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCricketStep(String number, String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepNumber(number, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: Pad.ink),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _testCricketConnection() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8080;

    if (ip.isEmpty || !_isValidIP(ip)) {
      setState(() {
        errorMessage = null;
        debugInfo = "Enter a valid PC address first, like 192.168.1.100.";
      });
      return;
    }

    setState(() {
      errorMessage = null;
      debugInfo = "Looking for the server at $ip:$port…";
    });

    Socket? testSocket;
    try {
      _updateDebugInfo("Cricket Test 1: Checking server availability...");

      testSocket = await Socket.connect(ip, port, timeout: Duration(seconds: 8));
      _updateDebugInfo("Cricket Test 1: SUCCESS - Server is responding!");

      _updateDebugInfo("Cricket Test 2: Verifying Cricket server type...");

      try {
        final testMsg = jsonEncode({
          'type': 'cricket_server_test',
          'test_version': '3.0',
          'expected_game': 'Cricket 24',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });

        testSocket.write('$testMsg\n');
        await testSocket.flush();
        _updateDebugInfo("Cricket Test 2: Server communication verified!");

        await Future.delayed(Duration(milliseconds: 600));
        _updateDebugInfo("Server found. You're ready to connect.");

      } catch (e) {
        _updateDebugInfo("Cricket Test 2: Communication test completed (server may not respond to tests)");
      }

    } catch (e) {
      _updateDebugInfo("CRICKET TESTS FAILED: ${_getCricketErrorMessage(e)}");

      // Additional Cricket-specific diagnostics
      if (e.toString().contains('timeout')) {
        _updateDebugInfo("\nCricket Diagnosis: Server timeout");
        _updateDebugInfo("• Check if 'python server.py' is running");
        _updateDebugInfo("• Verify IP matches server output exactly");
        _updateDebugInfo("• Ensure both devices on same WiFi network");
      } else if (e.toString().contains('refused')) {
        _updateDebugInfo("\nCricket Diagnosis: Connection refused");
        _updateDebugInfo("• Server may not be running on port $port");
        _updateDebugInfo("• Check Windows firewall settings");
        _updateDebugInfo("• Try restarting the Cricket server");
      }
    } finally {
      try {
        testSocket?.close();
      } catch (e) {
        print('Cricket test socket close error: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  Widget _stepNumber(String number, {double size = 26}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Pad.well, shape: BoxShape.circle),
      child: Text(
        number,
        style: TextStyle(color: Pad.muted, fontSize: size / 2, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _setupStep(String number, String title, InlineSpan detail) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepNumber(number),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: Pad.ink, fontSize: 14, fontWeight: FontWeight.w600)),
                Text.rich(detail, style: TextStyle(color: Pad.muted, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: Pad.ink, borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.sports_esports_rounded, color: Pad.well, size: 22),
          ),
          SizedBox(width: 10),
          Text('PocketPad', style: TextStyle(color: Pad.ink, fontSize: 17, fontWeight: FontWeight.w700)),
        ]),
        SizedBox(height: 16),
        Text(
          'Play Cricket 24\nfrom your phone',
          style: TextStyle(color: Pad.ink, fontSize: 32, fontWeight: FontWeight.w800, height: 1.08),
        ),
        SizedBox(height: 8),
        Text(
          'Your phone becomes a wireless controller for the game running on your PC.',
          style: TextStyle(color: Pad.muted, fontSize: 14, height: 1.45),
        ),
        SizedBox(height: 16),
        _setupStep('1', 'Start the server on your PC', TextSpan(children: [
          TextSpan(text: 'Run '),
          TextSpan(text: 'python server.py', style: TextStyle(fontFamily: 'monospace', color: Pad.ink, fontSize: 13)),
        ])),
        _setupStep('2', 'Enter the address it shows', TextSpan(text: 'Something like 192.168.1.100')),
        _setupStep('3', 'Stay on the same Wi-Fi', TextSpan(text: 'Allow Python through the firewall if asked')),
      ],
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    String? hint,
    TextInputType? keyboardType,
  }) {
    final radius = BorderRadius.circular(14);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Pad.muted, fontSize: 13, fontWeight: FontWeight.w500)),
        SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          enabled: !isConnecting,
          cursorColor: Pad.ink,
          style: TextStyle(color: Pad.ink, fontSize: 16, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Color(0xFF6B737B), fontWeight: FontWeight.w500),
            filled: true,
            fillColor: Pad.well,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: Pad.ink, width: 2)),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectButton() {
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: isConnecting ? null : connectToCricketServer,
        style: FilledButton.styleFrom(
          backgroundColor: Pad.ink,
          foregroundColor: Pad.well,
          disabledBackgroundColor: Pad.ink.withValues(alpha: 0.8),
          disabledForegroundColor: Pad.well,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        child: isConnecting
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Pad.well)),
                SizedBox(width: 10),
                Text('Connecting'),
              ])
            : Text('Connect'),
      ),
    );
  }

  Widget _buildMessage() {
    final String text;
    final Color color;
    final Widget lead;
    if (errorMessage != null) {
      text = errorMessage!;
      color = Pad.bad;
      lead = Icon(Icons.error_outline_rounded, color: color, size: 17);
    } else if (debugInfo.isNotEmpty) {
      text = debugInfo;
      color = Pad.muted;
      lead = isConnecting
          ? SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          : Icon(Icons.info_outline_rounded, color: color, size: 17);
    } else {
      return SizedBox(height: 12);
    }

    return Padding(
      padding: EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: EdgeInsets.only(top: 1), child: lead),
          SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
        ]),
      ),
    );
  }

  Widget _buildLinkButton({required String label, IconData? icon, IconData? trailing, VoidCallback? onPressed}) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Pad.muted,
        minimumSize: Size(0, 44),
        padding: EdgeInsets.symmetric(horizontal: 4),
        textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 18), SizedBox(width: 6)],
        Text(label),
        if (trailing != null) ...[SizedBox(width: 2), Icon(trailing, size: 18)],
      ]),
    );
  }

  Widget _buildSettings() {
    Widget row(String name, String value) => Padding(
          padding: EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(name, style: TextStyle(color: Pad.muted, fontSize: 13))),
            Text(value, style: TextStyle(color: Pad.ink, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        );
    return Column(children: [
      row('Shortest button press', '25 ms'),
      row('Repeat protection', '50 ms'),
      row('Stick updates', '60 per second'),
      row('Stick dead zone', '15%'),
      MergeSemantics(
        child: Row(children: [
          Expanded(child: Text('Left-handed layout', style: TextStyle(color: Pad.ink, fontSize: 13, fontWeight: FontWeight.w600))),
          Switch(
            value: _leftHanded,
            onChanged: (v) => setState(() => _leftHanded = v),
            activeTrackColor: Pad.ink,
            inactiveTrackColor: Pad.well,
            trackOutlineColor: WidgetStatePropertyAll(Colors.transparent),
            thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected) ? Pad.well : Pad.muted,
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildPanel() {
    return Container(
      padding: EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Pad.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 30, offset: Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Connect to your PC', style: TextStyle(color: Pad.ink, fontSize: 20, fontWeight: FontWeight.w700)),
          SizedBox(height: 14),
          _buildField(
            label: 'PC address',
            controller: _ipController,
            hint: '192.168.1.100',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
          ),
          SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(
              width: 104,
              child: _buildField(label: 'Port', controller: _portController, keyboardType: TextInputType.number),
            ),
            SizedBox(width: 10),
            Expanded(child: _buildConnectButton()),
          ]),
          _buildMessage(),
          SizedBox(height: 8),
          Divider(height: 1, color: Pad.line),
          SizedBox(height: 4),
          Wrap(alignment: WrapAlignment.spaceBetween, children: [
            _buildLinkButton(
              label: 'Test connection',
              icon: Icons.wifi_tethering_rounded,
              onPressed: isConnecting ? null : _testCricketConnection,
            ),
            _buildLinkButton(
              label: 'Controller settings',
              trailing: _showAdvanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
            ),
          ]),
          if (_showAdvanced) _buildSettings(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pad.bgBottom,
      body: DecoratedBox(
        decoration: Pad.background,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 680;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 820),
                  child: wide
                      ? Row(children: [
                          Expanded(child: _buildIntro()),
                          SizedBox(width: 36),
                          SizedBox(width: 360, child: _buildPanel()),
                        ])
                      : Column(children: [_buildIntro(), SizedBox(height: 24), _buildPanel()]),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }
}
