import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where one control group sits on the controller canvas: its centre as a fraction
/// of the canvas width and height, a size multiplier, and whether it is shown.
class ControlPos {
  double x, y, scale;
  bool visible;
  ControlPos(this.x, this.y, {this.scale = 1, this.visible = true});

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'scale': scale, 'visible': visible};

  factory ControlPos.fromJson(Map<String, dynamic> j) => ControlPos(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        scale: (j['scale'] as num?)?.toDouble() ?? 1,
        visible: j['visible'] as bool? ?? true,
      );
}

/// The user's controller layout, saved on the phone.
class PadLayout {
  static const _key = 'pad_layout_v1';
  static const minScale = 0.6, maxScale = 1.5;

  /// Factory layout: centres measured on the original 824 x 370 canvas.
  static Map<String, ControlPos> defaults() {
    ControlPos at(double x, double y) => ControlPos(x / 824, y / 370);
    return {
      'LT': at(80, 42),
      'LB': at(190, 44),
      'RB': at(634, 44),
      'RT': at(744, 42),
      'LS': at(111, 273),
      'DPAD': at(262, 156),
      'RS': at(552, 152),
      'FACE': at(706, 265),
      'SYS': at(412, 170),
    };
  }

  static Future<Map<String, ControlPos>> load() async {
    final layout = defaults();
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((id, j) {
          if (layout.containsKey(id)) layout[id] = ControlPos.fromJson(j as Map<String, dynamic>);
        });
      }
    } catch (_) {
      // corrupt or missing: fall back to the factory layout
    }
    return layout;
  }

  static Future<void> save(Map<String, ControlPos> layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(layout.map((id, p) => MapEntry(id, p.toJson()))));
  }
}
