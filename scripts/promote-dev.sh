#!/usr/bin/env bash
#
# 把定制分支（默认 dev）合并到发布分支（默认 main）。
#
# 常用：
#   ./scripts/promote-dev.sh --dry-run
#   ./scripts/promote-dev.sh                 # 本地合并 + 测试
#   ./scripts/promote-dev.sh --push          # 合并 + 测试 + 推送 main
#   ./scripts/promote-dev.sh --tag v1.20.0 --push
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${SOURCE:-dev}"
TARGET="${TARGET:-main}"
TAG=""
PUSH=0
RUN_TEST=1
FULL_TEST=0
DRY_RUN=0
ASSUME_YES=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: scripts/promote-dev.sh [选项]

  --source BRANCH   定制分支（默认 dev）
  --target BRANCH   发布分支（默认 main）
  --tag TAG         合并成功后打 tag，例如 v1.20.0
  --push            推送 target（以及 tag）到 origin
  --no-test         跳过 go build / go test
  --full-test       运行 go test ./...
  --dry-run         只打印计划
  --yes, -y         推送/打 tag 前不确认
  -h, --help        显示帮助
EOF
}

while (($#)); do
  case "$1" in
    --source) SOURCE="${2:?missing value}"; shift ;;
    --target) TARGET="${2:?missing value}"; shift ;;
    --tag)    TAG="${2:?missing value}"; shift ;;
    --push)   PUSH=1 ;;
    --no-test) RUN_TEST=0 ;;
    --full-test) FULL_TEST=1; RUN_TEST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
  shift
done

cd "$ROOT_DIR"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "不在 git 仓库中"
[[ -z "$(git status --porcelain)" ]] || die "工作区有未提交修改，请先 commit 或 stash"

log "拉取 origin"
git fetch origin --prune

ORIGINAL_BRANCH="$(git branch --show-current)"

if ! git rev-parse --verify "$SOURCE^{commit}" >/dev/null 2>&1; then
  if git rev-parse --verify "origin/$SOURCE^{commit}" >/dev/null 2>&1; then
    SOURCE="origin/$SOURCE"
  else
    die "找不到源分支: $SOURCE"
  fi
fi

if ! git rev-parse --verify "$TARGET^{commit}" >/dev/null 2>&1; then
  if git rev-parse --verify "origin/$TARGET^{commit}" >/dev/null 2>&1; then
    log "创建本地分支 $TARGET（跟踪 origin/$TARGET）"
    git branch --track "$TARGET" "origin/$TARGET"
  else
    die "找不到目标分支: $TARGET"
  fi
fi

if git merge-base --is-ancestor "$SOURCE" "$TARGET"; then
  log "$TARGET 已经包含 $SOURCE，无需合并"
  exit 0
fi

BACKUP="backup/pre-promote-$(date +%Y%m%d-%H%M%S)-$$"
log "源分支: $SOURCE"
log "目标分支: $TARGET"
log "备份分支: $BACKUP"
if [[ -n "$TAG" ]]; then
  log "发布 tag: $TAG"
fi

if (( DRY_RUN )); then
  echo "将执行: git checkout $TARGET"
  echo "将执行: git branch $BACKUP $TARGET"
  echo "将执行: git merge --no-ff --no-edit $SOURCE"
  if (( RUN_TEST )); then
    echo "将执行: go build ./... && go test ./adapter/... ./tunnel/... ./dns/... ./rules/..."
  fi
  if (( FULL_TEST )); then
    echo "将执行: go test ./..."
  fi
  if (( PUSH )); then
    echo "将执行: git push origin $TARGET"
  fi
  if [[ -n "$TAG" ]]; then
    echo "将执行: git tag -a $TAG && git push origin $TAG"
  fi
  exit 0
fi

git checkout "$TARGET"

# 确保本地目标分支至少和 origin 同步；分叉时直接停下，避免把错误历史推上去
if git rev-parse --verify "origin/$TARGET" >/dev/null 2>&1; then
  if git merge-base --is-ancestor "$TARGET" "origin/$TARGET"; then
    git merge --ff-only "origin/$TARGET"
  elif ! git merge-base --is-ancestor "origin/$TARGET" "$TARGET"; then
    die "本地 $TARGET 与 origin/$TARGET 已分叉，请先手动处理"
  fi
fi

git branch "$BACKUP" HEAD

if ! git merge --no-ff --no-edit "$SOURCE"; then
  conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ' || true)"
  git merge --abort || true
  git checkout "$ORIGINAL_BRANCH" || true
  die "merge 冲突，已 abort。冲突文件: ${conflicts:-unknown}；备份: $BACKUP"
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

log "合并完成"
git --no-pager log --oneline -5

if (( PUSH )); then
  if (( ! ASSUME_YES )); then
    [[ -t 0 ]] || die "非交互环境推送请加 --yes"
    read -r -p "推送 $TARGET${TAG:+ 和 tag $TAG} 到 origin？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
  fi

  git push origin "$TARGET"

  if [[ -n "$TAG" ]]; then
    if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
      die "tag 已存在: $TAG"
    fi
    git tag -a "$TAG" -m "release $TAG"
    git push origin "$TAG"
  fi
fi

log "完成。撤销本次合并: git checkout $TARGET && git reset --hard $BACKUP"
