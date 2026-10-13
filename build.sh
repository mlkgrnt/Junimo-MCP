#!/bin/sh
# junimo-mcp 构建入口（本项目约定的统一入口，所有 dune 命令都从这里走）。
#
# 用法:
#   bash build.sh build          # dune build
#   bash build.sh runtest        # dune runtest
#   bash build.sh release        # dune build + 复制二进制到 release/junimo-mcp.exe
#   bash build.sh clean          # dune clean
#   bash build.sh exec -- ...    # 透传（一般直接用 exe 更省事）
#
# 要点（见 skill ocaml-windows-toolchain）：
# - 必须用受管 Cygwin bash（Git Bash 会改写 /cygdrive 参数）
# - MSYS2_ARG_CONV_EXCL='*' 抑制参数路径重写
# - pi-env.sh 里 unset 了沙箱的 rm 函数、设了 E 盘 TMP
# - OCAMLPATH 用 Windows 形式路径（dune 是原生程序）
# - 无条件清 _build/.lock（坑 3：陈旧锁导致莫名报错）
#
# 注意：本脚本面向 Windows（受管 Cygwin）环境；仓库路径从脚本自身位置推导。
# 默认值对应作者的受管工具链，可用环境变量覆盖：
#   JUNIMO_CYGWIN_BASH  受管 Cygwin bash 路径
#   JUNIMO_PI_ENV       pi-env.sh 的 Cygwin 路径
#   JUNIMO_OCAMLPATH    OCAMLPATH（Windows 形式）
# 如果你用的是标准 opam 环境（Linux/macOS/常规 Windows），直接 `dune build` 即可，无需本脚本。

set -e
cd "$(dirname "$0")"
REPO_DIR=$(pwd -W 2>/dev/null || pwd)
# 本仓库的 Cygwin 形式路径（供内层受管 bash 使用）：E:/xxx → /cygdrive/e/xxx
DRIVE=$(printf '%s' "$REPO_DIR" | cut -c1 | tr '[:upper:]' '[:lower:]')
CYG_DIR="/cygdrive/$DRIVE$(printf '%s' "$REPO_DIR" | cut -c3-)"

CYGWIN_BASH="${JUNIMO_CYGWIN_BASH:-E:/ocaml/opam/.cygwin/root/bin/bash.exe}"
PI_ENV="${JUNIMO_PI_ENV:-/cygdrive/e/ocaml/pi-env.sh}"
OCAMLPATH_WIN="${JUNIMO_OCAMLPATH:-E:\\ocaml\\pi\\lib}"

if [ "$1" = "release" ]; then
  MSYS2_ARG_CONV_EXCL='*' "$CYGWIN_BASH" --noprofile --norc -c "
    . '$PI_ENV' >/dev/null 2>&1
    cd '$CYG_DIR' || exit 1
    export OCAMLPATH='$OCAMLPATH_WIN'
    rm -f _build/.lock
    dune build
  "
  mkdir -p release
  # dune 产物是只读的，覆盖前先去掉目标只读位
  chmod u+w release/junimo-mcp.exe 2>/dev/null || true
  cp _build/default/bin/main.exe release/junimo-mcp.exe
  chmod u+w release/junimo-mcp.exe 2>/dev/null || true
  echo "release/junimo-mcp.exe 已更新"
  exit 0
fi

MSYS2_ARG_CONV_EXCL='*' "$CYGWIN_BASH" --noprofile --norc -c "
  . '$PI_ENV' >/dev/null 2>&1
  cd '$CYG_DIR' || exit 1
  export OCAMLPATH='$OCAMLPATH_WIN'
  rm -f _build/.lock
  dune $*
"
