/// 设备长连接状态机（`GET /api/v1/devices/ws`，JSON Lines 协议）。
///
/// 本文件只做「连接生命周期」，不含 UI、不含业务语义：
/// - 握手：连上 → 发 `hello` → 等 `welcome` → 用 `welcome.heartbeat_s * 0.8` 起心跳
/// - 心跳：周期发 `ping`（`load` 可空）
/// - 退避：1s→2s→4s→8s→30s 封顶，±20% 抖动，**连续 5 次后转 dead**
/// - 帧级错误：按 `ErrorPayload.action` 分派（决策表见 `envelope.dart` 的 `WsFatalAction`）
///
/// 铁律：
/// 1. 心跳间隔**只能**取 [WelcomePayload.heartbeatInterval]，绝不硬编码 15s
///    （15s 只是服务端默认值；`protocol.go:200-209`）。收到 `welcome` 前用
///   [fallbackHeartbeat] 兜底，避免「服务端不回 welcome」时连接被判定离线。
/// 2. 令牌只出现在 URI / 请求头，日志一律走 `maskToken`（红线 R3）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../protocol/envelope.dart';
import '../../protocol/frame_payloads.dart';
import '../local/secure_store.dart' show maskToken;
import 'device_connection.dart';

/// 连接状态。
enum DeviceWsState {
  /// 未启动 / 被用户主动停止。
  disconnected,

  /// 正在建立 TCP/WS 连接。
  connecting,

  /// 已连上，已发 `hello`，等待 `welcome`。
  handshaking,

  /// 握手完成，心跳运行中（唯一「可用」状态）。
  live,

  /// 退避等待中（等待 [DeviceWsClient.retryCount] 次重连）。
  reconnecting,

  /// 终止：不再自动重连，等用户手动（[DeviceWsClient.reconnectNow]）。
  dead,
}

/// 转入 [DeviceWsState.dead] 的原因（供 UI 决定提示文案与后续动作）。
enum DeviceWsDeadReason {
  /// 退避重连次数耗尽。
  maxRetriesExceeded,

  /// `device.protocol_mismatch`：必须升级 App。
  upgradeRequired,

  /// `device.revoked`：令牌失效，需清令牌回配对页。
  repairPairing,

  /// `device.replaced`：本设备已在其他实例上线。
  replacedElsewhere,
}

/// 设备 WS 状态机。
class DeviceWsClient {
  DeviceWsClient({
    required DeviceConnectionFactory connectionFactory,
    required Uri baseUrl,
    String? deviceToken,
    DeviceTokenPlacement tokenPlacement = DeviceTokenPlacement.query,
    HelloPayload? hello,
    Map<String, dynamic> Function()? loadProvider,
    Duration fallbackHeartbeat = const Duration(seconds: 15),
    Duration handshakeTimeout = const Duration(seconds: 20),
    List<Duration>? backoffSchedule,
    int maxRetries = 5,
    double jitterRatio = 0.2,
    Random? random,
    void Function(String message)? onLog,
  })  : _connectionFactory = connectionFactory,
        _endpoint = deviceWsUri(
          baseUrl: baseUrl,
          deviceToken: deviceToken,
          placement: tokenPlacement,
        ),
        _maskedEndpoint = _maskEndpoint(baseUrl, deviceToken, tokenPlacement),
        _hello = hello,
        _loadProvider = loadProvider,
        _fallbackHeartbeat = fallbackHeartbeat,
        _handshakeTimeout = handshakeTimeout,
        _schedule = backoffSchedule ?? defaultBackoffSchedule,
        _maxRetries = maxRetries,
        _jitterRatio = jitterRatio,
        _random = random ?? Random(),
        _onLog = onLog {
    _stateController = StreamController<DeviceWsState>.broadcast();
    _frameController = StreamController<Envelope>.broadcast();
    _leaseController = StreamController<LeaseRevokedPayload>.broadcast();
  }

  /// 默认退避序列：1s→2s→4s→8s→30s（之后封顶 30s）。
  static const List<Duration> defaultBackoffSchedule = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 30),
  ];

  final DeviceConnectionFactory _connectionFactory;
  final Uri _endpoint;
  final String _maskedEndpoint;
  final HelloPayload? _hello;
  final Map<String, dynamic> Function()? _loadProvider;
  final Duration _fallbackHeartbeat;
  final Duration _handshakeTimeout;
  final List<Duration> _schedule;
  final int _maxRetries;
  final double _jitterRatio;
  final Random _random;
  final void Function(String message)? _onLog;

  late final StreamController<DeviceWsState> _stateController;
  late final StreamController<Envelope> _frameController;
  late final StreamController<LeaseRevokedPayload> _leaseController;

  DeviceConnection? _conn;
  StreamSubscription<String>? _sub;
  Timer? _heartbeatTimer;
  Timer? _handshakeTimer;
  Timer? _retryTimer;

  /// 尝试代数：每次连接尝试自增，用于作废上一代连接的所有迟到回调。
  int _gen = 0;

  /// 已排队的重连次数（握手成功后清零）。
  int _retryCount = 0;

  DeviceWsState _state = DeviceWsState.disconnected;
  DeviceWsDeadReason? _deadReason;
  String? _lastFrameCode;
  WelcomePayload? _welcome;
  Duration? _heartbeatInterval;
  int _frameSeq = 0;
  bool _disposed = false;

  /// 当前状态。
  DeviceWsState get state => _state;

  /// 转 dead 的原因（非 dead 时为 null）。
  DeviceWsDeadReason? get deadReason => _deadReason;

  /// 最近一次收到的帧级错误码（`FrameCode`，观测用）。
  String? get lastFrameCode => _lastFrameCode;

  /// 当前生效的心跳间隔（收到 `welcome` 后为 `heartbeat_s * 0.8`）。
  Duration? get heartbeatInterval => _heartbeatInterval;

  /// 已排队的重连次数（0 表示当前连接未经历退避）。
  int get retryCount => _retryCount;

  /// 最近一次 `welcome` 负载。
  WelcomePayload? get welcome => _welcome;

  /// 连接目标（含 `?token=`，**禁止**直接打日志，用 [maskedEndpoint]）。
  Uri get endpoint => _endpoint;

  /// 可安全打日志的端点表示（令牌经 `maskToken` 打码）。
  String get maskedEndpoint => _maskedEndpoint;

  /// 状态流（广播）。
  Stream<DeviceWsState> get states => _stateController.stream;

  /// 业务帧流（广播）：`task.dispatch` / `task.progress` / `task.result` /
  /// `lease.revoked` / `error`。握手类帧（hello/welcome/ping/pong）不外发。
  Stream<Envelope> get frames => _frameController.stream;

  /// 租约被抢占通知流（供 UI 转只读）。
  Stream<LeaseRevokedPayload> get leaseRevocations => _leaseController.stream;

  /// 计算第 [retryIndex]（0 基）次重连的等待时长（含抖动）。
  Duration backoffFor(int retryIndex) {
    final base = _schedule[min(retryIndex, _schedule.length - 1)];
    if (_jitterRatio <= 0) return base;
    final factor = 1 + (_random.nextDouble() * 2 - 1) * _jitterRatio;
    final ms = (base.inMilliseconds * factor).round();
    return Duration(milliseconds: max(1, ms));
  }

  /// 启动连接（幂等：已在连接中/live 时直接返回）。
  Future<void> start() async {
    if (_disposed) return;
    if (_state == DeviceWsState.connecting ||
        _state == DeviceWsState.handshaking ||
        _state == DeviceWsState.live) {
      return;
    }
    _retryCount = 0;
    await _attempt();
  }

  /// 用户手动重连（dead 状态下调用，重置退避预算）。
  Future<void> reconnectNow() async {
    if (_disposed) return;
    _retryCount = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _attempt();
  }

  /// 用户主动停止（不触发重连）。
  Future<void> stop() async {
    _gen++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryCount = 0;
    _teardown();
    _setState(DeviceWsState.disconnected);
  }

  /// 释放资源（之后不可再用）。
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _stateController.close();
    await _frameController.close();
    await _leaseController.close();
  }

  // ============ 内部：连接尝试 ============

  Future<void> _attempt() async {
    if (_disposed) return;
    final gen = ++_gen;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(DeviceWsState.connecting);

    final DeviceConnection conn;
    try {
      conn = _connectionFactory(_endpoint);
    } catch (e) {
      _handleFailure(gen, cause: '创建连接失败 ${_safe(e)}');
      return;
    }
    _conn = conn;

    try {
      await conn.connect();
    } catch (e) {
      _handleFailure(gen, cause: '连接失败 ${_safe(e)}');
      return;
    }
    if (!_isCurrent(gen)) return;

    _sub = conn.stream.listen(
      (line) => _onLine(gen, line),
      onError: (Object e) => _handleFailure(gen, cause: '连接异常 ${_safe(e)}'),
      onDone: () => _handleFailure(gen, cause: '连接被对端关闭'),
      cancelOnError: false,
    );

    _sendHello();
    _setState(DeviceWsState.handshaking);
    _startHandshakeTimeout(gen);
    // welcome 之前的兜底心跳（welcome 到达后会被 heartbeatInterval 替换）
    _startHeartbeat(gen, _fallbackHeartbeat);
  }

  void _startHandshakeTimeout(int gen) {
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(_handshakeTimeout, () {
      if (!_isCurrent(gen) || _state != DeviceWsState.handshaking) return;
      _handleFailure(gen, cause: '握手超时（未收到 welcome）');
    });
  }

  void _startHeartbeat(int gen, Duration interval) {
    _heartbeatTimer?.cancel();
    _heartbeatInterval = interval;
    _heartbeatTimer = Timer.periodic(interval, (_) {
      if (!_isCurrent(gen)) return;
      _sendPing();
    });
  }

  // ============ 内部：入站 ============

  void _onLine(int gen, String line) {
    if (!_isCurrent(gen)) return;
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) {
        _log('丢弃非对象 JSON 行');
        return;
      }
      json = decoded;
    } catch (_) {
      _log('丢弃无法解析的 JSON 行');
      return;
    }

    final Envelope env;
    try {
      env = Envelope.fromJson(json);
    } catch (_) {
      _log('丢弃字段缺失的信封');
      return;
    }
    final invalid = env.validate();
    if (invalid != null) {
      _log('丢弃非法帧：$invalid');
      return;
    }
    _onEnvelope(gen, env);
  }

  void _onEnvelope(int gen, Envelope env) {
    switch (env.type) {
      case MessageType.welcome:
        _onWelcome(gen, env);
        return;
      case MessageType.error:
        _onErrorFrame(gen, env);
        return;
      case MessageType.leaseRevoked:
        _onLeaseRevoked(env);
        return;
      case MessageType.pong:
      case MessageType.hello:
      case MessageType.ping:
        // 握手/心跳类帧不外发（业务层不关心）
        return;
      default:
        _emitFrame(env);
    }
  }

  void _onWelcome(int gen, Envelope env) {
    if (!_isCurrent(gen)) return;
    final WelcomePayload payload;
    try {
      payload = WelcomePayload.fromJson(env.payload ?? const {});
    } catch (e) {
      _handleFailure(gen, cause: 'welcome 解析失败 ${_safe(e)}');
      return;
    }

    // 版本不兼容：服务端本应发 protocol_mismatch，端侧再兜一层，绝不静默降级。
    if (!ProtocolVersion.isCompatible(payload.protocolVersion)) {
      _lastFrameCode = FrameCode.protocolMismatch;
      _die(gen, DeviceWsDeadReason.upgradeRequired,
          cause: 'welcome.protocol_version=${payload.protocolVersion} 不兼容');
      return;
    }

    _welcome = payload;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    // 铁律：心跳间隔取 welcome.heartbeat_s * 0.8（heartbeatInterval getter）
    _startHeartbeat(gen, payload.heartbeatInterval);
    _retryCount = 0;
    _setState(DeviceWsState.live);
    _log('握手完成 device=${payload.deviceId} '
        'heartbeat=${payload.heartbeatInterval.inMilliseconds}ms '
        'offline_after=${payload.offlineAfterS}s');
  }

  void _onErrorFrame(int gen, Envelope env) {
    final ErrorPayload payload;
    try {
      payload = ErrorPayload.fromJson(env.payload ?? const {});
    } catch (_) {
      _log('丢弃无法解析的 error 帧');
      return;
    }
    _lastFrameCode = payload.code;

    switch (payload.action) {
      case WsFatalAction.ignore:
        // bad_frame / task_unsupported：丢弃该帧，**保持连接**
        _emitFrame(env);
        _log('忽略帧级错误 ${payload.code}（保持连接）');
        return;
      case WsFatalAction.reconnect:
        _emitFrame(env);
        _handleFailure(gen, cause: '帧级错误 ${payload.code}');
        return;
      case WsFatalAction.upgradeRequired:
        _emitFrame(env);
        _die(gen, DeviceWsDeadReason.upgradeRequired,
            cause: '帧级错误 ${payload.code}');
        return;
      case WsFatalAction.repairPairing:
        _emitFrame(env);
        _die(gen, DeviceWsDeadReason.repairPairing,
            cause: '帧级错误 ${payload.code}');
        return;
      case WsFatalAction.replacedElsewhere:
        _emitFrame(env);
        _die(gen, DeviceWsDeadReason.replacedElsewhere,
            cause: '帧级错误 ${payload.code}');
        return;
    }
  }

  void _onLeaseRevoked(Envelope env) {
    _emitFrame(env);
    try {
      final payload = LeaseRevokedPayload.fromJson(env.payload ?? const {});
      if (!_leaseController.isClosed) _leaseController.add(payload);
      _log('租约被抢占 session=${payload.sessionId} epoch=${payload.epoch}');
    } catch (_) {
      _log('丢弃无法解析的 lease.revoked 帧');
    }
  }

  // ============ 内部：出站 ============

  void _sendHello() {
    final payload = _hello ??
        const HelloPayload(protocolVersion: ProtocolVersion.current);
    _send(Envelope.withPayload(
      type: MessageType.hello,
      payload: payload.toJson(),
      id: _nextFrameId('hello'),
    ));
  }

  void _sendPing() {
    final payload = PingPayload(
      load: _loadProvider?.call(),
      protocolVersion: ProtocolVersion.current,
    );
    _send(Envelope.withPayload(
      type: MessageType.ping,
      payload: payload.toJson(),
      id: _nextFrameId('ping'),
    ));
  }

  void _send(Envelope env) {
    final conn = _conn;
    if (conn == null) return;
    try {
      conn.send(jsonEncode(env.toJson()));
    } catch (e) {
      _log('发送 ${env.type} 失败 ${_safe(e)}');
    }
  }

  String _nextFrameId(String prefix) => '$prefix-${++_frameSeq}';

  // ============ 内部：失败与终止 ============

  /// 连接失败统一入口（同步推进状态，清理异步分离）。
  ///
  /// ⚠️ 必须是同步的：状态迁移若挂在 `await teardown()` 之后，微任务链一断
  /// （fake_async 下尤其明显）状态就会永远停在旧值。
  void _handleFailure(int gen, {String? cause}) {
    if (!_isCurrent(gen)) return;
    _gen++; // 作废本代连接的所有迟到回调
    if (cause != null) _log(cause);
    _teardown();

    if (_retryCount >= _maxRetries) {
      _setState(DeviceWsState.dead,
          reason: DeviceWsDeadReason.maxRetriesExceeded);
      _log('重连次数已达上限 $_maxRetries，转 dead');
      return;
    }

    final delay = backoffFor(_retryCount);
    _retryCount++;
    _setState(DeviceWsState.reconnecting);
    _log('第 $_retryCount/$_maxRetries 次重连将在 ${delay.inMilliseconds}ms 后开始');
    _retryTimer = Timer(delay, () {
      unawaited(_attempt());
    });
  }

  /// 终止连接（不再自动重连）。
  void _die(int gen, DeviceWsDeadReason reason, {String? cause}) {
    if (!_isCurrent(gen)) return;
    _gen++;
    if (cause != null) _log(cause);
    _teardown();
    _setState(DeviceWsState.dead, reason: reason);
  }

  /// 拆解当前连接（同步取消定时器 + 分离式关闭，不阻塞状态推进）。
  void _teardown() {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      unawaited(
        conn.close().catchError((Object _) {
          // 关闭失败不影响状态推进
        }),
      );
    }
  }

  // ============ 内部：工具 ============

  bool _isCurrent(int gen) => !_disposed && gen == _gen;

  void _setState(DeviceWsState next, {DeviceWsDeadReason? reason}) {
    if (next != DeviceWsState.dead) reason = null;
    _deadReason = next == DeviceWsState.dead ? (reason ?? _deadReason) : null;
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _emitFrame(Envelope env) {
    if (!_frameController.isClosed) _frameController.add(env);
  }

  void _log(String message) => _onLog?.call('[device_ws] $message');

  /// 异常文案可能含 URL/令牌，做一次保守打码。
  String _safe(Object error) {
    final text = error.toString();
    final token = _endpoint.queryParameters['token'];
    if (token == null || token.isEmpty) return text;
    return text.replaceAll(token, maskToken(token));
  }

  static String _maskEndpoint(
    Uri baseUrl,
    String? deviceToken,
    DeviceTokenPlacement placement,
  ) {
    final masked = placement == DeviceTokenPlacement.query && deviceToken != null
        ? maskToken(deviceToken)
        : '<header>';
    final scheme = baseUrl.scheme == 'https' ? 'wss' : 'ws';
    final path = joinUrlPath(baseUrl.path, deviceWsPath);
    return placement == DeviceTokenPlacement.query
        ? '$scheme://${baseUrl.authority}$path?token=$masked'
        : '$scheme://${baseUrl.authority}$path (Authorization: Bearer $masked)';
  }
}
