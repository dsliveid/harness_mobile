import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/config/base_url.dart';

/// baseUrl 归一化测试。
///
/// 重点防两类真实踩过的坑：
/// 1. `?#` 空尾巴：`uri.replace(query:'', fragment:'')` 会产出
///    `http://host?#`，导致 dio 拼 baseUrl 时路径错乱、服务端返回
///    纯文本 404、端侧报「非预期格式的错误响应」。
/// 2. 裸 host 补 scheme：局域网自建场景最常见输入。
void main() {
  group('基本归一化', () {
    test('裸 host 自动补 http:// 并加尾斜杠', () {
      expect(normalizeBaseUrl('127.0.0.1:5611'), 'http://127.0.0.1:5611/');
    });

    test('显式 http 保留', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:5611'),
        'http://127.0.0.1:5611/',
      );
    });

    test('https 保留', () {
      expect(
        normalizeBaseUrl('https://example.com'),
        'https://example.com/',
      );
    });

    test('去首尾空白', () {
      expect(normalizeBaseUrl('  http://a.com  '), 'http://a.com/');
    });
  });

  group('?# 空尾巴陷阱（回归防护）', () {
    test('不带路径的纯 host 不产生 ?# 尾巴', () {
      final out = normalizeBaseUrl('http://127.0.0.1:5611');
      expect(out.contains('?'), isFalse, reason: '不得出现 ? 尾巴');
      expect(out.contains('#'), isFalse, reason: '不得出现 # 尾巴');
      expect(out, 'http://127.0.0.1:5611/');
    });

    test('带尾斜杠输入也不产生双斜杠或尾巴', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:5611/'),
        'http://127.0.0.1:5611/',
      );
    });
  });

  group('子路径支持', () {
    test('保留路径前缀并归一为尾斜杠', () {
      expect(
        normalizeBaseUrl('https://host/harness'),
        'https://host/harness/',
      );
    });

    test('丢弃 query 与 fragment', () {
      expect(
        normalizeBaseUrl('http://a.com/path?x=1#frag'),
        'http://a.com/path/',
      );
    });
  });

  group('非法输入', () {
    test('空串返回空串', () {
      expect(normalizeBaseUrl(''), '');
      expect(normalizeBaseUrl('   '), '');
    });

    test('非法 scheme 返回空串', () {
      expect(normalizeBaseUrl('ftp://a.com'), '');
      expect(normalizeBaseUrl('ws://a.com'), '');
    });

    test('无 host 返回空串', () {
      expect(normalizeBaseUrl('http://'), '');
    });
  });
}
