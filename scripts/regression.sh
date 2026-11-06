#!/usr/bin/env bash
# ObsidianDrop 回归测试（QA-001 ~ QA-005）
#
# 特点：
#   · 全部在 mktemp 临时库里跑，用 --vault 覆盖，绝不碰真实 Obsidian 库
#   · 直接跑真实二进制，验证退出码、输出、落盘位置与 frontmatter
#
# 用法：
#   bash scripts/regression.sh              # 先编译再测
#   BIN=/path/to/ObsidianDrop bash scripts/regression.sh   # 用已有二进制
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
FAILED_CASES=()

check() { # check <名称> <条件结果 0/1> [细节]
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); printf 'FAIL  %s%s\n' "$1" "${3:+  → $3}"
  fi
}

eq() { [ "$1" = "$2" ]; return $?; }

# ---------- 准备二进制 ----------
if [ -z "${BIN:-}" ]; then
  BIN="$(mktemp -d)/ObsidianDrop"
  printf '==> 编译\n'
  if ! xcrun swiftc -O -parse-as-library -swift-version 5 \
      -target arm64-apple-macos13.0 \
      -framework AppKit -framework AVFoundation -framework CoreAudio \
      -framework Speech -framework Security \
      -o "$BIN" "$SRC_DIR"/Sources/*.swift 2>/tmp/od-build.log; then
    echo "编译失败："; head -20 /tmp/od-build.log; exit 1
  fi
fi

ROOT="$(mktemp -d)"
VAULT="$ROOT/vault"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$VAULT"/{00-收件箱,10-项目/验收项目,20-领域,30-资源}

MONTH="$(date +%Y-%m)"
IN="$ROOT/in"; mkdir -p "$IN"
printf 'alpha\n' > "$IN/a.txt"
printf 'beta\n'  > "$IN/b.txt"

run() { "$BIN" --vault "$VAULT" "$@" >"$ROOT/out" 2>"$ROOT/err"; echo $?; }

echo
echo "===== QA-001 批量部分成功 ====="
code=$(run --file "$IN/a.txt" "$IN/missing.txt" --target "00-收件箱")
check "部分成功退出码为 3" "$(eq "$code" 3; echo $?)" "实际 $code"
grep -q "✓" "$ROOT/out";                      check "输出列出成功项" $?
grep -q "✗" "$ROOT/out";                      check "输出列出失败项" $?
grep -q "部分成功" "$ROOT/out";               check "输出明确标注部分成功" $?
[ -f "$VAULT/00-收件箱/$(date +%Y-%m-%d) a.md" ]; check "成功项确实已落盘" $?

code=$(run --file "$IN/a.txt" "$IN/missing.txt" --target "00-收件箱" --json)
echo "$code" > /dev/null
grep -q '"exit_code":3' "$ROOT/out";           check "JSON 给出 exit_code=3" $?
grep -q '"succeeded":1' "$ROOT/out";           check "JSON 给出 succeeded=1" $?
grep -q '"failed":1' "$ROOT/out";              check "JSON 给出 failed=1" $?

code=$(run --file "$IN/nope1.txt" "$IN/nope2.txt" --target "00-收件箱")
check "全部失败退出码为 1" "$(eq "$code" 1; echo $?)" "实际 $code"

code=$(run --file "$IN/b.txt" --target "00-收件箱")
check "全部成功退出码为 0" "$(eq "$code" 0; echo $?)" "实际 $code"

echo
echo "===== QA-002 路径逃逸 ====="
code=$(run --file "$IN/a.txt" --target "../escape")
check "拒绝 ../escape" "$(eq "$code" 1; echo $?)" "实际 $code"
grep -qE "拒绝|不能包含" "$ROOT/err";          check "给出明确拒绝原因" $?
[ ! -e "$ROOT/escape" ];                       check "库外未创建目录" $?

code=$(run --file "$IN/a.txt" --target "/tmp/obsidiandrop-escape")
check "拒绝绝对路径目标" "$(eq "$code" 1; echo $?)" "实际 $code"
[ ! -e "/tmp/obsidiandrop-escape" ];           check "绝对路径目标未落盘" $?

code=$(run --file "$IN/a.txt" --target "10-项目/../../escape")
check "拒绝含 .. 的中段路径" "$(eq "$code" 1; echo $?)" "实际 $code"

OUTSIDE="$ROOT/outside"; mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE" "$VAULT/50-软链"
code=$(run --file "$IN/a.txt" --target "50-软链")
check "拒绝库内软链指向库外" "$(eq "$code" 1; echo $?)" "实际 $code"
[ -z "$(ls -A "$OUTSIDE")" ];                  check "软链目标目录未被写入" $?

# 逃逸失败时，附件目录也不应新增文件（笔记与附件不能分离）
attachments_before=$(find "$VAULT/附件" -type f 2>/dev/null | wc -l | tr -d ' ')
code=$(run --file "$IN/a.txt" --target "../escape")
attachments_after=$(find "$VAULT/附件" -type f 2>/dev/null | wc -l | tr -d ' ')
check "越界失败时附件不落库" "$(eq "$attachments_before" "$attachments_after"; echo $?)" \
  "$attachments_before → $attachments_after"

echo
echo "===== QA-003 标签与目标一致 ====="
"$BIN" --vault "$VAULT" --file "$IN/a.txt" --target "20-领域" >/dev/null 2>&1
"$BIN" --vault "$VAULT" --file "$IN/a.txt" --target "30-资源" >/dev/null 2>&1
"$BIN" --vault "$VAULT" --file "$IN/a.txt" --target "10-项目/验收项目" >/dev/null 2>&1

domain_note=$(find "$VAULT/20-领域" -name '*.md' | head -1)
res_note=$(find "$VAULT/30-资源" -name '*.md' | head -1)
proj_note=$(find "$VAULT/10-项目/验收项目" -name '*.md' | head -1)

grep -q '^  - "领域"$' "$domain_note";         check "领域笔记标签为「领域」" $?
grep -q '^  - "资源"$' "$res_note";            check "资源笔记标签为「资源」" $?
grep -q '^  - "项目"$' "$proj_note";           check "项目笔记标签为「项目」" $?

! grep -q "收件箱" "$domain_note";             check "领域笔记不再含「收件箱」" $?
! grep -q "收件箱" "$res_note";                check "资源笔记不再含「收件箱」" $?
! grep -q "收件箱" "$proj_note";               check "项目笔记不再含「收件箱」" $?

echo
echo "===== QA-005 附件位置提示 ====="
inbox_note=$(find "$VAULT/00-收件箱" -name '*.md' | head -1)
grep -q "存放位置：\`附件/$MONTH/\`" "$inbox_note"
check "提示包含 YYYY-MM 月份目录" $? "$(grep '存放位置' "$inbox_note" | head -1)"

actual_dir=$(dirname "$(grep '^文件: ' "$inbox_note" | head -1 | sed 's/^文件: //')")
check "提示目录与实际附件目录一致" \
  "$(eq "$actual_dir" "附件/$MONTH"; echo $?)" "实际附件在 $actual_dir"

echo
echo "===== QA-004 菜单刷新（静态检查） ====="
grep -q "menuNeedsUpdate" "$SRC_DIR/Sources/main.swift"
check "菜单实现 menuNeedsUpdate 钩子" $?
grep -q "sub.delegate = self" "$SRC_DIR/Sources/main.swift"
check "投递目标子菜单已挂 delegate" $?

echo
echo "===== QA-002 补充：附件/文档目录本身是软链 ====="
# 上面 run() 会自动注入 --vault，这里要自己指定库，所以用不注入的 run2
run2() { "$BIN" "$@" >"$ROOT/out" 2>"$ROOT/err"; echo $?; }
# 场景 A：整个「附件」目录被软链到库外（用户把附件目录链接到外置盘时很常见）
SYMV="$ROOT/vault-sym-attach"; SYMOUT="$ROOT/outside-attach"
mkdir -p "$SYMV/00-收件箱" "$SYMOUT"
ln -s "$SYMOUT" "$SYMV/附件"
code=$(run2 --vault "$SYMV" --file "$IN/a.txt" --target "00-收件箱")
check "附件目录软链指向库外被拒绝" "$(eq "$code" 1; echo $?)" "实际 $code"
check "软链附件目录未写入库外" "$(eq "$(ls -A "$SYMOUT" | wc -l | tr -d ' ')" 0; echo $?)"

# 场景 B：项目「文档」目录被软链到库外
PRJV="$ROOT/vault-sym-doc"; PRJOUT="$ROOT/outside-doc"
mkdir -p "$PRJV/10-项目/P1" "$PRJOUT"
ln -s "$PRJOUT" "$PRJV/10-项目/P1/文档"
code=$(run2 --vault "$PRJV" --file "$IN/a.txt" --target "10-项目/P1")
check "项目文档目录软链指向库外被拒绝" "$(eq "$code" 1; echo $?)" "实际 $code"
check "软链文档目录未写入库外" "$(eq "$(ls -A "$PRJOUT" | wc -l | tr -d ' ')" 0; echo $?)"

echo
echo "===== QA-001 补充：笔记失败不得遗留附件 ====="
NWV="$ROOT/vault-nowrite"; mkdir -p "$NWV/00-收件箱"
chmod 500 "$NWV/00-收件箱"
code=$(run2 --vault "$NWV" --file "$IN/a.txt" --target "00-收件箱")
chmod 700 "$NWV/00-收件箱"
check "笔记目录不可写时退出码为 1" "$(eq "$code" 1; echo $?)" "实际 $code"
check "失败后库内无孤儿附件" "$(eq "$(find "$NWV" -type f | wc -l | tr -d ' ')" 0; echo $?)"

echo
echo "===== 参数严格性（用法错误必须 exit 2 且不落盘） ====="
USGV="$ROOT/vault-usage"; mkdir -p "$USGV/00-收件箱"
code=$(run2 --vault "$USGV" --file "$IN/a.txt" --target)
check "--target 缺值退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"
grep -q "缺少目标值" "$ROOT/err";            check "缺值给出明确提示" $?

code=$(run2 --vault "$USGV" --file "$IN/a.txt" --target "00-收件箱" --nope)
check "未知选项退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"
grep -q "未知选项" "$ROOT/err";               check "未知选项给出明确提示" $?

code=$(run2 --file "$IN/a.txt" --vault)
check "--vault 缺值退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"

check "参数错误时不产生任何文件" "$(eq "$(find "$USGV" -type f | wc -l | tr -d ' ')" 0; echo $?)"

echo
echo "===== 源文件是软链时归档真实副本 ====="
LNKV="$ROOT/vault-link"; mkdir -p "$LNKV/00-收件箱" "$ROOT/realsrc"
printf 'real-content\n' > "$ROOT/realsrc/real.txt"
ln -s "$ROOT/realsrc/real.txt" "$ROOT/link.txt"
code=$(run2 --vault "$LNKV" --file "$ROOT/link.txt" --target "00-收件箱")
check "软链源归档成功" "$(eq "$code" 0; echo $?)" "实际 $code"
copied=$(find "$LNKV/附件" -type f 2>/dev/null | head -1)
if [ -n "$copied" ] && [ ! -L "$copied" ]; then r=0; else r=1; fi
check "库内产物是真实副本而非软链" "$r"
check "副本内容与原文件一致" "$(eq "$(cat "$copied" 2>/dev/null)" "real-content"; echo $?)"
grep -q '^文件: 附件/' "$LNKV/00-收件箱"/*.md 2>/dev/null
check "笔记里的文件字段是库内相对路径" $?

echo
echo "===== 目标写法规范化（./ 前缀 / 空格 / 单连字符）====="
NORMV="$ROOT/vault-norm"
mkdir -p "$NORMV/10-项目/验收项目" "$NORMV/20-领域" "$NORMV/00-收件箱"

code=$(run2 --vault "$NORMV" --file "$IN/a.txt" --target "./10-项目/验收项目")
check "./ 前缀目标归档成功" "$(eq "$code" 0; echo $?)" "实际 $code"
normfile=$(grep '^文件: ' "$NORMV/10-项目/验收项目"/*.md 2>/dev/null | head -1 | sed 's/^文件: //')
case "$normfile" in 10-项目/验收项目/文档/*) r=0;; *) r=1;; esac
check "./ 前缀目标附件进项目文档目录" "$r" "$normfile"
normtag=$(grep -A1 '^tags:' "$NORMV/10-项目/验收项目"/*.md 2>/dev/null | tail -1)
case "$normtag" in *项目*) r=0;; *) r=1;; esac
check "./ 前缀目标标签为「项目」" "$r" "$normtag"

code=$(run2 --vault "$NORMV" --file "$IN/a.txt" --target " 20-领域 ")
check "带空格目标归档成功" "$(eq "$code" 0; echo $?)" "实际 $code"
grep -q '^文件: 附件/' "$NORMV/20-领域"/*.md 2>/dev/null
check "领域目标附件进全局附件" $?

code=$(run2 --vault "$NORMV" -z --file "$IN/a.txt" --target "00-收件箱")
check "单连字符未知选项退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"
grep -q "未知选项" "$ROOT/err";               check "单连字符给出明确提示" $?

echo
echo "===== 子命令缺值不能静默降级（1.3.15）====="
# 给了 --target 却没给值，说明是笔误。退回「上次用的目标」会把文件投到没预期的目录。
code=$(run2 --vault "$NORMV" --shot full --target)
check "--shot 的 --target 缺值退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"
grep -q "缺少目标值" "$ROOT/err";              check "--shot 缺值给出明确提示" $?
code=$(run2 --vault "$NORMV" --transcribe "$IN/a.txt" --target)
check "--transcribe 的 --target 缺值退出码为 2" "$(eq "$code" 2; echo $?)" "实际 $code"

echo
echo "===== 内置自检 ====="
"$BIN" --self-test >"$ROOT/selftest" 2>&1
check "内置自检全部通过" $? "$(tail -1 "$ROOT/selftest")"

echo
echo "----------------------------------------"
echo "回归结果：通过 ${PASS}，失败 ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：%s\n' "${FAILED_CASES[*]}"
  exit 1
fi
exit 0
