#!/bin/bash
# AutoRaise 6.1 一键安装脚本
# 作用：把 AutoRaise.app 装进「应用程序」、去掉隔离标记、保持 ad-hoc 签名。
# 不需要 Apple 开发者账号。会要求输入本机登录密码（用于写入 /Applications）。

# 不用 set -u：中文全角标点紧贴变量名时（如 $VAR）会被 bash 当成变量名的一部分，
# 在 set -u 下直接 unbound variable 中止。本脚本所有变量一律 ${} 包裹，
# 关键失败点逐个检查退出码。
set -o pipefail

APP_NAME="AutoRaise"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_APP="${SRC_DIR}/${APP_NAME}.app"
DEST_APP="/Applications/${APP_NAME}.app"
BACKUP_DIR="${HOME}/Library/Application Support/AutoRaise/backup"
BACKUP_PATH=""

# 任何退出都留一口气，避免 Terminal 窗口秒关、用户看不到错误
pause_exit() {
    echo
    read -r -p "按回车键关闭本窗口..." _ 2>/dev/null || true
    exit "${1:-0}"
}

fail() {
    echo
    echo "❌ $1"
    pause_exit 1
}

echo "=============================================="
echo " AutoRaise 6.1 安装程序"
echo "=============================================="
echo

# ---- 前置检查 ----
[ -d "${SRC_APP}" ] || fail "找不到 ${SRC_APP}。请确保本脚本与 AutoRaise.app 在同一个文件夹里。"

# 安全守卫：目标路径必须是 /Applications 下的 .app，防止 rm -rf 误伤
case "${DEST_APP}" in
    /Applications/*.app) : ;;
    *) fail "安装路径异常（${DEST_APP}），已中止以保护系统。" ;;
esac

REQUIRED_MAJOR=14
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="$(echo "${OS_VER}" | cut -d. -f1)"
echo "当前系统：macOS ${OS_VER}"
if [ "${OS_MAJOR}" -lt "${REQUIRED_MAJOR}" ] 2>/dev/null; then
    fail "本版需要 macOS ${REQUIRED_MAJOR}.0 或更高，当前是 ${OS_VER}。继续安装会出现「图标能出、但设置打不开」。"
fi
echo "✅ 系统版本满足要求（≥ macOS ${REQUIRED_MAJOR}.0）"
echo

# ---- 提前验证管理员权限（避免走到一半才失败）----
echo "需要管理员权限写入 /Applications，请输入本机登录密码："
sudo -v || fail "密码验证失败（或已取消）。安装未做任何改动，你的原版本完好。"
echo "✅ 权限已验证"
echo

# ---- 若已在运行，先退出 ----
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "检测到 AutoRaise 正在运行，先退出它..."
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    sleep 1
fi

# ---- 备份旧版本（放用户能长期找到的地方，不用 /tmp）----
if [ -d "${DEST_APP}" ]; then
    STAMP="$(date +%Y%m%d_%H%M%S)"
    BACKUP_PATH="${BACKUP_DIR}/${APP_NAME}.app.${STAMP}"
    echo "发现已安装版本，正在备份到："
    echo "  ${BACKUP_PATH}"
    mkdir -p "${BACKUP_DIR}" || fail "无法创建备份目录 ${BACKUP_DIR}"
    cp -R "${DEST_APP}" "${BACKUP_PATH}" || fail "备份失败。为安全起见已中止安装，你的原版本完好。"
    echo "✅ 已备份"
    echo
fi

# ---- 拷贝 ----
echo "正在安装到 ${DEST_APP} ..."
sudo rm -rf "${DEST_APP}" || fail "删除旧版本失败（权限不足？）。备份在 ${BACKUP_PATH:-无}。"
sudo cp -R "${SRC_APP}" "${DEST_APP}" || fail "拷贝失败。备份在 ${BACKUP_PATH:-无}，可按提示手动恢复。"
[ -d "${DEST_APP}" ] || fail "拷贝后目标目录不存在，安装失败。"
echo "✅ 已拷贝"
echo

# ---- 去隔离标记 ----
echo "正在移除隔离标记（com.apple.quarantine）..."
sudo xattr -cr "${DEST_APP}" || echo "⚠️  移除隔离标记失败，但通常不影响运行。"
echo "✅ 已处理"
echo

# ---- 校验签名（刻意不重签）----
# DMG 内的包已是有效 ad-hoc 签名，且带所需权限。
# 若在此处盲 codesign --force 而不带 --entitlements，会清空权限，
# 导致 dyld 因 Team ID 不一致拒绝加载 MASShortcut.framework，app 启动即闪退（实测 exit=134）。
echo "正在校验签名..."
if codesign --verify --deep --strict "${DEST_APP}" >/dev/null 2>&1; then
    echo "✅ 签名有效"
else
    echo "⚠️  签名校验未通过。应用通常仍可运行；若打不开，请右键点 app → 打开。"
fi

# 确认关键权限还在（缺失会导致启动闪退）
if codesign -d --entitlements - "${DEST_APP}" 2>/dev/null | grep -q "disable-library-validation"; then
    echo "✅ 依赖库验证权限正常"
else
    echo "⚠️  缺少 disable-library-validation 权限，app 可能无法启动。"
    echo "   建议改用「方式二：手动拖拽」安装，或联系维护者。"
fi
echo

# ---- 刷新 LaunchServices ----
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST_APP}" >/dev/null 2>&1 || true

# ---- 完成 ----
echo "=============================================="
echo " ✅ 安装完成"
echo "=============================================="
echo
if [ -n "${BACKUP_PATH}" ]; then
    echo "旧版本备份在："
    echo "  ${BACKUP_PATH}"
    echo "如需回退，在终端执行："
    echo "  sudo rm -rf \"${DEST_APP}\" && sudo cp -R \"${BACKUP_PATH}\" \"${DEST_APP}\""
    echo
fi
echo "请打开「应用程序」文件夹，双击 AutoRaise 启动。"
echo
echo "⚠️  首次启动必做：授予辅助功能权限"
echo "    1. 启动后系统会弹出权限提示，点「打开系统设置」"
echo "    2. 在「隐私与安全性 → 辅助功能」中勾选 AutoRaise"
echo "    3. 若列表里已有 AutoRaise 但仍不生效：选中它点「−」移除，"
echo "       再重新添加 /Applications/AutoRaise.app"
echo
echo "菜单栏出现图标 = 已就绪。左键点图标启停功能，右键点图标打开菜单。"
echo

read -r -p "按回车键打开 AutoRaise..." _ 2>/dev/null || true
open "${DEST_APP}"
pause_exit 0
