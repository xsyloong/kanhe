#!/usr/bin/env bash
#
# 把上游 mihomo 同步到当前定制分支，并保留本地定制提交。
#
# 默认：把 upstream/Meta 合并进当前分支（适合已经推送、多人/多机使用的 dev 分支）。
# 也支持：--alpha、--tag、--rebase。
#
# 常用：
#   ./scripts/sync-upstream.sh                 # 合并 upstream/Meta
#   ./scripts/sync-upstream.sh --alpha         # 合并 upstream/Alpha
#   ./scripts/sync-upstream.sh --tag v1.19.33  # 合并指定 tag
#   ./scripts/sync-upstream.sh --dry-run       # 只看计划
#   ./scripts/sync-upstream.sh --no-test       # 跳过编译/测试
#   ./scripts/sync-upstream.sh --full-test     # go test ./...
#   ./scripts/sync-upstream.sh --push          # 成功后推送当前分支
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MetaCubeX/mihomo.git}"
CHANNEL="${CHANNEL:-Meta}"
TAG=""
REBASE=0
DRY_RUN=0
PUSH=0
RUN_TEST=1
FULL_TEST=0
ASSUME_YES=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: scripts/sync-upstream.sh [选项]

  --channel Meta|Alpha   上游分支（默认 Meta）
  --alpha                等价于 --channel Alpha
  --tag TAG              同步指定 tag，例如 v1.19.33
  --rebase               用 rebase 而不是 merge（会改写当前分支历史）
  --no-test              跳过 go build / go test
  --full-test            运行 go test ./...
  --push                 成功后推送当前分支
  --dry-run              只打印计划
  --yes, -y              推送前不确认
  -h, --help             显示帮助

说明：
  - 默认 merge，不会改写已推送的历史，适合长期维护的 dev 分支。
  - rebase 只建议用于私有 feature 分支；共享分支请用默认 merge。
  - 冲突时脚本会 abort，并保留 backup/pre-sync-* 备份分支。
  - 自动启用 git rerere，之后相同冲突会复用上次的解决方式。
EOF
}

while (($#)); do
  case "$1" in
    --channel) CHANNEL="${2:?missing value}"; shift ;;
    --alpha)   CHANNEL=Alpha ;;
    --tag)     TAG="${2:?missing value}"; shift ;;
    --rebase)  REBASE=1 ;;
    --no-test) RUN_TEST=0 ;;
    --full-test) FULL_TEST=1; RUN_TEST=1 ;;
    --push)    PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

[[ -z "$TAG" || "$CHANNEL" == "Meta" ]] || die "--tag 和 --alpha 不能同时使用"

cd "$ROOT_DIR"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "不在 git 仓库中"

CURRENT_BRANCH="$(git branch --show-current)"
[[ -n "$CURRENT_BRANCH" ]] || die "当前是 detached HEAD，请先切到分支"
[[ -z "$(git status --porcelain)" ]] || die "工作区有未提交修改，请先 commit 或 stash"

if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "Meta" || "$CURRENT_BRANCH" == "Alpha" ]]; then
  warn "当前分支是 $CURRENT_BRANCH，通常不应该在这里合入上游；建议在 dev 或 feature 分支操作"
fi

# 记住冲突解决方式
if [[ "$(git config --bool rerere.enabled 2>/dev/null || true)" != "true" ]]; then
  log "启用 git rerere（记住冲突解决）"
  git config rerere.enabled true
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  log "添加 upstream: $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi

if [[ -n "$TAG" ]]; then
  log "拉取 upstream tag $TAG"
  git fetch --no-tags upstream "refs/tags/$TAG:refs/tags/$TAG"
  TARGET="$TAG"
else
  log "拉取 upstream/$CHANNEL"
  git fetch --no-tags upstream "refs/heads/$CHANNEL:refs/remotes/upstream/$CHANNEL"
  TARGET="upstream/$CHANNEL"
fi

git rev-parse --verify "$TARGET^{commit}" >/dev/null 2>&1 || die "找不到目标: $TARGET"

if git merge-base --is-ancestor "$TARGET" HEAD; then
  log "$CURRENT_BRANCH 已经包含 $TARGET，无需同步"
  exit 0
fi

BACKUP="backup/pre-sync-$(date +%Y%m%d-%H%M%S)-$$"
UPSTREAM_NEW="$(git rev-list --count HEAD.."$TARGET")"
CUSTOM_NEW="$(git rev-list --count "$TARGET"..HEAD)"

log "当前分支: $CURRENT_BRANCH"
log "目标: $TARGET"
log "上游新增提交: $UPSTREAM_NEW"
log "本地独有提交: $CUSTOM_NEW"
log "备份分支: $BACKUP"

if (( DRY_RUN )); then
  if (( REBASE )); then
    echo "将执行: git rebase $TARGET"
  else
    echo "将执行: git merge --no-ff --no-edit $TARGET"
  fi
  if (( RUN_TEST )); then
    echo "将执行: go build ./... && go test ./adapter/... ./tunnel/... ./dns/... ./rules/..."
  fi
  if (( FULL_TEST )); then
    echo "将执行: go test ./..."
  fi
  if (( PUSH )); then
    echo "将执行: git push origin $CURRENT_BRANCH"
  fi
  exit 0
fi

git branch "$BACKUP" HEAD

if (( REBASE )); then
  warn "rebase 会改写 $CURRENT_BRANCH 的历史；共享分支请改用默认 merge"
  if ! git rebase "$TARGET"; then
    git rebase --abort || true
    die "rebase 冲突，已 abort。备份: $BACKUP；请手动 rebase 解决"
  fi
else
  if ! git merge --no-ff --no-edit "$TARGET"; then
    conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ' || true)"
    git merge --abort || true
    die "merge 冲突，已 abort。冲突文件: ${conflicts:-unknown}；备份: $BACKUP"
  fi
fi

if (( RUN_TEST )); then
  log "编译"
  go build ./...

  log "测试"
  if (( FULL_TEST )); then
    go test ./...
  else
    go test ./adapter/... ./tunnel/... ./dns/... ./rules/...
  fi
fi

log "同步完成"
log "上游新提交: $UPSTREAM_NEW，本地独有提交: $CUSTOM_NEW"
git --no-pager diff --stat "$TARGET"...HEAD || true

if (( PUSH )); then
  if (( ! ASSUME_YES )); then
    [[ -t 0 ]] || die "非交互环境推送请加 --yes"
    read -r -p "推送 $CURRENT_BRANCH 到 origin？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
  fi

  if (( REBASE )); then
    git push --force-with-lease origin "$CURRENT_BRANCH"
  else
    git push origin "$CURRENT_BRANCH"
  fi
fi

log "完成。需要撤销本次同步: git reset --hard $BACKUP"
