#!/usr/bin/env bash
#
# 拍照自动上传飞书多维表格 —— 一键初始化脚本
#
# 用法：
#   1. 安装 CLI：      npm install -g @larksuite/cli
#   2. 授权：          lark-cli auth login
#   3. 运行初始化：    ./init.sh
#
# 脚本会在当前登录用户的飞书里创建一个和「名片信息智能管理系统」结构一致的 Base：
#   - 数据表「名片表」（含 17 个字段）
#   - 7 个「字段插件」（姓名/职位/公司/电话/邮箱/地址/备注 的 LLM 补全）
#   - 表单视图「拍照识别名片信息」
#   - 网格视图「全部名片」+ 过滤（隐藏多图记录）
#   - 工作流「多图自动拆分为多行」
#
# 需要手动配置的部分（脚本无法代劳，见 README.md）：
#   - 识别工作流里的「AI Agent」节点（看图识别的核心 prompt/模型/工具）
#   - 3 个字段类型 not_support 的字段（WhatsApp破冰 / 背调状态 / 开发信2）
#   - 主字段：脚本用「姓名」做主字段（原 Base 主字段是公式「名片ID」）
#
set -euo pipefail

# ===== 可调参数 =====
BASE_NAME="${BASE_NAME:-名片信息智能管理系统}"
TABLE_NAME="名片表"
FORM_NAME="拍照识别名片信息"
VIEW_NAME="全部名片"
SPLIT_WORKFLOW_TITLE="多图自动拆分为多行"
TIME_ZONE="Asia/Shanghai"

# ===== 幂等化：如果已存在同名 Base，则直接复用 =====
EXISTING_BASE_TOKEN="$(lark-cli base +base-list --as user -q ".data[] | select(.name == \"$BASE_NAME\") | .base_token" | head -n 1 || true)"
if [ -n "$EXISTING_BASE_TOKEN" ] && [ "$EXISTING_BASE_TOKEN" != "null" ]; then
  info "已检测到同名 Base：$BASE_NAME（base_token=$EXISTING_BASE_TOKEN），跳过重复创建。"
  printf '\n  已复用现有 Base，不会重复创建。\n'
  exit 0
fi

# ===== 路径 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFS_DIR="$SCRIPT_DIR/defs"

# ===== 输出辅助 =====
info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[失败]\033[0m %s\n' "$*"; exit 1; }

# ===== 0. 前置检查 =====
command -v lark-cli >/dev/null 2>&1 \
  || fail "未找到 lark-cli。请先执行：npm install -g @larksuite/cli && lark-cli auth login"
[ -f "$DEFS_DIR/fields.json" ] || fail "缺少 $DEFS_DIR/fields.json"

info "=================================================="
info " 开始创建 Base：$BASE_NAME"
info "=================================================="

# ===== 1. 创建 Base + 名片表 + 基础字段 =====
info "1/8 创建 Base 与「$TABLE_NAME」（含基础字段）..."
CREATE_IDS="$(lark-cli base +base-create \
  --name "$BASE_NAME" \
  --table-name "$TABLE_NAME" \
  --fields "@$DEFS_DIR/fields.json" \
  --time-zone "$TIME_ZONE" \
  --as user \
  -q '(.data.base.base_token) + "|" + (.data.table.id) + "|" + (.data.table.views[0].id)')"
IFS='|' read -r BASE_TOKEN TABLE_ID VIEW_ID <<< "$CREATE_IDS"
[ -n "$BASE_TOKEN" ] && [ "$BASE_TOKEN" != "null" ] || fail "未能解析 base_token"
[ -n "$TABLE_ID" ]   && [ "$TABLE_ID" != "null" ]   || fail "未能解析 table_id"
ok "Base 创建完成：token=$BASE_TOKEN，表=$TABLE_ID"

# 解析「名片图片」字段 ID（表单题目 + 拆分工作流都要用）
ATTACH_ID="$(lark-cli base +field-get \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --field-id "名片图片" \
  --as user -q '.data.field.id')"
[ -n "$ATTACH_ID" ] && [ "$ATTACH_ID" != "null" ] || fail "未能解析「名片图片」字段 ID"

# ===== 2. 重命名默认视图为「全部名片」 =====
info "2/8 重命名默认视图为「$VIEW_NAME」..."
if [ -n "$VIEW_ID" ] && [ "$VIEW_ID" != "null" ]; then
  lark-cli base +view-rename \
    --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
    --view-id "$VIEW_ID" --name "$VIEW_NAME" --as user >/dev/null
else
  VIEW_ID="$(lark-cli base +view-list --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --as user \
    -q '.data.views[] | select(.type=="grid") | .id' | head -n 1)"
  lark-cli base +view-rename \
    --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
    --view-id "$VIEW_ID" --name "$VIEW_NAME" --as user >/dev/null
fi
ok "视图已重命名（view=$VIEW_ID）"

# ===== 3. 创建公式字段（名片ID / 图片数量） =====
info "3/8 创建公式字段「名片ID」「图片数量」..."
lark-cli base +field-create \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --json "@$DEFS_DIR/formula-fields.json" --i-have-read-guide --as user >/dev/null
ok "公式字段已创建"

# ===== 4. 配置 7 个字段插件 =====
info "4/8 配置字段插件（LLM 补全，7 个）..."
set_ext() {
  local field_name="$1" prompt_json="$2"
  lark-cli base +field-extension-update \
    --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
    --field-id "$field_name" --json "$prompt_json" --as user --yes >/dev/null
}
set_ext "姓名" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"field_ref","field":"图片解析"},{"type":"text","text":"提取名片中已识别的有效姓名，姓名空格需要被写入"}]}}'
set_ext "职位" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"text","text":"提取名片中已识别的有效职位"},{"type":"field_ref","field":"图片解析"}]}}'
set_ext "公司" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"field_ref","field":"图片解析"},{"type":"text","text":"提取名片中已识别的有效公司名称"}]}}'
set_ext "电话" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"text","text":"提取名片中已识别的有效电话"},{"type":"field_ref","field":"图片解析"}]}}'
set_ext "邮箱" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"field_ref","field":"图片解析"},{"type":"text","text":"提取名片中已识别的有效邮箱"}]}}'
set_ext "地址" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"field_ref","field":"图片解析"},{"type":"text","text":"提取名片中已识别的有效地址"}]}}'
set_ext "备注" '{"extension_id":"builtin_llm_completion","inputs":{"prompt":[{"type":"field_ref","field":"图片解析"},{"type":"text","text":"提取名片中已识别的有效手写备注"}]}}'
ok "7 个字段插件已配置"

# ===== 5. 创建表单视图「拍照识别名片信息」 =====
info "5/8 创建表单「$FORM_NAME」..."
FORM_ID="$(lark-cli base +form-create \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" \
  --name "$FORM_NAME" \
  --description "请上传需要识别的名片图片，提交后系统将自动处理。" \
  --as user -q '.data.id')"
[ -n "$FORM_ID" ] || fail "未能解析 form_id"
# form-create 会自动把所有字段都加为题目，这里先把「名片图片」改成标题/必填/描述
lark-cli base +form-questions-update \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --form-id "$FORM_ID" \
  --questions "[{\"id\":\"$ATTACH_ID\",\"title\":\"请上传名片图片\",\"description\":\"请拍摄清晰的名片照片并上传，系统将自动完成后续识别，一次最多上传5张照片。\",\"required\":true}]" \
  --as user >/dev/null
# 只保留「名片图片」一个可见题目，其余字段隐藏
lark-cli base +view-set-visible-fields \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "$FORM_ID" \
  --json "{\"visible_fields\":[\"$ATTACH_ID\"]}" \
  --as user >/dev/null
ok "表单已创建（form=$FORM_ID）"

# ===== 6. 设置「全部名片」视图过滤：隐藏多图记录 =====
info "6/8 设置视图过滤（图片数量 < 2，隐藏多图记录）..."
lark-cli base +view-set-filter \
  --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "$VIEW_ID" \
  --json '{"logic":"and","conditions":[["图片数量","<",2]]}' --as user >/dev/null
ok "视图过滤已设置"

# ===== 7. 创建工作流「多图自动拆分为多行」 =====
info "7/8 创建工作流「$SPLIT_WORKFLOW_TITLE」..."
CLIENT_TOKEN="split-$(date +%s)"
WORKFLOW_JSON="$(mktemp)"
sed -e "s/__ATTACHMENT_FIELD_ID__/${ATTACH_ID}/g" \
    -e "s/__CLIENT_TOKEN__/${CLIENT_TOKEN}/g" \
    "$DEFS_DIR/split-workflow.json" > "$WORKFLOW_JSON"

WFLOW_ID="$(lark-cli base +workflow-create \
  --base-token "$BASE_TOKEN" --json "@$WORKFLOW_JSON" --as user -q '.data.workflow_id')"
rm -f "$WORKFLOW_JSON"
[ -n "$WFLOW_ID" ] || fail "未能解析 workflow_id"

lark-cli base +workflow-enable \
  --base-token "$BASE_TOKEN" --workflow-id "$WFLOW_ID" --as user >/dev/null
ok "工作流已创建并启用（workflow=$WFLOW_ID）"

# ===== 8. 完成 =====
ok "=================================================="
ok " 初始化完成！"
ok "=================================================="
BASE_URL="$(lark-cli base +base-get --base-token "$BASE_TOKEN" --as user -q '.data.base.url')"
printf '\n  Base 地址：%s\n' "$BASE_URL"
printf '  表：%s\n' "$TABLE_NAME"
printf '  表单：%s\n' "$FORM_NAME"
printf '  工作流：%s（已启用）\n' "$SPLIT_WORKFLOW_TITLE"
printf '\n'
warn "仍需手动完成（详见 README.md）："
warn "  1. 识别工作流「拍照识别名片信息」里的 AI Agent 节点（看图识别核心）"
warn "  2. 可选：在飞书 UI 把主字段改为公式「名片ID」"
warn "  3. 可选：3 个 not_support 字段（WhatsApp破冰 / 背调状态 / 开发信2）"
