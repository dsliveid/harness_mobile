#!/usr/bin/env bash
#
# harness_mobile 启动脚本（调试）
# 用法：./run.sh [选项] [-- 透传给 flutter 的参数...]   （Windows：run.cmd）
#
# ⚠️ 默认目标是 Windows 桌面（团队日常调试都在 Windows 上）：
#    ./run.sh                    → flutter run -d windows
#    要跑安卓请显式加 --android 或 --device <id>，不要指望它自动切。
#
# 选项：
#   --android            用第一个在线安卓设备（adb devices 里 state=device 的）
#   --device ID          指定设备（等价 flutter run -d ID；ID=windows 即桌面）
#   --emulator ID        先 flutter emulators --launch ID，再 run
#   --server-url URL     通过 --dart-define=BASE_URL=URL 注入服务端地址
#                        （启动即生效，不覆盖你已保存的地址）
#   --adb-reverse [PORT] 先跑 adb reverse tcp:PORT tcp:PORT（默认 5611），
#                        真机 USB 调试时让手机 localhost 直通电脑；失败只警告不阻断
#   --release            以 release 模式运行（默认 debug，支持热重载）
#   --profile            以 profile 模式运行
#   --clean              运行前 flutter clean
#   --check              运行前 flutter analyze（不阻断，仅提示）
#   --dry-run            只打印将要执行的命令，不真正启动
#   -v, --verbose        透传 flutter 的 --verbose
#   -h, --help           显示本帮助
#
# 其余参数放在 `--` 之后会原样透传给 flutter：
#   ./run.sh --android -- --dart-define=FOO=bar
#
# 停止：Ctrl+C。脚本用 exec 把控制权完全交给 flutter，所以 r/R 热重载、
# p 性能面板、q 退出等交互全部照常可用（绝不能管道或重定向 stdin，
# 非 TTY 会让 flutter 关闭交互模式，热重载直接失效）。
#
# 等价的手敲命令见 docs/Android自用运行指南.md §3。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 公共函数（本仓自包含，不跨仓库引用：三端是独立 git 仓库）
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

need_val() {
  [ $# -ge 2 ] || die "$1 需要一个参数值。"
}

# flutter 三级定位：FLUTTER_HOME → PATH → 本机既定安装路径
find_flutter() {
  local c
  if [ -n "${FLUTTER_HOME:-}" ]; then
    for c in "$FLUTTER_HOME/bin/flutter" "$FLUTTER_HOME/bin/flutter.bat"; do
      [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
  fi
  if command -v flutter >/dev/null 2>&1; then
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
FLUTTER_DIR="$(dirname "$FLUTTER")"

# adb 通常和 flutter 在同一个 bin 目录（本机实测如此），其次才看 PATH
find_adb() {
  local c
  for c in "$FLUTTER_DIR/adb.exe" "$FLUTTER_DIR/adb"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v adb 2>/dev/null && return 0
  return 1
}

usage() {
  # 从 shebang 后一行一直打到 `set -uo pipefail` 之前，去掉行首的 `# `。
  # 不写死行号：以后改注释不会让 --help 截断或越界。
  awk 'NR>1 && /^set -uo pipefail/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
  exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
DEVICE="windows"     # ⚠️ 默认 Windows 桌面调试（团队约定）
EMULATOR=""
USE_ANDROID=""
SERVER_URL=""
ADB_REVERSE=""
ADB_PORT="5611"
MODE=""              # 空 = flutter 默认 debug
DO_CLEAN=""
DO_CHECK=""
DRY_RUN=""
VERBOSE=""
PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --android)   USE_ANDROID=1 ;;
    --device)    need_val "$@"; DEVICE="$2"; shift ;;
    --device=*)  DEVICE="${1#*=}" ;;
    --emulator)  need_val "$@"; EMULATOR="$2"; shift ;;
    --emulator=*) EMULATOR="${1#*=}" ;;
    --server-url) need_val "$@"; SERVER_URL="$2"; shift ;;
    --server-url=*) SERVER_URL="${1#*=}" ;;
    --adb-reverse)
      ADB_REVERSE=1
      # 可选的端口：仅当下一个参数是纯数字时吃掉它（否则它会当成未知参数报错）
      if [ $# -ge 2 ] && printf '%s' "$2" | grep -qE '^[0-9]+$'; then
        ADB_PORT="$2"; shift
      fi ;;
    --release)   MODE="--release" ;;
    --profile)   MODE="--profile" ;;
    --debug)     MODE="--debug" ;;
    --clean)     DO_CLEAN=1 ;;
    --check)     DO_CHECK=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -v|--verbose) VERBOSE="--verbose" ;;
    -h|--help)   usage ;;
    --)          shift; PASSTHRU=("$@"); break ;;
    *)           die "未知参数：$1（用 --help 看用法；要透传给 flutter 请放在 -- 之后）" ;;
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
# 0. 前置：flutter clean / analyze
# ---------------------------------------------------------------------------
if [ -n "$DO_CLEAN" ]; then
  say '[0/3] flutter clean ...'
  run_cmd "$FLUTTER" clean || die "flutter clean 失败。"
fi

if [ -n "$DO_CHECK" ]; then
  say '[0/3] flutter analyze（仅提示，不阻断）...'
  run_cmd "$FLUTTER" analyze || warn "flutter analyze 有告警，继续启动。"
fi

# ---------------------------------------------------------------------------
# 1. 可选：先起模拟器
# ---------------------------------------------------------------------------
if [ -n "$EMULATOR" ]; then
  say "[1/3] 启动模拟器 $EMULATOR ..."
  run_cmd "$FLUTTER" emulators --launch "$EMULATOR" || die "模拟器 $EMULATOR 启动失败。"
  # 模拟器冷启动需要时间，否则 flutter run 会报「找不到设备」
  [ -n "$DRY_RUN" ] || sleep 5
  DEVICE=""   # 交给 flutter 自己选（模拟器刚起来，让它挑）
fi

# ---------------------------------------------------------------------------
# 2. 设备解析
# ---------------------------------------------------------------------------
if [ -n "$USE_ANDROID" ]; then
  ADB="$(find_adb)" || die "找不到 adb。请用 --device <id> 手动指定设备
       （设备列表：flutter devices）。"
  if [ -n "$DRY_RUN" ]; then
    # dry-run 不真连设备：只需展示命令拼装结果，不该因为当前没插手机就失败
    DEVICE="<第一个在线安卓设备>"
    say "安卓设备：$DEVICE（dry-run，未实际探测）"
  else
    # 取第一个 state=device 的序列号；unauthorized / offline 的跳过
    ANDROID_ID="$("$ADB" devices 2>/dev/null | awk '$2=="device"{print $1; exit}')"
    [ -n "$ANDROID_ID" ] || die "没有在线的安卓设备。
       请确认：1) USB 调试已开 2) 手机上已点「允许 USB 调试」
       或是先用 --emulator <id> 起一个模拟器。"
    DEVICE="$ANDROID_ID"
    say "安卓设备：$DEVICE"
  fi
fi

# ---------------------------------------------------------------------------
# 3. 可选：adb reverse（真机 USB 调试最稳的连通方式）
# ---------------------------------------------------------------------------
if [ -n "$ADB_REVERSE" ]; then
  ADB="$(find_adb)" || { warn "找不到 adb，跳过 --adb-reverse。"; ADB=""; }
  if [ -n "$ADB" ]; then
    say "[2/3] adb reverse tcp:$ADB_PORT tcp:$ADB_PORT ..."
    if run_cmd "$ADB" reverse "tcp:$ADB_PORT" "tcp:$ADB_PORT"; then
      say "      手机上的 localhost:$ADB_PORT 已转发到本机。"
    else
      # 模拟器/未连真机时会失败，这不是致命错误：地址还可以手填 10.0.2.2 或局域网 IP
      warn "adb reverse 失败（模拟器或未连接真机时正常），不影响启动。"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. 组装 flutter run
# ---------------------------------------------------------------------------
RUN_ARGS=(run)
[ -n "$DEVICE" ] && RUN_ARGS+=(-d "$DEVICE")
[ -n "$MODE" ] && RUN_ARGS+=("$MODE")
[ -n "$VERBOSE" ] && RUN_ARGS+=("$VERBOSE")

if [ -n "$SERVER_URL" ]; then
  RUN_ARGS+=("--dart-define=BASE_URL=$SERVER_URL")
  say "注入服务端地址：$SERVER_URL（仅本次运行生效，不改已保存配置）"
fi

# 用户透传参数放最后，可覆盖上面的默认
[ ${#PASSTHRU[@]} -gt 0 ] && RUN_ARGS+=("${PASSTHRU[@]}")

say "[3/3] 启动：$FLUTTER ${RUN_ARGS[*]}"
say "      （Ctrl+C 停止；r 热重载 / R 热重启 / q 退出）"
say ''

if [ -n "$DRY_RUN" ]; then
  say "[dry-run] 到此为止，未真正启动。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. exec：让 flutter 独占终端，保住交互模式（热重载依赖 TTY）
#
# 不 exec 的后果：脚本成了父进程，flutter 的 stdin 变成管道 → 检测不到 TTY
# → 关闭交互，r/R/q 全部失效，看起来像「脚本把 flutter 搞坏了」。
# ---------------------------------------------------------------------------
case "$FLUTTER" in
  *.bat|*.cmd)
    # Git Bash 里 .bat 需要 cmd 中转；用 exec 保证信号直达、不留中间 shell
    exec cmd //c "$FLUTTER" "${RUN_ARGS[@]}" ;;
  *)
    exec "$FLUTTER" "${RUN_ARGS[@]}" ;;
esac
