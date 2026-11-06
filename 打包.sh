#!/bin/bash
# AutoRaise 6.1 打包脚本
#
# 把 Xcode 构建产物处理成可分发的 ad-hoc 签名包，并生成 DMG。
# 所有步骤都是为了修正 Xcode 默认行为的两个坑：
#   1. 会用本机 Apple Development 证书签名（泄漏开发者邮箱）
#   2. 会注入 com.apple.security.get-task-allow（调试权限）
#
# 用法：./打包.sh [版本号]
#   版本号默认 6.1，可选。

set -e
set -o pipefail

VERSION="${1:-6.1}"
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJ_DIR}"

BUILD_DIR="/tmp/ar_build_${VERSION}"
STAGE_DIR="/tmp/ar_stage_${VERSION}"
DMG_STAGE="/tmp/ar_dmg_${VERSION}"
OUT_DMG="${PROJ_DIR}/AutoRaise-${VERSION}.dmg"

step() { echo; echo "▶ $1"; }
ok()   { echo "  ✅ $1"; }
die()  { echo; echo "  ❌ $1"; exit 1; }

echo "=============================================="
echo " AutoRaise ${VERSION} 打包"
echo "=============================================="

# ---------- 1. 构建 ----------
step "1/8 构建 Release"
rm -rf "${BUILD_DIR}"
xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaise \
    -configuration Release -derivedDataPath "${BUILD_DIR}" build 2>&1 | tail -2
BUILT_APP="${BUILD_DIR}/Build/Products/Release/AutoRaise.app"
[ -d "${BUILT_APP}" ] || die "构建产物不存在：${BUILT_APP}"
ok "构建完成"

# ---------- 2. 拷到暂存区 ----------
step "2/8 拷到暂存区"
rm -rf "${STAGE_DIR}" && mkdir -p "${STAGE_DIR}"
cp -R "${BUILT_APP}" "${STAGE_DIR}/"
T="${STAGE_DIR}/AutoRaise.app"
ok "${T}"

# ---------- 3. 附带许可证 ----------
step "3/8 附带许可证与说明"
cp LICENSE.md NOTICE.md "${T}/Contents/Resources/"
[ -f "RELEASE-${VERSION}.md" ] && cp "RELEASE-${VERSION}.md" "${T}/Contents/Resources/发布说明-${VERSION}.md"
ok "LICENSE.md / NOTICE.md / 发布说明"

# ---------- 4. 清掉原签名 ----------
step "4/8 清除 Xcode 原签名"
for f in \
    "${T}/Contents/Frameworks/MASShortcut.framework" \
    "${T}/Contents/MacOS/AutoRaise" \
    "${T}/Contents/Resources/AutoRaise" \
    "${T}" ; do
    [ -e "$f" ] && codesign --remove-signature "$f" 2>/dev/null || true
done
ok "已清除"

# ---------- 5. entitlements ----------
step "5/8 准备 entitlements（只留 disable-library-validation）"
cat > /tmp/ar_ent_${VERSION}.plist <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
PL
ok "/tmp/ar_ent_${VERSION}.plist"

# ---------- 6. 自内向外 ad-hoc 重签 ----------
step "6/8 ad-hoc 重签（自内向外）"
# 注意：daemon（Contents/Resources/AutoRaise）必须单独正式签。
# 它默认只是 linker-signed（flags=0x20002），codesign --verify --strict 判定为「未签名」，
# 会导致辅助功能授权按 CDHash 记账时反复失效。
codesign --force --sign - --timestamp=none "${T}/Contents/Frameworks/MASShortcut.framework"
codesign --force --sign - --timestamp=none "${T}/Contents/Resources/AutoRaise"
codesign --force --sign - --timestamp=none "${T}/Contents/MacOS/AutoRaise"
codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "/tmp/ar_ent_${VERSION}.plist" "${T}"
ok "framework / daemon / launcher / bundle 全部已签"

# ---------- 7. 三项必查 ----------
step "7/8 发包前检查"
FAIL=0

# ① 不能有个人证书
if codesign -dvv "${T}" 2>&1 | grep -q "^Authority="; then
    echo "  ❌ 签名含个人证书："
    codesign -dvv "${T}" 2>&1 | grep "^Authority="
    FAIL=1
else
    ok "无个人证书（adhoc）"
fi

# ② 不能有 get-task-allow
if codesign -d --entitlements - "${T}" 2>/dev/null | grep -q "get-task-allow"; then
    echo "  ❌ 含 get-task-allow 调试权限"
    FAIL=1
else
    ok "无 get-task-allow"
fi

# ③ 必须有 disable-library-validation
if codesign -d --entitlements - "${T}" 2>/dev/null | grep -q "disable-library-validation"; then
    ok "有 disable-library-validation（MASShortcut 可加载）"
else
    echo "  ❌ 缺 disable-library-validation，app 启动会闪退"
    FAIL=1
fi

# ④ 整体验签
if codesign --verify --deep --strict "${T}" >/dev/null 2>&1; then
    ok "整体验签通过"
else
    echo "  ❌ 整体验签失败"
    FAIL=1
fi

# ⑤ daemon 也要能严格验签
if codesign --verify --strict "${T}/Contents/Resources/AutoRaise" >/dev/null 2>&1; then
    ok "daemon 严格验签通过"
else
    echo "  ❌ daemon 未正式签名（辅助功能授权会反复失效）"
    FAIL=1
fi

# ⑥ 无本机路径泄漏
if strings "${T}/Contents/MacOS/AutoRaise" 2>/dev/null | grep -q "/Users/"; then
    echo "  ⚠️  launcher 含 /Users/ 路径（通常是调试信息，确认非个人信息）"
else
    ok "无 /Users/ 路径泄漏"
fi

[ "${FAIL}" -eq 0 ] || die "检查未通过，不要发布"

# ---------- 8. 打包 DMG ----------
step "8/8 生成 DMG"
rm -rf "${DMG_STAGE}" && mkdir -p "${DMG_STAGE}"
cp -R "${T}" "${DMG_STAGE}/AutoRaise.app"
cp LICENSE.md "${DMG_STAGE}/"                    # DMG 根目录也放一份，不开包就能看
[ -f "发布素材/安装说明.md" ] && cp "发布素材/安装说明.md" "${DMG_STAGE}/"
[ -f "发布素材/安装 AutoRaise.command" ] && cp "发布素材/安装 AutoRaise.command" "${DMG_STAGE}/"
[ -f "RELEASE-${VERSION}.md" ] && cp "RELEASE-${VERSION}.md" "${DMG_STAGE}/"
chmod +x "${DMG_STAGE}/安装 AutoRaise.command" 2>/dev/null || true
ln -sfn /Applications "${DMG_STAGE}/应用程序"

rm -f "${OUT_DMG}"
hdiutil create -volname "AutoRaise ${VERSION}" -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO "${OUT_DMG}" 2>&1 | tail -1

# sha256 写成纯文件名（不带目录前缀，用户下载后可直接 -c 校验）
( cd "$(dirname "${OUT_DMG}")" && shasum -a 256 "$(basename "${OUT_DMG}")" > "$(basename "${OUT_DMG}").sha256" )

echo
echo "=============================================="
echo " ✅ 打包完成"
echo "=============================================="
ls -lh "${OUT_DMG}"
cat "${OUT_DMG}.sha256"
echo
echo "发包前请再手动确认一次：解压 DMG、双击安装脚本、启动 app 看菜单栏图标是否出现。"
