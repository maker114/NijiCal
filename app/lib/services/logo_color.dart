import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从官号头像里取一个能当标识色用的颜色。
///
/// 做法：缩略采样 → 跳过近白近黑与透明像素 → 求平均 → 拉到中等饱和/亮度，
/// 免得直接拿平均色得到一个发灰的颜色。
Future<Color?> dominantColorOf(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;

    final pixels = data.buffer.asUint8List();
    final total = image.width * image.height;
    if (total == 0) return null;
    // 最多采 2000 个点，够用且不卡
    final step = ((total / 2000).ceil() * 4).clamp(4, 1 << 20);

    var r = 0, g = 0, b = 0, n = 0;
    for (var i = 0; i + 3 < pixels.length; i += step) {
      if (pixels[i + 3] < 128) continue;
      final pr = pixels[i], pg = pixels[i + 1], pb = pixels[i + 2];
      final maxV = pr > pg ? (pr > pb ? pr : pb) : (pg > pb ? pg : pb);
      final minV = pr < pg ? (pr < pb ? pr : pb) : (pg < pb ? pg : pb);
      if (maxV > 240 && minV > 240) continue; // 近白
      if (maxV < 26) continue; // 近黑
      r += pr;
      g += pg;
      b += pb;
      n++;
    }
    if (n == 0) return null;

    final avg = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
    final hsl = HSLColor.fromColor(avg);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.32, 0.6))
        .withLightness(hsl.lightness.clamp(0.4, 0.56))
        .toColor();
  } catch (_) {
    return null;
  }
}
