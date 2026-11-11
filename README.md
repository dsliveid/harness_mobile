# harness_mobile

harness **移动端客户端**：**Flutter + Dart** 单代码仓（Android / iOS）。
定位是「**纯 WebView 主体 + 原生身份链路**」（2026-11 架构收口，提交 `15767d3`）——原生只负责**能进得来**：服务端地址 → 配对 → 登录 → 承载服务端 `web/dist` 的 WebView；**会话、审批、投递等业务界面一律由 Web UI 承担，原生不再重做一遍**。文件浏览、命令执行等重活属于桌面端。

> 🔴 2026-11 变更：**App 级生物识别解锁门已移除**（`webview_lock.dart` / `biometric_gate.dart` / `local_auth` 依赖及 `USE_BIOMETRIC`、`NSFaceIDUsageDescription` 声明全部删除）。单人自用场景下摩擦大于收益。身份链路现为「地址 → 配对 → 登录 → WebView」，不再有解锁环节。

> 三端关系：`harness_go`（服务端 + Web）· `harness_desktop`（重执行工位）· **本端（随身的 Web 入口 + 身份门禁）**。
> 设备协议经由服务端 `GET /api/v1/devices/ws` 长连接注册为 `kind=mobile` 设备，一切落库在服务端，端侧**永不直写 DB**。

---

## 一、当前状态

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **MM1** | 配对 → 登录 → 设备 WS 长连接（原「审批中心首屏 / 会话只读」页面已随架构收口删除） | ✅ 身份链路与 WS 交付并端到端联调通过；业务页面改由 WebView 承载 |
| **批次 1** | WebView 全功能视图 / 最小 JS 桥 / 账号页 / iOS·Android 上架材料 | ✅ 已交付 |
| ~~批次 2-1~~ | ~~相册/相机 → base64 投递（≤2MB）+ 重试队列~~ | ❌ **已注销**：`features/delivery`、`delivery_api.dart`、`delivery_queue.dart` 随 `15767d3` 整体删除 |
| ~~批次 2-2/2-3~~ | ~~`task.dispatch` 白名单执行与 result 回传~~ | ❌ **已注销**：架构上放弃手机端本地执行（协议层 `TaskResultPayload` 仍保留，恒 `source_trust=untrusted`，仅作解码用） |
| **批次 C** | **架构收口为 WebView 主体**：删除审批/会话/投递三域（含页面、仓储、data 层、路由），新增 App 级生物识别解锁门 `webview_lock.dart`、一次性票据透传 `webview_ticket_api.dart`、工作空间只读 `workspace_api.dart` | ✅ **已完成（含接线）**：删除与协议/身份链路已落地（`15767d3` / `4f2bfd3`）；`webview_ticket_api.dart` 已由提交 `22ebbe5` 完成首帧认证注入（`WebViewPage._prepareAuth` 已调用 `services.webviewTicket.prepareAuth`，首帧 URL 带 ticket fragment）；构建链已升级（见下方技术栈行）。🔴 **2026-11 变更**：`webview_lock.dart` 及生物识别依赖已整体移除，详见文首说明 |
| 批次 3 | 回前台 resync 编排 / 连接态诚实化 UI | 🔜 待开发（`device_ws.dart` 状态机与 `ws_lifecycle_bridge.dart` 已实现但**尚未接入 App**：无 `deviceWsProvider`、真实 `DeviceConnection` 实现缺失，服务端目前拿不到设备状态） |
| 批次 4 | 推送 / 大文件分片上传 / 增量同步 | ⏸ 阻塞于服务端（B1/B5/B3 缺口） |

**质量基线**（每轮 CI 强制，实测环境 Flutter 3.47.9 / Dart 3.13.7）：

```
flutter analyze --fatal-infos --fatal-warnings   → No issues found!
flutter test                                     → All tests passed!（182 用例；本仓 test/ 现为 11 个文件）
flutter build windows --debug                    → √ Built build\windows\x64\runner\Debug\harness_mobile.exe
```

> ### 📌 验证平台规则（2026-11 实测确立，**长期有效**）
>
> **功能与流程验证统一走 Windows 桌面模式；Android 打包验证延后、单独执行。**
>
> **为什么**（实测原因，非偏好）：
> 1. **本机内存硬约束**：物理内存 15.6G 但常驻空闲仅 2~3G，页面文件固定 2048MB。
>    Android 构建需同时拉起 Gradle daemon + Kotlin 编译 + Dart VM，实测导致
>    `Failed to reserve memory for new overflow mark stack` 乃至
>    **Dart VM 自身 `runtime/vm/zone.cc:95 Out of memory`** 崩溃 —— 这是资源问题，非代码缺陷。
> 2. **NDK 依赖**：`path_provider_android 2.3.0+` 经 `jni` 引入 C++ 源码（CMake），
>    强制要求 NDK 27.0.12077973；本机未装 NDK。已通过 `dependency_overrides`
>    锁定 `path_provider_android: 2.2.23`（无 jni）先行规避。
>    ⚠️ **该覆盖不可轻易删除**（2026-11 实测）：`path_provider` 虽已不是直接依赖，
>    但仍经 `flutter_secure_storage_windows` 传递引入；一旦移除覆盖，
>    `path_provider_android` 会解析到 2.3.1 并把 `jni`/`jni_flutter` 拉回依赖树，
>    Android 构建立刻硬失败。详见 `pubspec.yaml` 的 dependency_overrides 注释。
> 3. **Windows 模式覆盖度足够**：`flutter_inappwebview` 在 Windows 走 WebView2，
>    WebView 主体、票据首帧注入、路由与深链等**主流程均可验证**；
>    367MB 实跑内存 vs 模拟器 3.6GB，迭代成本低一个数量级。
>
> **适用范围与边界**：
> - ✅ Windows 可验证：WebView 主体与业务界面、票据/认证注入、路由与深链、账号页。
> - ⚠️ Windows **无法验证**（须留待 Android/iOS）：`onShowFileChooser` / `runOpenPanelWith` 文件选择器、FCM/APNs 推送、Keystore/Keychain。
> - ⚠️ 「WS 连接」目前**尚未接入 App**（`device_ws.dart` 状态机与生命周期桥已实现，但缺 `deviceWsProvider` 与真实 `DeviceConnection` 实现），故任何平台都还验证不到真实长连接。
> - ❗ 涉及上述平台专属能力的功能，**不得以「Windows 通过」宣称交付完成**，须显式标注「待 Android/iOS 验证」。
>
> **Android 侧已修复但未最终验证的构建链改动**（待后续单独验证时复核）：
> Gradle `8.7 → 8.14.3`、AGP `8.6.1 → 8.11.1`、Kotlin `1.9.24 → 2.2.20`、
> JVM 内存下调（`-Xmx1280m` / Metaspace `512m` / `workers.max=1` / Kotlin 进程内编译）、
> 移除 `ndkVersion` 声明、摘除死依赖 `drift`/`sqlite3_flutter_libs`/`drift_dev`。

---

## 二、技术栈与选型理由

| 层 | 选型 | 为什么 |
| --- | --- | --- |
| 业务与 UI（~85%） | **Dart 3.13 / Flutter 3.47**（`pubspec.yaml` 门槛仍为 `flutter >=3.24.0` / `sdk >=3.5.0`） | 编译期类型安全（sealed/records 表达协议帧）；单一工具链 `analyze + test`，CI 无需真机 |
| Android 构建链 | **JDK 21 + Gradle 8.14.3 + AGP 8.11.1 + Kotlin 2.2.20**，`compileSdk 35`，Java 目标 17 | ⚠️ 2026-11 实测升级：Flutter 3.47.9 的硬下限为 Gradle **8.14.0** / AGP **8.11.1** / Kotlin **2.2.20**（见 `flutter_tools/gradle/.../DependencyVersionChecker.kt`）。原组合 8.7 / 8.6.1 / 1.9.24 是 Flutter 3.24 时代的写法，**在 3.47.9 下已被拒绝构建**；旧文档「Gradle 8.7 是 Flutter tool 的已知兼容上限」的表述已失效。 |
| Android 平台通道 | Kotlin（minSdk 24） | 只做 FCM / Keystore 的「能力代理」，不发 HTTP、不解析协议（生物识别代理已随 local_auth 移除，2026-11） |
| iOS 平台通道 | Swift 5.9（iOS 14+） | 同上，只做 APNs / Keychain（LocalAuthentication 已随 local_auth 移除，2026-11） |
| WebView 视图 | **`flutter_inappwebview ^6.1.5`**（Android/iOS 走原生 WebView，Windows 走 WebView2） | 业务界面**唯一归属**（会话/审批/工作区/工具市场）；**仓内 0 行 TypeScript**。选它而非 `webview_flutter`：后者只有 android/ios/macos 实现，**没有任何 Windows 路径** |
| 桌面调试目标（非分发） | **Windows Desktop**（`windows/` 平台骨架 + WebView2 Runtime + NuGet CLI） | 让 Web 工作区能在本机低开销迭代（367MB vs 模拟器 3.6GB）；**不作为交付形态**，真机能力（相册/推送）仍只能在 Android/iOS 验证 |

**刻意不做过的事**（见 `../harness_go/docs/移动端架构与功能设计.md` §6.3.1）：

- ❌ 不申报 `workspace.list` / `process` / `llm`——移动端 OS 沙箱做不到，申报即撒谎（`workspace_api.dart` 只**消费**服务端已有的工作空间列表，不等于申报该能力）
- ❌ 不做后台常驻长连接——iOS 系统层面做不到，改为**推送唤醒 + 前台 WS + 回前台 resync**
- ❌ 不做原生审批卡片 / 会话列表 / 相册投递——与 Web UI 重复建设，已于批次 C 删除
- ❌ 结果恒 `source_trust=untrusted`——端侧结果是**不可信来源**，服务端强制覆盖

---

## 三、代码地图（lib/ 共 29 个文件）

```
lib/
├── main.dart                    # 入口：ProviderScope + HarnessMobileApp
├── app.dart                     # go_router 路由表 + redirect（阶段驱动）+ 启动页
│
├── protocol/                    # ★ 与 Go internal/device/protocol.go 逐字段对齐的线格式层
│   ├── envelope.dart            #   信封 + 9 帧类型 + 8 帧级错误码 + 断线决策枚举
│   └── frame_payloads.dart      #   各帧 Payload + 能力申报白名单（network+device）
│
├── core/
│   ├── config/base_url.dart     # baseUrl 归一化（防 Dart Uri 的 ?# 空尾巴陷阱）
│   ├── error/app_error.dart     # 对齐服务端 apperr：统一错误体 {"error":{...}}
│   └── app/
│       ├── app_session.dart     # 首屏门禁唯一事实来源（setup→pairing→login→webview）+ AppRoutes
│       ├── providers.dart       # Riverpod 依赖注入图
│       └── api_services.dart    # ApiFactory（按 baseUrl 缓存实例）+ /healthz 探测
│
├── data/
│   ├── local/
│   │   ├── secure_store.dart    # Keychain / Keystore 封装（tokens 绝不进日志）
│   │   └── app_settings_store.dart  # baseUrl / 设备名等非敏感偏好
│   ├── remote/
│   │   ├── http_client.dart     # dio 封装：Bearer 鉴权头、统一错误归一（9 种 DioException 穷举）
│   │   ├── auth_api.dart        # login / me / logout（服务端单令牌模型，无 refresh）
│   │   ├── device_api.dart      # pair-codes / pair / devices / revoke
│   │   ├── webview_ticket_api.dart  # ★ 批次 C：一次性 ticket → `#ticket=` fragment（失败降级为 Cookie 注入）
│   │   └── workspace_api.dart   # ★ 批次 C：工作空间**只读**消费（list / get，刻意不实现写操作）
│   └── ws/
│       ├── device_connection.dart  # WS 抽象接口（测试注入 Fake）
│       └── device_ws.dart       # 状态机：握手→welcome→心跳(heartbeat_s*0.8)→退避重连→dead
│
└── features/
    ├── webview/
    │   ├── webview_page.dart    # ★ 首屏：承载服务端 web/dist，含错误态与重新加载
    │   └── js_bridge.dart       # 单向深链桥（session / reauth），**绝不注入 device_token**
    ├── pairing/pairing_page.dart    # 6 位配对码 + 设备名（请求体字段白名单有测试）
    ├── auth/login_page.dart         # 原生唯一登录入口（WebView 内无登录表单）
    ├── settings/
    │   ├── setup_page.dart          # 服务端地址配置 + /healthz 测试连接
    │   └── account_page.dart        # 解绑 / 登出 / 注销降级指引
    └── shared/
        ├── web_entry.dart           # baseUrl → Web 入口 URI（丢弃 query/fragment）
        └── ui_helpers.dart          # 错误文案 / 空态 / 时间格式化等纯展示小件
```

> 已删除（随 `15767d3` 架构收口）：`features/approval/`、`features/session/`、`features/delivery/`、`domain/repositories/approval_repository.dart`、`data/remote/{approval,session,delivery}_api.dart`、`data/ws/sse_client.dart`。深链 `harness://session/<sid>` 改为进 WebView 后在 Web 内定位，`harness://approval/...` 已被白名单拒绝。

**平台目录**：`android/`（自用运行目标）、`ios/`（材料齐备但未实机验证）、`windows/`（**开发期调试目标，18 个构建源文件**，不作为分发形态）。

**测试（11 个文件，182 用例）**：

| 测试文件 | 防什么 |
| --- | --- |
| `test/protocol/golden_test.dart` | **黄金 fixture 门禁**：`fixtures/` 下 9 个 Go 生成的 JSON 样本反序列化全绿，防 Go/Dart 双写漂移 |
| `test/protocol/capability_policy_test.dart` | 能力申报恒为 `network+device`，禁标签不出现在上行 |
| `test/core/base_url_test.dart` | baseUrl 无 `?#` 尾巴（联调时真实踩过的坑） |
| `test/data/api_contract_test.dart` | 上行请求体字段精确（服务端 `DisallowUnknownFields`，多一字段即 400）；含 webview ticket / workspace 只读的键集合断言 |
| `test/data/webview_ticket_test.dart` | **红线 R3**：一次性票据不透出到日志、不进注入脚本；失败降级路径与空票据拒绝 |
| `test/core/webview_lock_test.dart` | App 级解锁门语义：冷启锁定 / 解锁成功 / **闸门抛异常必须回滚 locked（fail-closed，不得永久卡 authenticating）** |
| `test/data/device_ws_test.dart` | 8 个帧级错误码分支 + 心跳取 `welcome.heartbeat_s*0.8`（**禁硬编码 15s**） |
| `test/data/secure_store_test.dart` | 令牌存取与 `maskToken` 脱敏（红线 R3） |
| `test/features/webview_test.dart` | **红线 R3**：JS 桥产出脚本不含任何 token 字样；深链白名单（`session` / `reauth`，拒 `approval`） |
| `test/features/routing_test.dart` | 首屏铁律（身份齐备落在 `/webview`）+ 二级页面可自由访问不被弹回 |
| `test/widget_test.dart` | 根组件装配与 splash 阶段冒烟 |

---

## 四、快速开始

### 4.1 环境要求

| 组件 | 版本（本机实测 2026-11） |
| --- | --- |
| Flutter | **3.47.9** stable（Dart **3.13.7**）；`pubspec.yaml` 门槛仍为 `flutter >=3.24.0` / `sdk >=3.5.0` |
| JDK | **21**（`D:\Program Files\Java\jdk-21.0.8`，无需 JDK 17） |
| Gradle / AGP / Kotlin | **8.7 / 8.6.1 / 1.9.24**（`android/gradle/wrapper/gradle-wrapper.properties`、`android/settings.gradle`） |
| Android SDK | platform 35（`compileSdk = 35`）、build-tools 34+ |
| 模拟器（可选） | AVD + AEHD 驱动 |

**完整环境搭建步骤**（本机实测路径与版本）：`docs/环境搭建指南.md`

### 4.2 拉取与验证

```bash
cd F:\WorkSpace\Other\harness_mobile

F:\Software\flutter\bin\flutter.bat pub get
F:\Software\flutter\bin\flutter.bat analyze --fatal-infos --fatal-warnings   # No issues found!
F:\Software\flutter\bin\flutter.bat test                                    # 全绿（用例数以实际输出为准）
```

> ⚠️ Flutter 未加入 PATH 时用绝对路径；若在 PowerShell 用管道接 `Select-Object` 会让退出码失真，请重定向日志读取。

#### 一键脚本（推荐，替代上面的手敲命令）

根目录提供 `run.sh` / `build.sh`（Git Bash）与 `run.cmd` / `build.cmd`（双击/CMD）：

```bash
./run.sh                                  # 默认 flutter run -d windows（Windows 桌面调试）
./run.sh --server-url http://127.0.0.1:5611   # 顺带注入服务端地址，免手填
./run.sh --android --adb-reverse          # 真机 USB：自动 adb reverse 5611 + 跑第一个在线设备
./build.sh                                # 默认 = --target device（arm64-v8a，单 APK）
./build.sh --target emulator --debug      # x86_64 APK，装进 AVD（模拟器只认这个）
./build.sh --windows                      # 打 Windows 桌面版（产物是整个目录）
./run.sh --help                           # 全部参数
```

Windows 用户直接 `run.cmd` / `build.cmd`，无需先开 Git Bash（脚本会自动找 bash）。

> 设计要点：脚本用 `exec` 把控制台交给 flutter，所以 `r`/`R`/`q` 热重载交互全部照常可用。
> `--server-url` 只影响**本次运行**，不会覆盖你在 App 里已保存的地址。

#### 双轨 ABI：模拟器包与真机包不能互装

`build.sh` 用 `--target` 三档控制目标 ABI（缺省 `device`）：

| 档位 | 注入参数 | 用途 |
| --- | --- | --- |
| `emulator` | `--target-platform android-x64` | x86_64 AVD（本机 `harness_test`） |
| `device` | `--target-platform android-arm64` | arm64-v8a 真机（默认） |
| `all` | 不带 `--target-platform` | 全 ABI，**最慢**（要 3 份引擎 jar，各 100MB+） |

必守规则：

- **不能互装**：x86_64 APK 装真机会报 `INSTALL_FAILED_NO_MATCHING_ABIS`，反之亦然。
- **不能外推**：在 x86_64 模拟器上验证通过的架构相关行为，**不得**直接认定 arm64 真机同样成立（原生库实现可能不同）。
- 显式指定单 ABI 不是洁癖：不指定时 Flutter 会为每个 ABI 拉一份引擎 jar，首次构建看起来像卡死十几分钟。

#### 构建前置自检

`build.sh` 在动工前会自检三项，缺项**快速失败并给修复命令**（`--skip-preflight` 可跳过，不推荐）：

1. **nuget 可见性**（仅 Windows 桌面构建）— 且会区分「没装」与「装了但当前终端 PATH 没刷新」。
2. **MSVC v143 工具集**（仅 Windows 桌面构建）— 校验 `windows/CMakeLists.txt` 里的注入是否存在且位于 `project()` **之前**，并检查 14.3x 工具集文件真装了。
3. **Gradle 代理一致性**— 设了 `HTTP_PROXY` 就必须在 `android/gradle.properties` 里同时配 `-Dhttp.proxyHost/Port`，否则 Gradle 下载恒 0 字节（看起来像卡死）。

`--dry-run` 会打印完整命令与**目标 ABI**，可先核对再真跑。

### 4.3 连接本地服务端跑通全链

前置：`harness_go` 服务端已启动（默认 `http://127.0.0.1:5611`）。

```bash
# 方式 A：模拟器（adb reverse 直达宿主机，免改地址）
F:\Software\Android\sdk\platform-tools\adb.exe reverse tcp:5611 tcp:5611
F:\Software\flutter\bin\flutter.bat run -d emulator-5554
# App 内服务端地址填：http://127.0.0.1:5611（经 adb reverse 转发）
# 不走 adb reverse 时用 10.0.2.2 直达宿主机

# 方式 B：真机 USB
adb reverse tcp:5611 tcp:5611 && flutter run
# App 内同样填 http://127.0.0.1:5611
```

配对流程：

1. 服务端 Web 端登录（管理员账号）→ 设备管理 → 生成配对码（`kind=mobile`）
2. App 配对页输入 6 位码（**TTL 120 秒**，过期重新生成）
3. 配对成功 → 登录页输入同一账号 → **进入 WebView 主体（首屏铁律，`/webview`）**
4. 冷启动 / 回前台超 5 分钟 / 设置页手动锁定后需过硬生物识别（`WebViewLock`）——**接口已就绪、UI 尚未接线**，当前 WebView 为裸加载

> 详细运行与排障：`docs/Android自用运行指南.md`（端口/防火墙/明文 HTTP/常见错误表）。

### 4.4 打包 APK（自用）

```bash
F:\Software\flutter\bin\flutter.bat build apk --debug
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
| R1 | 端侧永不直写 DB，一切状态以服务端为准 | `protocol/` 只编解码、`data/remote/` 只发 HTTP；`pubspec.yaml` 虽仍列 `drift`/`sqlite3_flutter_libs`，但 `lib/` 内**零引用**（无本地业务库） |
| R2 | 端侧结果恒 `source_trust=untrusted` | `TaskResultPayload` 默认值与 `fromJson` 兜底均为 `'untrusted'`（`frame_payloads.dart:303/331`）；批次 C 后仅作解码，不产生上行结果 |
| R3 | 令牌只存 Keychain/Keystore，绝不进日志/WebView | `secure_store.dart`（`maskToken`）+ `webview_test.dart` 否定断言 + CI grep 门禁 1；`WebViewTicket` 的 `toString` 只印 `expires_at` |
| R4 | 后台不断言实时，回前台必须重新确认再放开业务 | `device_ws.dart` 状态机不回放「已连」假象（`live` 之外一律不可用）；`webview_lock.dart` 回前台超 `relockAfter`（默认 5 分钟）重新加锁。**注意**：回前台后主动 resync 重拉数据尚未实现（批次 3 待办） |
| R5 | **WebView 入口凭据一次性**：ticket 走 URL fragment、绝不写日志/文案；ticket 拿不到时只能降级为 Cookie 注入，**绝不把原生 `device_token` 注入 WebView** | `webview_ticket_api.dart`（`appendTicketFragment` 用 fragment 不用 query，保留 hash 路由；任何异常静默降级）+ `webview_lock.dart` fail-closed 锁语义。现状：`harness://reauth` 深链已接入 `WebViewPage._handleReauthDeepLink`（复用 `webviewTicket.issue`，失败 fail-closed 提示回登录）；但**首帧入口的 ticket fragment 注入尚未接线**（`_createWebView` 仍用 `webEntryUri(baseUrl)` 裸地址），接线时不得为了省事直接把 token 拼进 URL；`WebViewLock` 亦尚未挂到页面，仅状态机与单测就绪 |
| R6 | 移动端不暴露目录浏览（不自造能力标签） | `capability_policy_test` + CI grep 门禁 2；`workspace_api.dart` 只**消费**服务端已有的工作空间列表，不申报 `workspace.list` |
| R7 | 上行请求体字段精确（`DisallowUnknownFields`） | `api_contract_test` 键集合断言 + `ui_helpers.dart` 优先透出服务端 `message` |

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
| 9 帧 | hello / welcome / ping / pong / error / task.dispatch / task.progress / task.result / lease.revoked | 同文件 `:34-53`（`Valid()` 判据 `:86-93`） |
| 8 错误码 | `device.bad_frame` / `device.protocol_mismatch` / `device.task_unsupported` / `device.replaced` / `device.offline_timeout` / `device.revoked` / `device.server_closing` / `device.write_failed` | 同文件 `:57-74`；端侧镜像在 `lib/protocol/envelope.dart:83-105` |
| 能力标签 | 共 7 个（`workspace.read/write/list`、`process`、`network`、`llm`、`device`），移动端只申报 `network` + `device` | `harness_go/pkg/toolapi/spec.go:92-113` |
| 心跳 | `welcome.heartbeat_s * 0.8`，禁硬编码 15s（15s 只是服务端默认值） | `protocol.go:199-209`（`WelcomePayload`）；下发点 `internal/device/gateway.go:209` |

**批次 C 后的端侧消费边界**：9 帧类型仍**完整解码**（`fixtures/` 9 个样本仍全绿），但端侧**不再产生** `task.progress` / `task.result` 上行（本地执行已放弃）；`task.dispatch` 到达时按未支持处理。

**WebView 认证透传契约**（`lib/data/remote/webview_ticket_api.dart`，服务端待接线）：

```
① POST /api/v1/auth/webview-ticket    需用户会话，Body {device_id, ttl_s} → {ticket, expires_at}
② 入口 URL：https://<server>/#ticket=<ticket>（fragment，不进 Referer / access log）
③ POST /api/v1/auth/webview-exchange  免鉴权，Body {ticket} → Set-Cookie: hg_sess=...; HttpOnly
```

端侧只负责 ①签发与 ②拼 URL，③由 Web 前端自己调（本仓不实现 exchange）。服务端 ①/③ 尚未实现时 `prepareAuth` 静默降级为「注入原生会话 Cookie」（方案 B），绝不弹 Web 内登录表单。

**黄金 fixture 机制**（防双写漂移）：

```bash
# 在 harness_go 仓库执行，产物落到本仓 fixtures/
cd F:\WorkSpace\Other\harness_go
go run scripts/gen-fixtures.go -out ../harness_mobile/fixtures
```

`test/protocol/golden_test.dart` 会验证全部 9 个样本可被 Dart 端解析。**服务端改协议字段但未同步更新 fixture/本仓时，CI 直接红。**

---

## 七、已知限制与工程设计取舍

| # | 限制 | 说明 |
| --- | --- | --- |
| 1 | 服务端无推送链路（B1 未实现） | 推送相关逻辑暂无；`firebase_messaging` / `firebase_core` 已**移除**（2026-11，Windows 构建阻塞所致：其包内藏着未声明的 `windows/` C++ 实现，会链 `firebase_cpp_sdk` 失败），`flutter_local_notifications` 仍在但 `lib/` 内**零引用**。将来接推送需重新引入并按平台条件加载 |
| 2 | 业务界面全在 WebView（含审批/会话/投递） | 原生不再重做 UI；WebView 不可用（地址错、服务端挂、版本不兼容）时只能给错误态 + 重试，无原生兜底页 |
| 3 | WebView 认证透传服务端未接线 | ticket 端点（①/③）未实现，端侧 `prepareAuth` 也只能降级到「注入会话 Cookie」；且 `webview_ticket_api.dart` 尚未接入 `WebViewPage`，当前 WebView 实际是**裸加载入口 URL**，Web 侧登录态失效即需用户重进（`harness://reauth` 深链为其预留入口） |
| 4 | 回前台不做数据重拉（批次 3 待办） | `device_ws.dart` 无 `WidgetsBindingObserver` 钩子；`WebViewLock` 只处理锁/重新验真，不做数据 resync，且尚未接线 |
| 5 | 无增量同步参数（B3） | 服务端无 `updated_since` / `since_seq`，Web 侧只能全量 + 分页 |
| 6 | 账号注销依赖 Web 端 | 服务端无注销端点；App 内提供解绑 + Web 指引降级 |
| 7 | Windows 桌面未做真机能力验证 | `flutter build windows` 可跑通 Web 工作区，但 `local_auth`(Windows Hello) / `image_picker`(文件选择器) 语义与手机不同，推送无 Windows 实现；**指纹/相册/推送三项只能在 Android/iOS 真机验证** |
| 8 | 移动端不执行本地任务 | `task.dispatch` 白名单执行为架构收口主动放弃（批次 2-2/2-3 已注销），不是待办 |

---

## 八、文档索引

| 文档 | 内容 |
| --- | --- |
| `docs/环境搭建指南.md` | Flutter/JDK 21/Android SDK/模拟器全流程（本机实测路径与版本） |
| `docs/Android自用运行指南.md` | 不上架的运行方式、端口填法、排障表 |
| `../harness_go/docs/移动端架构与功能设计.md` | 架构基线：选型论证、协议对照、语言分层、CI 设计（WebView 主体后的最新版） |
| `../harness_go/docs/移动端开发实施计划.md` | 排期与批次拆解、每批验收门、批次 C 架构收口记录 |
| `../harness_go/docs/三端功能矩阵与能力申报对齐表.md` | 三端能力归属与申报纪律 |
| `../harness_go/docs/工作空间模型与三端能力收口协议.md` | `workspace_api.dart` 的上位契约（含移动端只读边界） |
| `fixtures/` | 黄金协议样本（由服务端 `scripts/gen-fixtures.go` 生成，勿手改） |

---

## 九、常见问题

| 现象 | 根因 | 解法 |
| --- | --- | --- |
| `CLEARTEXT communication not permitted` | Android 9+ 拦明文 HTTP | 项目已配 `network_security_config.xml`；若仍报错检查 manifest 挂载 |
| 模拟器填 `localhost` 连不上 | localhost 指模拟器自己 | 改填 `http://10.0.2.2:<port>` 或用 `adb reverse` |
| 服务器报「非预期格式的错误响应」 | 服务端返回了非 JSON（如纯文本 404），多半是 baseUrl 拼错 | 检查是否带了 `?#` 尾巴；本仓 `base_url.dart` 已防 |
| 401 但 token 正确 | 鉴权头缺 `Bearer ` 前缀 | `http_client.dart` 已修；自定义请求注意加前缀 |
| 进 WebView 后立刻要求重新登录 | WebView Cookie 独立于原生 Keychain，透传失败（ticket 端点未实现且 Cookie 注入失败） | 属已知降级失败路径；先确认服务端 `POST /api/v1/auth/webview-ticket` 是否 404（`webview_ticket_api.dart` 头注释的三步契约） |
| WebView 白屏 / 只显示错误态 | 服务端 `web/dist` 未就绪、地址末尾多了路径、或协议版本不兼容 | 先在浏览器打开同一 baseUrl 验证；WebView 错误态含「重新加载」（`WebViewPage.reload`） |
| 切回前台后再进 App 要求指纹 | `WebViewLock.relockAfter` 默认 5 分钟，超时重新加锁（设计如此，fail-closed） | 如需调整改 `providers.dart` 里 `WebViewLock` 构造的 `relockAfter`，不要绕过锁 |
| `x86_64 emulation currently requires hardware acceleration` | AEHD 驱动未装 | 见 `docs/环境搭建指南.md` §1 起的模拟器章节 |
| Gradle `Connection reset` 拉不到 Flutter 引擎 | 国内网络可达性差 | 设 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| Gradle 构建卡住不动 | 多套守护进程互锁 | `gradlew --stop` 或按 PID 终止旧 java 进程 |
| `Unsupported class file major version 65` | Gradle 8.3 及以下在 JDK 21 上跑不了 | 保持 `gradle-wrapper.properties` 为 8.7（详见 `docs/环境搭建指南.md` §2 不变量 1/2） |
| 覆盖安装提示「应用未安装」 | 签名不一致 | 卸载重装；**不要跨版本换签名** |
| Windows 构建报 `NUGET-NOTFOUND ... Microsoft.Windows.ImplementationLibrary` | NuGet 只在**用户级** PATH，MSBuild 不继承 | NuGet 目录必须写入**系统级** PATH（`Machine`），并在构建时重新拼接环境变量；详见 `docs/环境搭建指南.md` Windows 桌面调试章节 |
| Windows 构建报 `LNK2019/LNK2001 __std_find_last_trivial_1`（来自 `firebase_app.lib`） | `firebase_core` 包内藏着未声明 windows 平台的 C++ 实现 | 本项目已移除 firebase 依赖；若重新引入需按平台条件加载，勿让其进入 Windows 构建 |
| Windows 桌面跑起来但指纹/相册不可用 | Windows 上 `local_auth` 走 Windows Hello、`image_picker` 走文件选择器，语义与手机不同 | 属设计内差异，这三项能力必须回 Android/iOS 真机验证 |

---

## 十、版本史

| 日期 | 变更 |
| --- | --- |
| 2026-11 | **WebView 迁移到 `flutter_inappwebview`（提交 `009e3ea`），打通 Windows 桌面调试**：`webview_flutter` → `flutter_inappwebview ^6.1.5`（后者支持 Windows/WebView2，前者无任何 Windows 路径）；新增 `windows/` 平台骨架（18 个构建源文件）；移除 `firebase_messaging`/`firebase_core`（其包内藏着未声明 windows 的 C++ 实现，会链 `firebase_cpp_sdk` 失败，实测 `lib/`·`test/`·`android/` 三处零引用）。迁移中补齐了**原先并不存在**的「首帧注入只做一次」标记 `_bridgeInjected`（因 `onPageFinished` → `onLoadStop` 在 SPA 内部导航时会重复触发）。实测 `analyze` 零问题、`test` **182 用例**全绿、`build windows --debug` 成功（0.6MB / 实跑 367MB）。⚠️ Android 真机未复验 |
| 2026-11 | **批次 C 架构收口（提交 `15767d3`）**：产品定位改为「纯 WebView 主体 + 原生身份链路」；删除 `features/{approval,session,delivery}`、`domain/repositories/approval_repository.dart`、`data/remote/{approval,session,delivery}_api.dart`、`data/ws/sse_client.dart` 与对应路由（`AppRoutes` 只剩 splash/setup/pairing/login/webview/account）；新增 `core/app/webview_lock.dart`（App 级生物识别解锁门）、`data/remote/webview_ticket_api.dart`（一次性票据透传）、`data/remote/workspace_api.dart`（工作空间只读）；深链白名单 `approval` → `reauth`；随后 `4f2bfd3` 补工作空间只读 API。构建链升级为 **JDK 21 + Gradle 8.7 + AGP 8.6.1**。`lib/` 收敛到 28 文件、`test/` 11 文件（170 用例）。<br>⚠️ 后续核算修正：批次 C 之后 `lib/` 实为 **29** 文件（原文 28 少计 1），整体为 `app.dart` 与 `core/app/` 下 5 件并存所致；测试用例数同期为 182 而非 170 |
| 2026-11 | MM1（配对/登录/审批中心/WS/会话）+ 批次 1（WebView/JS 桥/上架材料）+ 批次 2-1（相册投递）交付；端到端联调通过；`analyze` 零问题 + 当时基线 162 测试全绿（其中审批中心/会话/投递相关用例已随批次 C 删除） |
