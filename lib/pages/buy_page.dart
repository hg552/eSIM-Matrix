import 'package:flutter/material.dart';
import 'web_browser_page.dart';

class BuyPage extends StatelessWidget {
  final String url;
  final String title;

  const BuyPage({
    super.key,
    this.url = 'https://9es.im/',
    this.title = '9eSIM Store',
  });

  @override
  Widget build(BuildContext context) {
    return WebBrowserPage(initialUrl: url, title: title);
  }
}
