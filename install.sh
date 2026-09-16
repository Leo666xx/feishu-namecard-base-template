#!/usr/bin/env bash
set -euo pipefail

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[失败]\033[0m %s\n' "$*"; exit 1; }

info "检查运行环境..."
command -v node >/dev/null 2>&1 || fail "请先安装 Node.js：https://nodejs.org/"
command -v npm >/dev/null 2>&1 || fail "请先安装 npm"
command -v git >/dev/null 2>&1 || fail "请先安装 git"

if ! command -v lark-cli >/dev/null 2>&1; then
  info "未检测到 lark-cli，正在安装 @larksuite/cli ..."
  npm install -g @larksuite/cli
  ok "lark-cli 安装完成"
else
  ok "已检测到 lark-cli，跳过安装"
fi

warn "下一步将打开浏览器，完成飞书登录与权限授权。"
warn "如果你还没有飞书账号或没有相应权限，请先在浏览器完成登录。"

lark-cli auth login --recommend

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/init.sh" ]; then
  info "开始初始化飞书 Base..."
  bash "$SCRIPT_DIR/init.sh"
else
  fail "未找到 init.sh，请确认项目目录正确。"
fi

ok "安装与初始化已完成。"
ok "接下来请在飞书中补齐 AI Agent 节点和可选字段配置，详见 README.md。"
