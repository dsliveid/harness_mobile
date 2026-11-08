# harness_mobile

harness **移动端客户端**：**Flutter + Dart** 单代码仓（Android / iOS）。
定位是「**遥控器 + 轻执行**」——在手机上安全地**审批** Agent 的敏感操作、**查看**会话与运行状态、**投递**现场照片给 Agent；**不承担**文件浏览、命令执行等重活（那是桌面端的职责）。

> 三端关系：`harness_go`（服务端 + Web）· `harness_desktop`（重执行工位）· **本端（随时随地的审批入口）**。
> 设备协议经由服务端 `GET /api/v1/devices/ws` 长连接注册为 `kind=mobile` 设备，一切落库在服务端，端侧**永不直写 DB**。

---

## 一、当前状态

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **MM1** | 配对 → 登录 → 审批中心（首屏）→ 设备 WS 长连接 → 会话只读 | ✅ 已交付并**端到端联调通过** |
| **批次 1** | WebView 全功能视图 / 最小 JS 桥 / 账号页 / iOS·Android 上架材料 | ✅ 已交付 |
| **批次 2-1** | 相册/相机 → base64 投递（≤2MB）+ 重试队列 | ✅ 已交付 |
| 批次 2-2/3 | `task.dispatch` 白名单执行与 result 回传 | 🔜 待真机联调 |
| 批次 3 | 回前台 resync 编排 / 连接态诚实化 UI | 🔜 待开发 |
| 批次 4 | 推送 / 大文件分片上传 / 增量同步 | ⏸ 阻塞于服务端（B1/B5/B3 缺口） |

**质量基线**（每轮 CI 强制）：

```
flutter analyze --fatal-infos --fatal-warnings   → No issues found!
flutter test                                     → 162 passed
```

---

## 二、技术栈与选型理由

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 业务与 UI（~85%） | **Dart 3.5 / Flutter 3.24** | 编译期类型安全（sealed/records 表达协议帧）；单一工具链 `analyze + test`，CI 无需真机 |
| Android 平台通道 | Kotlin（minSdk 24） | 只做 FCM / Keystore / 生物识别的「能力代理」，不发 HTTP、不解析协议 |
| iOS 平台通道 | Swift 5.9（iOS 14+） | 同上，只做 APNs / Keychain / LocalAuthentication |
| WebView 视图 | 加载服务端 `web/dist` | 低频深水区（项目/工作区/工具市场）不重复造 UI；**仓内 0 行 TypeScript** |

**刻意不做过的事**（见 `../harness_go/docs/移动端架构与功能设计.md` §6.3.1）：

- ❌ 不申报 `workspace.list` / `process` / `llm`——移动端 OS 沙箱做不到，申报即撒谎
- ❌ 不做后台常驻长连接——iOS 系统层面做不到，改为**推送唤醒 + 前台 WS + 回前台 resync**
- ❌ 结果恒 `source_trust=untrusted`——端侧结果是**不可信来源**，服务端强制覆盖

---

## 三、代码地图（lib/ 共 35 个文件）

```
lib/
├── protocol/                    # ★ 与 Go internal/device/protocol.go 逐字段对齐的线格式层
│   ├── envelope.dart            #   信封 + 9 帧类型 + 8 帧级错误码 + 断线决策枚举
│   └── frame_payloads.dart      #   各帧 Payload + 能力申报白名单（network+device）
│
├── core/
│   ├── config/base_url.dart     # baseUrl 归一化（防 Dart Uri 的 ?# 空尾巴陷阱）
│   ├── error/app_error.dart     # 对齐服务端 apperr：统一错误体 {"error":{...}}
│   └── app/
│       ├── app_session.dart     # 首屏门禁唯一事实来源（setup→pairing→login→approvals）
│       ├── providers.dart       # Riverpod 依赖注入图
│       ├── api_services.dart    # ApiFactory（按 baseUrl 缓存实例）
│       └── biometric_gate.dart  # 生物识别抽象（真机/AlwaysPass/AlwaysDeny 可注入）
│
├── data/
│   ├── local/
│   │   ├── secure_store.dart    # Keychain / Keystore 封装（tokens 绝不进日志）
│   │   └── app_settings_store.dart  # baseUrl / 设备名等非敏感偏好
│   ├── remote/
│   │   ├── http_client.dart     # dio 封装：Bearer 鉴权头、统一错误归一（9 种 DioException 穷举）
│   │   ├── auth_api.dart        # login / me / logout（服务端单令牌模型，无 refresh）
│   │   ├── device_api.dart      # pair-codes / pair / devices / revoke
│   │   ├── session_api.dart     # sessions / messages / active-run / tool-events
│   │   ├── approval_api.dart    # decide（allow_once / allow_session / deny）
│   │   └── delivery_api.dart    # base64 投递（≤2MB + sha256）
│   └── ws/
│       ├── device_connection.dart  # WS 抽象接口（测试注入 Fake）
│       ├── device_ws.dart       # 状态机：握手→welcome→心跳(heartbeat_s*0.8)→退避重连
│       └── sse_client.dart      # 手写 SSE 解析（忽略 `:` 注释帧 / resync 触发重拉）
│
├── domain/repositories/
│   └── approval_repository.dart # 首屏待审批列表：N+1 拼装（并发上限 6）待服务端聚合端点
│
└── features/
    ├── approval/approval_center_page.dart  # ★ 首屏：审批卡片 + 生物识别 + device_mismatch 锁定
    ├── pairing/pairing_page.dart           # 6 位配对码 + 设备名（请求体字段白名单有测试）
    ├── auth/login_page.dart                # 用户名/密码（失败透出服务端 message）
    ├── session/                            # 会话列表 + 消息流（只读）
    ├── delivery/                           # 相册/相机投递 + 重试队列（3 次上限）
    ├── webview/                            # 全功能视图 + JS 桥（绝不注入 device_token）
    ├── settings/                           # 服务端地址配置 + 账号页（解绑/注销降级指引）
    └── shared/                             # webEntry 工具 + UI helpers
```

**测试（11 个文件 / 162 用例）**：

| 测试文件 | 防什么 |
| --- | --- |
| `test/protocol/golden_test.dart` | **黄金 fixture 门禁**：9 个 Go 生成的 JSON 样本反序列化全绿，防 Go/Dart 双写漂移 |
| `test/protocol/capability_policy_test.dart` | 能力申报恒为 `network+device`，禁标签不出现在上行 |
| `test/core/base_url_test.dart` | baseUrl 无 `?#` 尾巴（联调时真实踩过的坑） |
| `test/data/api_contract_test.dart` | 上行请求体字段精确（服务端 `DisallowUnknownFields`，多一字段即 400） |
| `test/data/device_ws_test.dart` | 8 个帧级错误码分支 + 心跳取 `welcome.heartbeat_s*0.8`（**禁硬编码 15s**） |
| `test/data/sse_client_test.dart` | `: ping` 注释帧被忽略 / `resync` 帧触发快照重拉 |
| `test/features/approval_center_test.dart` | **红线 R5**：`device_mismatch` 锁定该行；生物识别 fail-closed 不发请求 |
| `test/features/webview_test.dart` | **红线 R3**：JS 桥产出脚本不含任何 token 字样 |
| `test/features/delivery_test.dart` | 2MB 边界 / sha256 / 重试 3 次上限 |
| `test/features/routing_test.dart` | 首屏铁律 + 二级页面可自由访问不被弹回 |

---

## 四、快速开始

### 4.1 环境要求

| 组件 | 版本 |
| --- | --- |
| Flutter | 3.24.x stable（Dart ≥ 3.5） |
| JDK | 17 |
| Android SDK | platform 35（`compileSdk`）、build-tools 34+ |
| 模拟器（可选） | AVD android-34 + AEHD 驱动 |

**完整环境搭建步骤**（本机实测路径与版本）：`docs/环境搭建指南.md`

### 4.2 拉取与验证

```bash
cd D:\WorkSpace\Project\harness_mobile

D:\Software\flutter\bin\flutter.bat pub get
D:\Software\flutter\bin\flutter.bat analyze --fatal-infos --fatal-warnings   # No issues found!
D:\Software\flutter\bin\flutter.bat test                                    # 162 passed
```

> ⚠️ Flutter 未加入 PATH 时用绝对路径；若在 PowerShell 用管道接 `Select-Object` 会让退出码失真，请重定向日志读取。

### 4.3 连接本地服务端跑通全链

前置：`harness_go` 服务端已启动（默认 `http://127.0.0.1:5611`）。

```bash
# 方式 A：模拟器（10.0.2.2 直达宿主机）
D:\Software\Android\sdk\platform-tools\adb.exe reverse tcp:5611 tcp:5611
D:\Software\flutter\bin\flutter.bat run -d emulator-5554
# App 内服务端地址填：http://127.0.0.1:5611（经 adb reverse 转发）

# 方式 B：真机 USB
adb reverse tcp:5611 tcp:5611 && flutter run
# App 内同样填 http://127.0.0.1:5611
```

配对流程：

1. 服务端 Web 端登录（管理员账号）→ 设备管理 → 生成配对码（`kind=mobile`）
2. App 配对页输入 6 位码（**TTL 120 秒**，过期重新生成）
3. 配对成功 → 登录页输入同一账号 → **进入审批中心（首屏黑铁律）**

> 详细运行与排障：`docs/Android自用运行指南.md`（端口/防火墙/明文 HTTP/常见错误表）。

### 4.4 打包 APK（自用）

```bash
D:\Software\flutter\bin\flutter.bat build apk --debug
# 产物：build\app\outputs\flutter-apk\app-debug.apk
```

自用场景无需正式签名（debug 签名可用）；**不要更换签名**，否则覆盖安装会提示「应用未安装」。
若仓库在发布环境，建议设置镜像变量以避免 Gradle 拉依赖失败：

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
```

---

## 五、架构红线（违反即打回）

| # | 红线 | 落地位置 |
| --- | --- | --- |
| R1 | 端侧永不直写 DB，一切状态以服务端为准 | `protocol/` 只编解码，无 DB 写 |
| R2 | 端侧结果恒 `source_trust=untrusted` | `TaskResultPayload` 默认值 |
| R3 | 令牌只存 Keychain/Keystore，绝不进日志/WebView | `secure_store.dart` + `webview_test` 否定断言 |
| R4 | 后台不断言实时，回前台先 resync 再连 WS | `device_ws.dart` 状态机 |
| R5 | `approval.device_mismatch` 禁止就地批准 | 审批中心锁定该行（有测试） |
| R6 | 移动端不暴露目录浏览（不自造能力标签） | `capability_policy_test` |
| R7 | 上行请求体字段精确（`DisallowUnknownFields`） | `api_contract_test` 键集合断言 |

**CI 三条 grep 门禁**（`.github/workflows/ci.yml`）：

```bash
! grep -rn "dart:ffi" lib/                                          # 平台能力必须走 MethodChannel
! grep -rnE '"(process|workspace\.(list|read|write)|llm)"' lib/      # 能力标签白名单
! grep -rniE 'print\(.*(token|authorization|secret|password)' lib/   # 令牌永不进日志
```

---

## 六、协议对接（与服务端对齐的唯一契约）

| 版 | 内容 | 字段权威 |
| --- | --- | --- |
| 信封 | `{v, type, id, run_id, ts, payload}` | `harness_go/internal/device/protocol.go:96-109` |
| 9 帧 | hello / welcome / ping / pong / error / task.dispatch / task.progress / task.result / lease.revoked | 同文件 `:34-53` |
| 8 错误码 | bad_frame / protocol_mismatch / task_unsupported / replaced / offline_timeout / revoked / server_closing / write_failed | 同文件 `:57-74` |
| 能力标签 | 只有 7 个，移动端申报 `network` + `device` | `harness_go/pkg/toolapi/spec.go:92-113` |
| 心跳 | `welcome.heartbeat_s * 0.8`，禁硬编码 15s | `protocol.go:200-209` |

**黄金 fixture 机制**（防双写漂移）：

```bash
# 在 harness_go 仓库执行，产物落到本仓 fixtures/
cd D:\WorkSpace\Project\harness_go
go run scripts/gen-fixtures.go -out ../harness_mobile/fixtures
```

`test/protocol/golden_test.dart` 会验证全部 9 个样本可被 Dart 端解析。**服务端改协议字段但未同步更新 fixture/本仓时，CI 直接红。**

---

## 七、已知限制与工程设计取舍

| # | 限制 | 说明 |
| --- | --- | --- |
| 1 | 服务端无推送链路（B1 未实现） | 推送相关 UI 暂缺；`PushChannel` 抽象已预留 |
| 2 | 无分片上传端点（B5） | 投递用 base64 内联 ≤2MB（照片场景 99% 够用） |
| 3 | 无增量同步参数（B3） | resync 走全量 + SSE `Last-Event-ID` 续传（唯一原生增量） |
| 4 | 审批列表 N+1 请求 | 无跨会话聚合端点（B2）；并发上限 6 + 渐进渲染缓解 |
| 5 | 会话消息流为只读 | 移动端默认非租约持有者，不做写权抢占 |
| 6 | 账号注销依赖 Web 端 | 服务端无注销端点；App 内提供解绑 + Web 指引降级 |

---

## 八、文档索引

| 文档 | 内容 |
| --- | --- |
| `docs/环境搭建指南.md` | Flutter/JDK/Android SDK/模拟器全流程（本机实测路径） |
| `docs/Android自用运行指南.md` | 不上架的运行方式、端口填法、排障表 |
| `../harness_go/docs/移动端架构与功能设计.md` | 架构基线：选型论证、协议对照、语言分层、CI 设计 |
| `../harness_go/docs/移动端开发实施计划.md` | 排期与批次拆解、每批验收门、契约修正记录 |
| `../harness_go/docs/三端功能矩阵与能力申报对齐表.md` | 三端能力归属与申报纪律 |
| `fixtures/` | 黄金协议样本（由服务端 `gen-fixtures.go` 生成，勿手改） |

---

## 九、常见问题

| 现象 | 根因 | 解法 |
| --- | --- | --- |
| `CLEARTEXT communication not permitted` | Android 9+ 拦明文 HTTP | 项目已配 `network_security_config.xml`；若仍报错检查 manifest 挂载 |
| 模拟器填 `localhost` 连不上 | localhost 指模拟器自己 | 改填 `http://10.0.2.2:<port>` 或用 `adb reverse` |
| 服务器报「非预期格式的错误响应」 | 服务端返回了非 JSON（如纯文本 404），多半是 baseUrl 拼错 | 检查是否带了 `?#` 尾巴；本仓 `base_url.dart` 已防 |
| 401 但 token 正确 | 鉴权头缺 `Bearer ` 前缀 | `http_client.dart` 已修；自定义请求注意加前缀 |
| `x86_64 emulation currently requires hardware acceleration` | AEHD 驱动未装 | 见 `docs/环境搭建指南.md` §7.1 |
| Gradle `Connection reset` 拉不到 Flutter 引擎 | 国内网络可达性差 | 设 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| Gradle 构建卡住不动 | 多套守护进程互锁 | `gradlew --stop` 或按 PID 终止旧 java 进程 |
| 覆盖安装提示「应用未安装」 | 签名不一致 | 卸载重装；**不要跨版本换签名** |

---

## 十、版本史

| 日期 | 变更 |
| --- | --- |
| 2026-11 | MM1（配对/登录/审批中心/WS/会话）+ 批次 1（WebView/JS 桥/上架材料）+ 批次 2-1（相册投递）交付；端到端联调通过；`analyze` 零问题 + **162 测试全绿** |
