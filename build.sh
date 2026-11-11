#!/usr/bin/env bash
#
# harness_mobile 打包脚本
# 用法：./build.sh [选项]   （Windows：build.cmd）
#
# ⚠️ 默认产物是 Android 单 APK（自用装自己手机，单包最省事）：
#    ./build.sh                  → flutter build apk --release --target-platform android-arm64
#
# ★ 双轨 ABI 策略（--target 三档，缺省 device）★
#   emulator → --target-platform android-x64    （x86_64 模拟器 AVD，如 harness_test）
#   device   → --target-platform android-arm64  （真机 arm64-v8a）
#   all      → 不带 --target-platform           （全 ABI，最慢：需 3 份 Flutter 引擎 jar）
#
#   ⚠️ 模拟器是 x86_64、真机是 arm64，两者**不能互装**：
#      装错会报 INSTALL_FAILED_NO_MATCHING_ABIS。
#   ⚠️ x86_64 模拟器上的结论**不得外推到 arm64 真机**（原生库行为可能不同）。
#   ⚠️ 只有 emulator 档需要 AVD；打真机包不要用 emulator 档，反之亦然。
#
# 选项：
#   --target MODE      Android ABI 档位：emulator | device | all（缺省 device）
#   --windows          打 Windows 桌面版（产物是**整个目录**，不是单文件！）
#   --aab              打 Android App Bundle（上架用；自用不需要）
#   --debug            用 debug 模式构建（默认 release）
#   --split-per-abi    按 CPU 架构拆成多个 APK（体积更小，但要装对型号）
#   --ios              打 iOS（仅 macOS；其它平台直接报错退出）
#   --server-url URL   把服务端地址编进包里（--dart-define=BASE_URL=URL）
#   --out DIR          产物额外复制到 DIR（默认不复制，留在 build/ 里）
#   --clean            构建前 flutter clean
#   --dry-run          只打印将要执行的命令（含目标 ABI），不真正构建
#   -v, --verbose      透传 flutter 的 --verbose
#   -h, --help         显示本帮助
#
# ★ 前置环境自检（构建前自动跑，缺项快速失败并给修复命令）★
#   1. nuget 在 PATH 中可见（Windows 桌面构建的 CMake 依赖；系统级 PATH，用户级无效）
#   2. MSVC v143 工具集文件存在（默认 MSVC 14.51 会把 /await 升为 C2338 硬错误）
#   3. HTTP_PROXY 已设时，android/gradle.properties 必须含对应 proxy 项
#      （Java 不读 HTTP_PROXY 环境变量，必须显式 -Dhttp.proxyHost/Port）
#   自检失败时按提示修，或用 --skip-preflight 跳过（不推荐）。
#
# ★ 构建失败诊断★
#   Gradle 长时间无进展时，本脚本会给出 jstack / CPU 判据与 --offline 反查缺失构件的方法。
#
# ⚠️ Windows 产物必须整目录分发：
#    build/windows/x64/runner/Release/ 整个目录拷走，只拷 harness_mobile.exe
#    会缺 flutter_windows.dll / WebView2Loader.dll 等，双击直接闪退。
#
# 签名说明（自用）：android/app/build.gradle 用的是 signingConfigs.debug，
# release 包也是 debug 签名。能装能跑，但**不要随意换签名**，否则覆盖安装
# 会提示「应用未安装」，必须先卸载旧版。详见 docs/Android自用运行指南.md §4。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 公共函数（本仓自包含，不跨仓库引用）
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

need_val() { [ $# -ge 2 ] || die "$1 需要一个参数值。"; }

find_flutter() {
  # ⚠️ Git Bash 下的坑（实测踩过，退出码 255）：
  #   Flutter SDK 的 bin/ 同时有 `flutter`（bash 脚本）和 `flutter.bat`。
  #   在 MINGW/Git Bash 里直接跑那个无扩展名的 bash 脚本时，它内部会去调
  #   shared.bat 并把批处理源码当 shell 脚本回显，最终以 255 退出——
  #   既没构建也没说清原因。因此 Windows（MINGW/MSYS/CYGWIN）必须优先用 .bat。
  local ext_order
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ext_order="flutter.bat flutter" ;;
    *)                    ext_order="flutter flutter.bat" ;;
  esac

  local c name
  if [ -n "${FLUTTER_HOME:-}" ]; then
    for name in $ext_order; do
      c="$FLUTTER_HOME/bin/$name"
      [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
  fi
  # command -v 在 Git Bash 里通常只命中无扩展名的那个，所以不直接采信它，
  # 而是用它定位 SDK 目录，再按平台偏好重新挑文件名。
  if command -v flutter >/dev/null 2>&1; then
    local found bindir
    found="$(command -v flutter)"
    bindir="$(cd "$(dirname "$found")" && pwd)"
    for name in $ext_order; do
      [ -f "$bindir/$name" ] && { printf '%s' "$bindir/$name"; return 0; }
    done
    command -v flutter
    return 0
  fi
  for c in "D:/Software/flutter/bin/flutter.bat" "D:/Software/flutter/bin/flutter"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

FLUTTER="$(find_flutter)" || die "找不到 flutter。请设置 FLUTTER_HOME，或把 flutter 加进 PATH。
        （本机既定路径 D:\\Software\\flutter\\bin 也不存在）"

# ---------------------------------------------------------------------------
# flutter 调用封装（核心兼容层，勿删）
# ---------------------------------------------------------------------------
# ⚠️ MSYS/Git Bash 下的致命坑（实测定位，退出码 255）：
#   在 Git Bash（MSYS2）里调用 flutter.bat，如果不把 stdin 从终端摘开，
#   cmd.exe 会把 shared.bat 的**批处理源码原样回显**并直接退出（255），
#   根本进不到构建逻辑。日志里会看到一堆 `IF %stamp_value% NEQ ...`
#   这种批处理语句——这不是 Flutter 的问题，是 MSYS pty 与 cmd 批处理
#   解析器的交互缺陷。
#   解法：给所有 flutter 调用加 `< /dev/null`，把 stdin 从 pty 上摘掉。
#   （只影响 stdin，stdout/stderr 仍照常转发，能正常看进度和日志。）
run_flutter() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) "$FLUTTER" "$@" < /dev/null ;;
    *)                    "$FLUTTER" "$@" ;;
  esac
}

usage() {
  awk 'NR>1 && /^set -uo pipefail/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
  exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
TARGET="apk"        # apk | windows | aab | ios
ABI_TIER="device"   # emulator | device | all（仅对 apk / aab 生效）
BUILD_MODE="release"
SPLIT=""
SERVER_URL=""
OUT_DIR=""
DO_CLEAN=""
DRY_RUN=""
VERBOSE=""
SKIP_PREFLIGHT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --windows)  TARGET="windows" ;;
    --aab)      TARGET="aab" ;;
    --ios)      TARGET="ios" ;;
    --apk)      TARGET="apk" ;;
    --target)   need_val "$@"
                ABI_TIER="$2"; shift
                case "$ABI_TIER" in
                  emulator|device|all) : ;;
                  *) die "--target 只接受 emulator | device | all（收到：$ABI_TIER）。
       当前是 apk/aab 的 ABI 档位，不是构建平台。
       想打 Windows 桌面版请用 --windows，iOS 请用 --ios。" ;;
                esac ;;
    --target=*) ABI_TIER="${1#*=}"
                case "$ABI_TIER" in
                  emulator|device|all) : ;;
                  *) die "--target 只接受 emulator | device | all（收到：$ABI_TIER）。" ;;
                esac ;;
    --debug)    BUILD_MODE="debug" ;;
    --release)  BUILD_MODE="release" ;;
    --profile)  BUILD_MODE="profile" ;;
    --split-per-abi) SPLIT="--split-per-abi" ;;
    --server-url)   need_val "$@"; SERVER_URL="$2"; shift ;;
    --server-url=*) SERVER_URL="${1#*=}" ;;
    --out)      need_val "$@"; OUT_DIR="$2"; shift ;;
    --out=*)    OUT_DIR="${1#*=}" ;;
    --clean)    DO_CLEAN=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    -v|--verbose) VERBOSE="--verbose" ;;
    -h|--help)  usage ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
  shift
done

run_cmd() {
  if [ -n "$DRY_RUN" ]; then
    say "[dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 前置环境自检（快速失败 + 给修复命令）
# ---------------------------------------------------------------------------
# 设计原则：宁可 2 秒内失败并说清怎么修，也不要跑到 10 分钟后才报一个看不懂的错。
# 每个检查只在该检查「真的会挡路」时才启用（例如 nuget 只在 Windows 构建时需要）。

preflight_warn_count=0
pf_ok()   { say "  [OK]   $*"; }
pf_warn() { printf '  [WARN] %s\n' "$*" >&2; preflight_warn_count=$((preflight_warn_count + 1)); }
pf_fail() { printf '  [FAIL] %s\n' "$*" >&2; PREFLIGHT_FAILED=1; }
PREFLIGHT_FAILED=""

# 1) nuget 可见性 —— Windows 桌面构建的 CMake 依赖
#    已知坑：装到用户级 PATH 无效（MSBuild 不继承 User PATH），必须系统级。
#    另外 CMakeCache.txt 会固化旧的 NUGET:FILEPATH，导致「Failed to install nuget package」。
check_nuget() {
  if command -v nuget >/dev/null 2>&1 || command -v nuget.exe >/dev/null 2>&1; then
    pf_ok "nuget 可见（$(command -v nuget 2>/dev/null || command -v nuget.exe)）"
    return 0
  fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *) pf_ok "nuget 检查跳过（非 Windows）"; return 0 ;;
  esac
  # 区分两种失败：① 系统里根本没装/没配 ② 已配到系统级 PATH 但当前终端没刷新
  # 后者最常见（改了 Machine PATH 但没重开终端），修复成本极低，提示必须点明。
  local sys_path=""
  if command -v powershell >/dev/null 2>&1; then
    sys_path="$(powershell -NoProfile -Command '[Environment]::GetEnvironmentVariable("Path","Machine")' 2>/dev/null | tr -d '\r')"
  fi
  local found_dir=""
  local d
  for d in $(printf '%s' "$sys_path" | tr ';' '\n'); do
    if [ -f "$d/nuget.exe" ] || [ -f "$d/nuget" ]; then found_dir="$d"; break; fi
  done
  if [ -z "$found_dir" ]; then
    for d in "$HOME/.nuget-cli" "/c/Users/$USER/.nuget-cli"; do
      if [ -f "$d/nuget.exe" ]; then found_dir="$d"; break; fi
    done
  fi

  if [ -n "$found_dir" ]; then
    pf_fail "nuget.exe 存在于 $found_dir，但**当前终端**的 PATH 里没有它"
    say '         原因：PATH 改动只对新开的终端生效，本终端仍用旧 PATH。'
    say '         修复（最常见，成本最低）：**关掉当前终端重开一个**，再跑本脚本。'
    say '         若重开后仍不行，说明它没在系统级 PATH（用户级对 MSBuild 无效）：'
    say '           [Environment]::SetEnvironmentVariable("Path", $env:Path + ";'"$found_dir"'", "Machine")'
    return 0
  fi

  pf_fail "nuget 不在 PATH 中（Windows 桌面构建需要它装 WebView2 依赖）"
  say '         修复：装到**系统级** PATH 后重开终端（用户级 PATH 对 MSBuild 无效）：'
  say '           [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Users\<you>\.nuget-cli", "Machine")'
  say '         若之前用户级装过，还要清掉固化了旧路径的构建缓存：'
  say '           rm -rf build/windows && ./build.sh --windows'
}

# 2) MSVC v143 工具集 —— 默认 MSVC 14.51 会把 /await 旧协程升为 C2338 硬错误
#    解法只能是在 windows/CMakeLists.txt 的 project() 之前注入 CMAKE_GENERATOR_TOOLSET=v143
#    （-T 参数 / env 变量 / 改 CMakeCache 三种直觉做法均实测失败）。
check_msvc_v143() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *) pf_ok "v143 检查跳过（非 Windows）"; return 0 ;;
  esac
  local cmakelists="windows/CMakeLists.txt"
  if [ ! -f "$cmakelists" ]; then
    pf_fail "找不到 $cmakelists"
    return 0
  fi
  # 工具集注入必须在 project() 之前才生效（放后面 CMake 已经选定工具集了）
  local toolset_line proj_line
  toolset_line="$(grep -n 'CMAKE_GENERATOR_TOOLSET' "$cmakelists" 2>/dev/null | head -n1 | cut -d: -f1)"
  proj_line="$(grep -n '^\s*project\s*(' "$cmakelists" 2>/dev/null | head -n1 | cut -d: -f1)"
  if [ -z "$toolset_line" ]; then
    pf_fail "$cmakelists 里没有 CMAKE_GENERATOR_TOOLSET=v143 注入"
    say '         不加这行，MSVC 14.51+ 会把 /await 判为 C2338 STL1011 直接构建失败。'
    say '         修复：在 project() **之前**加一行 set(CMAKE_GENERATOR_TOOLSET "v143")。'
    return 0
  fi
  if [ -n "$proj_line" ] && [ "$toolset_line" -gt "$proj_line" ]; then
    pf_fail "CMAKE_GENERATOR_TOOLSET 注入位置错了（第 $toolset_line 行，在 project() 第 $proj_line 行之后）"
    say '         CMake 在 project() 时就已选定工具集，写在后面不生效。请移到 project() 之前。'
    return 0
  fi
  # 再确认工具集文件真的装了（只有注入没有文件，会报找不到工具集）
  local vsroot=""
  for c in "/d/Program Files/Microsoft Visual Studio/18/Insiders" \
           "/c/Program Files/Microsoft Visual Studio/18/Insiders" \
           "/c/Program Files/Microsoft Visual Studio/2022/Community" \
           "/c/Program Files/Microsoft Visual Studio/2022/Professional" \
           "/c/Program Files/Microsoft Visual Studio/2022/Enterprise"; do
    [ -d "$c/VC/Tools/MSVC" ] && { vsroot="$c"; break; }
  done
  if [ -z "$vsroot" ]; then
    pf_warn "没找到 Visual Studio 的 VC/Tools/MSVC 目录，无法校验 v143 工具集文件是否真装了"
    say '         若构建报「找不到 v143 工具集」，用 VS Installer 装「MSVC v143 - VS 2022 C++ x64/x86 生成工具」+ ATL。'
    return 0
  fi
  if ls "$vsroot/VC/Tools/MSVC"/14.3* >/dev/null 2>&1; then
    pf_ok "MSVC v143 工具集存在（$(basename "$(ls -d "$vsroot/VC/Tools/MSVC"/14.3* | head -n1)")）"
  else
    pf_fail "找到了 VS（$vsroot）但没有 14.3x（v143）工具集"
    say '         修复：VS Installer → 修改 → 单个组件 → 勾「MSVC v143 - VS 2022 C++ x64/x86 生成工具」和 ATL。'
  fi
}

# 3) 代理一致性 —— Java 不读 HTTP_PROXY 环境变量，必须显式 -Dhttp.proxyHost/Port
check_proxy() {
  local gp="android/gradle.properties"
  local env_proxy="${HTTP_PROXY:-${http_proxy:-}}"
  local env_https="${HTTPS_PROXY:-${https_proxy:-}}"
  if [ -z "$env_proxy" ] && [ -z "$env_https" ]; then
    pf_ok "未设 HTTP(S)_PROXY 环境变量，代理检查跳过"
    return 0
  fi
  if [ ! -f "$gp" ]; then
    pf_fail "设了代理但找不到 $gp"
    return 0
  fi
  if grep -q 'http.proxyHost' "$gp" 2>/dev/null; then
    pf_ok "代理已同时配到 $gp（Java 才能生效）"
  else
    pf_fail "设了 HTTP_PROXY 但 $gp 没有 proxyHost 项"
    say "         环境变量只能让 curl/git 走代理，Java/Gradle **不读**它。"
    say "         现象：Gradle 下载恒 0 字节，看起来像卡死。"
    say "         修复：在 $gp 的 org.gradle.jvmargs 里加："
    say "           -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=<端口> -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=<端口>"
  fi
}

run_preflight() {
  # Windows 桌面构建才需要 nuget/v143；Android 构建不该因为桌面链没配好而被挡
  local need_msvc=""
  case "$TARGET" in
    windows) need_msvc=1 ;;
  esac

  say '[自检] 前置环境 ...'
  if [ -n "$need_msvc" ]; then
    check_nuget
    check_msvc_v143
  else
    pf_ok "nuget / v143 检查跳过（当前目标 $TARGET 不需要 Windows 原生工具链）"
  fi
  check_proxy

  if [ -n "$PREFLIGHT_FAILED" ]; then
    say ''
    die "前置环境自检未通过（见上面 [FAIL] 项）。按提示修复后重跑。
       确实要跳过自检：--skip-preflight（不推荐，只会把失败推迟到更难诊断的地方）"
  fi
  if [ "$preflight_warn_count" -gt 0 ]; then
    warn "自检有 $preflight_warn_count 条警告，构建继续（可能影响某些 target）。"
  fi
  say ''
}

if [ -z "$SKIP_PREFLIGHT" ]; then
  run_preflight
else
  warn "已用 --skip-preflight 跳过前置环境自检，失败时可能难以诊断。"
fi

# ---------------------------------------------------------------------------
# 平台校验
# ---------------------------------------------------------------------------
case "$TARGET" in
  ios)
    [ "$(uname -s)" = "Darwin" ] || die "iOS 构建只能在 macOS 上做（需要 Xcode）。
       当前系统：$(uname -s)。本脚本不提供跨平台偷偷打包的路径。"
    ;;
  windows)
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) : ;;
      *) die "Windows 产物只能在 Windows 上构建（当前：$(uname -s)）。" ;;
    esac
    ;;
esac

if [ -n "$DO_CLEAN" ]; then
  say '[0/3] flutter clean ...'
  run_cmd run_flutter clean || die "flutter clean 失败。"
fi

# ---------------------------------------------------------------------------
# 组装 flutter build
# ---------------------------------------------------------------------------
ARGS=(build)
DART_DEFINES=()
[ -n "$SERVER_URL" ] && DART_DEFINES+=("--dart-define=BASE_URL=$SERVER_URL")
[ -n "$VERBOSE" ] && ARGS+=("$VERBOSE")

case "$TARGET" in
  apk)     ARGS+=(apk --"$BUILD_MODE") ;;
  aab)     ARGS+=(appbundle --"$BUILD_MODE") ;;
  windows) ARGS+=(windows --"$BUILD_MODE") ;;
  ios)     ARGS+=(ios --"$BUILD_MODE" --no-codesign) ;;
esac

# ★ 双轨 ABI 注入（仅 apk / aab 有意义）★
#   emulator → android-x64    真机装不上，但 x86_64 AVD 只认这个
#   device   → android-arm64  绝大多数真机
#   all      → 不带参数（全 ABI）
#   为什么要显式指定而不是让 Flutter 自己来：Flutter 默认会为**每个** ABI 下载
#   一份引擎 jar（各 100MB+），首次构建看起来像卡死 15 分钟。单 ABI 能省掉这部分。
ABI_DESC=""
TARGET_PLATFORM=""
case "$TARGET" in
  apk|aab)
    case "$ABI_TIER" in
      emulator) TARGET_PLATFORM="android-x64";   ABI_DESC="x86_64（模拟器 AVD）" ;;
      device)   TARGET_PLATFORM="android-arm64"; ABI_DESC="arm64-v8a（真机）" ;;
      all)      TARGET_PLATFORM="";              ABI_DESC="全部 ABI（arm64-v8a + armeabi-v7a + x86_64，最慢）" ;;
    esac
    [ -n "$TARGET_PLATFORM" ] && ARGS+=("--target-platform" "$TARGET_PLATFORM")
    ;;
  *)
    # windows / ios 不吃 --target-platform，但如果用户显式传了非默认档位就提醒一下
    if [ "$ABI_TIER" != "device" ]; then
      warn "--target $ABI_TIER 对 $TARGET 无效（只影响 apk / aab），已忽略。"
    fi
    ABI_DESC="不适用（$TARGET）"
    ;;
esac

[ -n "$SPLIT" ] && ARGS+=("$SPLIT")
# 空数组在 `set -u` 下的展开行为随 bash 版本而异，显式判空最稳
[ ${#DART_DEFINES[@]} -gt 0 ] && ARGS+=("${DART_DEFINES[@]}")

say "[1/3] 构建目标：$TARGET（$BUILD_MODE）"
say "        目标 ABI：$ABI_DESC"
[ -n "$SERVER_URL" ] && say "        编入服务端地址：$SERVER_URL（长期生效，直到下次覆盖构建）"
say "[2/3] $FLUTTER ${ARGS[*]}"

if [ -n "$DRY_RUN" ]; then
  say '[dry-run] 到此为止，未真正构建。'
  exit 0
fi

run_flutter "${ARGS[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  # ---- 失败信息可诊断化：不猜原因，但把「下一步该看什么」摆到眼前 ----
  say '' >&2
  printf '[诊断] 构建失败（退出码 %s）。按下面顺序排查：\n' "$rc" >&2
  case "$TARGET" in
    apk|aab)
      say '  1) 是否缺引擎/依赖构件（最常见）：加 --offline 重跑同一命令' >&2
      say '       它能立刻把「需要联网下载但没下到」的构件名直接报出来，比正常构建的日志清楚得多。' >&2
      say "       例：$FLUTTER build apk --$BUILD_MODE ${TARGET_PLATFORM:+--target-platform $TARGET_PLATFORM} --offline" >&2
      say '     若报某 ABI 的 flutter 引擎 jar 缺失 → 通常是网络/代理问题，见下面第 3 条。' >&2
      say '  2) 是否是「看着卡死」而不是真死：' >&2
      say '       - 看 CPU：Gradle 编译期 CPU 会明显占用；若某 java 进程 CPU 恒 0% 且网络不动 → 大概率在等下载。' >&2
      say '       - 抓栈：jstack <该 java 进程 PID> | grep -A5 "SocketInputStream\|HttpClient"' >&2
      say '         停在 socket read 且长时间不返回 → 卡在下载，不是死锁。' >&2
      say '  3) 代理：Java/Gradle **不读** HTTP_PROXY 环境变量，' >&2
      say '     必须在 android/gradle.properties 的 org.gradle.jvmargs 里写 -Dhttp.proxyHost/-Dhttp.proxyPort。' >&2
      say '     症状：Gradle 下载进度恒 0 字节。' >&2
      say '  4) ABI 档位是否匹配设备：' >&2
      say "     当前档位 $ABI_TIER → $ABI_DESC" >&2
      say '     模拟器需 --target emulator，真机需 --target device，装错会 INSTALL_FAILED_NO_MATCHING_ABIS。' >&2
      ;;
    windows)
      say '  1) 报 C2338 / STL1011 → MSVC 太新，需 v143 工具集（见 windows/CMakeLists.txt 的注入）。' >&2
      say '  2) 报 C1083 atlstr.h → 漏装 ATL，用 VS Installer 补。' >&2
      say '  3) 报 Failed to install nuget package → nuget 不在**系统级** PATH，或 build/windows 缓存了旧路径：' >&2
      say '       rm -rf build/windows 后重试。' >&2
      ;;
    ios)
      say '  iOS 构建失败通常是 Xcode/签名问题；本脚本用 --no-codesign，真机分发需另配。' >&2
      ;;
  esac
  say '' >&2
  die "构建失败（退出码 $rc）。"
fi
say ''

# ---------------------------------------------------------------------------
# 产物定位与报告
# ---------------------------------------------------------------------------
# 移动端 Windows 产物是**目录**，其它是单文件；分别处理。
ARTIFACT=""
IS_DIR=""
case "$TARGET" in
  apk)
    # split-per-abi 会产出多个 apk，取目录整体
    if [ -n "$SPLIT" ]; then
      ARTIFACT="build/app/outputs/flutter-apk"
      IS_DIR=1
    else
      if [ "$BUILD_MODE" = "debug" ]; then
        ARTIFACT="build/app/outputs/flutter-apk/app-debug.apk"
      else
        ARTIFACT="build/app/outputs/flutter-apk/app-release.apk"
      fi
    fi ;;
  aab)     ARTIFACT="build/app/outputs/bundle/$BUILD_MODE/app-$BUILD_MODE.aab" ;;
  windows) ARTIFACT="build/windows/x64/runner/Release"
           IS_DIR=1 ;;
  ios)     ARTIFACT="build/ios/iphoneos/Runner.app"
           IS_DIR=1 ;;
esac

[ -e "$ARTIFACT" ] || die "构建成功但找不到产物：$ARTIFACT
       若 Flutter 改过输出目录结构，请检查 build/ 下的实际路径。"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    # ⚠️ Git Bash 下若 stdout 被重定向，sha256sum 可能报
    #   "failed to set file descriptor text/binary mode: Bad file descriptor"
    #   于是哈希算不出来。退化到 PowerShell 的 Get-FileHash，保证始终有值。
    local h
    h="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
    if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
  fi
  if command -v powershell >/dev/null 2>&1; then
    local win h2
    win="$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")"
    h2="$(powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 -Path '$win').Hash" 2>/dev/null | tr -d '\r\n ')"
    if [ -n "$h2" ]; then printf '%s' "$h2"; return 0; fi
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  printf '(无 sha256 工具)'
}

human_mb() {
  awk -v b="$1" 'BEGIN { printf "%.1f MB", b/1048576 }'
}

say '[3/3] 产物：'
if [ -n "$IS_DIR" ]; then
  size="$(du -sb "$ARTIFACT" 2>/dev/null | awk '{print $1}')"
  say "      目录 $ARTIFACT（$(human_mb "${size:-0}")）"
  if [ "$TARGET" = "windows" ]; then
    say ''
    say '      ⚠️ Windows 版必须**整个目录**一起分发，只拷 .exe 会闪退：'
    say '         目录内 flutter_windows.dll / WebView2Loader.dll 等缺一不可。'
    say '         运行前提：目标机装了 Microsoft Edge WebView2 Runtime。'
  fi
else
  bytes="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  say "      文件 $ARTIFACT（$(human_mb "${bytes:-0}")）"
  say "      sha256 $(sha256_of "$ARTIFACT")"
fi

# aab / apk 的签名提醒（自用场景下 debug 签名是既定事实，只提示不阻断）
if [ "$TARGET" = "aab" ] && [ ! -f android/key.properties ]; then
  say ''
  warn "没有 android/key.properties，本次用的是 debug 签名。"
  warn "自用没问题；但若以后换成正式 keystore，覆盖安装会报「应用未安装」，"
  warn "必须先卸载旧版。详见 docs/Android自用运行指南.md §4。"
fi

# ---------------------------------------------------------------------------
# 可选：复制到 --out
# ---------------------------------------------------------------------------
if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" || die "无法创建输出目录：$OUT_DIR"
  if [ -n "$IS_DIR" ]; then
    cp -r "$ARTIFACT" "$OUT_DIR/" || die "复制到 $OUT_DIR 失败。"
  else
    cp "$ARTIFACT" "$OUT_DIR/" || die "复制到 $OUT_DIR 失败。"
  fi
  say "      已复制到 $OUT_DIR"
fi

say ''
say '完成。安装/运行方式见 docs/Android自用运行指南.md §3。'
