import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:vibration/vibration.dart';
import 'home_screen.dart';

/// Console design tokens, shared by the connect and controller screens.
class Pad {
  static const bgTop = Color(0xFF2A2E33);
  static const bgBottom = Color(0xFF1F2226);
  static const surface = Color(0xFF2B2F34);
  static const raised = Color(0xFF383D43);
  static const well = Color(0xFF1B1E21);
  static const line = Color(0xFF43494F);
  static const ink = Color(0xFFECEEF0);
  static const muted = Color(0xFFA3AAB2);
  static const ok = Color(0xFF7BC96F);
  static const bad = Color(0xFFEE7D76);
  static const a = Color(0xFF7BC96F);
  static const b = Color(0xFFEE7D76);
  static const x = Color(0xFF6AA6EC);
  static const y = Color(0xFFEBCB5E);
  static const keyTop = Color(0xFF3F444A);
  static const keyBottom = Color(0xFF34393E);
  static const keyShadow = Color(0xFF15181B);
  static const inkShadow = Color(0xFF9DA3AA);

  static const background = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [bgTop, bgBottom],
    ),
  );
}

class CricketGamepadScreen extends StatefulWidget {
  final Socket socket;
  final bool leftHanded;
  const CricketGamepadScreen({required this.socket, this.leftHanded = false, super.key});

  @override
  State<CricketGamepadScreen> createState() => _CricketGamepadScreenState();
}

class _CricketGamepadScreenState extends State<CricketGamepadScreen> {
  final String playerId = 'cricket_player';

  // Enhanced socket management for Cricket 24
  late Socket _socket;
  bool _socketReady = true;
  bool _isConnected = true;
  int? _assignedPlayerId;
  StreamSubscription? _socketSubscription;
  Timer? _heartbeatTimer;

  // UDP path for input packets, opened once the server advertises udp_port
  RawDatagramSocket? _udp;
  int _udpPort = 0;
  List<int> _udpToken = const []; // per-session token every datagram starts with

  // CRITICAL: Cricket 24 button state management with anti-repeat
  final Map<String, bool> _buttonStates = {};
  final Map<String, DateTime> _lastButtonPress = {};
  final Map<String, DateTime> _lastButtonRelease = {};
  final Map<String, bool> _physicallyPressed = {}; // Track actual user interaction
  final Map<String, Timer> _buttonTimers = {}; // For delayed releases

  // FIXED: Add trigger state tracking
  final Map<String, double> _triggerStates = {'LT': 0.0, 'RT': 0.0};

  // Cricket 24 specific timing
  static const Duration _minPressDuration = Duration(milliseconds: 25); // Cricket needs minimum press
  static const Duration _minReleaseGap = Duration(milliseconds: 50);    // Gap between presses
  static const Duration _appealCooldown = Duration(milliseconds: 1000); // Appeal cooldown
  static const Duration _shotCooldown = Duration(milliseconds: 200);    // Shot button cooldown

  // Joystick optimization for Cricket 24
  final Map<String, DateTime> _lastJoystickSend = {};
  final Map<String, dynamic> _lastJoystickValues = {};
  static const Duration _joystickThrottle = Duration(milliseconds: 16); // 60fps
  static const double _cricketDeadzone = 0.15; // Cricket 24 optimized deadzone

  // Enhanced connection monitoring
  DateTime _lastServerMessage = DateTime.now();
  Timer? _connectionMonitor;
  bool _serverSupportsEnhanced = false;

  // Vibration support
  bool _hasVibrator = false;
  bool _hasAmplitudeControl = false;

  // Performance tracking
  int _messagesSent = 0;
  int _messagesReceived = 0;
  DateTime _sessionStart = DateTime.now();

  // UI refresh: inputs-per-second readout and the DRS countdown
  Timer? _rateTimer;
  Timer? _appealTicker;
  int _inputRate = 0;
  int _sentAtLastTick = 0;

  @override
  void initState() {
    super.initState();
    _initializeCricketSocket();
    _checkVibrationSupport();
    _sendCricketHandshake();
    _rateTimer = Timer.periodic(Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _inputRate = _messagesSent - _sentAtLastTick;
        _sentAtLastTick = _messagesSent;
      });
    });
  }

  void _initializeCricketSocket() {
    _socket = widget.socket;
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
      print('Cricket 24 socket initialized');

      // Listen for server messages
      _socketSubscription = _socket.listen(
        _handleServerMessage,
        onError: _handleSocketError,
        onDone: _handleSocketClosed,
        cancelOnError: false,
      );

      // Cricket 24 optimized heartbeat
      _heartbeatTimer = Timer.periodic(Duration(seconds: 15), _sendHeartbeat);

    } catch (e) {
      print('Cricket socket initialization error: $e');
      Future.microtask(() => _handleConnectionLost());
    }
  }

  void _handleServerMessage(List<int> data) {
    try {
      final message = utf8.decode(data, allowMalformed: true);
      final lines = message.split('\n');

      for (final line in lines) {
        if (line.trim().isEmpty) continue;

        try {
          final json = jsonDecode(line.trim());
          _processServerMessage(json);
          _messagesReceived++;
        } catch (e) {
          // Ignore malformed JSON
        }
      }

      _lastServerMessage = DateTime.now();
    } catch (e) {
      print('Error handling Cricket server message: $e');
    }
  }

  void _processServerMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'cricket_welcome':
      case 'welcome':
        _assignedPlayerId = message['player_id'];
        _serverSupportsEnhanced = message['server_version'] == 'cricket_v2';
        print('Cricket Player $_assignedPlayerId connected');
        if (message['udp_port'] is int && message['udp_token'] is String && _udp == null) {
          _udpToken = utf8.encode(message['udp_token']);
          _openUdp(message['udp_port']);
        }
        if (mounted) setState(() {});
        break;
      case 'error':
      case 'cricket_server_full':
        print('Cricket server error: ${message['message']}');
        _showErrorSnackBar(message['message'] ?? 'Server error');
        break;
      case 'cricket_disconnect':
      case 'disconnect':
        print('Cricket server disconnect requested');
        _handleConnectionLost();
        break;
    }
  }

  void _handleSocketError(error) {
    print('Cricket socket error: $error');
    _handleConnectionLost();
  }

  void _handleSocketClosed() {
    print('Cricket socket closed by server');
    _handleConnectionLost();
  }

  void _handleConnectionLost() {
    if (!_isConnected) return;

    _isConnected = false;
    _socketReady = false;

    // Cancel all pending button timers
    for (final timer in _buttonTimers.values) {
      timer.cancel();
    }
    _buttonTimers.clear();

    if (mounted) {
      setState(() {});
      Future.microtask(() {
        if (mounted) {
          _showErrorSnackBar('Connection to the PC lost');

          Future.delayed(Duration(milliseconds: 800), () {
            if (mounted) {
              _showCricketReconnectionDialog();
            }
          });
        }
      });
    }
  }

  // The controller replaced the connect screen, so going back means rebuilding it.
  void _backToSetup() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => CricketHomeScreen()),
      (_) => false,
    );
  }

  void _showCricketReconnectionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Pad.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text('Connection lost', style: TextStyle(color: Pad.ink, fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Your phone can't reach the server. Check that server.py is still running and both devices are on the same Wi-Fi.",
                style: TextStyle(color: Pad.muted),
              ),
              SizedBox(height: 12),
              Text('Session length: ${DateTime.now().difference(_sessionStart).inMinutes} min', style: TextStyle(color: Pad.ink)),
              Text('Inputs sent: $_messagesSent', style: TextStyle(color: Pad.ink)),
              Text('Messages received: $_messagesReceived', style: TextStyle(color: Pad.ink)),
            ],
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Pad.ink, foregroundColor: Pad.well),
              child: Text('Back to connect'),
              onPressed: () {
                Navigator.of(context).pop();
                _backToSetup();
              },
            ),
          ],
        );
      },
    );
  }

  void _showErrorSnackBar(String message) {
    if (mounted && context.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.red[600],
              duration: Duration(seconds: 4),
            ),
          );
        }
      });
    }
  }

  void _sendHeartbeat(Timer timer) {
    if (!_socketReady || !_isConnected) {
      timer.cancel();
      return;
    }

    try {
      _sendCricketMessage({
        'type': 'heartbeat',
        'player': playerId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'session_stats': {
          'sent': _messagesSent,
          'received': _messagesReceived,
          'uptime': DateTime.now().difference(_sessionStart).inSeconds,
        }
      });
    } catch (e) {
      print('Cricket heartbeat failed: $e');
      _handleConnectionLost();
    }
  }

  void _sendCricketHandshake() {
    _sendCricketMessage({
      'type': 'cricket_handshake',
      'player': playerId,
      'client_type': 'cricket_gamepad_v3',
      'game': 'Cricket 24',
      'features': ['anti_repeat', 'enhanced_timing', 'performance_tracking'],
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _checkVibrationSupport() async {
    try {
      _hasVibrator = await Vibration.hasVibrator() ?? false;
      _hasAmplitudeControl = await Vibration.hasAmplitudeControl() ?? false;
      print('Cricket vibration support: $_hasVibrator');
    } catch (e) {
      print('Cricket vibration check failed: $e');
    }
  }

  Future<void> _openUdp(int port) async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpPort = port;
      print('Cricket UDP input path open on port $port');
    } catch (e) {
      print('Cricket UDP bind failed, staying on TCP: $e');
    }
  }

  // ULTRA-FAST: Cricket 24 optimized message sending
  void _sendCricketMessage(Map<String, dynamic> message) {
    if (!_socketReady || !_isConnected) return;

    try {
      final messageStr = jsonEncode(message) + '\n';
      final bytes = utf8.encode(messageStr);
      final isInput = message.containsKey('button') || message.containsKey('trigger') || message.containsKey('joystick');
      if (_udp != null && isInput) {
        final datagram = [..._udpToken, ...bytes];
        _udp!.send(datagram, _socket.remoteAddress, _udpPort);
        // ponytail: button/trigger events sent twice so one lost datagram cannot leave a key stuck; server dedups identical bytes within 50ms
        if (!message.containsKey('joystick')) _udp!.send(datagram, _socket.remoteAddress, _udpPort);
      } else {
        _socket.add(bytes);
      }
      _messagesSent++;
    } catch (e) {
      print('Cricket send error: $e');
      _handleConnectionLost();
    }
  }

  // FIXED: Handle RT/LT as triggers instead of buttons
  void _pressCricketTrigger(String trigger) {
    if (!_isConnected) return;

    final now = DateTime.now();
    final lastPress = _lastButtonPress[trigger];

    if (lastPress != null && now.difference(lastPress) < _minReleaseGap) {
      print('Cricket $trigger on cooldown');
      return;
    }

    // Set trigger to maximum value (1.0)
    _triggerStates[trigger] = 1.0;
    _lastButtonPress[trigger] = now;

    _sendCricketMessage({
      'player': playerId,
      'trigger': trigger,
      'value': 1.0,
      'type': 'trigger_press',
      'game': 'cricket24',
      'timestamp': now.millisecondsSinceEpoch,
    });

    setState(() {});
    _provideCricketFeedback(trigger);
    print('CRICKET TRIGGER PRESS: $trigger');
  }

  void _releaseCricketTrigger(String trigger) {
    if (!_isConnected) return;

    // Set trigger to zero
    _triggerStates[trigger] = 0.0;
    _lastButtonRelease[trigger] = DateTime.now();

    _sendCricketMessage({
      'player': playerId,
      'trigger': trigger,
      'value': 0.0,
      'type': 'trigger_release',
      'game': 'cricket24',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    setState(() {});
    print('CRICKET TRIGGER RELEASE: $trigger');
  }

  // CRITICAL: Cricket 24 optimized button press with anti-repeat
  void _pressCricketButton(String button) {
    if (!_isConnected) return;

    final now = DateTime.now();

    // Check if button is on cooldown
    final lastPress = _lastButtonPress[button];
    Duration cooldown = _minReleaseGap;

    // Cricket 24 specific cooldowns
    if (['A', 'SHOT'].contains(button)) {
      cooldown = _shotCooldown;
    } else if (button == 'APPEAL') {
      cooldown = _appealCooldown;
    }

    if (lastPress != null && now.difference(lastPress) < cooldown) {
      print('Cricket $button on cooldown (${now.difference(lastPress).inMilliseconds}ms)');
      return;
    }

    // CRITICAL: Prevent phantom presses
    if (_buttonStates[button] == true || _physicallyPressed[button] == true) {
      print('Cricket $button already active - phantom prevention');
      return;
    }

    // Mark as physically pressed and update state
    _physicallyPressed[button] = true;
    _buttonStates[button] = true;
    _lastButtonPress[button] = now;

    // Send Cricket 24 optimized press message
    _sendCricketMessage({
      'player': playerId,
      'button': button,
      'type': 'press',
      'game': 'cricket24',
      'timestamp': now.millisecondsSinceEpoch,
    });

    // Visual and haptic feedback
    setState(() {});
    _provideCricketFeedback(button);

    print('CRICKET PRESS: $button');

    // Schedule minimum press duration for Cricket 24
    _buttonTimers[button]?.cancel();
    _buttonTimers[button] = Timer(_minPressDuration, () {
      // Auto-release after minimum duration if still pressed
      if (_buttonStates[button] == true) {
        print('Cricket auto-release: $button');
        _releaseCricketButton(button, autoRelease: true);
      }
    });
  }

  void _releaseCricketButton(String button, {bool autoRelease = false}) {
    if (!_isConnected) return;

    // CRITICAL: Only release if actually pressed
    if (_buttonStates[button] != true) {
      print('Cricket $button not pressed - ignoring release');
      return;
    }

    // For manual releases, ensure minimum press duration
    if (!autoRelease) {
      final pressTime = _lastButtonPress[button];
      if (pressTime != null) {
        final pressDuration = DateTime.now().difference(pressTime);
        if (pressDuration < _minPressDuration) {
          print('Cricket $button press too short - delaying release');

          _buttonTimers[button]?.cancel();
          _buttonTimers[button] = Timer(
            _minPressDuration - pressDuration,
                () => _releaseCricketButton(button, autoRelease: true),
          );
          return;
        }
      }
    }

    // Execute release
    _physicallyPressed[button] = false;
    _buttonStates[button] = false;
    _lastButtonRelease[button] = DateTime.now();

    // Cancel any pending auto-release
    _buttonTimers[button]?.cancel();
    _buttonTimers.remove(button);

    _sendCricketMessage({
      'player': playerId,
      'button': button,
      'type': 'release',
      'game': 'cricket24',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    setState(() {});
    print('CRICKET RELEASE: $button');
  }

  // SPECIAL: Cricket 24 tap with perfect timing
  void _cricketTap(String button) {
    if (!_isConnected) return;

    final now = DateTime.now();

    // Check cooldown
    final lastPress = _lastButtonPress[button];
    Duration cooldown = _minReleaseGap;

    if (['A', 'SHOT'].contains(button)) {
      cooldown = _shotCooldown;
    } else if (button == 'APPEAL') {
      cooldown = _appealCooldown;
    }

    if (lastPress != null && now.difference(lastPress) < cooldown) {
      print('Cricket $button tap on cooldown');
      return;
    }

    // Prevent if button is currently active
    if (_buttonStates[button] == true) {
      print('Cricket $button already active - ignoring tap');
      return;
    }

    _lastButtonPress[button] = now;

    _sendCricketMessage({
      'player': playerId,
      'button': button,
      'type': 'tap', // Use tap type for single-frame actions
      'game': 'cricket24',
      'timestamp': now.millisecondsSinceEpoch,
    });

    // Strong feedback for taps
    _provideCricketFeedback(button);

    // Brief visual feedback
    setState(() {
      _buttonStates[button] = true;
    });

    Timer(Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _buttonStates[button] = false;
        });
      }
    });

    // Rebuild once the cooldown ends so the dimmed key brightens again
    Timer(cooldown, () {
      if (mounted) setState(() {});
    });

    print('CRICKET TAP: $button');
  }

  void _sendJoystick(String id, double x, double y) {
    if (!_isConnected) return;

    final now = DateTime.now();
    final key = 'joy_$id';

    // Apply Cricket 24 deadzone
    if (x.abs() < _cricketDeadzone) x = 0.0;
    if (y.abs() < _cricketDeadzone) y = 0.0;

    // Check if values changed significantly
    final lastValues = _lastJoystickValues[key];
    if (lastValues != null) {
      final lastX = lastValues['x'] ?? 0.0;
      final lastY = lastValues['y'] ?? 0.0;

      if ((x - lastX).abs() < 0.05 && (y - lastY).abs() < 0.05) {
        return; // Not enough change
      }
    }

    // Throttle updates for Cricket 24 (60fps max)
    if (x != 0.0 || y != 0.0) {
      final lastSend = _lastJoystickSend[key];
      if (lastSend != null && now.difference(lastSend) < _joystickThrottle) {
        return;
      }
    }

    _lastJoystickSend[key] = now;
    _lastJoystickValues[key] = {'x': x, 'y': y};

    _sendCricketMessage({
      'player': playerId,
      'joystick': id,
      'x': x.toStringAsFixed(3),
      'y': y.toStringAsFixed(3),
      'game': 'cricket24',
      'timestamp': now.millisecondsSinceEpoch,
    });

    // Light haptic for strong movements in Cricket 24
    if (x.abs() > 0.7 || y.abs() > 0.7) {
      HapticFeedback.selectionClick();
    }
  }

  void _provideCricketFeedback(String button) {
    // Cricket 24 specific feedback patterns
    if (['A', 'SHOT'].contains(button)) {
      _vibrateCricketShot();
    } else if (['B', 'DEFEND'].contains(button)) {
      _vibrateCricketDefend();
    } else if (['LB', 'RB', 'LT', 'RT'].contains(button)) {
      _vibrateCricketTrigger();
    } else if (button == 'APPEAL') {
      _vibrateCricketAppeal();
    } else {
      _vibrateCricketGeneral();
    }
  }

  void _vibrateCricketShot() async {
    try {
      if (_hasVibrator && _hasAmplitudeControl) {
        await Vibration.vibrate(duration: 40, amplitude: 120);
      } else {
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      HapticFeedback.mediumImpact();
    }
  }

  void _vibrateCricketDefend() async {
    try {
      if (_hasVibrator && _hasAmplitudeControl) {
        await Vibration.vibrate(duration: 25, amplitude: 80);
      } else {
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      HapticFeedback.lightImpact();
    }
  }

  void _vibrateCricketTrigger() async {
    try {
      if (_hasVibrator && _hasAmplitudeControl) {
        await Vibration.vibrate(duration: 60, amplitude: 150);
      } else {
        HapticFeedback.heavyImpact();
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
    }
  }

  void _vibrateCricketAppeal() async {
    try {
      if (_hasVibrator && _hasAmplitudeControl) {
        // Double vibration for appeal
        await Vibration.vibrate(duration: 80, amplitude: 200);
        await Future.delayed(Duration(milliseconds: 50));
        await Vibration.vibrate(duration: 60, amplitude: 150);
      } else {
        HapticFeedback.heavyImpact();
        await Future.delayed(Duration(milliseconds: 50));
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
    }
  }

  void _vibrateCricketGeneral() async {
    try {
      if (_hasVibrator && _hasAmplitudeControl) {
        await Vibration.vibrate(duration: 30, amplitude: 100);
      } else {
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      HapticFeedback.lightImpact();
    }
  }

  bool _isButtonOnCooldown(String button) {
    final lastPress = _lastButtonPress[button];
    if (lastPress == null) return false;

    final now = DateTime.now();
    Duration cooldown = _minReleaseGap;

    if (['A', 'SHOT'].contains(button)) {
      cooldown = _shotCooldown;
    } else if (button == 'APPEAL') {
      cooldown = _appealCooldown;
    }

    return now.difference(lastPress) < cooldown;
  }

  // ---------------------------------------------------------------------------
  // Layout. Ergonomics for a phone held in landscape with two thumbs:
  // - Primary controls (left stick, A/B/X/Y) sit in the lower outer corners where thumbs rest.
  // - Secondary controls (D-pad, right stick, DRS) sit one stretch inward and up.
  // - Triggers and bumpers hug the top corners: edge targets are the easiest to hit blind.
  // - Rare controls (View, Menu, Pause, Back) go in the centre so they aren't hit by accident.
  // - Every target is at least 48dp; sticks accept touches beyond their ring.
  // The layout is drawn on an 824x370 canvas and scaled to fit the screen.
  // ---------------------------------------------------------------------------

  static const double _canvasW = 824, _canvasH = 370;
  static const double _edgeX = 24, _edgeBottom = 16;

  Widget _holdKey(String label, {required double width, required double height, required BorderRadius radius, double fontSize = 16}) {
    return PadKey(
      label: label,
      width: width,
      height: height,
      radius: radius,
      onDown: () {
        HapticFeedback.lightImpact();
        _pressCricketButton(label);
      },
      onUp: () => _releaseCricketButton(label),
      child: Text(label, style: TextStyle(fontSize: fontSize)),
    );
  }

  Widget _trigger(String label) {
    return PadKey(
      label: label,
      width: 112,
      height: 56,
      radius: BorderRadius.vertical(top: Radius.circular(22), bottom: Radius.circular(14)),
      active: (_triggerStates[label] ?? 0) > 0,
      onDown: () {
        HapticFeedback.mediumImpact();
        _pressCricketTrigger(label);
      },
      onUp: () => _releaseCricketTrigger(label),
      child: Text(label, style: TextStyle(fontSize: 18)),
    );
  }

  Widget _dpad() {
    const s = 48.0;
    final r = BorderRadius.circular(12);
    Widget arrow(String label, IconData icon, String name) => PadKey(
          label: name,
          width: s,
          height: s,
          radius: r,
          onDown: () {
            HapticFeedback.lightImpact();
            _pressCricketButton(label);
          },
          onUp: () => _releaseCricketButton(label),
          child: Icon(icon, size: 28),
        );
    // Plain Positioned (not directional) so the arrows never mirror.
    return SizedBox(
      width: s * 3,
      height: s * 3,
      child: Stack(children: [
        Positioned(left: s, top: 0, child: arrow('UP', Icons.keyboard_arrow_up_rounded, 'D-pad up')),
        Positioned(left: 0, top: s, child: arrow('LEFT', Icons.keyboard_arrow_left_rounded, 'D-pad left')),
        Positioned(left: s * 2, top: s, child: arrow('RIGHT', Icons.keyboard_arrow_right_rounded, 'D-pad right')),
        Positioned(left: s, top: s * 2, child: arrow('DOWN', Icons.keyboard_arrow_down_rounded, 'D-pad down')),
      ]),
    );
  }

  Widget _faceButtons() {
    const w = 60.0, h = 58.0, gx = 4.0, gy = 2.0;
    final r = BorderRadius.circular(30);
    Widget face(String label, Color color, {bool tap = false}) => PadKey(
          label: label,
          width: w,
          height: h,
          radius: r,
          color: color,
          activeFill: color,
          active: _buttonStates[label] == true && tap,
          coolingDown: tap && _isButtonOnCooldown(label),
          onDown: () {
            HapticFeedback.lightImpact();
            tap ? _cricketTap(label) : _pressCricketButton(label);
          },
          onUp: tap ? null : () => _releaseCricketButton(label),
          child: Text(label, style: TextStyle(fontSize: 22)),
        );
    // Xbox arrangement, kept the same in left-handed mode.
    return SizedBox(
      width: w * 3 + gx * 2,
      height: h * 3 + gy * 2,
      child: Stack(children: [
        Positioned(left: w + gx, top: 0, child: face('Y', Pad.y)),
        Positioned(left: 0, top: h + gy, child: face('X', Pad.x)),
        Positioned(left: (w + gx) * 2, top: h + gy, child: face('B', Pad.b)),
        Positioned(left: w + gx, top: (h + gy) * 2, child: face('A', Pad.a, tap: true)),
      ]),
    );
  }

  Widget _hud() {
    final statusColor = _isConnected ? Pad.ok : Pad.bad;
    final statusText = _isConnected
        ? (_assignedPlayerId != null ? 'Player $_assignedPlayerId' : 'Connected')
        : 'Disconnected';

    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        height: 40,
        padding: EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: Pad.well, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.25), spreadRadius: 3)],
            ),
          ),
          SizedBox(width: 8),
          Text(statusText, style: TextStyle(color: Pad.ink, fontSize: 13, fontWeight: FontWeight.w700)),
          if (_serverSupportsEnhanced && _isConnected) ...[
            SizedBox(width: 4),
            Icon(Icons.flash_on_rounded, size: 14, color: Pad.y),
          ],
          SizedBox(width: 8),
          Text('$_inputRate/s', style: TextStyle(color: Pad.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ),
      SizedBox(width: 8),
      Semantics(
        button: true,
        label: 'Disconnect',
        child: Material(
          color: Pad.well,
          shape: CircleBorder(),
          child: InkWell(
            customBorder: CircleBorder(),
            onTap: _backToSetup,
            child: SizedBox(width: 48, height: 48, child: Icon(Icons.logout_rounded, color: Pad.muted, size: 22)),
          ),
        ),
      ),
    ]);
  }

  Widget _systemGrid() {
    Widget sys(String label, IconData icon, String caption) => PadKey(
          label: caption,
          width: 52,
          height: 52,
          radius: BorderRadius.circular(26),
          active: _buttonStates[label] == true,
          onDown: () {
            HapticFeedback.lightImpact();
            _cricketTap(label);
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20),
            Text(caption, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600)),
          ]),
        );
    return SizedBox(
      width: 52 * 2 + 12,
      child: Wrap(spacing: 12, runSpacing: 12, children: [
        sys('VIEW', Icons.filter_none_rounded, 'View'),
        sys('MENU', Icons.menu_rounded, 'Menu'),
        sys('PAUSE', Icons.pause_rounded, 'Pause'),
        sys('BACK', Icons.undo_rounded, 'Back'),
      ]),
    );
  }

  Widget _buildCanvas() {
    const reach = PadStick.reach;
    return Stack(children: [
      // Thumb-side controls. RTL directionality mirrors them for left-handed play.
      Positioned.fill(
        child: Directionality(
          textDirection: widget.leftHanded ? TextDirection.rtl : TextDirection.ltr,
          child: Stack(children: [
            PositionedDirectional(start: _edgeX, top: 14, child: _trigger('LT')),
            PositionedDirectional(start: _edgeX + 124, top: 20,
                child: _holdKey('LB', width: 84, height: 48, radius: BorderRadius.circular(24))),
            PositionedDirectional(end: _edgeX + 124, top: 20,
                child: _holdKey('RB', width: 84, height: 48, radius: BorderRadius.circular(24))),
            PositionedDirectional(end: _edgeX, top: 14, child: _trigger('RT')),
            PositionedDirectional(
              start: _edgeX + 12 - reach,
              bottom: _edgeBottom + 6 - reach,
              child: PadStick(size: 150, label: 'Move', onMove: (x, y) => _sendJoystick('left', x, y)),
            ),
            PositionedDirectional(start: 190, top: 84, child: _dpad()),
            PositionedDirectional(
              end: 216 - reach,
              top: 96 - reach,
              child: PadStick(size: 112, label: 'Camera', onMove: (x, y) => _sendJoystick('right', x, y)),
            ),
            PositionedDirectional(end: _edgeX, bottom: _edgeBottom, child: _faceButtons()),
          ]),
        ),
      ),
      // Centre column is never mirrored.
      Positioned(top: 18, left: 0, right: 0, child: Center(child: _hud())),
      Positioned(top: 112, left: 0, right: 0, child: Center(child: _systemGrid())),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pad.bgBottom,
      body: Container(
        constraints: BoxConstraints.expand(),
        decoration: Pad.background,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            // Scale the canvas to fit; it widens on wider screens so edge-anchored
            // controls stay at the edges.
            final scale = math.min(c.maxWidth / _canvasW, c.maxHeight / _canvasH);
            return SizedBox.expand(
              child: FittedBox(
                child: SizedBox(
                  width: c.maxWidth / scale,
                  height: c.maxHeight / scale,
                  child: _buildCanvas(),
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
    print('Disposing Cricket 24 gamepad...');

    // Cancel all timers
    _heartbeatTimer?.cancel();
    _udp?.close();
    _connectionMonitor?.cancel();
    _rateTimer?.cancel();
    _appealTicker?.cancel();

    // Cancel all button timers
    for (final timer in _buttonTimers.values) {
      timer.cancel();
    }
    _buttonTimers.clear();

    // Clean up button states
    _buttonStates.clear();
    _physicallyPressed.clear();
    _lastButtonPress.clear();
    _lastButtonRelease.clear();
    _triggerStates.clear();

    // Close socket subscription
    _socketSubscription?.cancel();

    // Send Cricket 24 disconnect message
    try {
      if (_socketReady && _isConnected) {
        final sessionStats = {
          'duration_seconds': DateTime.now().difference(_sessionStart).inSeconds,
          'messages_sent': _messagesSent,
          'messages_received': _messagesReceived,
        };

        _sendCricketMessage({
          'type': 'cricket_disconnect',
          'player': playerId,
          'session_stats': sessionStats,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });

        // Give time for disconnect message to send
        Future.delayed(Duration(milliseconds: 100), () {
          try {
            _socket.close();
          } catch (e) {
            print('Cricket socket close error: $e');
          }
        });
      }
    } catch (e) {
      print('Cricket disconnect message error: $e');
      try {
        _socket.close();
      } catch (e2) {
        print('Cricket socket force close error: $e2');
      }
    }
    print('Cricket 24 gamepad disposed');
    super.dispose();
  }
}

/// A raised key that sinks while a finger is on it. Uses raw pointer events so a
/// press registers instantly and a thumb sliding slightly doesn't cancel it.
class PadKey extends StatefulWidget {
  final String label;
  final double? width;
  final double height;
  final BorderRadius radius;
  final VoidCallback onDown;
  final VoidCallback? onUp;
  final Widget child;
  final bool active; // pressed state reported by the game logic (e.g. a tap flash)
  final bool coolingDown;
  final bool dimWhenCooling;
  final Color color; // text/icon colour at rest
  final Color activeFill;
  final Color? idleFill; // null = the standard graphite key
  final Color? idleShadow;

  const PadKey({
    super.key,
    required this.label,
    this.width,
    required this.height,
    required this.radius,
    required this.onDown,
    this.onUp,
    required this.child,
    this.active = false,
    this.coolingDown = false,
    this.dimWhenCooling = true,
    this.color = Pad.ink,
    this.activeFill = Pad.ink,
    this.idleFill,
    this.idleShadow = Pad.keyShadow,
  });

  @override
  State<PadKey> createState() => _PadKeyState();
}

class _PadKeyState extends State<PadKey> {
  int? _pointer;

  bool get _down => _pointer != null || widget.active;

  void _end(PointerEvent e) {
    if (e.pointer != _pointer) return;
    setState(() => _pointer = null);
    widget.onUp?.call();
  }

  @override
  Widget build(BuildContext context) {
    final down = _down;
    final content = down ? Pad.well : widget.color;

    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        onPointerDown: (e) {
          if (_pointer != null) return;
          setState(() => _pointer = e.pointer);
          widget.onDown();
        },
        onPointerUp: _end,
        onPointerCancel: _end,
        child: Opacity(
          opacity: widget.dimWhenCooling && widget.coolingDown && !down ? 0.5 : 1,
          child: Container(
            width: widget.width,
            height: widget.height,
            transform: Matrix4.translationValues(0, down ? 3 : 0, 0),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: widget.radius,
              color: down ? widget.activeFill : widget.idleFill,
              gradient: down || widget.idleFill != null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Pad.keyTop, Pad.keyBottom],
                    ),
              boxShadow: down || widget.idleShadow == null
                  ? null
                  : [BoxShadow(color: widget.idleShadow!, offset: Offset(0, 3))],
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: content),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: content, fontWeight: FontWeight.w800),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Analog stick that follows the thumb anywhere inside a circle [reach] dp wider
/// than its visible ring. Reports x/y in -1..1 (y is positive downwards).
class PadStick extends StatefulWidget {
  static const double reach = 28;

  final double size;
  final String label;
  final void Function(double x, double y) onMove;

  const PadStick({super.key, required this.size, required this.label, required this.onMove});

  @override
  State<PadStick> createState() => _PadStickState();
}

class _PadStickState extends State<PadStick> {
  int? _pointer;
  Offset _knob = Offset.zero;

  double get _max => widget.size * 0.3;

  void _update(Offset local) {
    final center = Offset(widget.size / 2 + PadStick.reach, widget.size / 2 + PadStick.reach);
    var d = local - center;
    if (d.distance > _max) d = d / d.distance * _max;
    setState(() => _knob = d);
    widget.onMove(d.dx / _max, d.dy / _max);
  }

  void _end(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    setState(() => _knob = Offset.zero);
    widget.onMove(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final outer = widget.size + PadStick.reach * 2;
    final knob = widget.size * 0.4;
    final active = _pointer != null;

    return Semantics(
      label: '${widget.label} stick',
      child: ClipOval(
        // ClipOval also clips hit-testing, so the touch area is round, not square.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (_pointer != null) return;
            _pointer = e.pointer;
            _update(e.localPosition);
          },
          onPointerMove: (e) {
            if (e.pointer == _pointer) _update(e.localPosition);
          },
          onPointerUp: _end,
          onPointerCancel: _end,
          child: SizedBox(
            width: outer,
            height: outer,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Pad.well, Color(0xFF141619)], stops: [0.75, 1]),
                ),
              ),
              Transform.translate(
                offset: _knob,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: Alignment(0, -0.2),
                      colors: active ? [Colors.white, Color(0xFFCFD3D8)] : [Color(0xFF59606A), Color(0xFF3A3F45)],
                    ),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 8, offset: Offset(0, 4))],
                  ),
                ),
              ),
              Positioned(
                top: PadStick.reach + widget.size + 4,
                child: Text(widget.label, style: TextStyle(color: Pad.muted, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
