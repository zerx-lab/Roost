#!/bin/sh
# Roost 统一检查。按仓库里实际存在的文件启用对应检查,任一失败则退出码非 0。
#   Luau : luau-lsp 严格类型检查 + lint(配合 tern.d.luau、.luaurc);有 tests/run.py 时跑测试
#   Rust : 对每个 Cargo.toml 执行 fmt --check、clippy(-D warnings,lint 见 .cargo/config.toml)、test
#   记忆 : .omp/memory/MEMORY.md 行数预算 + 明文密钥扫描
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

fail=0
step() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1:$2" >&2; exit 2; }; }
prune='-path ./.git -o -path ./target -o -path ./node_modules'

# ---------- Luau ----------
if [ -n "$(find . \( $prune \) -prune -o -name '*.luau' ! -name 'tern.d.luau' -print | head -n 1)" ]; then
	need tern "安装 Tern 并确保 tern CLI 在 PATH"
	need luau-lsp "从 https://github.com/JohnnyMorganz/luau-lsp/releases 下载放入 PATH"

	# 仅在内容变化时覆盖 tern.d.luau:link 开发时任何写入都会触发 Tern 重载全部插件
	step "tern.d.luau"
	tmp=$(mktemp -d)
	tern plugin types "$tmp" >/dev/null
	if cmp -s "$tmp/tern.d.luau" tern.d.luau 2>/dev/null; then
		echo "已是最新"
	else
		cp "$tmp/tern.d.luau" tern.d.luau
		echo "已更新"
	fi
	rm -rf "$tmp"

	step "luau-lsp analyze"
	find . \( $prune \) -prune -o -name '*.luau' ! -name 'tern.d.luau' -print0 |
		xargs -0 luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau || fail=1
fi

if [ -f tests/run.py ]; then
	need luau "brew install luau"
	step "Luau 测试 (tests/run.py)"
	python3 tests/run.py || fail=1
fi

# ---------- Rust ----------
manifests=$(find . \( $prune \) -prune -o -name Cargo.toml -print)
for m in $manifests; do
	need cargo "安装 rustup"
	step "cargo fmt --check ($m)"
	cargo fmt --manifest-path "$m" --check || fail=1
	step "cargo clippy ($m)"
	cargo clippy --manifest-path "$m" --all-targets -- -D warnings || fail=1
	step "cargo test ($m)"
	cargo test --manifest-path "$m" || fail=1
done

# ---------- 项目记忆 ----------
mem=.omp/memory
if [ -d "$mem" ]; then
	step "项目记忆"
	limit=150
	lines=$(wc -l <"$mem/MEMORY.md" | tr -d ' ')
	memfail=0
	if [ "$lines" -gt "$limit" ]; then
		echo "MEMORY.md $lines 行,超过 $limit 行预算:运行 /memory-tidy 精简" >&2
		memfail=1
	fi
	secret='(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(api[_-]?key|secret|password|passwd|token)[[:space:]]*[:=][[:space:]]*[^[:space:]<]{8,})'
	if grep -rEni "$secret" "$mem"; then
		echo "记忆文件里疑似有明文凭据,删除或替换为占位说明" >&2
		memfail=1
	fi
	if [ "$memfail" -eq 0 ]; then
		echo "MEMORY.md $lines/$limit 行,未发现明文凭据"
	else
		fail=1
	fi
fi

if [ "$fail" -ne 0 ]; then
	printf '\n检查失败\n' >&2
	exit 1
fi
printf '\n全部通过\n'
