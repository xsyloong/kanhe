#!/usr/bin/env bash
#
# 本地开发一键构建 / 安装 / 重启 mihomo。
#
# 默认行为：
#   1. 用当前工作区代码编译 linux 二进制（with_gvisor）
#   2. 用新二进制测试现有配置
#   3. 备份 /usr/local/bin/mihomo
#   4. 原子替换并重启 systemd 服务
#   5. 检查版本、服务状态、控制面板
#
# 常用：
#   ./scripts/dev-install.sh --build-only     # 只编译
#   ./scripts/dev-install.sh --yes            # 编译并安装，跳过确认
#   ./scripts/dev-install.sh --no-restart     # 安装但不重启
#   ./scripts/dev-install.sh --rollback       # 回滚到最近一次备份
#   ./scripts/dev-install.sh --dry-run        # 只打印将执行的命令
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVICE="${SERVICE:-mihomo}"
BINARY="${BINARY:-/usr/local/bin/mihomo}"
CONFIG_DIR="${CONFIG_DIR:-/etc/mihomo}"
BUILD_TAGS="${BUILD_TAGS:-with_gvisor}"
GOAMD64_OPT="${GOAMD64:-v3}"

BUILD_ONLY=0
SKIP_BUILD=0
NO_RESTART=0
SKIP_CONFIG_TEST=0
DRY_RUN=0
ASSUME_YES=0
ROLLBACK=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: scripts/dev-install.sh [选项]

  --build-only          只编译，不安装、不重启
  --skip-build          跳过编译，直接安装 bin/ 下已有产物
  --no-restart          安装后不重启服务
  --skip-config-test    跳过新二进制的配置测试
  --rollback            回滚到最近一次 /usr/local/bin/mihomo.bak.*
  --dry-run             只打印计划，不执行构建或系统修改
  --yes, -y             跳过确认
  -h, --help            显示帮助

可通过环境变量覆盖：
  SERVICE=mihomo               systemd 服务名
  BINARY=/usr/local/bin/mihomo 安装路径
  CONFIG_DIR=/etc/mihomo       配置目录
  BUILD_TAGS=with_gvisor       编译 tags
  GOAMD64=v3                   amd64 微架构等级（v1/v2/v3）
EOF
}

while (($#)); do
  case "$1" in
    --build-only)       BUILD_ONLY=1 ;;
    --skip-build)       SKIP_BUILD=1 ;;
    --no-restart)       NO_RESTART=1 ;;
    --skip-config-test) SKIP_CONFIG_TEST=1 ;;
    --rollback)         ROLLBACK=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    --yes|-y)           ASSUME_YES=1 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

cd "$ROOT_DIR"

# ---------- 平台 / 工具检查 ----------

[[ "$(uname -s)" == "Linux" ]] || die "这个脚本只处理 Linux + systemd"
command -v go >/dev/null 2>&1 || die "找不到 go，请先安装 Go 1.20+（生产建议 1.26.10+）"

case "$(uname -m)" in
  x86_64|amd64)
    GOOS=linux
    GOARCH=amd64
    ;;
  aarch64|arm64)
    GOOS=linux
    GOARCH=arm64
    GOAMD64_OPT=""
    ;;
  armv7l|armv6l)
    GOOS=linux
    GOARCH=arm
    GOARM="${GOARM:-7}"
    GOAMD64_OPT=""
    ;;
  *)
    die "暂不支持架构: $(uname -m)"
    ;;
esac

if [[ -n "$GOAMD64_OPT" && "$GOARCH" == "amd64" ]]; then
  if ! grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw avx2; then
    warn "当前 CPU 未检测到 AVX2，GOAMD64=v3 的二进制可能无法运行；可改用 GOAMD64=v1"
  fi
fi

GOVER="$(go env GOVERSION 2>/dev/null || true)"
log "Go: ${GOVER:-unknown}  目标: ${GOOS}/${GOARCH}${GOAMD64_OPT:+/$GOAMD64_OPT}"
if [[ -n "$GOVER" && "$GOVER" != "go1.26.10" && "$GOVER" != go1.27* ]]; then
  warn "当前 Go 不是 1.26.10+；生产环境建议使用最新安全补丁版本"
fi

if (( EUID == 0 )); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "非 root 运行需要 sudo"
  SUDO=(sudo)
fi

BUILD_OUT="$ROOT_DIR/bin/mihomo-${GOOS}-${GOARCH}${GOAMD64_OPT:+-$GOAMD64_OPT}"
VERSION="$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LDFLAGS="-X github.com/metacubex/mihomo/constant.Version=${VERSION} -X github.com/metacubex/mihomo/constant.BuildTime=${BUILD_TIME} -w -s -buildid="
BACKUP="${BINARY}.bak.$(date +%Y%m%d-%H%M%S)-$$"

run() {
  if (( DRY_RUN )); then
    printf '+ '; printf '%q ' "$@"; echo
  else
    "$@"
  fi
}

confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || die "非交互环境请加 --yes"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

build_binary() {
  [[ -d "$ROOT_DIR/bin" ]] || mkdir -p "$ROOT_DIR/bin"

  local env_args=(CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH")
  [[ -n "$GOAMD64_OPT" ]] && env_args+=(GOAMD64="$GOAMD64_OPT")
  [[ -n "${GOARM:-}" ]] && env_args+=(GOARM="$GOARM")

  local tag_args=()
  [[ -n "$BUILD_TAGS" ]] && tag_args=(-tags "$BUILD_TAGS")

  log "编译 $BUILD_OUT"
  log "版本 $VERSION"
  run env "${env_args[@]}" go build "${tag_args[@]}" -trimpath -ldflags "$LDFLAGS" -o "$BUILD_OUT" .
}

test_config() {
  (( SKIP_CONFIG_TEST )) && return 0
  [[ -r "$CONFIG_DIR/config.yaml" ]] || die "读不到 $CONFIG_DIR/config.yaml"

  log "测试配置 $CONFIG_DIR/config.yaml"
  # -t 只解析配置；非 root 运行时 cache.db 无写权限的 warning 可以忽略
  run "$BUILD_OUT" -d "$CONFIG_DIR" -t
}

verify_runtime() {
  log "版本"
  "$BINARY" -v || true

  if command -v curl >/dev/null 2>&1 && [[ -r "$CONFIG_DIR/config.yaml" ]]; then
    local controller secret
    controller="$(sed -n 's/^external-controller:[[:space:]]*//p' "$CONFIG_DIR/config.yaml" | head -1 | tr -d '"')"
    secret="$(sed -n 's/^secret:[[:space:]]*//p' "$CONFIG_DIR/config.yaml" | head -1 | tr -d '"')"

    if [[ "$controller" == 127.0.0.1:* || "$controller" == localhost:* ]]; then
      log "控制面板 http://$controller/version"
      if [[ -n "$secret" ]]; then
        curl -fsS --max-time 5 -H "Authorization: Bearer $secret" \
          "http://$controller/version" && echo || warn "控制面板检查失败（不影响进程运行）"
      else
        curl -fsS --max-time 5 "http://$controller/version" && echo || warn "控制面板检查失败（不影响进程运行）"
      fi
    fi
  fi

  if ip link show Meta >/dev/null 2>&1; then
    log "TUN 网卡 Meta 已存在"
  fi
}

wait_active() {
  local i
  for i in {1..20}; do
    "${SUDO[@]}" systemctl is-active --quiet "$SERVICE" && return 0
    sleep 0.5
  done
  return 1
}

rollback_to() {
  local backup="$1"
  [[ -f "$backup" ]] || die "备份不存在: $backup"

  log "回滚到 $backup"
  run "${SUDO[@]}" systemctl stop "$SERVICE" || true
  run "${SUDO[@]}" install -o root -g root -m 0755 "$backup" "$BINARY"
  run "${SUDO[@]}" systemctl start "$SERVICE" || true
  run "$BINARY" -v || true
}

do_rollback() {
  local backup
  backup="$(ls -1t "${BINARY}".bak.* 2>/dev/null | head -1 || true)"
  [[ -n "$backup" ]] || die "没有找到 ${BINARY}.bak.*"

  log "最近备份: $backup"
  confirm "确认回滚并重启 $SERVICE？" || exit 1
  if (( EUID != 0 )); then "${SUDO[@]}" -v; fi
  rollback_to "$backup"
}

print_plan() {
  cat <<EOF
将执行：

  cd $ROOT_DIR
  env CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH ${GOAMD64_OPT:+GOAMD64=$GOAMD64_OPT} \\
    go build ${BUILD_TAGS:+-tags "$BUILD_TAGS"} -trimpath \\
    -ldflags "$LDFLAGS" -o "$BUILD_OUT" .

  $BUILD_OUT -d "$CONFIG_DIR" -t

  ${SUDO[*]:+sudo }cp -a "$BINARY" "$BACKUP"
  ${SUDO[*]:+sudo }install -o root -g root -m 0755 "$BUILD_OUT" "${BINARY}.new"
  ${SUDO[*]:+sudo }mv "${BINARY}.new" "$BINARY"

  ${SUDO[*]:+sudo }systemctl restart "$SERVICE"
  "$BINARY" -v
EOF
}

# ---------- 主流程 ----------

if (( ROLLBACK )); then
  if (( DRY_RUN )); then
    backup="$(ls -1t "${BINARY}".bak.* 2>/dev/null | head -1 || true)"
    echo "将回滚到: ${backup:-<没有备份>}"
    echo "  ${SUDO[*]:+sudo }systemctl stop $SERVICE"
    echo "  ${SUDO[*]:+sudo }install -o root -g root -m 0755 $backup $BINARY"
    echo "  ${SUDO[*]:+sudo }systemctl start $SERVICE"
    exit 0
  fi
  do_rollback
  exit 0
fi

if (( DRY_RUN )); then
  print_plan
  exit 0
fi

if (( ! SKIP_BUILD )); then
  build_binary
fi

[[ -x "$BUILD_OUT" ]] || die "找不到可执行文件: $BUILD_OUT"

test_config

if (( BUILD_ONLY )); then
  log "只编译模式，未安装。产物: $BUILD_OUT"
  exit 0
fi

if (( EUID != 0 )); then
  "${SUDO[@]}" -v
fi

confirm "安装 $BUILD_OUT 到 $BINARY，并重启 $SERVICE？" || exit 1

if [[ -f "$BINARY" ]]; then
  log "备份 $BINARY -> $BACKUP"
  run "${SUDO[@]}" cp -a "$BINARY" "$BACKUP"
else
  warn "$BINARY 不存在，跳过备份"
fi

log "原子替换二进制"
run "${SUDO[@]}" install -o root -g root -m 0755 "$BUILD_OUT" "${BINARY}.new"
run "${SUDO[@]}" mv "${BINARY}.new" "$BINARY"

if (( NO_RESTART )); then
  log "已安装，未重启。需要时执行: systemctl restart $SERVICE"
  exit 0
fi

log "重启 $SERVICE"
if ! run "${SUDO[@]}" systemctl restart "$SERVICE"; then
  warn "重启失败，自动回滚"
  rollback_to "$BACKUP"
  exit 1
fi

if ! wait_active; then
  warn "服务未在 10 秒内进入 active，自动回滚"
  "${SUDO[@]}" systemctl status "$SERVICE" --no-pager -l || true
  "${SUDO[@]}" journalctl -u "$SERVICE" -n 50 --no-pager || true
  rollback_to "$BACKUP"
  exit 1
fi

# 防止二进制一启动就崩溃、systemd 又立刻拉起造成“看似 active”
sleep 2
if ! "${SUDO[@]}" systemctl is-active --quiet "$SERVICE"; then
  warn "服务启动后不稳定，自动回滚"
  "${SUDO[@]}" systemctl status "$SERVICE" --no-pager -l || true
  "${SUDO[@]}" journalctl -u "$SERVICE" -n 50 --no-pager || true
  rollback_to "$BACKUP"
  exit 1
fi

log "服务已启动"
"${SUDO[@]}" systemctl status "$SERVICE" --no-pager -l | head -20 || true

verify_runtime

log "完成。回滚命令: $0 --rollback"
