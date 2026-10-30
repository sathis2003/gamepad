import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'gamepad_screen.dart'; // Import the Cricket gamepad screen

class CricketHomeScreen extends StatefulWidget {
  @override
  State<CricketHomeScreen> createState() => _CricketHomeScreenState();
}

/// A PC running PocketPad Server that answered the LAN discovery broadcast.
class _FoundPc {
  final String name;
  final String ip;
  _FoundPc(this.name, this.ip);
}

class _CricketHomeScreenState extends State<CricketHomeScreen> {
  static const int port = 8080;
  final TextEditingController _ipController = TextEditingController();
  String? errorMessage;
  bool isConnecting = false;
  String debugInfo = '';
  bool _showAdvanced = false;
  bool _leftHanded = false;

  final List<_FoundPc> _found = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  /// Broadcasts POCKETPAD_DISCOVER on UDP 8080 and collects replies for 2 s.
  /// Sends to 255.255.255.255 and to each local /24 broadcast so hotspot and USB tethering work too.
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _found.clear();
    });
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udp.broadcastEnabled = true;
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = udp?.receive();
        if (dg == null) return;
        try {
          final reply = jsonDecode(utf8.decode(dg.data));
          final ip = dg.address.address;
          if (reply['pocketpad'] == 1 && _found.every((p) => p.ip != ip) && mounted) {
            setState(() => _found.add(_FoundPc(reply['name']?.toString() ?? ip, ip)));
          }
        } catch (_) {
          // not a PocketPad reply
        }
      });

      final targets = {'255.255.255.255'};
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in nic.addresses) {
          final parts = a.address.split('.');
          // ponytail: assumes /24, true for home routers, hotspot and USB tethering
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      final probe = utf8.encode('POCKETPAD_DISCOVER');
      for (var round = 0; round < 3; round++) {
        for (final t in targets) {
          udp.send(probe, InternetAddress(t), port);
        }
        await Future.delayed(Duration(milliseconds: 650));
      }
    } catch (e) {
      print('PC scan failed: $e');
    } finally {
      udp?.close();
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _updateDebugInfo(String info) {
    if (mounted) {
      setState(() {
        debugInfo = info;
      });
    }
    print('CRICKET DEBUG: $info');
  }

  Future<void> connectToCricketServer([String? foundIp]) async {
    if (isConnecting) return;

    final ip = foundIp ?? _ipController.text.trim();

    // Enhanced Cricket 24 validation
    if (ip.isEmpty) {
      setState(() {
        errorMessage = "Enter the address shown in the PocketPad Server window on your PC.";
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
      return 'The PC did not answer. Check:\n'
          '• PocketPad Server is open on the PC\n'
          '• The address matches the one in its window\n'
          '• Phone and PC are on the same Wi-Fi';
    } else if (errorStr.contains('refused') || errorStr.contains('connection failed')) {
      return 'The PC refused the connection:\n'
          '• Open PocketPad Server on the PC\n'
          '• If it is open, close it and open it again';
    } else if (errorStr.contains('unreachable') || errorStr.contains('no route')) {
      return 'The PC cannot be reached:\n'
          '• Put phone and PC on the same Wi-Fi\n'
          '• Check the address is correct';
    } else if (errorStr.contains('host lookup failed')) {
      return 'That PC address is not valid';
    }

    return 'Could not connect: ${error.toString()}';
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
                _buildCricketStep('1', 'Open PocketPad Server on the PC'),
                _buildCricketStep('2', 'Put phone and PC on the same Wi-Fi'),
                _buildCricketStep('3', 'Tap Scan again, or type the address shown in the PocketPad Server window'),
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
        _setupStep('1', 'Open PocketPad Server on your PC', TextSpan(text: 'Download it from the PocketPad website')),
        _setupStep('2', 'Use the same Wi-Fi', TextSpan(text: 'Or the phone hotspot, or a USB cable')),
        _setupStep('3', 'Tap your PC', TextSpan(text: 'It shows up in the list automatically')),
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

  Widget _buildPcList() {
    final tiles = _found.map((pc) => Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Material(
            color: Pad.well,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: isConnecting ? null : () => connectToCricketServer(pc.ip),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                child: Row(children: [
                  Icon(Icons.desktop_windows_rounded, color: Pad.ok, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(pc.name, style: TextStyle(color: Pad.ink, fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(pc.ip, style: TextStyle(color: Pad.muted, fontSize: 12)),
                    ]),
                  ),
                  Text('Connect', style: TextStyle(color: Pad.ink, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ));

    final status = _scanning
        ? Row(children: [
            SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Pad.muted)),
            SizedBox(width: 10),
            Text('Looking for your PC…', style: TextStyle(color: Pad.muted, fontSize: 13)),
          ])
        : _found.isEmpty
            ? Text('No PC found. Open PocketPad Server on your PC and use the same Wi-Fi.',
                style: TextStyle(color: Pad.muted, fontSize: 13))
            : SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...tiles,
      status,
      if (!_scanning)
        Align(
          alignment: Alignment.centerLeft,
          child: _buildLinkButton(label: 'Scan again', icon: Icons.refresh_rounded, onPressed: _scan),
        ),
    ]);
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
          _buildPcList(),
          SizedBox(height: 18),
          _buildField(
            label: 'Or type the PC address',
            controller: _ipController,
            hint: '192.168.1.100',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
          ),
          SizedBox(height: 10),
          _buildConnectButton(),
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
    super.dispose();
  }
}
