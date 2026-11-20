/// SSE 会话状态机（纯 Dart，零 Flutter 依赖，可在 `flutter test` 的 Dart VM 里全覆盖）。
///
/// # 与 `lib/data/ws/device_ws.dart` 的关系（刻意同构、刻意不同）
///
/// | 维度 | `DeviceWsClient`（设备长连接） | [SseSession]（事件流） |
/// | --- | --- | --- |
/// | 握手 | `hello` → `welcome`（有协议握手） | **无握手**，首帧 `snapshot` 即就绪 |
/// | 序号 / 续传 | 无（JSON Lines） | ①②③ 流均无 `id:` ⇒ **不可续传**，重连必重拿快照 |
/// | 终态 `dead` | ✅ 有（升级 / 重配 / 顶替 / 耗尽） | ❌ **刻意不设**（见下） |
/// | 退避 | 1→2→4→8→30s，耗尽转 dead | **同一序列**（共享 `backoff_policy.dart`），耗尽**落长退避继续自愈** |
///
/// ## 为什么 SSE 不设 `dead`（D3，勿「统一」掉）
/// `DeviceWsClient` 的 `dead` 存在，是因为设备连接有**真实业务终态**：
/// `device.protocol_mismatch` 要求用户升级 App、`device.revoked` 要求重新配对、
/// `device.replaced` 表示被别处顶替 —— 这几种状态下继续重连是纯浪费（只会持续 401）。
///
/// 而设备状态流 / 会话列表流**没有任何用户动作才能解除的终态**：
/// 它只是「服务端当前态」的镜像，断线唯一正确的反应就是**继续重试**。
/// 若照抄 `dead`，用户会在一次电梯断网后永久失去实时性，只能手动重启 App。
/// 故：退避序列耗尽后**落到封顶长退避（30s）继续重试**，只有 `close()` 才停。
///
/// ## 为什么 `open` 的判据是「首帧 snapshot 落地」而不是「TCP 已连」（D4）
/// SSE 没有握手帧，`connect()` 成功只代表 HTTP 头回来了 —— 服务端完全可能
/// （例如总线未装配而返回了 200 空流、或反代吞掉 body）一个事件都不发。
/// 若以 TCP 连接成功判 `open`，UI 会诚实地说「已连接」而界面永不更新，
/// 这正是 `connection_state_ui.dart` 文件头痛斥的那类谎报。
library;

import 'dart:async';

import 'backoff_policy.dart';
import 'sse_connection.dart';
import 'sse_event.dart';

/// SSE 会话状态。
enum SseState {
  /// 未启动 / 已关闭。
  idle,

  /// 正在建立连接（含重连的 connect 阶段）。
  connecting,

  /// 已收到首帧快照，流可用（唯一「可用」状态）。
  open,

  /// 断线，退避等待中。
  backoff,
}

/// SSE 会话：负责「连接 → 分帧 → 解析 → 逐事件回调」这一条流水线。
///
/// 状态机**不做领域归约**（那是 `device_state_state.dart` 的职责）：
/// 它只保证「帧被正确解析并按顺序交给 [onEvent]」，因此可以被所有域共享。
class SseSession {
  SseSession({
    required this.factory,
    required this.endpoint,
    Map<String, String>? headers,
    List<int>? backoffScheduleMs,
    double jitterRatio = defaultJitterRatio,
    this.onEvent,
    this.onStateChanged,
    this.onLog,
  })  : headers = headers ?? const <String, String>{},
        _backoffScheduleMs = backoffScheduleMs ?? defaultBackoffScheduleMs,
        _jitterRatio = jitterRatio;

  /// 连接工厂（测试注入假实现的关键接缝，同 `DeviceConnectionFactory` 范式）。
  final SseConnectionFactory factory;

  /// 连接目标（不含任何令牌）。
  final Uri endpoint;

  /// 附加请求头（`Authorization: Bearer <user_token>` 由上层组装）。
  ///
  /// 🔴 红线 R3：令牌只进请求头，绝不进 URL、绝不进日志。
  final Map<String, String> headers;

  /// 每解析出一帧就回调一次（畸形帧已在解析层被丢弃，这里只会收到好帧）。
  final void Function(SseEvent event)? onEvent;

  /// 状态跃迁回调（UI / 控制器据此刷新，**不保证**每次重连都回调）。
  final void Function(SseState state)? onStateChanged;

  /// 调试日志（令牌必经 `maskToken` 打码，本类不打印 headers）。
  final void Function(String message)? onLog;

  final List<int> _backoffScheduleMs;
  final double _jitterRatio;

  SseConnection? _connection;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;

  final SseFrameSplitter _splitter = SseFrameSplitter();

  SseState _state = SseState.idle;
  bool _closed = false;
  bool _connecting = false;
  bool _gotSnapshot = false;
  int _attempt = 0;

  /// 已重连次数（排查用，也是退避序列的索引来源）。
  int get attempt => _attempt;

  /// 当前状态。
  SseState get state => _state;

  /// 是否已收到首帧快照（= [SseState.open] 的唯一判据）。
  bool get hasSnapshot => _gotSnapshot;

  /// 启动（幂等：重复调用在已运行时直接返回）。
  Future<void> start() async {
    if (_closed || _state != SseState.idle) return;
    _attempt = 0;
    await _connectOnce();
  }

  /// 立即重连（供「回前台」等外部事件使用）。
  ///
  /// 语义与 [start] 不同：无论当前处于 `backoff`、`open` 还是 `idle`，
  /// 都先把旧连接彻底拆掉再建新连接 —— 因为回前台时旧连接**必然**已死
  /// （锁屏 → 系统回收 TCP），但状态机自己并不知道，它可能仍认为自己是 `open`。
  /// 这正是 `ws_lifecycle_bridge.dart` 文件头描述的同一个坑。
  Future<void> reconnectNow() async {
    if (_closed) return;
    _cancelRetryTimer();
    await _teardownConnection();
    _gotSnapshot = false;
    _attempt = 0;
    await _connectOnce();
  }

  /// 挂起（进后台：拆连接、停退避，省电且不留半死连接）。
  ///
  /// 幂等：重复调用无副作用。下次 [start] 或 [reconnectNow] 重新拉起。
  Future<void> suspend() async {
    if (_closed) return;
    _cancelRetryTimer();
    await _teardownConnection();
    _gotSnapshot = false;
    _attempt = 0;
    _setState(SseState.idle);
  }

  /// 终止：不再重连（幂等）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelRetryTimer();
    await _teardownConnection();
    _setState(SseState.idle);
  }

  // —— 内部实现 ——

  Future<void> _connectOnce() async {
    if (_closed || _connecting) return;
    _connecting = true;
    _setState(SseState.connecting);
    // 每次新建连接都清空分帧缓冲：旧连接的半帧绝不能被拼进新连接的帧里
    // （否则会产生一条「两个连接的字节粘在一起」的坏帧）。
    _splitter.reset();

    SseConnection? connection;
    try {
      connection = await factory(endpoint, headers);
      await connection.connect();
    } catch (error) {
      _connecting = false;
      try {
        await connection?.close();
      } catch (_) {
        // 关闭路径绝不上抛。
      }
      _log('建连失败：$error');
      _scheduleRetry();
      return;
    }

    _connection = connection;
    _connecting = false;

    _subscription = connection.stream.listen(
      _handleChunk,
      onError: (Object error) {
        _log('流异常：$error');
        // 不在这里 await：onError 是同步回调，异步清理走微任务。
        unawaited(_handleDisconnect());
      },
      onDone: () {
        // 服务端慢消费者策略会主动断开（`docs/protocols.md` §4.4 第 7 条），
        // 流正常 done 与异常在状态机里同等对待：都是断线，都走退避。
        unawaited(_handleDisconnect());
      },
      cancelOnError: true,
    );
  }

  void _handleChunk(String chunk) {
    if (_closed) return;
    for (final String frame in _splitter.add(chunk)) {
      final SseEvent? event = parseSseFrame(frame);
      // 畸形帧 / 心跳注释帧已在 parseSseFrame 里归为 null：静默跳过。
      if (event == null) continue;

      // 🔴 首帧快照是 `open` 的唯一判据（D4）。
      if (!_gotSnapshot) {
        _gotSnapshot = true;
        _attempt = 0;
        _setState(SseState.open);
      }

      // 单帧回调抛异常**绝不能**打断整条订阅（§4.4 第 3 条的精神）。
      try {
        onEvent?.call(event);
      } catch (error) {
        _log('事件回调异常（已隔离，不影响订阅）：$error');
      }
    }
  }

  Future<void> _handleDisconnect() async {
    if (_closed) return;
    await _teardownConnection();
    _gotSnapshot = false;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed) return;
    _cancelRetryTimer();
    final int delayMs = backoffDelayMs(
      _attempt,
      schedule: _backoffScheduleMs,
      jitterRatio: _jitterRatio,
    );
    _attempt++;
    _setState(SseState.backoff);
    if (isBeyondFastRetries(_attempt)) {
      _log('已重连 $_attempt 次，落长退避继续自愈（SSE 无业务终态，不设 dead）');
    }
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      _retryTimer = null;
      unawaited(_connectOnce());
    });
  }

  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _teardownConnection() async {
    final StreamSubscription<String>? subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // 取消订阅失败不影响后续重连。
    }
    final SseConnection? connection = _connection;
    _connection = null;
    try {
      await connection?.close();
    } catch (_) {
      // 关闭路径绝不上抛。
    }
  }

  void _setState(SseState next) {
    if (_state == next) return;
    _state = next;
    try {
      onStateChanged?.call(next);
    } catch (error) {
      _log('状态回调异常（已隔离）：$error');
    }
  }

  void _log(String message) => onLog?.call('[sse_session] $message');
}
