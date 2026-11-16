#!/bin/sh
# Build with ignored local signing configuration, restoring the tracked profile on exit.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f build-profile.local.json5 ]; then
  echo "缺少 build-profile.local.json5：请先在 DevEco Studio 配置本机签名。" >&2
  exit 1
fi

BUILD_COMMAND="${HVIGORW:-hvigorw}"
DEVECO_CLI_FALLBACK=""
if ! command -v "$BUILD_COMMAND" >/dev/null 2>&1; then
  # 只装了 DevEco Studio 命令行（没有独立 hvigorw）时退回 devecocli，CI 仍走 hvigorw。
  DEVECO_CLI="${DEVECO_CLI:-$HOME/.deveco/bin/devecocli}"
  if [ -x "$DEVECO_CLI" ]; then
    DEVECO_CLI_FALLBACK="$DEVECO_CLI"
  else
    echo "找不到 hvigorw；请配置 DevEco SDK PATH、HVIGORW 或 DEVECO_CLI。" >&2
    exit 1
  fi
fi

umask 077
BACKUP=$(mktemp "${TMPDIR:-/tmp}/dsh-harmony-profile.XXXXXX")
cp -p build-profile.json5 "$BACKUP"
restore() { cp -p "$BACKUP" build-profile.json5; rm -f "$BACKUP"; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 600 build-profile.json5
cp build-profile.local.json5 build-profile.json5
if [ -n "$DEVECO_CLI_FALLBACK" ]; then
  # devecocli 的构建辅助进程与当前用户不同，umask 077 会让它自己的 .hvigor 变成不可写。
  ( umask 000; "$DEVECO_CLI_FALLBACK" build --build-mode debug "$@" )
else
  "$BUILD_COMMAND" --no-daemon assembleHap -p product=default -p buildMode=debug "$@"
fi
