import 'package:flutter/foundation.dart';

import 'services/prefs.dart';
import 'theme.dart';

/// 只负责“当前用哪套主题色”，单独拎出来避免改主题时把整个 AppState 一起重建。
class ThemeController extends ChangeNotifier {
  String accentId = defaultAccentId;

  Future<void> restore() async {
    final saved = await Prefs.loadAccentId();
    if (saved != null && accentPresets.any((p) => p.id == saved)) {
      accentId = saved;
      notifyListeners();
    }
  }

  void select(String id) {
    if (id == accentId) return;
    accentId = id;
    Prefs.saveAccentId(id);
    notifyListeners();
  }
}
