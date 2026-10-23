#!/bin/bash
# ================= mattermost 维护脚本 =================
# 功能：硬删除指定天数前的历史消息，并删除对应的本地附件文件。
#
# 交互使用（二选一）：
#   bash run.sh configure mattermost
#   bash <服务目录>/mattermost/configure.sh
#
# 非交互（手动执行）：
#   bash app/mattermost/configure.sh --db postgres --days 90 --yes
#
# 注意：
#   - 本脚本仅支持手动执行，不会安装任何定时任务。
#   - 硬删除不可恢复，执行前请备份数据库与 data/ 目录。
#   - 仅支持本地附件存储；检测到 S3/MinIO 时会中止。
#   - 会删除“早于保留天数的根帖及其整个回复线程”，避免遗留孤立回复。

# 脚本使用了 bash 特性（数组、printf -v、10# 进制转换等）。
# 兼容 `sh configure.sh` 的直接调用：非 bash 时自动重新以 bash 执行。
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_PATH" || exit 1

usage() {
    printf "用法: bash configure.sh [选项]\n\n"
    printf "  --db <postgres|mysql>  数据库类型（缺省交互选择）\n"
    printf "  --days <N>             保留天数，清理 N 天前的消息（缺省交互输入）\n"
    printf "  --container <名称>     数据库容器名\n"
    printf "  --yes                  跳过确认，直接执行\n"
    printf "  -h, --help             显示本帮助\n"
}

# --help 不触发服务根目录/网络初始化
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# 服务目录判定：
#   1) 从服务目录运行（install.sh 会把本脚本复制为 $SERVICE_DIR/configure.sh）
#      → 脚本所在目录就是服务目录
#   2) 从项目源码目录运行（bash run.sh configure mattermost）
#      → 按 .installer.conf 的 SERVICE_BASE 定位，找不到则交互输入
if [ -f "$SCRIPT_PATH/docker-compose.yml" ]; then
    SERVICE_DIR="$SCRIPT_PATH"
else
    PROJECT_ROOT="$(cd "$SCRIPT_PATH/../.." && pwd)"
    SERVICE_BASE=""
    [ -f "$PROJECT_ROOT/.installer.conf" ] && . "$PROJECT_ROOT/.installer.conf"
    if [ -n "$SERVICE_BASE" ] && [ -f "$SERVICE_BASE/mattermost/docker-compose.yml" ]; then
        SERVICE_DIR="$SERVICE_BASE/mattermost"
    else
        printf "请输入 Mattermost 服务目录: "
        read -r SERVICE_DIR || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    fi
fi

# 读取密码时关闭回显，退出/中断时恢复
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; exit 130' INT
trap 'stty echo 2>/dev/null; exit 143' TERM

# 本地敏感输入函数（脚本安装到服务目录后不再依赖项目公共库）
read_secret() {
    local prompt="$1" var_name="$2" value
    while true; do
        printf "%s" "$prompt" >&2
        stty -echo
        read -r value || { stty echo; printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; return 1; }
        stty echo
        printf "\n" >&2
        [ -n "$value" ] && break
        printf "❌ 该项不能为空，请重新输入。\n" >&2
    done
    printf -v "$var_name" '%s' "$value"
}

DB_TYPE=""
DAYS=""
ASSUME_YES=0
DB_CONTAINER=""
DB_USER=""
DB_PASSWORD=""
DB_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --db)        DB_TYPE="$2"; shift 2 ;;
        --days)      DAYS="$2"; shift 2 ;;
        --container) DB_CONTAINER="$2"; shift 2 ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            printf "❌ 未知参数: %s\n" "$1" >&2
            usage
            exit 1 ;;
    esac
done

if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
    printf "❌ 未找到 Mattermost 的 docker-compose.yml: %s\n" "$SERVICE_DIR"
    exit 1
fi

ENV_FILE="$SERVICE_DIR/.env"
[ -f "$ENV_FILE" ] || { printf "❌ 未找到 %s，无法读取数据库配置。\n" "$ENV_FILE"; exit 1; }

# 串行化清理任务：避免两个进程同时操作同一批表
mkdir -p "$SERVICE_DIR/logs"
if command -v flock >/dev/null 2>&1; then
    LOCK_FILE="$SERVICE_DIR/logs/.mattermost-cleanup.lock"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        printf "❌ 另一个 Mattermost 清理任务正在运行，已中止。\n"
        exit 1
    fi
else
    printf "⚠️  未找到 flock，跳过并发保护。\n"
fi

# 从 .env 读取单个键（不 source，避免值中的特殊字符被 shell 解释）
env_get() {
    local value
    value=$(sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -n1)
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    printf '%s' "$value"
}

container_running() {
    command -v docker >/dev/null 2>&1 || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# ---------- 数据库类型与连接参数 ----------
if [ -z "$DB_TYPE" ]; then
    printf "==========================================\n"
    printf "🗄️  请选择数据库类型\n"
    printf "==========================================\n"
    printf "  1) PostgreSQL [默认]\n"
    printf "  2) MySQL\n"
    printf "请输入序号 (1/2) [1]: "
    read -r db_choice || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    case "${db_choice:-1}" in
        1) DB_TYPE="postgres" ;;
        2) DB_TYPE="mysql" ;;
        *) printf "❌ 无效选择 '%s'。\n" "$db_choice"; exit 1 ;;
    esac
fi

case "$DB_TYPE" in
    postgres)
        [ -n "$DB_CONTAINER" ] || DB_CONTAINER="mattermost-postgres17"
        [ -n "$DB_USER" ] || DB_USER="$(env_get POSTGRES_USER)"
        [ -n "$DB_USER" ] || DB_USER="mmuser"
        DB_PASSWORD="$(env_get POSTGRES_PASSWORD)"
        [ -n "$DB_NAME" ] || DB_NAME="$(env_get POSTGRES_DB)"
        [ -n "$DB_NAME" ] || DB_NAME="mattermost"
        ;;
    mysql)
        [ -n "$DB_CONTAINER" ] || DB_CONTAINER="mattermost-mysql"
        [ -n "$DB_USER" ] || DB_USER="$(env_get MYSQL_USER)"
        [ -n "$DB_USER" ] || DB_USER="mmuser"
        DB_PASSWORD="$(env_get MYSQL_PASSWORD)"
        [ -n "$DB_NAME" ] || DB_NAME="$(env_get MYSQL_DATABASE)"
        [ -n "$DB_NAME" ] || DB_NAME="mattermost"
        ;;
    *)
        printf "❌ 不支持的数据库类型: %s（仅支持 postgres/mysql）\n" "$DB_TYPE"
        exit 1 ;;
esac

# 容器未运行时允许交互更换；非交互模式直接报错
while ! container_running "$DB_CONTAINER"; do
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf "❌ 数据库容器 '%s' 未运行，已中止。\n" "$DB_CONTAINER"
        exit 1
    fi
    printf "❌ 数据库容器 '%s' 未运行，请输入正确的容器名（回车退出）: " "$DB_CONTAINER"
    read -r input_container || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    [ -n "$input_container" ] || exit 1
    DB_CONTAINER="$input_container"
done

# 密码缺失时交互补录
if [ -z "$DB_PASSWORD" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf "❌ %s 中未找到数据库密码，非交互模式无法继续。\n" "$ENV_FILE"
        exit 1
    fi
    read_secret "请输入数据库密码: " DB_PASSWORD || exit 1
fi

# 数据库名只允许常规标识符，避免拼进 SQL 时出问题
case "$DB_NAME" in
    ''|*[!A-Za-z0-9_]*)
        printf "❌ 数据库名 '%s' 含有不允许的字符。\n" "$DB_NAME"
        exit 1 ;;
esac

# ---------- 保留天数 ----------
if [ -z "$DAYS" ]; then
    while true; do
        printf "请输入保留天数（清理多少天前的消息）: "
        read -r DAYS || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
        case "$DAYS" in
            ''|*[!0-9]*) printf "❌ 请输入正整数。\n"; continue ;;
        esac
        [ "$DAYS" -ge 1 ] && break
        printf "❌ 至少为 1 天。\n"
    done
fi
case "$DAYS" in
    ''|*[!0-9]*) printf "❌ 保留天数必须是正整数。\n"; exit 1 ;;
esac
[ "$DAYS" -ge 1 ] || { printf "❌ 保留天数至少为 1。\n"; exit 1; }
# 去除前导零，避免被 arithmetic 当作八进制
DAYS=$((10#$DAYS))

# ---------- 附件存储安全检查 ----------
DATA_ROOT="$SERVICE_DIR/data"

# .env 或 config.json 声明使用 S3/MinIO 时，本地文件不是附件真实位置，直接中止
driver_env="$(env_get MM_FILESETTINGS_DRIVERNAME)"
if [ "$driver_env" = "amazon-s3" ]; then
    printf "❌ 检测到 MM_FILESETTINGS_DRIVERNAME=amazon-s3，本脚本仅支持本地附件存储。\n"
    exit 1
fi
if [ -f "$SERVICE_DIR/config/config.json" ] &&
   grep -Eq '"DriverName"[[:space:]]*:[[:space:]]*"amazon-s3"' "$SERVICE_DIR/config/config.json"; then
    printf "❌ 检测到附件存储在 S3，本脚本仅支持本地附件存储。\n"
    exit 1
fi

# ---------- 数据库访问封装 ----------
db_query() {
    case "$DB_TYPE" in
        postgres)
            docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
                psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -At -v ON_ERROR_STOP=1 -c "$1" ;;
        mysql)
            docker exec -i -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" \
                mysql -N -B -u"$DB_USER" -D "$DB_NAME" -e "$1" ;;
    esac
}

db_exec() {
    case "$DB_TYPE" in
        postgres)
            docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
                psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 ;;
        mysql)
            docker exec -i -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" \
                mysql -u"$DB_USER" -D "$DB_NAME" ;;
    esac
}

# 目标集合使用固定表名；flock 保证同一时间只有一个清理进程。
# 启动时先清理所有历史残留表（包括旧版本带 PID 后缀的 _mm_cleanup_* 表）。
ROOTS_TABLE="_mm_cleanup_roots"
POSTS_TABLE="_mm_cleanup_posts"
DB_READY=0

cleanup_stale_tables() {
    local tables t
    case "$DB_TYPE" in
        postgres)
            tables=$(db_query "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND left(tablename, 12) = '_mm_cleanup_';") || return 0
            ;;
        mysql)
            tables=$(db_query "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND left(table_name, 12) = '_mm_cleanup_';") || return 0
            ;;
    esac
    [ -n "$tables" ] || return 0

    printf "🧹 清理历史残留的临时表...\n"
    for t in $tables; do
        case "$t" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        db_query "DROP TABLE IF EXISTS $t;" >/dev/null 2>&1 &&
            printf "   - 已删除 %s\n" "$t"
    done
}

cleanup_db_tables() {
    [ "$DB_READY" -eq 1 ] || return 0
    db_query "DROP TABLE IF EXISTS ${ROOTS_TABLE}; DROP TABLE IF EXISTS ${POSTS_TABLE};" >/dev/null 2>&1 || true
}
trap 'stty echo 2>/dev/null; cleanup_db_tables' EXIT

cleanup_stale_tables

if [ "$DB_TYPE" = "postgres" ]; then
    CUTOFF="(EXTRACT(EPOCH FROM NOW() - INTERVAL '${DAYS} days') * 1000)::bigint"
    SETUP_SQL="
SET client_min_messages = warning;
DROP TABLE IF EXISTS ${ROOTS_TABLE};
DROP TABLE IF EXISTS ${POSTS_TABLE};
CREATE TABLE ${ROOTS_TABLE} (Id text PRIMARY KEY);
INSERT INTO ${ROOTS_TABLE}
  SELECT DISTINCT COALESCE(NULLIF(RootId, ''), Id) FROM Posts
  WHERE CreateAt < ${CUTOFF}
  ON CONFLICT DO NOTHING;
CREATE TABLE ${POSTS_TABLE} (Id text PRIMARY KEY);
INSERT INTO ${POSTS_TABLE} SELECT Id FROM ${ROOTS_TABLE} ON CONFLICT DO NOTHING;
INSERT INTO ${POSTS_TABLE}
  SELECT p.Id FROM Posts p
  WHERE p.RootId IN (SELECT Id FROM ${ROOTS_TABLE})
  ON CONFLICT DO NOTHING;
"
else
    CUTOFF="UNIX_TIMESTAMP(NOW() - INTERVAL ${DAYS} DAY) * 1000"
    SETUP_SQL="
DROP TABLE IF EXISTS ${ROOTS_TABLE};
DROP TABLE IF EXISTS ${POSTS_TABLE};
CREATE TABLE ${ROOTS_TABLE} (Id varchar(64) PRIMARY KEY);
INSERT IGNORE INTO ${ROOTS_TABLE}
  SELECT DISTINCT COALESCE(NULLIF(RootId, ''), Id) FROM Posts
  WHERE CreateAt < ${CUTOFF};
CREATE TABLE ${POSTS_TABLE} (Id varchar(64) PRIMARY KEY);
INSERT IGNORE INTO ${POSTS_TABLE} SELECT Id FROM ${ROOTS_TABLE};
INSERT IGNORE INTO ${POSTS_TABLE}
  SELECT p.Id FROM Posts p
  WHERE p.RootId IN (SELECT Id FROM ${ROOTS_TABLE});
"
fi

printf '%s\n' "$SETUP_SQL" | db_exec >/dev/null || {
    printf "❌ 构建待清理帖子集合失败，请检查数据库连接与权限。\n"
    exit 1
}
DB_READY=1

POSTS_COUNT="$(db_query "SELECT COUNT(*) FROM ${POSTS_TABLE};")"
FILES_COUNT="$(db_query "SELECT COUNT(*) FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});")"

printf "==========================================\n"
printf "🧹 Mattermost 历史消息清理\n"
printf "==========================================\n"
printf "数据库类型: %s\n" "$DB_TYPE"
printf "数据库容器: %s\n" "$DB_CONTAINER"
printf "保留天数:   %s 天\n" "$DAYS"
printf "待删帖子:   %s 条\n" "${POSTS_COUNT:-0}"
printf "附件记录:   %s 条\n" "${FILES_COUNT:-0}"
printf "==========================================\n"

if [ "${POSTS_COUNT:-0}" -eq 0 ]; then
    printf "ℹ️  没有需要清理的历史消息。\n"
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "⚠️  这是硬删除，操作不可恢复。请输入 DELETE 继续: "
    read -r confirm_delete || { printf "\n❌ 输入已结束（EOF），已中止。\n" >&2; exit 1; }
    if [ "$confirm_delete" != "DELETE" ]; then
        printf "已取消。\n"
        exit 0
    fi
fi

# ---------- 删除本地附件文件 ----------
PATHS_FILE="$SERVICE_DIR/logs/.mattermost-cleanup-paths.$$"
mkdir -p "$SERVICE_DIR/logs"
: > "$PATHS_FILE"

SQL_PATHS="
SELECT Path FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE}) AND Path IS NOT NULL AND Path <> ''
UNION
SELECT ThumbnailPath FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE}) AND ThumbnailPath IS NOT NULL AND ThumbnailPath <> ''
UNION
SELECT PreviewPath FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE}) AND PreviewPath IS NOT NULL AND PreviewPath <> '';
"
db_query "$SQL_PATHS" > "$PATHS_FILE" || {
    printf "❌ 查询附件路径失败，已中止（数据库记录未删除）。\n"
    exit 1
}

# 将 FileInfo 中的相对路径安全解析到本地 data 目录
resolve_attachment_path() {
    local p="$1" cand real root_real
    local -a candidates=()
    case "$p" in
        ''|/*|*..*) return 1 ;;
    esac
    [ -d "$DATA_ROOT" ] || return 1
    root_real=$(readlink -f "$DATA_ROOT" 2>/dev/null) || return 1

    candidates+=("$DATA_ROOT/$p")
    # 兼容 FileInfo.Path 自带 data/ 前缀的情况
    case "$p" in
        data/*) candidates+=("$DATA_ROOT/${p#data/}") ;;
    esac

    for cand in "${candidates[@]}"; do
        [ -f "$cand" ] || continue
        real=$(readlink -f "$cand" 2>/dev/null) || continue
        case "$real" in
            "$root_real"/*) printf '%s\n' "$real"; return 0 ;;
        esac
    done
    return 1
}

DELETED_FILES=0
MISSING_FILES=0
FAILED_FILES=0

if [ -d "$DATA_ROOT" ]; then
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if resolved=$(resolve_attachment_path "$p"); then
            if rm -f -- "$resolved"; then
                DELETED_FILES=$((DELETED_FILES + 1))
            else
                FAILED_FILES=$((FAILED_FILES + 1))
                printf "⚠️  文件删除失败: %s\n" "$resolved"
            fi
        else
            MISSING_FILES=$((MISSING_FILES + 1))
        fi
    done < "$PATHS_FILE"
else
    printf "⚠️  未找到附件目录 %s，跳过本地文件删除。\n" "$DATA_ROOT"
fi
rm -f "$PATHS_FILE"

printf "📎 附件文件: 已删除 %s，未找到 %s，失败 %s\n" "$DELETED_FILES" "$MISSING_FILES" "$FAILED_FILES"

if [ "$FAILED_FILES" -gt 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
    printf "⚠️  有 %s 个文件删除失败，是否仍继续删除数据库记录？(y/N): " "$FAILED_FILES"
    read -r continue_anyway || continue_anyway="n"
    case "$continue_anyway" in
        y|Y) ;;
        *) printf "已中止，数据库记录未删除。\n"; exit 1 ;;
    esac
fi

# ---------- 硬删除数据库记录 ----------
if [ "$DB_TYPE" = "postgres" ]; then
    DELETE_SQL="
DELETE FROM Reactions WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DELETE FROM ThreadMemberships WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DELETE FROM Threads WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DO \$\$
BEGIN
  IF to_regclass('public.postacknowledgements') IS NOT NULL THEN
    DELETE FROM PostAcknowledgements WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
  END IF;
END
\$\$;
DELETE FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
-- 先删回复再删根帖，兼容存在 RootId 自引用外键的场景
DELETE FROM Posts WHERE Id IN (SELECT Id FROM ${POSTS_TABLE}) AND RootId <> '';
DELETE FROM Posts WHERE Id IN (SELECT Id FROM ${POSTS_TABLE});
"
else
    DELETE_SQL="
DELETE FROM Reactions WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DELETE FROM ThreadMemberships WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DELETE FROM Threads WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
DELETE FROM FileInfo WHERE PostId IN (SELECT Id FROM ${POSTS_TABLE});
-- 先删回复再删根帖，兼容存在 RootId 自引用外键的场景
DELETE FROM Posts WHERE Id IN (SELECT Id FROM ${POSTS_TABLE}) AND RootId <> '';
DELETE FROM Posts WHERE Id IN (SELECT Id FROM ${POSTS_TABLE});
"
fi

printf '%s\n' "$DELETE_SQL" | db_exec || {
    printf "❌ 数据库删除失败，请检查错误信息。\n"
    exit 1
}

printf "✅ 已删除帖子 %s 条、附件记录 %s 条、本地附件文件 %s 个。\n" \
    "$POSTS_COUNT" "$FILES_COUNT" "$DELETED_FILES"
printf "ℹ️  数据库中的 soft-deleted 帖子（DeleteAt 非 0）也已一并清理。\n"

exit 0