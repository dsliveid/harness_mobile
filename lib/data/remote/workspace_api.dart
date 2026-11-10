/// 工作空间 API（对齐服务端 `internal/api/workspace_handler.go`）。
///
/// 契约（服务端实际路由，`internal/api/router.go`）：
/// ```
/// GET    /api/v1/workspaces          → { items: [WorkSpace] }
/// GET    /api/v1/workspaces/{wid}    → WorkSpace
/// POST   /api/v1/workspaces          → WorkSpace（移动端会被 403，见下）
/// PATCH  /api/v1/workspaces/{wid}    → WorkSpace（kind 不可改）
/// DELETE /api/v1/workspaces/{wid}    → 204
/// ```
///
/// 移动端职责边界（架构文档 §3.2 / §8 三端职责矩阵）：
/// - **只读消费**：移动端不创建、不修改、不删除工作空间。
/// - 因此本文件**只实现 list / get**，写操作一律不做——这是刻意的能力收窄，
///   不是「还没写」。真要加写方法时请先复核协议 §8 的三端职责矩阵。
///
/// 能力语义提醒（协议 §4.1）：会话的能力天花板由所属 Workspace 的 `kind` 决定，
/// 与「谁创建会话」无关。移动端配对后服务端会自动建一个 `kind=mobile` 的空间。
library;

import 'http_client.dart';

/// 工作空间类型（与后端 `model.WorkspaceKind` 及前端 `WorkspaceKind` 逐字一致）。
///
/// 注意：**不含** `cli` / `tablet`——那是 `DeviceKind` 的取值，两者是不同枚举，
/// 不要混用（协议 §2.4.3：两套枚举各自独立，不存在映射关系）。
abstract final class WorkspaceKinds {
  static const String server = 'server';
  static const String desktop = 'desktop';
  static const String mobile = 'mobile';
  static const String browser = 'browser';
}

/// 一个工作空间（执行面/客户端接入）。
class WorkSpace {
  const WorkSpace({
    required this.id,
    required this.name,
    required this.kind,
    required this.deviceId,
    required this.rootPath,
    required this.online,
    required this.host,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// `server` / `desktop` / `mobile` / `browser`（见 [WorkspaceKinds]）。
  final String kind;

  /// 绑定的设备 ID；空串 = 服务端内置空间。
  final String deviceId;

  /// 执行面默认工作目录（可空）。
  final String rootPath;

  /// 是否在线（服务端派生态）。
  ///
  /// 语义提醒（协议 §3.1）：仅用于 UI 置灰与提示，**绝不参与能力判定**。
  /// 能力只看 [kind]。
  final bool online;

  /// 工作区宿主：`server` 或 `device:<device_id>`（协议 §1.1 的既有定义）。
  final String host;

  final int createdAt;
  final int updatedAt;

  /// 是否为移动端空间（能力天花板 = 仅对话）。
  bool get isMobile => kind == WorkspaceKinds.mobile;

  factory WorkSpace.fromJson(Map<String, dynamic> json) => WorkSpace(
        id: _stringOf(json['id']),
        name: _stringOf(json['name']),
        kind: _stringOf(json['kind']),
        deviceId: _stringOf(json['device_id']),
        rootPath: _stringOf(json['root_path']),
        online: json['online'] == true,
        host: _stringOf(json['host']),
        createdAt: _intOf(json['created_at']),
        updatedAt: _intOf(json['updated_at']),
      );
}

/// 工作空间只读 API（移动端不提供写操作）。
class WorkspaceApi {
  const WorkspaceApi({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// 列出全部工作空间（含派生的 online / host）。
  Future<List<WorkSpace>> listWorkspaces() => _client.get<List<WorkSpace>>(
        '/api/v1/workspaces',
        parse: (Object? data) => itemsOf(data)
            .map(WorkSpace.fromJson)
            .toList(growable: false),
      );

  /// 取单个工作空间（不存在返回 404 → [AppError]）。
  Future<WorkSpace> getWorkspace(String id) => _client.get<WorkSpace>(
        '/api/v1/workspaces/$id',
        parse: (Object? data) => WorkSpace.fromJson(mapOf(data)),
      );
}

// ============ 宽容解析工具（防服务端 int64 被当 double 丢精度）============

String _stringOf(Object? v) => v is String ? v : '';

int _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}
