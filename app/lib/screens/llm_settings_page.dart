import 'package:flutter/material.dart';

import '../services/llm_normalizer.dart';
import '../services/prefs.dart';
import '../theme.dart';

/// 大模型配置：OpenAI 兼容端点 + key + 模型名。
/// key 只写到本机 SharedPreferences，不上传、不进仓库。
class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key});

  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  final baseCtrl = TextEditingController(text: 'https://api.deepseek.com');
  final keyCtrl = TextEditingController();
  final modelCtrl = TextEditingController(text: 'deepseek-chat');
  bool obscure = true;
  bool busy = false;
  String? testResult;

  @override
  void initState() {
    super.initState();
    Prefs.loadLlm().then((cfg) {
      if (!mounted) return;
      setState(() {
        baseCtrl.text = cfg['baseUrl'] ?? 'https://api.deepseek.com';
        keyCtrl.text = cfg['apiKey'] ?? '';
        modelCtrl.text = cfg['model'] ?? 'deepseek-chat';
      });
    });
  }

  @override
  void dispose() {
    baseCtrl.dispose();
    keyCtrl.dispose();
    modelCtrl.dispose();
    super.dispose();
  }

  LlmConfig get _config => LlmConfig(
        baseUrl: baseCtrl.text.trim().isEmpty ? 'https://api.deepseek.com' : baseCtrl.text.trim(),
        apiKey: keyCtrl.text.trim(),
        model: modelCtrl.text.trim().isEmpty ? 'deepseek-chat' : modelCtrl.text.trim(),
      );

  Future<void> _save() async {
    await Prefs.saveLlm(
      baseUrl: _config.baseUrl,
      apiKey: _config.apiKey,
      model: _config.model,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存到本机')));
    Navigator.of(context).pop(true);
  }

  Future<void> _test() async {
    setState(() {
      busy = true;
      testResult = null;
    });
    final result = await LlmNormalizer.test(_config);
    if (!mounted) return;
    setState(() {
      busy = false;
      testResult = result == 'ok' ? '连接正常，模型能按格式返回' : '失败：$result';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('大模型解析'),
        actions: [
          TextButton(onPressed: busy ? null : _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            'B 站动态会先交给大模型，转成规范事件（游戏 / 版本 / 类型 / 起止时间 / 标签）再入日历。'
            '没有配置就不会解析，也不会猜时间。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('API 地址', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: baseCtrl,
            decoration: const InputDecoration(hintText: 'https://api.deepseek.com'),
          ),
          const SizedBox(height: 14),
          Text('模型名', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: modelCtrl,
            decoration: const InputDecoration(hintText: 'deepseek-chat'),
          ),
          const SizedBox(height: 14),
          Text('API Key', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: keyCtrl,
            obscureText: obscure,
            decoration: InputDecoration(
              hintText: 'sk-…',
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => obscure = !obscure),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '只保存在本机应用私有目录，不会上传到任何服务器；换设备或清数据后需重新填写。',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : _test,
                  style: OutlinedButton.styleFrom(
                    shape: AppShapes.pill,
                    side: BorderSide.none,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(busy ? '测试中…' : '测试连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : _save,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
          if (testResult != null) ...[
            const SizedBox(height: 12),
            Text(testResult!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
