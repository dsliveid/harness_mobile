/// SSE 帧解析（纯函数，零 IO / 零 Flutter 依赖）。
///
/// # 为什么手写而不引三方库
/// Dart 侧**没有**浏览器原生 `EventSource`（那是 Web 平台 API），
/// 而 `text/event-stream` 的语法只有寥寥几条规则，自己实现反而是
/// 最可控的做法：可以针对服务端的**实际帧形态**逐条固化断言，
/// 而不必迁就某个库的内部实现细节。
///
/// # 本解析器必须正确处理的四条真实形态（缺一即产生「幽灵断连」）
///
/// 1. 🔴 **心跳注释行 `: ping`**
///    服务端每 15s 写一帧 `: ping\n\n`（`internal/api/session_events_handler.go:132`
///    与设备状态流共用同一写帧口径）。SSE 规范中以 `:` 开头的行是**注释**，
///    必须整行丢弃。若把它当「畸形帧」处理（例如解析失败即断连），
///    会在**完全健康的连接上**每 15s 自杀一次，表现为「界面每 15 秒闪一下」。
///
/// 2. 🔴 **多行 `data:` 必须用 `\n` 拼接**
///    规范规定同一帧内多条 `data:` 行以换行连接为完整载荷。服务端当前是单行，
///    但反代/网关重写、未来 JSON 美化都可能引入多行；只取最后一行会得到
///    残缺 JSON —— 单行场景下拼不拼接结果相同，故这里按规范实现零成本。
///
/// 3. 🔴 **`\r\n` 与 `\n` 必须都支持**
///    同一份代码要跑 Android / iOS / Windows(WebView 宿主)，不同平台与代理的
///    换行口径并不一致。只 `split('\n')` 会在行尾留下 `\r`，
///    使 `event` 字段变成 `"snapshot\r"` —— 归类到「未知事件」被静默丢弃，
///    表现为「连上了但界面永远不更新」。
///
/// 4. 🔴 **坏 JSON 必须返回 null 而不是抛异常**
///    `docs/protocols.md` §4.4 第 3 条：畸形帧必须静默跳过，
///    绝不能让一条坏帧使整个订阅崩溃（否则界面从此不再更新，用户只能手动刷新）。
///    因此**数据解析失败与语法解析失败都归为 null**，由上层跳过。
///
/// # 与 `envelope.dart` 的关系
/// `lib/protocol/envelope.dart` 解析的是**设备 WS 的 JSON Lines** 帧（一行一 JSON，
/// 有 `hello`/`welcome`/`ping` 的严格握手）。SSE 是另一套传输（`event:`/`data:` 分段、
/// 无握手、无序号），**严禁复用**，否则会把两套重连/握手语义搅在一起。
library;

import 'dart:convert';

/// 一条已解析的 SSE 事件。
///
/// 不可变值对象：便于测试做**整体相等断言**（任何字段被顺手改动都会立刻红灯，
/// 与 `features/shared/connection_state_ui.dart` 的 `ConnectionStateVisual` 同一手法）。
class SseEvent {
  const SseEvent({
    required this.event,
    required this.data,
    this.id,
  });

  /// 事件名（`event:` 行）。缺省时按 SSE 规范为 `"message"`。
  ///
  /// 服务端实际取值：`snapshot` / `device.online` / `device.offline` /
  /// `device.revoked`（见 `internal/device/state_bus.go:69-81`）。
  final String event;

  /// 已解析的 JSON 载荷（`data:` 行合并后 `jsonDecode` 的结果）。
  ///
  /// 恒为非 null：解析失败的事件不会被构造成 [SseEvent]（见 [parseSseFrame]）。
  final Object? data;

  /// `id:` 行（仅 ① Run 事件流携带，用于 `Last-Event-ID` 续传）。
  ///
  /// 设备状态流 / 会话列表流**不带** id（不可续传，重连即重拿快照），
  /// 故此字段为 null 是正常形态而非缺陷。
  final String? id;

  /// 载荷是否为 JSON 对象（调用方取字段前的推荐守卫）。
  bool get isMap => data is Map<String, dynamic>;

  /// 载荷转对象，非对象形态返回 null（不抛）。
  Map<String, dynamic>? get mapOrNull {
    final Object? value = data;
    return value is Map<String, dynamic> ? value : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SseEvent &&
      other.event == event &&
      other.id == id &&
      _deepEquals(other.data, data);

  @override
  int get hashCode => Object.hash(event, id, data);

  @override
  String toString() => 'SseEvent($event, id=$id, data=$data)';
}

/// 解析一帧 SSE（入参是**以空行分隔后的单帧文本**，不含结尾空行）。
///
/// 返回 null 的三种合法情形（**都不是错误**，上层一律静默跳过）：
/// 1. 纯注释帧（例如心跳 `: ping`）—— 没有任何 `event`/`data`；
/// 2. 载荷不是合法 JSON —— 坏帧静默跳过（§4.4 第 3 条）；
/// 3. 完全没有可识别字段 —— 空帧 / 代理插入的填充。
///
/// 绝**不**抛出：调用方不该为「某条帧写坏了」写 try/catch，
/// 那会让一条坏帧有机会中断整个订阅。
SseEvent? parseSseFrame(String block) {
  if (block.trim().isEmpty) return null;

  String? eventField;
  String? idField;
  final StringBuffer dataBuffer = StringBuffer();
  bool hasData = false;

  // 统一换行：`\r\n` → `\n`，再处理残留的 `\r`（老式 Mac 换行）。
  for (final String rawLine in block.split('\n')) {
    final String line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (line.isEmpty) continue;

    // 🔴 注释行（含心跳 `: ping`）：整行丢弃，绝不当畸形帧。
    if (line.startsWith(':')) continue;

    final int colon = line.indexOf(':');
    // 无冒号的行按规范（字段名后必须跟冒号）属无效行，静默跳过。
    if (colon <= 0) continue;

    final String field = line.substring(0, colon);
    // 规范要求去掉冒号后的**一个**前导空格，而不是 trimLeft 掉所有空白
    // （载荷本身的缩进可能有意义，虽然 JSON 场景无差别，这里按规范来）。
    final String value =
        line.length > colon + 1 && line[colon + 1] == ' '
            ? line.substring(colon + 2)
            : line.substring(colon + 1);

    switch (field) {
      case 'event':
        eventField = value;
      case 'id':
        idField = value;
      case 'data':
        // 多行 data 以 `\n` 拼接（规范约定）。
        if (hasData) dataBuffer.write('\n');
        dataBuffer.write(value);
        hasData = true;
      case 'retry':
        // 重连间隔建议：本项目的退避策略由 backoff_policy 统一决策
        // （与设备 ws 同口径），**刻意忽略**该字段，避免两处策略打架。
        break;
      default:
        // 未知字段（代理扩展 / 未来协议）：静默忽略。
        break;
    }
  }

  // 纯注释帧 / 空帧：那不是事件，只是保活或填充。
  if (!hasData && eventField == null) return null;

  Object? payload;
  if (hasData) {
    try {
      payload = jsonDecode(dataBuffer.toString());
    } on FormatException {
      // 坏帧静默跳过（§4.4 第 3 条）。这里**绝不能**抛出：
      // 一条坏帧不该让整个订阅崩溃（那会让界面从此不再更新）。
      return null;
    } catch (_) {
      return null;
    }
  }

  return SseEvent(
    event: eventField == null || eventField.isEmpty ? 'message' : eventField,
    data: payload,
    id: idField,
  );
}

/// 增量帧切分器：把**字节流增量**切成完整帧（保留跨块的半帧）。
///
/// # 为什么必须是有状态的对象而不是纯函数
/// TCP 不保证「一次 read = 一帧」。服务端 `fmt.Fprintf` 一帧可能被拆成多次
/// 到达（尤其帧内有中文/多字节 UTF-8 时），若无缓冲就会把一帧拆成两条坏帧。
///
/// 用法：
/// ```dart
/// final splitter = SseFrameSplitter();
/// final frames = splitter.add(decodedChunk); // 完整帧列表（可能为空）
/// ```
/// 注意：调用方应先用 `utf8.decoder.bind(...)` 之类**按字符**解码后再喂入，
/// 否则多字节字符会在块边界被截断成乱码（本类只负责 `\n\n` 分帧，不做编码处理）。
class SseFrameSplitter {
  final StringBuffer _buffer = StringBuffer();

  /// 喂入一段文本，返回其中**已完成**的帧（可为空列表）。
  ///
  /// 帧分隔符是空行：`\n\n`，或（Windows/代理形态）`\r\n\r\n`。
  /// 统一策略：先归一化 `\r\n` → `\n`，再以 `\n\n` 切分；
  /// 末尾不足一帧的残留**保留在缓冲区**，等下一块到达时拼接。
  List<String> add(String chunk) {
    if (chunk.isEmpty) return const <String>[];
    // 归一化换行。逐块归一化是安全的：`\r\n` 不会被跨块拆开
    // （`\r` 与 `\n` 之间不存在「等下一块」的语义，拆开也只是变成两个 `\n`，
    //   而连续 `\n` 只是多一个空行，分帧结果不变）。
    _buffer.write(chunk.replaceAll('\r\n', '\n'));

    final String pending = _buffer.toString();
    final List<String> frames = <String>[];
    int cursor = 0;
    while (true) {
      final int boundary = pending.indexOf('\n\n', cursor);
      if (boundary < 0) break;
      final String frame = pending.substring(cursor, boundary);
      cursor = boundary + 2;
      if (frame.trim().isNotEmpty) frames.add(frame);
    }

    // 保留未完成的残留（可能为空串/半帧）。
    final String rest = pending.substring(cursor);
    _buffer
      ..clear()
      ..write(rest);

    return frames;
  }

  /// 清空缓冲（连接重建时必须调用，避免旧连接的半帧污染新连接）。
  void reset() => _buffer.clear();

  /// 是否存在未完成的半帧（排查用）。
  bool get hasPending => _buffer.isNotEmpty;
}

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final Object? key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
