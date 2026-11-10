import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';

class EnhanceSettings {
  static const _keyServerUrl = 'enhance_server_url';

  Future<String> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyServerUrl)?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    return AiConfig.defaultEnhanceServerUrl.trim();
  }

  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, url.trim());
  }
}
