import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/config/base_url.dart';

/// `--dart-define=BASE_URL=...` 注入语义测试。
///
/// 背景：脚本 `run.sh --server-url` 把地址通过 `--dart-define=BASE_URL=...`
/// 编进运行期。本文件锁死 [resolveStartupBaseUrl] 的四类语义，防止后续改动
/// 把「调试注入」变成「永久污染用户配置」。
///
/// 为什么这些断言重要：
/// 1. 注入必须**优先于**本地存储——否则脚本参数形同虚设；
/// 2. 注入非法时必须**回落**本地存储——不能因为一个坏参数把 App 卡在 setup 页；
/// 3. 未注入（正常发布包）时行为必须与加此特性**之前逐字节一致**；
/// 4. 注入值也要归一化——避免 `?#` 空尾巴等历史坑从新入口重新溜进来。
void main() {
  group('注入优先于本地存储', () {
    test('两者都合法时取注入值', () {
      expect(
        resolveStartupBaseUrl(
          saved: 'http://127.0.0.1:5611',
          injected: 'http://192.168.1.10:5611',
        ),
        'http://192.168.1.10:5611/',
      );
    });

    test('本地为空、注入合法 → 取注入值（首次运行免手填）', () {
      expect(
        resolveStartupBaseUrl(
          saved: '',
          injected: 'http://10.0.2.2:5611',
        ),
        'http://10.0.2.2:5611/',
      );
    });

    test('注入值也走归一化：裸 host 自动补 scheme 并加尾斜杠', () {
      expect(
        resolveStartupBaseUrl(saved: '', injected: 'localhost:5611'),
        'http://localhost:5611/',
      );
    });

    test('注入值带尾斜杠/首尾空白时归一化干净（不产生 ?# 尾巴）', () {
      final out = resolveStartupBaseUrl(
        saved: '',
        injected: '  http://a.com:8080/  ',
      );
      expect(out, 'http://a.com:8080/');
      expect(out.contains('?'), isFalse, reason: '不得出现 ? 尾巴');
      expect(out.contains('#'), isFalse, reason: '不得出现 # 尾巴');
    });

    test('注入 https 保留 scheme', () {
      expect(
        resolveStartupBaseUrl(saved: '', injected: 'https://example.com'),
        'https://example.com/',
      );
    });

    test('注入值保留子路径前缀（服务端可挂在子路径）', () {
      expect(
        resolveStartupBaseUrl(
          saved: '',
          injected: 'https://host/harness',
        ),
        'https://host/harness/',
      );
    });
  });

  group('非法注入回落本地存储（不能把 App 卡在 setup 页）', () {
    test('注入 scheme 非法（ftp）→ 回落 saved', () {
      expect(
        resolveStartupBaseUrl(
          saved: 'http://127.0.0.1:5611',
          injected: 'ftp://a.com',
        ),
        'http://127.0.0.1:5611/',
      );
    });

    test('注入无 host（http://）→ 回落 saved', () {
      expect(
        resolveStartupBaseUrl(
          saved: 'http://127.0.0.1:5611',
          injected: 'http://',
        ),
        'http://127.0.0.1:5611/',
      );
    });

    test('注入纯空白 → 回落 saved', () {
      expect(
        resolveStartupBaseUrl(
          saved: 'http://127.0.0.1:5611',
          injected: '   ',
        ),
        'http://127.0.0.1:5611/',
      );
    });

    test('注入非法且本地也为空 → 空串（进入 setup 页，符合预期）', () {
      expect(
        resolveStartupBaseUrl(saved: '', injected: 'ftp://a.com'),
        '',
      );
    });

    test('注入非法时本地值仍被归一化', () {
      expect(
        resolveStartupBaseUrl(
          saved: ' 127.0.0.1:5611 ',
          injected: 'nonsense://x',
        ),
        'http://127.0.0.1:5611/',
      );
    });
  });

  group('未注入时与旧行为逐字节一致（发布包默认形态）', () {
    test('两者都空 → 空串', () {
      expect(resolveStartupBaseUrl(saved: '', injected: ''), '');
    });

    test('注入空 → 等价于直接 normalizeBaseUrl(saved)', () {
      const saved = 'http://127.0.0.1:5611';
      expect(
        resolveStartupBaseUrl(saved: saved, injected: ''),
        normalizeBaseUrl(saved),
      );
    });

    test('注入空 + 本地非法 → 空串（与旧行为一致）', () {
      expect(
        resolveStartupBaseUrl(saved: 'ftp://a.com', injected: ''),
        '',
      );
    });

    test('测试环境未传 --dart-define 时 kInjectedBaseUrl 必须是空串', () {
      // 这条断言保护「默认不注入」这个前提：若哪天有人给它加了非空默认值，
      // 所有发布包都会忽略用户自己配置的地址，且极难排查。
      expect(kInjectedBaseUrl, isEmpty);
    });
  });
}
