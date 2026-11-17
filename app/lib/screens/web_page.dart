import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 应用内打开一个网页（看视频/看公告原文用）
class WebPageScreen extends StatefulWidget {
  const WebPageScreen({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<WebPageScreen> createState() => _WebPageScreenState();
}

class _WebPageScreenState extends State<WebPageScreen> {
  late final WebViewController controller;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(child: WebViewWidget(controller: controller)),
    );
  }
}
