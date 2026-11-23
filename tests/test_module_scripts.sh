#!/usr/bin/env bash
# tests/test_module_scripts.sh
# 验证 OpenList-Magisk 模块脚本中的 Token 提取、offline.conf 配置合并与桥接、
# 伴侣菜单可见性联动、control.sh 钩子、旧版升级解包及卸载保留逻辑

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_SH="$REPO_ROOT/OpenList-Magisk/service.sh"
ACTION_SH="$REPO_ROOT/OpenList-Magisk/action.sh"
CUSTOMIZE_SH="$REPO_ROOT/OpenList-Magisk/customize.sh"
UNINSTALL_SH="$REPO_ROOT/OpenList-Magisk/uninstall.sh"
UNINSTALL_USER_SH="$REPO_ROOT/OpenList-Magisk/uninstall-user.sh"
CONTROL_SH="$REPO_ROOT/OpenList-Magisk/control.sh"
MODULE_PROP="$REPO_ROOT/OpenList-Magisk/module.prop"
UPDATE_JSON="$REPO_ROOT/update.json"
WEBROOT_INDEX="$REPO_ROOT/OpenList-Magisk/webroot/index.html"
WEBROOT_APP_JS="$REPO_ROOT/OpenList-Magisk/webroot/app.js"

FAILED=0
TOTAL=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $message"
    else
        echo "  [FAIL] $message: expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        echo "  [PASS] $message"
    else
        echo "  [FAIL] $message: file '$file' does not match pattern '$pattern'"
        FAILED=$((FAILED + 1))
    fi
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        echo "  [FAIL] $message: file '$file' unexpectedly matches pattern '$pattern'"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] $message"
    fi
}

assert_all_kv_lines() {
    local output="$1"
    local message="$2"
    TOTAL=$((TOTAL + 1))
    if [ -z "$output" ]; then
        echo "  [FAIL] $message: output is empty"
        FAILED=$((FAILED + 1))
        return
    fi
    local bad_line=""
    bad_line=$(printf '%s\n' "$output" | grep -vE '^[A-Za-z0-9_]+=' | head -n 1 || true)
    if [ -z "$bad_line" ]; then
        echo "  [PASS] $message"
    else
        echo "  [FAIL] $message: unexpected non-kv stdout line '$bad_line'"
        FAILED=$((FAILED + 1))
    fi
}

b64_encode() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

# 测试环境临时目录
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

echo "=== 开始测试 OpenList-Magisk 模块脚本 ==="

# 准备模拟数据环境
export DATA_DIR="$TEST_TMP/openlist_data"
export LOG_FILE="$TEST_TMP/service.log"
export OPENLIST_LOG="$TEST_TMP/openlist.log"
export BRIDGE_TMP_CONF="$TEST_TMP/local_tmp/openlist_offline.conf"
export HELPER_DATA_DIR="$TEST_TMP/data_io_openlist_helper"
mkdir -p "$DATA_DIR"
mkdir -p "$TEST_TMP/local_tmp"
mkdir -p "$HELPER_DATA_DIR"

# 引入 service.sh 中的函数
# 注意：service.sh 内部有脚本自执行保护，被 source 时不会执行主进程
if [ ! -f "$SERVICE_SH" ]; then
    echo "错误：未找到 $SERVICE_SH"
    exit 1
fi
# shellcheck disable=SC1090
. "$SERVICE_SH"

# -------------------------------------------------------------
# 测试 1: 纯二进制/grep 降级提取 OpenList Token (剥离连续 string 列值)
# -------------------------------------------------------------
echo ""
echo "-> 测试 1: 纯二进制无 sqlite3 环境提取 Token"
MOCK_TOKEN="openlist-6d91b7d6-0b6e-4766-9bc2-680f599c9b59SbVfjghkfiP64UbC0i8apymduCgubSoMsgfKm1bHIFeXhmytpXSGHRsKhpd8e6IX"
# 写入含有 SQLite 连续字段 (token+value+string) 的模拟二进制 data.db
printf "\x00\x01\xFE\xFF\x80\x90token%sstring\x00\x12\x34\x56" "$MOCK_TOKEN" > "$DATA_DIR/data.db"

EXTRACTED_BIN_TOKEN=$(extract_openlist_token)
assert_eq "$MOCK_TOKEN" "$EXTRACTED_BIN_TOKEN" "从纯二进制 data.db 正确提取 openlist-* Token 并剥离尾部 string"

# -------------------------------------------------------------
# 测试 2: sqlite3 环境提取 OpenList Token (如果系统安装了 sqlite3)
# -------------------------------------------------------------
echo ""
echo "-> 测试 2: 使用 sqlite3 数据库表提取 Token"
if command -v sqlite3 >/dev/null 2>&1; then
    SQL_MOCK_TOKEN="openlist-sqliteTestToken9876543210zyx"
    rm -f "$DATA_DIR/data.db"
    sqlite3 "$DATA_DIR/data.db" "CREATE TABLE x_setting_items (key TEXT, value TEXT);"
    sqlite3 "$DATA_DIR/data.db" "INSERT INTO x_setting_items (key, value) VALUES ('token', '$SQL_MOCK_TOKEN');"

    EXTRACTED_SQL_TOKEN=$(extract_openlist_token)
    assert_eq "$SQL_MOCK_TOKEN" "$EXTRACTED_SQL_TOKEN" "从 SQLite 数据库表 x_setting_items 正确提取 Token"
else
    echo "  [SKIP] 当前环境无 sqlite3 命令，跳过 SQLite 表查询测试"
fi

# -------------------------------------------------------------
# 测试 3: offline.conf 首次不存在时自动生成默认配置并填充 Token 与 Port
# -------------------------------------------------------------
echo ""
echo "-> 测试 3: offline.conf 首次不存在时自动初始化并同步"
rm -f "$DATA_DIR/offline.conf"
rm -f "$BRIDGE_TMP_CONF"
rm -f "$HELPER_DATA_DIR/files/offline.conf"

# 运行同步逻辑，指定端口为 5244
sync_companion_apk_and_config "5244"

assert_file_contains "$DATA_DIR/offline.conf" "^HOST=127.0.0.1" "offline.conf 包含 HOST=127.0.0.1"
assert_file_contains "$DATA_DIR/offline.conf" "^PORT=5244" "offline.conf 包含 PORT=5244"
assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=openlist-" "offline.conf 自动填充提取到的有效 Token"
assert_file_contains "$DATA_DIR/offline.conf" "^PATH=/115/影视/" "offline.conf 默认目标路径为 /115/影视/"
assert_file_contains "$DATA_DIR/offline.conf" "^TOOL=115 Open" "offline.conf 默认离线下载引擎 (Offline Engine) 为 115 Open"
assert_file_contains "$DATA_DIR/offline.conf" "^DELETE_POLICY=delete_on_upload_succeed" "offline.conf 默认删除策略为 delete_on_upload_succeed"
assert_file_contains "$DATA_DIR/offline.conf" "^PRESET_PATHS=/115/影视/,/115/" "offline.conf 包含预设路径列表"

# 验证桥接文件已生成
assert_file_contains "$BRIDGE_TMP_CONF" "^PATH=/115/影视/" "桥接到 /data/local/tmp 成功且内容一致"
assert_file_contains "$HELPER_DATA_DIR/files/offline.conf" "^PATH=/115/影视/" "桥接到伴侣私有目录成功且内容一致"

# -------------------------------------------------------------
# 测试 4: 端口变化时自动更新 PORT
# -------------------------------------------------------------
echo ""
echo "-> 测试 4: OpenList 端口变更时动态更新 PORT"
sync_companion_apk_and_config "5249"

assert_file_contains "$DATA_DIR/offline.conf" "^PORT=5249" "offline.conf 中的 PORT 已更新为 5249"
assert_file_contains "$BRIDGE_TMP_CONF" "^PORT=5249" "桥接文件中的 PORT 同步更新为 5249"

# -------------------------------------------------------------
# 测试 5: 保留用户自定义配置（路径、策略、自定义 Token 等）
# -------------------------------------------------------------
echo ""
echo "-> 测试 5: 用户自定义配置保护（不被启动脚本覆盖）"
cat > "$DATA_DIR/offline.conf" << 'EOF'
# 用户自定义配置
HOST=192.168.1.100
PORT=5244
TOKEN=user-manual-custom-token-123
PATH=/115/动漫剧场/
TOOL=115 Open
DELETE_POLICY=delete_never
PRESET_PATHS=/115/动漫剧场/,/115/电影/
EOF

# 即使检测到的运行端口是 5244，数据库里是另一个 token
sync_companion_apk_and_config "5244"

assert_file_contains "$DATA_DIR/offline.conf" "^HOST=192.168.1.100" "保留自定义 HOST"
assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=user-manual-custom-token-123" "非空已有 TOKEN 不被覆盖"
assert_file_contains "$DATA_DIR/offline.conf" "^PATH=/115/动漫剧场/" "保留自定义 PATH"
assert_file_contains "$DATA_DIR/offline.conf" "^DELETE_POLICY=delete_never" "保留自定义 DELETE_POLICY"
assert_file_contains "$DATA_DIR/offline.conf" "^PRESET_PATHS=/115/动漫剧场/,/115/电影/" "保留自定义 PRESET_PATHS"

# -------------------------------------------------------------
# 测试 6: 用户仅配置了部分字段，缺失字段被平滑补齐且不影响已有字段
# -------------------------------------------------------------
echo ""
echo "-> 测试 6: 缺失字段平滑补全"
cat > "$DATA_DIR/offline.conf" << 'EOF'
PATH=/115/纪录片/
EOF

sync_companion_apk_and_config "5244"

assert_file_contains "$DATA_DIR/offline.conf" "^PATH=/115/纪录片/" "保留原本唯一的自定义 PATH"
assert_file_contains "$DATA_DIR/offline.conf" "^TOOL=115 Open" "补全 TOOL=115 Open"
assert_file_contains "$DATA_DIR/offline.conf" "^PORT=5244" "补全 PORT=5244"
assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=openlist-" "补全提取到的 TOKEN"

# -------------------------------------------------------------
# 测试 7: 历史被污染的 TOKEN=...string 自动清洗
# -------------------------------------------------------------
echo ""
echo "-> 测试 7: 历史被污染的 TOKEN=...string 自动清洗"
POLLUTED_TOKEN="openlist-6d91b7d6-0b6e-4766-9bc2-680f599c9b59SbVfjghkfiP64UbC0i8apymduCgubSoMsgfKm1bHIFeXhmytpXSGHRsKhpd8e6IXstring"
CLEANED_TOKEN="openlist-6d91b7d6-0b6e-4766-9bc2-680f599c9b59SbVfjghkfiP64UbC0i8apymduCgubSoMsgfKm1bHIFeXhmytpXSGHRsKhpd8e6IX"

# 构造含有该 Token 的二进制 data.db
printf "\x00\x01\xFE\xFF\x80\x90token%sstring\x00\x12\x34\x56" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"

cat > "$DATA_DIR/offline.conf" << EOF
HOST=127.0.0.1
PORT=5244
TOKEN=$POLLUTED_TOKEN
PATH=/115/影视/
TOOL=115 Open
DELETE_POLICY=delete_on_upload_succeed
PRESET_PATHS=/115/影视/,/115/
EOF

# 运行同步逻辑
sync_companion_apk_and_config "5244"

assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=$CLEANED_TOKEN$" "offline.conf 中被污染的 TOKEN 尾部 string 被成功剥除"
assert_file_contains "$BRIDGE_TMP_CONF" "^TOKEN=$CLEANED_TOKEN$" "桥接配置中的 TOKEN 尾部 string 同步被剥除"
assert_file_contains "$HELPER_DATA_DIR/files/offline.conf" "^TOKEN=$CLEANED_TOKEN$" "伴侣私有目录配置中的 TOKEN 尾部 string 同步被剥除"

# 7b: 验证若 data.db 缺失时，offline.conf 中被污染的 TOKEN 仍被就地剥离 string 后缀
rm -f "$DATA_DIR/data.db"
cat > "$DATA_DIR/offline.conf" << EOF
HOST=127.0.0.1
PORT=5244
TOKEN=openlist-noDbPollutedTokenTest123456789string
PATH=/115/影视/
TOOL=115 Open
DELETE_POLICY=delete_on_upload_succeed
PRESET_PATHS=/115/影视/,/115/
EOF
sync_companion_apk_and_config "5244"
assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=openlist-noDbPollutedTokenTest123456789$" "无 data.db 时 offline.conf 中的 TOKEN 尾部 string 就地剥除"

# 7c: 验证含 CRLF (\r\n) 换行符的 offline.conf 中被污染的 TOKEN 尾部 string 仍被正确剥除
printf "HOST=127.0.0.1\r\nPORT=5244\r\nTOKEN=openlist-crlfPollutedTokenTest123456789string\r\nPATH=/115/影视/\r\nTOOL=115 Open\r\nDELETE_POLICY=delete_on_upload_succeed\r\nPRESET_PATHS=/115/影视/,/115/\r\n" > "$DATA_DIR/offline.conf"
sync_companion_apk_and_config "5244"
assert_file_contains "$DATA_DIR/offline.conf" "^TOKEN=openlist-crlfPollutedTokenTest123456789" "CRLF 换行符下 offline.conf 中的 TOKEN 尾部 string 成功剥除"

# -------------------------------------------------------------
# 测试 8: 开机存储自动重载函数 reload_openlist_storages 测试
# -------------------------------------------------------------
echo ""
echo "-> 测试 8: 开机存储自动重载逻辑"
RELOAD_DELAY=0 reload_openlist_storages "5244"
sleep 0.2
assert_file_contains "$LOG_FILE" "存储重载" "服务成功触发或记录存储重载逻辑"

# -------------------------------------------------------------
# 准备公共模拟工具目录 (供后续测试共享)
# -------------------------------------------------------------
MOCK_BIN_DIR="$TEST_TMP/mock_bin"
PM_LOG="$TEST_TMP/pm_calls.log"
FAKE_RUNNING="$TEST_TMP/fake_openlist_running"
mkdir -p "$MOCK_BIN_DIR"
cat > "$MOCK_BIN_DIR/pm" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$PM_LOG"
if [ "\$1" = "path" ]; then
    echo "package:/data/app/io.openlist.helper/base.apk"
    exit 0
fi
exit 0
EOF
cat > "$MOCK_BIN_DIR/ip" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$MOCK_BIN_DIR/ss" << 'EOF'
#!/usr/bin/env bash
echo "tcp LISTEN 0 128 *:5244 *:* users:((\"openlist\",pid=99999,fd=3))"
EOF
cat > "$MOCK_BIN_DIR/getprop" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "ro.product.cpu.abi" ]; then
    echo "arm64-v8a"
else
    echo "1"
fi
EOF
cat > "$MOCK_BIN_DIR/pgrep" << EOF
#!/usr/bin/env bash
if [ -f "$FAKE_RUNNING" ]; then
    echo "99999"
    exit 0
fi
exit 1
EOF
cat > "$MOCK_BIN_DIR/pkill" << EOF
#!/usr/bin/env bash
rm -f "$FAKE_RUNNING"
exit 0
EOF
cat > "$MOCK_BIN_DIR/ps" << EOF
#!/usr/bin/env bash
if [ -f "$FAKE_RUNNING" ]; then
    exit 0
fi
exit 1
EOF
cat > "$MOCK_BIN_DIR/busybox" << EOF
#!/usr/bin/env bash
cmd="\$1"
shift
case "\$cmd" in
    pgrep)
        if [ -f "$FAKE_RUNNING" ]; then
            echo "99999"
            exit 0
        fi
        exit 1
        ;;
    pkill)
        rm -f "$FAKE_RUNNING"
        exit 0
        ;;
    sed)
        exec sed "\$@"
        ;;
    *)
        exec "\$cmd" "\$@"
        ;;
esac
EOF
chmod +x "$MOCK_BIN_DIR/pm" "$MOCK_BIN_DIR/ip" "$MOCK_BIN_DIR/ss" "$MOCK_BIN_DIR/getprop" \
         "$MOCK_BIN_DIR/pgrep" "$MOCK_BIN_DIR/pkill" "$MOCK_BIN_DIR/ps" "$MOCK_BIN_DIR/busybox"
export PATH="$MOCK_BIN_DIR:$PATH"

# -------------------------------------------------------------
# 测试 9: uninstall.sh 默认保留数据 vs .delete_data_on_uninstall 删数据 + clean_companion 始终清理
# -------------------------------------------------------------
echo ""
echo "-> 测试 9: uninstall.sh 数据默认保留策略与伴侣始终清理逻辑"
assert_file_contains "$UNINSTALL_SH" "rm -f /data/local/tmp/openlist_offline\.conf" "uninstall.sh clean_companion 包含清理 /data/local/tmp/openlist_offline.conf"
assert_file_contains "$UNINSTALL_SH" '\.delete_data_on_uninstall' "uninstall.sh 支持 .delete_data_on_uninstall 显式删数据标记"

UNINST_MOD="$TEST_TMP/uninst_mod"
UNINST_DATA="$TEST_TMP/uninst_data"
UNINST_SVC_D="$TEST_TMP/uninst_service_d"
mkdir -p "$UNINST_MOD/bin" "$UNINST_DATA" "$UNINST_SVC_D"
cp "$UNINSTALL_SH" "$UNINST_MOD/uninstall.sh"
cp "$SERVICE_SH" "$UNINST_MOD/service.sh"
sed -i "s|__PLACEHOLDER_DATA_DIR__|$UNINST_DATA|g" "$UNINST_MOD/service.sh"
sed -i "s|__PLACEHOLDER_BINARY_PATH__|\$MODDIR/bin/openlist|g" "$UNINST_MOD/service.sh"
touch "$UNINST_MOD/bin/openlist"
echo "PATH=/115/保留测试/" > "$UNINST_DATA/offline.conf"
echo "dbdata" > "$UNINST_DATA/data.db"
touch "$UNINST_SVC_D/openlist_companion_sync.sh"

MOCK_TMP_CONF="/data/local/tmp/openlist_offline.conf"
if [ -w "/data/local/tmp" ] 2>/dev/null; then
    touch "$MOCK_TMP_CONF" 2>/dev/null || true
fi

# 9a: 默认无 .delete_data_on_uninstall -> 保留 $DATA_DIR 与 $DATA_DIR/offline.conf，但伴侣始终被清理
rm -f "$UNINST_MOD/.delete_data_on_uninstall" "$FAKE_RUNNING"
: > "$PM_LOG"
MODPATH="$UNINST_MOD" SERVICE_D_DIR="$UNINST_SVC_D" sh "$UNINST_MOD/uninstall.sh" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [ -d "$UNINST_DATA" ] && [ -f "$UNINST_DATA/offline.conf" ] && [ -f "$UNINST_DATA/data.db" ]; then
    echo "  [PASS] 无 .delete_data_on_uninstall 时 uninstall.sh 默认保留 DATA_DIR 与 offline.conf"
else
    echo "  [FAIL] 无 .delete_data_on_uninstall 时 uninstall.sh 意外删除了数据目录"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
if [ ! -f "$UNINST_MOD/bin/openlist" ]; then
    echo "  [PASS] uninstall.sh 正常清理二进制文件"
else
    echo "  [FAIL] uninstall.sh 未清理二进制文件"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
if [ ! -f "$UNINST_SVC_D/openlist_companion_sync.sh" ]; then
    echo "  [PASS] 数据保留模式下 clean_companion 仍清理 openlist_companion_sync.sh"
else
    echo "  [FAIL] 数据保留模式下 clean_companion 未清理 openlist_companion_sync.sh"
    FAILED=$((FAILED + 1))
fi
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "数据保留模式下 clean_companion 仍禁用 ProcessTextActivity"
assert_file_contains "$PM_LOG" "^uninstall io\.openlist\.helper$" "数据保留模式下 clean_companion 仍卸载 io.openlist.helper"

if [ -w "/data/local/tmp" ] 2>/dev/null; then
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$MOCK_TMP_CONF" ]; then
        echo "  [PASS] 成功清理 /data/local/tmp/openlist_offline.conf"
    else
        echo "  [FAIL] 未能清理 /data/local/tmp/openlist_offline.conf"
        FAILED=$((FAILED + 1))
    fi
fi

# 9b: 存在 .delete_data_on_uninstall -> 删除 $DATA_DIR 及 $DATA_DIR/offline.conf，同时清理伴侣
if [ ! -d "/data/adb/openlist" ] && [ ! -d "/sdcard/Android/openlist" ]; then
    touch "$UNINST_MOD/.delete_data_on_uninstall"
    touch "$UNINST_SVC_D/openlist_companion_sync.sh"
    : > "$PM_LOG"
    MODPATH="$UNINST_MOD" SERVICE_D_DIR="$UNINST_SVC_D" sh "$UNINST_MOD/uninstall.sh" >/dev/null 2>&1

    TOTAL=$((TOTAL + 1))
    if [ ! -d "$UNINST_DATA" ] && [ ! -f "$UNINST_DATA/offline.conf" ]; then
        echo "  [PASS] 存在 .delete_data_on_uninstall 时 uninstall.sh 删除 DATA_DIR 与 offline.conf"
    else
        echo "  [FAIL] 存在 .delete_data_on_uninstall 时 uninstall.sh 未删除 DATA_DIR"
        FAILED=$((FAILED + 1))
    fi
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$UNINST_SVC_D/openlist_companion_sync.sh" ]; then
        echo "  [PASS] 删数据模式下 clean_companion 同样清理 openlist_companion_sync.sh"
    else
        echo "  [FAIL] 删数据模式下 clean_companion 未清理 openlist_companion_sync.sh"
        FAILED=$((FAILED + 1))
    fi
    assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "删数据模式下 clean_companion 禁用 ProcessTextActivity"
    assert_file_contains "$PM_LOG" "^uninstall io\.openlist\.helper$" "删数据模式下 clean_companion 卸载 io.openlist.helper"
else
    echo "  [SKIP] 宿主机存在真实 /data/adb/openlist 或 /sdcard/Android/openlist，跳过破坏性删数据测试"
fi

# -------------------------------------------------------------
# 测试 10: customize.sh 离线配置规范与 MIGRATE 执行顺序验证
# -------------------------------------------------------------
echo ""
echo "-> 测试 10: customize.sh 离线配置规范与 MIGRATE 顺序约束"
assert_file_contains "$CUSTOMIZE_SH" "offline\.conf" "customize.sh 包含 offline.conf 初始化逻辑"
assert_file_contains "$CUSTOMIZE_SH" "OpenListHelper\.apk" "customize.sh 包含 OpenListHelper.apk 权限与安装处理"
assert_file_contains "$CUSTOMIZE_SH" "chcon -R u:object_r:system_file:s0" "customize.sh 正确设置 SELinux 上下文"
assert_file_contains "$CUSTOMIZE_SH" "pm disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity" "customize.sh 安装伴侣后若服务未运行则默认隐藏菜单"
assert_file_contains "$CUSTOMIZE_SH" '\[ -w "\$DATA_DIR" \] && \[ ! -f "\$DATA_DIR/offline\.conf" \]' "customize.sh 仅在 DATA_DIR 可写且 offline.conf 不存在时初始化"
assert_file_contains "$CONTROL_SH" "grep -vx 'bin'" "control.sh migrate-core 要求目标目录不含非 bin 文件（印证顺序关键性）"

MIGRATE_EXEC_LINE=$(grep -n 'control\.sh" migrate-core' "$CUSTOMIZE_SH" | head -n 1 | cut -d: -f1)
MIGRATE_DONE_LINE=$(grep -n '迁移完成，旧目录已删除' "$CUSTOMIZE_SH" | head -n 1 | cut -d: -f1)
OFFLINE_INIT_LINE=$(grep -n 'cat > "\$DATA_DIR/offline\.conf"' "$CUSTOMIZE_SH" | head -n 1 | cut -d: -f1)
HELPER_SETUP_LINE=$(grep -n 'HELPER_APK="\$HELPER_DIR/OpenListHelper\.apk"' "$CUSTOMIZE_SH" | head -n 1 | cut -d: -f1)
HELPER_INSTALL_LINE=$(grep -n 'pm install -r "\$HELPER_APK"' "$CUSTOMIZE_SH" | head -n 1 | cut -d: -f1)

TOTAL=$((TOTAL + 1))
if [ -n "$MIGRATE_EXEC_LINE" ] && [ -n "$MIGRATE_DONE_LINE" ] && [ -n "$OFFLINE_INIT_LINE" ] && \
   [ "$MIGRATE_EXEC_LINE" -lt "$MIGRATE_DONE_LINE" ] && [ "$MIGRATE_DONE_LINE" -lt "$OFFLINE_INIT_LINE" ]; then
    echo "  [PASS] customize.sh 中 MIGRATE (L${MIGRATE_EXEC_LINE}-L${MIGRATE_DONE_LINE}) 严格早于 offline.conf 初始化 (L${OFFLINE_INIT_LINE})"
else
    echo "  [FAIL] customize.sh 中 MIGRATE 未严格早于 offline.conf 初始化 (migrate=${MIGRATE_EXEC_LINE}..${MIGRATE_DONE_LINE}, offline=${OFFLINE_INIT_LINE})"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
if [ -n "$MIGRATE_DONE_LINE" ] && [ -n "$HELPER_SETUP_LINE" ] && [ -n "$HELPER_INSTALL_LINE" ] && \
   [ "$MIGRATE_DONE_LINE" -lt "$HELPER_SETUP_LINE" ] && [ "$HELPER_SETUP_LINE" -lt "$HELPER_INSTALL_LINE" ]; then
    echo "  [PASS] customize.sh 中 MIGRATE (结束于 L${MIGRATE_DONE_LINE}) 严格早于 OpenListHelper.apk 配置与安装 (L${HELPER_SETUP_LINE}-L${HELPER_INSTALL_LINE})"
else
    echo "  [FAIL] customize.sh 中 MIGRATE 未严格早于 OpenListHelper.apk 配置与安装 (migrate_end=${MIGRATE_DONE_LINE}, helper=${HELPER_SETUP_LINE}..${HELPER_INSTALL_LINE})"
    FAILED=$((FAILED + 1))
fi

# -------------------------------------------------------------
# 测试 11: set_companion_menu_enabled / bridge_companion_offline_conf / refresh_companion_menu_visibility
# -------------------------------------------------------------
echo ""
echo "-> 测试 11: 伴侣辅助函数 (set_companion_menu_enabled / bridge / refresh)"
: > "$PM_LOG"
set_companion_menu_enabled 1
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper$" "启用菜单时先确保包体处于 enable 状态"
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "set_companion_menu_enabled 1 调用 pm enable ProcessTextActivity"

: > "$PM_LOG"
set_companion_menu_enabled 0
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "set_companion_menu_enabled 0 调用 pm disable ProcessTextActivity"

# 11b: bridge_companion_offline_conf 合约
DIRECT_CONF="$TEST_TMP/direct_offline.conf"
DIRECT_BRIDGE_TMP="$TEST_TMP/direct_bridge/openlist_offline.conf"
DIRECT_HELPER_DIR="$TEST_TMP/direct_helper_pkg"
mkdir -p "$DIRECT_HELPER_DIR"
cat > "$DIRECT_CONF" << 'EOF'
HOST=127.0.0.1
PORT=5244
PATH=/115 Cloud/直连桥接/
EOF
bridge_companion_offline_conf "$DIRECT_CONF" "$DIRECT_BRIDGE_TMP" "$DIRECT_HELPER_DIR"
assert_file_contains "$DIRECT_BRIDGE_TMP" "^PATH=/115 Cloud/直连桥接/$" "bridge_companion_offline_conf 成功同步至 bridge_tmp"
assert_file_contains "$DIRECT_HELPER_DIR/files/offline.conf" "^PATH=/115 Cloud/直连桥接/$" "bridge_companion_offline_conf 成功同步至 helper_pkg_dir/files/offline.conf"

# 缺失 conf_file 时静默返回 0
BRIDGE_MISS_RC=0
bridge_companion_offline_conf "$TEST_TMP/nonexistent_offline.conf" "$DIRECT_BRIDGE_TMP" "$DIRECT_HELPER_DIR" || BRIDGE_MISS_RC=$?
assert_eq "0" "$BRIDGE_MISS_RC" "bridge_companion_offline_conf 在源文件缺失时返回 0"

# 11c: refresh_companion_menu_visibility 合约 (check_running=1 未运行时禁用菜单)
rm -f "$FAKE_RUNNING"
: > "$PM_LOG"
refresh_companion_menu_visibility "5244" "1"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "refresh_companion_menu_visibility 在服务未运行时禁用菜单"

# -------------------------------------------------------------
# 测试 12: 模块处于 disable 状态时 sync_companion_apk_and_config 自动隐藏菜单
# -------------------------------------------------------------
echo ""
echo "-> 测试 12: 模块存在 disable 标记时同步逻辑自动禁用菜单"
MOCK_MODDIR="$TEST_TMP/mock_moddir"
mkdir -p "$MOCK_MODDIR"
export MODDIR="$MOCK_MODDIR"
export SERVICE_D_DIR="$TEST_TMP/service.d"

# 正常未禁用状态
rm -f "$MOCK_MODDIR/disable" "$MOCK_MODDIR/remove"
printf "\x00\x01/115115 Cloud\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
: > "$PM_LOG"
sync_companion_apk_and_config "5244"
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "模块未禁用时 sync_companion_apk_and_config 启用系统菜单"

# 创建 disable 标记文件
touch "$MOCK_MODDIR/disable"
: > "$PM_LOG"
sync_companion_apk_and_config "5244"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "模块存在 disable 文件时 sync_companion_apk_and_config 隐藏系统菜单"
rm -f "$MOCK_MODDIR/disable"

# -------------------------------------------------------------
# 测试 13: install_boot_companion_sync_guard 生成开机守卫并在模块禁用时隐藏菜单
# -------------------------------------------------------------
echo ""
echo "-> 测试 13: 开机守卫脚本 openlist_companion_sync.sh 生成与禁用检测"
GUARD_SCRIPT="$SERVICE_D_DIR/openlist_companion_sync.sh"
export OPENLIST_BINARY="$MOCK_MODDIR/bin/openlist"
install_boot_companion_sync_guard

TOTAL=$((TOTAL + 1))
if [ -x "$GUARD_SCRIPT" ]; then
    echo "  [PASS] 成功生成可执行的 openlist_companion_sync.sh"
else
    echo "  [FAIL] openlist_companion_sync.sh 未生成或不可执行"
    FAILED=$((FAILED + 1))
fi
assert_file_contains "$GUARD_SCRIPT" "^GUARD_MODDIR=" "开机守卫脚本使用 GUARD_MODDIR 避免与 service.sh 顶层变量同名冲突"
assert_file_contains "$GUARD_SCRIPT" "^GUARD_OPENLIST_BINARY=" "开机守卫脚本使用 GUARD_OPENLIST_BINARY 避免与 service.sh 顶层变量同名冲突"

touch "$MOCK_MODDIR/disable"
: > "$PM_LOG"
sh "$GUARD_SCRIPT"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "开机守卫检测到模块 disable 时自动隐藏菜单"
rm -f "$MOCK_MODDIR/disable"

# -------------------------------------------------------------
# 测试 14: action.sh 停止与启动服务时同步切换系统菜单可见性
# -------------------------------------------------------------
echo ""
echo "-> 测试 14: action.sh 启停服务时同步隐藏/显示系统菜单与品牌描述"
ACTION_TEST_DIR="$TEST_TMP/action_mod"
mkdir -p "$ACTION_TEST_DIR/bin"
cp "$ACTION_SH" "$ACTION_TEST_DIR/action.sh"
sed -i "s|__PLACEHOLDER_BINARY_PATH__|$ACTION_TEST_DIR/bin/openlist|g" "$ACTION_TEST_DIR/action.sh"
cat > "$ACTION_TEST_DIR/module.prop" << 'EOF'
id=openlist
description=init
EOF

# 创建模拟 service.sh 供 action.sh 启动调用
cat > "$ACTION_TEST_DIR/service.sh" << EOF
#!/usr/bin/env bash
touch "$FAKE_RUNNING"
exit 0
EOF
chmod +x "$ACTION_TEST_DIR/service.sh"

# 14a: 当前正在运行 -> 执行 action.sh 停止服务 -> 应调用 pm disable 并更新 module.prop
touch "$FAKE_RUNNING"
: > "$PM_LOG"
sh "$ACTION_TEST_DIR/action.sh" >/dev/null 2>&1
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "action.sh 停止服务后立即隐藏 115 离线系统菜单"
assert_file_contains "$ACTION_TEST_DIR/module.prop" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk" "action.sh 停止后更新 module.prop 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$ACTION_TEST_DIR/module.prop" "Alien-Et" "action.sh 停止后 module.prop 不包含 Alien-Et"

# 14b: 当前未运行 -> 执行 action.sh 启动服务 -> 应调用 pm enable
rm -f "$FAKE_RUNNING"
: > "$PM_LOG"
sh "$ACTION_TEST_DIR/action.sh" >/dev/null 2>&1
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "action.sh 启动服务成功后立即启用 115 离线系统菜单"

# -------------------------------------------------------------
# 测试 15: uninstall.sh clean_companion 函数（source 隔离调用）
# -------------------------------------------------------------
echo ""
echo "-> 测试 15: uninstall.sh clean_companion 单独调用清理守卫并卸载伴侣"
touch "$GUARD_SCRIPT"
: > "$PM_LOG"
(
    # shellcheck disable=SC1090
    . "$UNINSTALL_SH"
    SERVICE_D_DIR="$SERVICE_D_DIR" clean_companion >/dev/null
)

TOTAL=$((TOTAL + 1))
if [ ! -f "$GUARD_SCRIPT" ]; then
    echo "  [PASS] clean_companion 成功清理 openlist_companion_sync.sh"
else
    echo "  [FAIL] clean_companion 未清理 openlist_companion_sync.sh"
    FAILED=$((FAILED + 1))
fi
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "clean_companion 卸载前先禁用 ProcessTextActivity"
assert_file_contains "$PM_LOG" "^uninstall io\.openlist\.helper$" "clean_companion 调用 pm uninstall 卸载伴侣应用"

# -------------------------------------------------------------
# 测试 16: 真实 service.sh 预检失败隐藏菜单 & action.sh 启用后台守护时管道不阻塞
# -------------------------------------------------------------
echo ""
echo "-> 测试 16: service.sh 预检失败隐藏菜单及 action.sh 启动真实 service.sh (ENABLE_DISABLE_WATCHER=1) 不挂起管道"
assert_file_contains "$SERVICE_SH" "watch_module_disable_state </dev/null >/dev/null 2>&1 &" "watch_module_disable_state 重定向关闭标准输入输出与错误流"

# 部署真实 service.sh 到 ACTION_TEST_DIR
cp "$SERVICE_SH" "$ACTION_TEST_DIR/service.sh"
sed -i "s|__PLACEHOLDER_DATA_DIR__|$DATA_DIR|g" "$ACTION_TEST_DIR/service.sh"
sed -i "s|__PLACEHOLDER_BINARY_PATH__|$ACTION_TEST_DIR/bin/openlist|g" "$ACTION_TEST_DIR/service.sh"
chmod +x "$ACTION_TEST_DIR/service.sh"

# 16a: 预检失败（OPENLIST_BINARY 不存在）时应主动调用 set_companion_menu_enabled 0
rm -f "$ACTION_TEST_DIR/bin/openlist" "$FAKE_RUNNING"
: > "$PM_LOG"
(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    sh "$ACTION_TEST_DIR/service.sh" >/dev/null 2>&1 || true
)
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "service.sh 预检失败退出前确保隐藏 115 离线菜单"

# 16b: 准备模拟 openlist 守护进程（持续后台存活直到 FAKE_RUNNING 被移除）
cat > "$ACTION_TEST_DIR/bin/openlist" << EOF
#!/usr/bin/env bash
touch "$FAKE_RUNNING"
while [ -f "$FAKE_RUNNING" ]; do
    sleep 0.2
done
EOF
chmod +x "$ACTION_TEST_DIR/bin/openlist"

printf "\x00\x01/115115 Cloud\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
rm -f "$FAKE_RUNNING"
: > "$PM_LOG"

# 使用命令替换捕获输出；若后台子进程未关闭 stdout/stderr，此处会永久阻塞直到假进程结束
ACTION_RET=0
if command -v timeout >/dev/null 2>&1; then
    ACTION_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        ENABLE_DISABLE_WATCHER=1 WATCH_INTERVAL=1 RELOAD_DELAY=0 TOKEN_RETRY_MAX=1 \
            timeout 8 sh "$ACTION_TEST_DIR/action.sh" 2>&1
    ) || ACTION_RET=$?
else
    ACTION_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        ENABLE_DISABLE_WATCHER=1 WATCH_INTERVAL=1 RELOAD_DELAY=0 TOKEN_RETRY_MAX=1 \
            sh "$ACTION_TEST_DIR/action.sh" 2>&1
    ) || ACTION_RET=$?
fi

# 清理模拟后台守护进程
rm -f "$FAKE_RUNNING"
sleep 0.3

assert_eq "0" "$ACTION_RET" "ENABLE_DISABLE_WATCHER=1 时 output=\$(sh action.sh) 立即返回且不阻塞管道"
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "真实 service.sh 启动后启用 115 离线菜单"

# -------------------------------------------------------------
# 测试 17: ADR 0002 退役回归校验（确认已移除二进制补丁、WAL 锁清理与日志调优）
# -------------------------------------------------------------
echo ""
echo "-> 测试 17: ADR 0002 退役回归校验"
assert_file_not_contains "$SERVICE_SH" "patch_openlist_binary_sqlite_dsn" "service.sh 不再包含 patch_openlist_binary_sqlite_dsn"
assert_file_not_contains "$SERVICE_SH" "ensure_sqlite_wal_and_clean_locks" "service.sh 不再包含 ensure_sqlite_wal_and_clean_locks"
assert_file_not_contains "$SERVICE_SH" "optimize_openlist_config" "service.sh 不再包含 optimize_openlist_config"

for retired_fn in patch_openlist_binary_sqlite_dsn ensure_sqlite_wal_and_clean_locks optimize_openlist_config; do
    TOTAL=$((TOTAL + 1))
    if type "$retired_fn" >/dev/null 2>&1; then
        echo "  [FAIL] source service.sh 后仍意外定义了退役函数 $retired_fn"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] source service.sh 后未定义退役函数 $retired_fn"
    fi
done

# -------------------------------------------------------------
# 测试 18: has_enabled_115_storage 检测网盘状态与菜单可见性强绑定
# -------------------------------------------------------------
echo ""
echo "-> 测试 18: has_enabled_115_storage 存储状态校验与系统菜单可见性联动"

# 18a: data.db 无 115 网盘存储（仅本地存储）
printf "\x00\x01/localLocal\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
rm -f "$DATA_DIR/data.db-wal"
: > "$PM_LOG"
TOTAL=$((TOTAL + 1))
if ! has_enabled_115_storage "5244"; then
    echo "  [PASS] data.db 无 115 存储时 has_enabled_115_storage 返回非 0"
else
    echo "  [FAIL] data.db 无 115 存储时 has_enabled_115_storage 未返回非 0"
    FAILED=$((FAILED + 1))
fi
sync_companion_apk_and_config "5244"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "data.db 无 115 存储时 sync_companion_apk_and_config 禁用系统菜单"

# 18b: data.db 含有 115 存储但处于 disabled 状态
printf "\x00\x01/115115 Cloud\x1edisabled{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
rm -f "$DATA_DIR/data.db-wal"
: > "$PM_LOG"
TOTAL=$((TOTAL + 1))
if ! has_enabled_115_storage "5244"; then
    echo "  [PASS] data.db 115 存储禁用时 has_enabled_115_storage 返回非 0"
else
    echo "  [FAIL] data.db 115 存储禁用时 has_enabled_115_storage 未返回非 0"
    FAILED=$((FAILED + 1))
fi
sync_companion_apk_and_config "5244"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "data.db 115 存储禁用时 sync_companion_apk_and_config 禁用系统菜单"

# 18c: data.db 含有已启用的 115 存储
printf "\x00\x01/115115 Open\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
rm -f "$DATA_DIR/data.db-wal"
: > "$PM_LOG"
TOTAL=$((TOTAL + 1))
if has_enabled_115_storage "5244"; then
    echo "  [PASS] data.db 含有已启用 115 存储时 has_enabled_115_storage 返回 0"
else
    echo "  [FAIL] data.db 含有已启用 115 存储时 has_enabled_115_storage 未返回 0"
    FAILED=$((FAILED + 1))
fi
sync_companion_apk_and_config "5244"
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "data.db 含有已启用 115 存储时 sync_companion_apk_and_config 启用系统菜单"

# 18d: Live HTTP API /api/admin/storage/list 接口模拟测试 (Tier 1)
MOCK_HTTP_DIR="$TEST_TMP/mock_http_bin"
mkdir -p "$MOCK_HTTP_DIR"
cat > "$MOCK_HTTP_DIR/curl" << 'EOF'
#!/usr/bin/env bash
if [ -n "$MOCK_STORAGE_RESPONSE" ]; then
    echo "$MOCK_STORAGE_RESPONSE"
    exit 0
fi
exit 1
EOF
chmod +x "$MOCK_HTTP_DIR/curl"

TOTAL=$((TOTAL + 1))
RET=0
(
    export PATH="$MOCK_HTTP_DIR:$PATH"
    export MOCK_STORAGE_RESPONSE='{"code":200,"message":"success","data":{"content":[{"id":1,"driver":"Local","disabled":false}]}}'
    has_enabled_115_storage "5244"
) || RET=$?
if [ "$RET" -ne 0 ]; then
    echo "  [PASS] HTTP API 无 115 存储时 has_enabled_115_storage 返回非 0"
else
    echo "  [FAIL] HTTP API 无 115 存储时 has_enabled_115_storage 未返回非 0"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
RET=0
(
    export PATH="$MOCK_HTTP_DIR:$PATH"
    export MOCK_STORAGE_RESPONSE='{"code":200,"message":"success","data":{"content":[{"id":1,"driver":"115 Open","disabled":true}]}}'
    has_enabled_115_storage "5244"
) || RET=$?
if [ "$RET" -ne 0 ]; then
    echo "  [PASS] HTTP API 115 存储禁用时 has_enabled_115_storage 返回非 0"
else
    echo "  [FAIL] HTTP API 115 存储禁用时 has_enabled_115_storage 未返回非 0"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
RET=0
(
    export PATH="$MOCK_HTTP_DIR:$PATH"
    export MOCK_STORAGE_RESPONSE='{"code":200,"message":"success","data":{"content":[{"id":1,"driver":"115 Cloud","disabled":false}]}}'
    has_enabled_115_storage "5244"
) || RET=$?
if [ "$RET" -eq 0 ]; then
    echo "  [PASS] HTTP API 115 存储已启用时 has_enabled_115_storage 返回 0"
else
    echo "  [FAIL] HTTP API 115 存储已启用时 has_enabled_115_storage 未返回 0"
    FAILED=$((FAILED + 1))
fi

TOTAL=$((TOTAL + 1))
RET=0
(
    export PATH="$MOCK_HTTP_DIR:$PATH"
    export MOCK_STORAGE_RESPONSE='{"code":200,"message":"success","data":{"content":[{"id":1,"mount_path":"/本地存储","driver":"Local","disabled":false},{"id":2,"mount_path":"/115","driver":"115 网盘开放平台","status":"work","disabled":false},{"id":3,"mount_path":"/Google","driver":"GoogleDrive","disabled":false},{"id":4,"mount_path":"/quark","driver":"Quark Open","disabled":false}]}}'
    has_enabled_115_storage "5244"
) || RET=$?
if [ "$RET" -eq 0 ]; then
    echo "  [PASS] HTTP API 115 网盘开放平台启用时 has_enabled_115_storage 返回 0"
else
    echo "  [FAIL] HTTP API 115 网盘开放平台启用时 has_enabled_115_storage 未返回 0"
    FAILED=$((FAILED + 1))
fi

# 18e: watch_module_disable_state 在运行期动态根据 115 存储切换菜单可见性
touch "$FAKE_RUNNING"
: > "$PM_LOG"
printf "\x00\x01/115115 Open\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
WATCH_INTERVAL=0.1 watch_module_disable_state &
WATCH_PID=$!
sleep 0.3
# 动态切换为禁用
printf "\x00\x01/115115 Open\x1edisabled{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
sleep 0.3
# 动态切换回启用
printf "\x00\x01/115115 Open\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$DATA_DIR/data.db"
sleep 0.3
# 终止循环
rm -f "$FAKE_RUNNING"
wait "$WATCH_PID" 2>/dev/null || true
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "watch_module_disable_state 运行时检测到 115 存储启用调用 pm enable"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "watch_module_disable_state 运行时检测到 115 存储禁用动态调用 pm disable"

# -------------------------------------------------------------
# 测试 19: service.sh 纯字面量头部提取、sed -i 改写安全、环境变量覆盖与零副作用 source
# -------------------------------------------------------------
echo ""
echo "-> 测试 19: service.sh 字面量提取、sed -i 改写安全、env 覆盖与零副作用 source"

DATA_MATCHES=$(sed -n 's/^DATA_DIR="\(.*\)"/\1/p' "$SERVICE_SH")
BIN_MATCHES=$(sed -n 's/^OPENLIST_BINARY="\(.*\)"/\1/p' "$SERVICE_SH")
DATA_MATCH_COUNT=$(printf '%s\n' "$DATA_MATCHES" | grep -c . || true)
BIN_MATCH_COUNT=$(printf '%s\n' "$BIN_MATCHES" | grep -c . || true)
RAW_DATA_COUNT=$(grep -c '^DATA_DIR=' "$SERVICE_SH" || true)
RAW_BIN_COUNT=$(grep -c '^OPENLIST_BINARY=' "$SERVICE_SH" || true)

assert_eq "1" "$DATA_MATCH_COUNT" "service.sh 中 sed -n 提取 ^DATA_DIR=\"...\" 恰好返回 1 条匹配"
assert_eq "__PLACEHOLDER_DATA_DIR__" "$DATA_MATCHES" "service.sh 中 DATA_DIR 为纯字面量占位符（不含 \${VAR:-...}）"
assert_eq "1" "$BIN_MATCH_COUNT" "service.sh 中 sed -n 提取 ^OPENLIST_BINARY=\"...\" 恰好返回 1 条匹配"
assert_eq "__PLACEHOLDER_BINARY_PATH__" "$BIN_MATCHES" "service.sh 中 OPENLIST_BINARY 为纯字面量占位符（不含 \${VAR:-...}）"
assert_eq "1" "$RAW_DATA_COUNT" "service.sh 全文 ^DATA_DIR= 仅出现 1 次（不受 heredoc 干扰）"
assert_eq "1" "$RAW_BIN_COUNT" "service.sh 全文 ^OPENLIST_BINARY= 仅出现 1 次（不受 heredoc 干扰）"

# 19b: sed -i 改写安全测试
SED_SAFE_DIR="$TEST_TMP/svc_sed_safe"
mkdir -p "$SED_SAFE_DIR"
cp "$SERVICE_SH" "$SED_SAFE_DIR/service.sh"
sed -i 's|^DATA_DIR=.*|DATA_DIR="/data/adb/custom_openlist"|' "$SED_SAFE_DIR/service.sh"
sed -i 's|^OPENLIST_BINARY=.*|OPENLIST_BINARY="/data/adb/custom_bin/openlist"|' "$SED_SAFE_DIR/service.sh"

REWRITTEN_DATA=$(sed -n 's/^DATA_DIR="\(.*\)"/\1/p' "$SED_SAFE_DIR/service.sh")
REWRITTEN_BIN=$(sed -n 's/^OPENLIST_BINARY="\(.*\)"/\1/p' "$SED_SAFE_DIR/service.sh")
assert_eq "/data/adb/custom_openlist" "$REWRITTEN_DATA" "sed -i 改写 DATA_DIR 后提取值完全一致"
assert_eq "/data/adb/custom_bin/openlist" "$REWRITTEN_BIN" "sed -i 改写 OPENLIST_BINARY 后提取值完全一致"
assert_file_contains "$SED_SAFE_DIR/service.sh" 'GUARD_OPENLIST_BINARY="\$OPENLIST_BINARY"' "sed -i 改写后 heredoc 内 GUARD_OPENLIST_BINARY 保持完好"

BASH_SYNTAX_RC=0
bash -n "$SED_SAFE_DIR/service.sh" || BASH_SYNTAX_RC=$?
assert_eq "0" "$BASH_SYNTAX_RC" "sed -i 改写后的 service.sh 通过 bash -n 语法检查"

# 19c: 无 env 覆盖 vs 有 env 覆盖
NO_ENV_RES=$(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    bash -c '. "$1"; printf "%s|%s|%s\n" "$DATA_DIR" "$OPENLIST_BINARY" "${_ENV_DATA_DIR:-UNSET}"' _ "$SED_SAFE_DIR/service.sh"
)
assert_eq "/data/adb/custom_openlist|/data/adb/custom_bin/openlist|UNSET" "$NO_ENV_RES" "未传入环境变量时 source service.sh 读取字面量值并清理 _ENV_*"

WITH_ENV_RES=$(
    DATA_DIR="/tmp/env_data" \
    OPENLIST_BINARY="/tmp/env_bin" \
    MODULE_PROP_FILE="/tmp/env_prop" \
    LOG_FILE="/tmp/env_svc.log" \
    OPENLIST_LOG="/tmp/env_app.log" \
    bash -c '. "$1"; printf "%s|%s|%s|%s|%s|%s\n" "$DATA_DIR" "$OPENLIST_BINARY" "$MODULE_PROP_FILE" "$LOG_FILE" "$OPENLIST_LOG" "${_ENV_DATA_DIR:-UNSET}"' _ "$SED_SAFE_DIR/service.sh"
)
assert_eq "/tmp/env_data|/tmp/env_bin|/tmp/env_prop|/tmp/env_svc.log|/tmp/env_app.log|UNSET" "$WITH_ENV_RES" "传入环境变量时 source service.sh 保留全部 5 项覆盖并清理 _ENV_*"

# 19d: source service.sh 零 stdout/stderr 与零文件副作用
CLEAN_SRC_DIR="$TEST_TMP/svc_clean_source"
mkdir -p "$CLEAN_SRC_DIR"
cp "$SED_SAFE_DIR/service.sh" "$CLEAN_SRC_DIR/service.sh"
SRC_OUT=$(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    bash -c '. "$1"' _ "$CLEAN_SRC_DIR/service.sh" 2>&1
)
SRC_FILES=$(ls -A "$CLEAN_SRC_DIR" | tr '\n' ',' | sed 's/,$//')
assert_eq "" "$SRC_OUT" "source service.sh 产生零 stdout/stderr 输出"
assert_eq "service.sh" "$SRC_FILES" "source service.sh 不创建日志或临时文件（零副作用）"

# -------------------------------------------------------------
# 测试 20: 旧版 fork v4.2.9 ${VAR:-...} 语法解包兼容性
# -------------------------------------------------------------
echo ""
echo "-> 测试 20: 旧版 fork v4.2.9 \${VAR:-...} 语法解包（customize.sh / control.sh / uninstall.sh / uninstall-user.sh）"

LEGACY_MOD="$TEST_TMP/legacy_v429_mod"
LEGACY_DATA="$TEST_TMP/legacy_v429_data"
mkdir -p "$LEGACY_MOD/bin" "$LEGACY_DATA"
touch "$LEGACY_MOD/bin/openlist"
echo "legacy-db" > "$LEGACY_DATA/data.db"
cat > "$LEGACY_MOD/service.sh" << EOF
#!/system/bin/sh
MODDIR="\${0%/*}"
DATA_DIR="\${DATA_DIR:-$LEGACY_DATA}"
OPENLIST_BINARY="\${OPENLIST_BINARY:-\$MODDIR/bin/openlist}"
EOF
cat > "$LEGACY_MOD/action.sh" << 'EOF'
#!/system/bin/sh
OPENLIST_BINARY="${OPENLIST_BINARY:-/old/outdated/openlist}"
EOF
cat > "$LEGACY_MOD/module.prop" << 'EOF'
id=openlist
version=v4.2.9
description=init
EOF

# 20a: customize.sh unwrap_legacy_var + OLD_MOD 解析
CUST_UNWRAP_RES=$(bash -c '
    eval "$(awk "/^unwrap_legacy_var\\(\\)/,/^}/" "$1")"
    OLD_MOD="$2"
    OLD_DATA="$(unwrap_legacy_var DATA_DIR "$(sed -n "s/^DATA_DIR=\"\\(.*\\)\"/\\1/p" "$OLD_MOD/service.sh" 2>/dev/null | head -n 1)")"
    OLD_BIN_PATH="$(unwrap_legacy_var OPENLIST_BINARY "$(sed -n "s/^OPENLIST_BINARY=\"\\(.*\\)\"/\\1/p" "$OLD_MOD/service.sh" 2>/dev/null | head -n 1)")"
    case "$OLD_BIN_PATH" in "\$MODDIR"*) OLD_BIN_PATH="$OLD_MOD${OLD_BIN_PATH#\$MODDIR}" ;; esac
    PLAIN="$(unwrap_legacy_var DATA_DIR "/data/adb/plain")"
    MISMATCH="$(unwrap_legacy_var DATA_DIR "\${OTHER_VAR:-/keep}")"
    printf "%s|%s|%s|%s\n" "$OLD_DATA" "$OLD_BIN_PATH" "$PLAIN" "$MISMATCH"
' _ "$CUSTOMIZE_SH" "$LEGACY_MOD")
assert_eq "$LEGACY_DATA|$LEGACY_MOD/bin/openlist|/data/adb/plain|\${OTHER_VAR:-/keep}" "$CUST_UNWRAP_RES" "customize.sh unwrap_legacy_var 正确解包旧版 DATA_DIR/OPENLIST_BINARY 且保留普通与非匹配值"

# 20b: control.sh get_var / unwrap_legacy_var (status + fix-paths)
cp "$CONTROL_SH" "$LEGACY_MOD/control.sh"
rm -f "$FAKE_RUNNING"
LEGACY_CTL_STATUS=$(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    TMP_DIR="$TEST_TMP/legacy_tmp" PROGRESS_FILE="$TEST_TMP/legacy_tmp/prog" TOKEN_CACHE="$TEST_TMP/legacy_tmp/tok" \
        sh "$LEGACY_MOD/control.sh" status
)
assert_all_kv_lines "$LEGACY_CTL_STATUS" "control.sh status 在旧版 service.sh 下输出纯净 key=value"
assert_eq "$LEGACY_DATA" "$(printf '%s\n' "$LEGACY_CTL_STATUS" | sed -n 's/^data_dir=//p')" "control.sh get_var 正确解包旧版 DATA_DIR"
assert_eq "$LEGACY_MOD/bin/openlist" "$(printf '%s\n' "$LEGACY_CTL_STATUS" | sed -n 's/^bin=//p')" "control.sh get_var 正确解包并展开旧版 OPENLIST_BINARY"

LEGACY_FIX_OUT=$(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    TMP_DIR="$TEST_TMP/legacy_tmp" PROGRESS_FILE="$TEST_TMP/legacy_tmp/prog" TOKEN_CACHE="$TEST_TMP/legacy_tmp/tok" \
        sh "$LEGACY_MOD/control.sh" fix-paths
)
assert_all_kv_lines "$LEGACY_FIX_OUT" "control.sh fix-paths 输出纯净 key=value"
assert_file_contains "$LEGACY_MOD/action.sh" '^OPENLIST_BINARY="\$MODDIR/bin/openlist"$' "control.sh fix-paths 解包旧版 action.sh/service.sh 并写回纯字面量路径"

# 20c: uninstall.sh get_service_var 解包旧版 service.sh
UNINST_LEGACY_VARS=$(
    MODPATH="$LEGACY_MOD" bash -c '
        . "$1"
        printf "%s|%s\n" "$(get_service_var DATA_DIR)" "$(get_service_var OPENLIST_BINARY)"
    ' _ "$UNINSTALL_SH"
)
assert_eq "$LEGACY_DATA|\$MODDIR/bin/openlist" "$UNINST_LEGACY_VARS" "uninstall.sh get_service_var 正确解包旧版 DATA_DIR 与 OPENLIST_BINARY"

# 20d: uninstall-user.sh get_service_var 解包与交互式清理验证
UNINST_USER_LEGACY_VARS=$(
    MODROOT="$LEGACY_MOD" bash -c '
        eval "$(awk "/^get_service_var\\(\\)/,/^}/" "$1")"
        printf "%s|%s\n" "$(get_service_var DATA_DIR)" "$(get_service_var OPENLIST_BINARY)"
    ' _ "$UNINSTALL_USER_SH"
)
assert_eq "$LEGACY_DATA|\$MODDIR/bin/openlist" "$UNINST_USER_LEGACY_VARS" "uninstall-user.sh get_service_var 正确解包旧版 DATA_DIR 与 OPENLIST_BINARY"

# 选项 1（保留数据，清理旧版解包后的二进制）
printf '1\n' | MODPATH="$LEGACY_MOD" sh "$UNINSTALL_USER_SH" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if [ ! -f "$LEGACY_MOD/bin/openlist" ] && [ -d "$LEGACY_DATA" ]; then
    echo "  [PASS] uninstall-user.sh 选 1 时通过解包路径删除旧版二进制并保留旧版数据目录"
else
    echo "  [FAIL] uninstall-user.sh 选 1 时清理行为异常"
    FAILED=$((FAILED + 1))
fi

# 选项 2（删除旧版解包后的数据目录）
if [ ! -d "/data/adb/openlist" ] && [ ! -d "/sdcard/Android/openlist" ]; then
    printf '2\n' | MODPATH="$LEGACY_MOD" sh "$UNINSTALL_USER_SH" >/dev/null 2>&1
    TOTAL=$((TOTAL + 1))
    if [ ! -d "$LEGACY_DATA" ]; then
        echo "  [PASS] uninstall-user.sh 选 2 时通过解包路径删除旧版数据目录"
    else
        echo "  [FAIL] uninstall-user.sh 选 2 时未能删除旧版数据目录"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  [SKIP] 宿主机存在真实 /data/adb/openlist 或 /sdcard/Android/openlist，跳过 uninstall-user.sh 删数据测试"
fi

# -------------------------------------------------------------
# 准备 control.sh 四大伴侣钩子测试沙盒
# -------------------------------------------------------------
CTL_MOD="$TEST_TMP/ctl_mod"
CTL_DATA="$TEST_TMP/ctl_data"
CTL_TMP="$TEST_TMP/ctl_tmp"
CTL_BRIDGE="$TEST_TMP/ctl_bridge/openlist_offline.conf"
CTL_HELPER="$TEST_TMP/ctl_helper"
mkdir -p "$CTL_MOD/bin" "$CTL_DATA" "$CTL_TMP" "$CTL_HELPER"

cp "$CONTROL_SH" "$CTL_MOD/control.sh"
cp "$SERVICE_SH" "$CTL_MOD/service.sh"
cp "$ACTION_SH" "$CTL_MOD/action.sh"
sed -i "s|__PLACEHOLDER_DATA_DIR__|$CTL_DATA|g" "$CTL_MOD/service.sh"
sed -i "s|__PLACEHOLDER_BINARY_PATH__|$CTL_MOD/bin/openlist|g" "$CTL_MOD/service.sh"
sed -i "s|__PLACEHOLDER_BINARY_PATH__|$CTL_MOD/bin/openlist|g" "$CTL_MOD/action.sh"
chmod +x "$CTL_MOD/control.sh" "$CTL_MOD/service.sh" "$CTL_MOD/action.sh"

cat > "$CTL_MOD/bin/openlist" << EOF
#!/usr/bin/env bash
if [ "\$1" = "admin" ] && [ "\$2" = "token" ]; then
    echo "Admin token: openlist-ctlTestToken1234567890abcdef"
    exit 0
fi
if [ "\$1" = "server" ]; then
    touch "$FAKE_RUNNING"
    while [ -f "$FAKE_RUNNING" ]; do
        sleep 0.2
    done
    exit 0
fi
exit 0
EOF
chmod +x "$CTL_MOD/bin/openlist"

cat > "$CTL_MOD/module.prop" << 'EOF'
id=openlist
version=v4.2.10
versionCode=40210
description=【运行中】测试状态
EOF

run_ctl() {
    local script="$1"
    shift
    (
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        TMP_DIR="$CTL_TMP" \
        PROGRESS_FILE="$CTL_TMP/update.progress" \
        TOKEN_CACHE="$CTL_TMP/token.cache" \
        BRIDGE_TMP_CONF="$CTL_BRIDGE" \
        HELPER_DATA_DIR="$CTL_HELPER" \
        ENABLE_DISABLE_WATCHER=0 \
        RELOAD_DELAY=0 \
        TOKEN_RETRY_MAX=1 \
            sh "$script" "$@"
    )
}

# -------------------------------------------------------------
# 测试 21: control.sh 钩子 1/4 — cmd_stop 隐藏伴侣菜单、更新品牌描述且零 stdout 污染
# -------------------------------------------------------------
echo ""
echo "-> 测试 21: control.sh cmd_stop 伴侣菜单隐藏、品牌描述与纯净 stdout"
touch "$FAKE_RUNNING"
: > "$PM_LOG"
STOP_OUT=$(run_ctl "$CTL_MOD/control.sh" stop)
STOP_EXPECTED="$(printf 'stopped=1\nresult=ok')"

assert_all_kv_lines "$STOP_OUT" "control.sh stop 输出纯净 key=value（零 stdout 污染）"
assert_eq "$STOP_EXPECTED" "$STOP_OUT" "control.sh stop 精确输出 stopped=1 与 result=ok"
assert_file_contains "$PM_LOG" "^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "control.sh stop 调用 pm disable 隐藏伴侣菜单"
assert_file_contains "$CTL_MOD/module.prop" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk" "control.sh stop 更新 module.prop 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$CTL_MOD/module.prop" "Alien-Et" "control.sh stop 更新后的 module.prop 不包含 Alien-Et"

# -------------------------------------------------------------
# 测试 22: control.sh 钩子 2/4 — cmd_config_save 允许空格路径、拒绝注入/控制符并立即桥接
# -------------------------------------------------------------
echo ""
echo "-> 测试 22: control.sh cmd_config_save 空格路径、非法字符拦截与即时桥接"
VALID_CONF_CONTENT=$(cat << 'EOF'
HOST=127.0.0.1
PORT=5244
TOKEN=openlist-ctlTestToken1234567890abcdef
PATH=/115 Cloud/离线下载
TOOL=115 Open
DELETE_POLICY=delete_on_upload_succeed
PRESET_PATHS=/115 Cloud/电影/,/115 网盘/动漫/
EOF
)
VALID_CONF_B64=$(b64_encode "$VALID_CONF_CONTENT")
rm -f "$CTL_BRIDGE" "$CTL_HELPER/files/offline.conf"

SAVE_OUT=$(run_ctl "$CTL_MOD/control.sh" config-save "$VALID_CONF_B64")
assert_all_kv_lines "$SAVE_OUT" "control.sh config-save 输出纯净 key=value（零 stdout 污染）"
assert_eq "result=ok" "$SAVE_OUT" "control.sh config-save 精确返回 result=ok"
assert_file_contains "$CTL_DATA/offline.conf" "^PATH=/115 Cloud/离线下载$" "config-save 接受含空格的 PATH 并写入 DATA_DIR/offline.conf"
assert_file_contains "$CTL_DATA/offline.conf" "^PRESET_PATHS=/115 Cloud/电影/,/115 网盘/动漫/$" "config-save 接受含空格的 PRESET_PATHS 并写入 DATA_DIR/offline.conf"
assert_file_contains "$CTL_BRIDGE" "^PATH=/115 Cloud/离线下载$" "config-save 立即桥接 PATH 到 BRIDGE_TMP_CONF"
assert_file_contains "$CTL_BRIDGE" "^PRESET_PATHS=/115 Cloud/电影/,/115 网盘/动漫/$" "config-save 立即桥接 PRESET_PATHS 到 BRIDGE_TMP_CONF"
assert_file_contains "$CTL_HELPER/files/offline.conf" "^PATH=/115 Cloud/离线下载$" "config-save 立即桥接 PATH 到 HELPER_DATA_DIR/files/offline.conf"
assert_file_contains "$CTL_HELPER/files/offline.conf" "^PRESET_PATHS=/115 Cloud/电影/,/115 网盘/动漫/$" "config-save 立即桥接 PRESET_PATHS 到 HELPER_DATA_DIR/files/offline.conf"

# 拒绝各类 Shell 注入与控制字符（PATH 与 PRESET_PATHS）
check_config_save_rejected() {
    local label="$1"
    local payload="$2"
    local b64 rc=0 out=""
    b64=$(b64_encode "$payload")
    out=$(run_ctl "$CTL_MOD/control.sh" config-save "$b64") || rc=$?
    TOTAL=$((TOTAL + 1))
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '^result=fail$'; then
        echo "  [PASS] config-save 拒绝非法输入: $label"
    else
        echo "  [FAIL] config-save 未拒绝非法输入: $label (rc=$rc, out='$out')"
        FAILED=$((FAILED + 1))
    fi
}

check_config_save_rejected "PATH 含分号 ;" "$(printf 'PATH=/115 Cloud/;id\n')"
check_config_save_rejected "PATH 含美元符 \$" "$(printf 'PATH=/115/$(whoami)\n')"
check_config_save_rejected "PATH 含反引号 \`" "$(printf 'PATH=/115/`id`\n')"
check_config_save_rejected "PATH 含制表符 \\t" "$(printf 'PATH=/115\tCloud/dl\n')"
check_config_save_rejected "PATH 不以 / 开头" "$(printf 'PATH=115 Cloud/dl\n')"
check_config_save_rejected "PRESET_PATHS 含分号 ;" "$(printf 'PRESET_PATHS=/115 Cloud/,/115;rm\n')"
check_config_save_rejected "PRESET_PATHS 含美元符 \$" "$(printf 'PRESET_PATHS=/115 Cloud/,/115$HOME\n')"
check_config_save_rejected "PRESET_PATHS 含反引号 \`" "$(printf 'PRESET_PATHS=/115/`id`\n')"
check_config_save_rejected "PRESET_PATHS 含制表符 \\t" "$(printf 'PRESET_PATHS=/115\tCloud/\n')"

# 验证被拒绝后原有效 offline.conf 未被破坏
assert_file_contains "$CTL_DATA/offline.conf" "^PATH=/115 Cloud/离线下载$" "非法 config-save 失败后保留原有有效 offline.conf"

# -------------------------------------------------------------
# 测试 23: control.sh 钩子 3/4 — cmd_api 保持原样 JSON 与退出码并异步刷新伴侣菜单
# -------------------------------------------------------------
echo ""
echo "-> 测试 23: control.sh cmd_api 保持原样 JSON/退出码并异步刷新菜单可见性"
MOCK_API_BIN="$TEST_TMP/mock_api_bin"
MOCK_STORAGE_FILE="$TEST_TMP/mock_api_storage_list.json"
MOCK_API_RC_FILE="$TEST_TMP/mock_api_rc"
MOCK_API_RESP_FILE="$TEST_TMP/mock_api_resp.json"
mkdir -p "$MOCK_API_BIN"

cat > "$MOCK_API_BIN/curl" << EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
    case "\$arg" in
        http://*|https://*) url="\$arg" ;;
    esac
done
case "\$url" in
    */api/admin/storage/list*)
        cat "$MOCK_STORAGE_FILE" 2>/dev/null
        exit 0
        ;;
    *)
        cat "$MOCK_API_RESP_FILE" 2>/dev/null
        rc=\$(cat "$MOCK_API_RC_FILE" 2>/dev/null || echo 0)
        exit "\${rc:-0}"
        ;;
esac
EOF
chmod +x "$MOCK_API_BIN/curl"

wait_for_pm_pattern() {
    local pattern="$1"
    local tries=0
    while [ "$tries" -lt 40 ]; do
        if grep -qE "$pattern" "$PM_LOG" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# 23a: POST /api/admin/storage/enable -> 原样 JSON + 退出码 0 + 异步 pm enable
touch "$FAKE_RUNNING"
printf '%s' '{"code":200,"message":"success","data":null}' > "$MOCK_API_RESP_FILE"
printf '0' > "$MOCK_API_RC_FILE"
printf '%s' '{"code":200,"message":"success","data":{"content":[{"id":2,"driver":"115 Open","disabled":false}]}}' > "$MOCK_STORAGE_FILE"
: > "$PM_LOG"

API_RC=0
if command -v timeout >/dev/null 2>&1; then
    API_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        PATH="$MOCK_API_BIN:$PATH" timeout 8 bash -c '
            TMP_DIR="$1" PROGRESS_FILE="$1/p" TOKEN_CACHE="$1/tok" sh "$2" api POST "/api/admin/storage/enable?id=2"
        ' _ "$CTL_TMP" "$CTL_MOD/control.sh"
    ) || API_RC=$?
else
    API_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        PATH="$MOCK_API_BIN:$PATH" \
        TMP_DIR="$CTL_TMP" PROGRESS_FILE="$CTL_TMP/p" TOKEN_CACHE="$CTL_TMP/tok" \
        sh "$CTL_MOD/control.sh" api POST "/api/admin/storage/enable?id=2"
    ) || API_RC=$?
fi

assert_eq "0" "$API_RC" "cmd_api POST /api/admin/storage/enable 返回退出码 0 且不阻塞"
assert_eq '{"code":200,"message":"success","data":null}' "$API_OUT" "cmd_api POST /api/admin/storage/enable 输出精确未修改 JSON（零 stdout 污染）"
wait_for_pm_pattern '^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$' || true
assert_file_contains "$PM_LOG" '^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$' "cmd_api POST storage/enable 异步触发伴侣菜单启用"

# 23b: POST /api/admin/storage/disable -> 原样 JSON + 退出码 0 + 异步 pm disable
printf '%s' '{"code":200,"message":"success","data":{"content":[{"id":2,"driver":"115 Open","disabled":true}]}}' > "$MOCK_STORAGE_FILE"
: > "$PM_LOG"

API_RC=0
if command -v timeout >/dev/null 2>&1; then
    API_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        PATH="$MOCK_API_BIN:$PATH" timeout 8 bash -c '
            TMP_DIR="$1" PROGRESS_FILE="$1/p" TOKEN_CACHE="$1/tok" sh "$2" api POST "/api/admin/storage/disable?id=2"
        ' _ "$CTL_TMP" "$CTL_MOD/control.sh"
    ) || API_RC=$?
else
    API_OUT=$(
        unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
        PATH="$MOCK_API_BIN:$PATH" \
        TMP_DIR="$CTL_TMP" PROGRESS_FILE="$CTL_TMP/p" TOKEN_CACHE="$CTL_TMP/tok" \
        sh "$CTL_MOD/control.sh" api POST "/api/admin/storage/disable?id=2"
    ) || API_RC=$?
fi

assert_eq "0" "$API_RC" "cmd_api POST /api/admin/storage/disable 返回退出码 0 且不阻塞"
assert_eq '{"code":200,"message":"success","data":null}' "$API_OUT" "cmd_api POST /api/admin/storage/disable 输出精确未修改 JSON（零 stdout 污染）"
wait_for_pm_pattern '^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$' || true
assert_file_contains "$PM_LOG" '^disable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$' "cmd_api POST storage/disable 异步触发伴侣菜单隐藏"

# 23c: curl 返回非零退出码时原样保留退出码与输出且不触发伴侣菜单刷新
printf '%s' '{"code":500,"message":"upstream error"}' > "$MOCK_API_RESP_FILE"
printf '7' > "$MOCK_API_RC_FILE"
: > "$PM_LOG"

API_RC=0
API_OUT=$(
    unset DATA_DIR OPENLIST_BINARY MODULE_PROP_FILE LOG_FILE OPENLIST_LOG
    PATH="$MOCK_API_BIN:$PATH" \
    TMP_DIR="$CTL_TMP" PROGRESS_FILE="$CTL_TMP/p" TOKEN_CACHE="$CTL_TMP/tok" \
    sh "$CTL_MOD/control.sh" api POST "/api/admin/storage/enable?id=2"
) || API_RC=$?
sleep 0.3

assert_eq "7" "$API_RC" "cmd_api 在 curl 失败时原样保留退出码 7"
assert_eq '{"code":500,"message":"upstream error"}' "$API_OUT" "cmd_api 在 curl 失败时原样保留响应内容"
TOTAL=$((TOTAL + 1))
if [ ! -s "$PM_LOG" ]; then
    echo "  [PASS] cmd_api 失败时不误触发伴侣菜单刷新"
else
    echo "  [FAIL] cmd_api 失败时意外触发了 pm 调用: $(cat "$PM_LOG")"
    FAILED=$((FAILED + 1))
fi
rm -f "$FAKE_RUNNING"

# -------------------------------------------------------------
# 测试 24: control.sh 钩子 4/4 — cmd_use_data 更新 DATA_DIR 并立即桥接 offline.conf
# -------------------------------------------------------------
echo ""
echo "-> 测试 24: control.sh cmd_use_data 切换数据目录、即时桥接与纯净 stdout"

# 24a: 未修改版 control.sh 拒绝非法白名单外路径
BAD_USE_RC=0
BAD_USE_OUT=$(run_ctl "$CTL_MOD/control.sh" use-data "$(b64_encode "/etc/not_allowed")") || BAD_USE_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$BAD_USE_RC" -ne 0 ] && printf '%s\n' "$BAD_USE_OUT" | grep -q '^result=fail$'; then
    echo "  [PASS] 原版 control.sh use-data 拒绝非白名单路径"
else
    echo "  [FAIL] 原版 control.sh use-data 未拒绝非白名单路径 (rc=$BAD_USE_RC)"
    FAILED=$((FAILED + 1))
fi

# 24b: 沙盒内扩展白名单以允许 $TEST_TMP/* 验证完整 use-data 流程（停止态 + 运行态）
CTL_USEDATA_SH="$CTL_MOD/control_usedata.sh"
cp "$CTL_MOD/control.sh" "$CTL_USEDATA_SH"
sed -i "s|case \"\$dir\" in /data/\*|case \"\$dir\" in \"$TEST_TMP\"/*\|/data/*|" "$CTL_USEDATA_SH"
chmod +x "$CTL_USEDATA_SH"

NEW_DATA_1="$TEST_TMP/ctl_data_switched_1"
mkdir -p "$NEW_DATA_1"
printf "\x00\x01/115115 Open\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$NEW_DATA_1/data.db"
printf '{"database":{"db_file":"%s/data.db"}}\n' "$CTL_DATA" > "$NEW_DATA_1/config.json"
cat > "$NEW_DATA_1/offline.conf" << 'EOF'
HOST=127.0.0.1
PORT=5244
TOKEN=openlist-switchedDataDirToken12345678
PATH=/115 Cloud/切换目录一/
TOOL=115 Open
DELETE_POLICY=delete_on_upload_succeed
PRESET_PATHS=/115 Cloud/切换目录一/,/115/
EOF

rm -f "$FAKE_RUNNING" "$CTL_BRIDGE" "$CTL_HELPER/files/offline.conf"
USE1_OUT=$(run_ctl "$CTL_USEDATA_SH" use-data "$(b64_encode "$NEW_DATA_1")")
assert_all_kv_lines "$USE1_OUT" "control.sh use-data (停止态) 输出纯净 key=value（零 stdout 污染）"
assert_eq "ok" "$(printf '%s\n' "$USE1_OUT" | sed -n 's/^result=//p')" "control.sh use-data (停止态) 返回 result=ok"
assert_eq "$NEW_DATA_1" "$(sed -n 's/^DATA_DIR="\(.*\)"/\1/p' "$CTL_MOD/service.sh")" "use-data 成功更新 service.sh 中的 DATA_DIR"
assert_eq "1" "$(grep -c '^DATA_DIR=' "$CTL_MOD/service.sh")" "use-data 更新后 service.sh 中 ^DATA_DIR= 仍保持唯一"
assert_file_contains "$NEW_DATA_1/config.json" "\"$NEW_DATA_1/data\.db\"" "use-data 同步更新 config.json 内绝对路径"
assert_file_contains "$CTL_BRIDGE" "^PATH=/115 Cloud/切换目录一/$" "use-data 立即桥接新目录 offline.conf 至 BRIDGE_TMP_CONF"
assert_file_contains "$CTL_HELPER/files/offline.conf" "^PATH=/115 Cloud/切换目录一/$" "use-data 立即桥接新目录 offline.conf 至 HELPER_DATA_DIR/files/offline.conf"

# 24c: 运行态执行 use-data -> 重启服务、立即桥接并刷新伴侣菜单可见性
NEW_DATA_2="$TEST_TMP/ctl_data_switched_2"
mkdir -p "$NEW_DATA_2"
printf "\x00\x01/115115 Cloud\x1ework{}\x00token%sstring\x00" "$CLEANED_TOKEN" > "$NEW_DATA_2/data.db"
cat > "$NEW_DATA_2/offline.conf" << 'EOF'
HOST=127.0.0.1
PORT=5244
TOKEN=openlist-switchedDataDirToken87654321
PATH=/115 Cloud/切换目录二/
TOOL=115 Open
DELETE_POLICY=delete_on_upload_succeed
PRESET_PATHS=/115 Cloud/切换目录二/
EOF

touch "$FAKE_RUNNING"
: > "$PM_LOG"
USE2_OUT=$(run_ctl "$CTL_USEDATA_SH" use-data "$(b64_encode "$NEW_DATA_2")")
rm -f "$FAKE_RUNNING"
sleep 0.3

assert_all_kv_lines "$USE2_OUT" "control.sh use-data (运行态) 输出纯净 key=value（零 stdout 污染）"
assert_eq "ok" "$(printf '%s\n' "$USE2_OUT" | sed -n 's/^result=//p')" "control.sh use-data (运行态) 返回 result=ok"
assert_eq "$NEW_DATA_2" "$(sed -n 's/^DATA_DIR="\(.*\)"/\1/p' "$CTL_MOD/service.sh")" "use-data (运行态) 更新 service.sh 中的 DATA_DIR"
assert_file_contains "$CTL_BRIDGE" "^PATH=/115 Cloud/切换目录二/$" "use-data (运行态) 立即桥接新目录 offline.conf 至 BRIDGE_TMP_CONF"
assert_file_contains "$CTL_HELPER/files/offline.conf" "^PATH=/115 Cloud/切换目录二/$" "use-data (运行态) 立即桥接新目录 offline.conf 至 HELPER_DATA_DIR/files/offline.conf"
assert_file_contains "$PM_LOG" "^enable io\.openlist\.helper/io\.openlist\.helper\.ProcessTextActivity$" "use-data (运行态) 重启后刷新伴侣菜单可见性"

# -------------------------------------------------------------
# 测试 25: 仓库品牌一致性与 WebUI 客户端路径校验正则测试
# -------------------------------------------------------------
echo ""
echo "-> 测试 25: 品牌链接一致性与 WebUI app.js 空格路径正则校验"

assert_file_contains "$MODULE_PROP" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk" "module.prop description 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_contains "$MODULE_PROP" "https://raw\.githubusercontent\.com/BLACK-BIRTHDAY/OpenList-Magisk/main/update\.json" "module.prop updateJson 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$MODULE_PROP" "Alien-Et/OpenList-Magisk" "module.prop 链接不含 Alien-Et/OpenList-Magisk"

assert_file_contains "$UPDATE_JSON" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk/releases/download/" "update.json zipUrl 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_contains "$UPDATE_JSON" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk/raw/main/OpenList-Magisk/CHANGELOG\.md" "update.json changelog 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$UPDATE_JSON" "Alien-Et/OpenList-Magisk" "update.json 不含 Alien-Et/OpenList-Magisk"

assert_file_contains "$ACTION_SH" '^REPO_URL="https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk"$' "action.sh REPO_URL 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$ACTION_SH" "Alien-Et/OpenList-Magisk" "action.sh 不含 Alien-Et/OpenList-Magisk"

assert_file_contains "$CONTROL_SH" "https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk" "control.sh update_desc_stopped 指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_not_contains "$CONTROL_SH" "Alien-Et/OpenList-Magisk" "control.sh 不含 Alien-Et/OpenList-Magisk"

assert_file_contains "$WEBROOT_INDEX" 'href="https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk"' "webroot/index.html 项目地址指向 BLACK-BIRTHDAY/OpenList-Magisk"
assert_file_contains "$WEBROOT_INDEX" 'href="https://github\.com/BLACK-BIRTHDAY/OpenList-Magisk/releases/latest"' "webroot/index.html Release 链接指向 BLACK-BIRTHDAY/OpenList-Magisk"

# WebUI app.js 客户端 PATH / PRESET_PATHS 正则必须允许普通空格
assert_file_contains "$WEBROOT_APP_JS" '\^\\/\[A-Za-z0-9_\\-\./ \\u4e00-\\u9fa5\]\*\$/\.test\(path\)' "webroot/app.js PATH 正则允许普通空格"
assert_file_contains "$WEBROOT_APP_JS" '\^\\/\[A-Za-z0-9_\\-\./ \\u4e00-\\u9fa5\]\*\(,\\/\[A-Za-z0-9_\\-\./ \\u4e00-\\u9fa5\]\*\)\*\$/\.test\(presets\)' "webroot/app.js PRESET_PATHS 正则允许普通空格"

if command -v node >/dev/null 2>&1; then
    NODE_REGEX_RC=0
    node - "$WEBROOT_APP_JS" << 'EOF' || NODE_REGEX_RC=$?
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const pathMatch = src.match(/if \(!(\/.+\/)\.test\(path\)\)/);
const presetsMatch = src.match(/if \(presets && !(\/.+\/)\.test\(presets\)\)/);
if (!pathMatch || !presetsMatch) {
    console.error('Failed to extract PATH/PRESET_PATHS regex from app.js');
    process.exit(1);
}
const pathRe = eval(pathMatch[1]);
const presetsRe = eval(presetsMatch[1]);

const mustPassPath = ['/115/影视/', '/115 Cloud/离线下载', '/115 网盘/2026 电影/'];
const mustFailPath = ['115 Cloud/dl', '/115/;id', '/115/$(id)', '/115/`id`', '/115\tCloud/dl'];
const mustPassPresets = ['/115/影视/,/115/', '/115 Cloud/电影/,/115 网盘/动漫/'];
const mustFailPresets = ['/115/;id,/115/', '/115 Cloud/,115/bad', '/115\tCloud/'];

for (const v of mustPassPath) if (!pathRe.test(v)) { console.error('pathRe failed:', v); process.exit(2); }
for (const v of mustFailPath) if (pathRe.test(v)) { console.error('pathRe accepted bad:', v); process.exit(3); }
for (const v of mustPassPresets) if (!presetsRe.test(v)) { console.error('presetsRe failed:', v); process.exit(4); }
for (const v of mustFailPresets) if (presetsRe.test(v)) { console.error('presetsRe accepted bad:', v); process.exit(5); }
EOF
    assert_eq "0" "$NODE_REGEX_RC" "node 实测 webroot/app.js 提取的 PATH/PRESET_PATHS 正则放行空格并拦截非法字符"
else
    echo "  [SKIP] 当前环境无 node 命令，跳过 app.js 正则动态校验"
fi

# -------------------------------------------------------------
# 测试汇总报告
# -------------------------------------------------------------
echo ""
echo "=== 测试完成: 总计 $TOTAL 项，失败 $FAILED 项 ==="

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

exit 0
