--!strict
-- Roost upgrading itself (`upgrade = true` steps). The step runs in a worktree of a clone of
-- Roost's own repository, after an agent committed there. M.CHECK makes sure the commits follow the
-- plugin checkout's HEAD, the checkout has no uncommitted changes, and scripts/check.sh passes on
-- the committed tree (in a fresh worktree, not the agent's); then it hands M.APPLY to a detached
-- process, because moving the plugin checkout reloads every plugin and ends this VM.
--
-- M.APPLY fast-forwards the checkout, reloads Roost and waits for the new host to write boot.txt
-- (core.booted, the last thing host.luau does); `tern plugin reload` failing, or no new boot in time, moves the checkout back to
-- the old commit (`reset --keep`, never over local changes). The outcome lands in
-- upgrades/<run>.json, which the next host start reports.
--
-- This is the one place Roost writes its own plugin directory, and only out of process.

local util = require("./util")

local M = {}

-- `sh -c CHECK roost PLUGIN DATA RUN APPLY` in the run's worktree.
M.CHECK = [==[
set -u
plugin=$1; data=$2; run=$3; apply=$4
work=$PWD
say() { printf '[roost] %s\n' "$*"; }
short() { printf '%.10s' "$1"; }
git -C "$work" rev-parse --git-dir >/dev/null 2>&1 || { say "工作目录不是 git 仓库:$work"; exit 2; }
command -v tern >/dev/null 2>&1 || { say "PATH 里找不到 tern,无法重载插件,不升级"; exit 2; }
new=$(git -C "$work" rev-parse HEAD) || exit 2
old=$(git -C "$plugin" rev-parse HEAD 2>/dev/null) || { say "插件目录不是 git 仓库:$plugin"; exit 2; }
if [ "$new" = "$old" ]; then
	say "没有新的提交,不需要升级"
	exit 0
fi
if ! git -C "$work" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
	say "提交 $(short "$new") 不是插件当前 HEAD $(short "$old") 的后续(插件目录已前进或分叉),不升级"
	exit 3
fi
# --no-optional-locks: status must not rewrite the plugin's .git/index (Tern reloads on any write there).
if [ -n "$(git --no-optional-locks -C "$plugin" status --porcelain --untracked-files=no)" ]; then
	say "插件目录有未提交的修改,不升级"
	exit 4
fi
git -C "$plugin" symbolic-ref -q HEAD >/dev/null || { say "插件目录不在分支上,不升级"; exit 4; }
mkdir -p "$data/upgrade" || exit 5
v="$data/upgrade/verify-$run"
rm -rf "$v"
git -C "$work" worktree add --quiet --detach "$v" "$new" || { say "无法为提交创建检查用的 worktree"; exit 5; }
# The gate is the installed version's check.sh, so a commit can't relax the checks it is judged by.
if ! git -C "$plugin" show HEAD:scripts/check.sh >"$v/scripts/check.sh" 2>/dev/null; then
	git -C "$work" worktree remove --force "$v" 2>/dev/null || rm -rf "$v"
	say "插件当前版本没有 scripts/check.sh,不升级"
	exit 5
fi
say "在 $v 用插件当前版本的 scripts/check.sh 检查提交 $(short "$new")"
( cd "$v" && /bin/sh scripts/check.sh )
code=$?
git -C "$work" worktree remove --force "$v" 2>/dev/null || rm -rf "$v"
git -C "$work" worktree prune
if [ "$code" -ne 0 ]; then
	say "scripts/check.sh 失败(退出码 $code),不升级"
	exit 5
fi
src=$(cd "$work" && cd "$(git rev-parse --git-common-dir)" && pwd) || exit 6
ref="roost-upgrade/$run"
git -C "$work" branch -f "$ref" "$new" >/dev/null || { say "无法为提交建分支"; exit 6; }
set -m
nohup /bin/sh "$apply" "$plugin" "$old" "$new" "$data" "$run" "$src" "$ref" >>"$data/upgrade/$run.log" 2>&1 </dev/null &
say "检查通过:$(short "$old") → $(short "$new") 交给后台脚本应用(日志 $data/upgrade/$run.log,结果 $data/upgrades/$run.json)"
exit 0
]==]

-- `sh APPLY PLUGIN OLD NEW DATA RUN SRC REF`, detached.
M.APPLY = [==[
plugin=$1; old=$2; new=$3; data=$4; run=$5; src=$6; ref=$7
# This script is written for one upgrade; it goes when it ends.
trap 'rm -f "$0"' EXIT
out="$data/upgrades/$run.json"
mkdir -p "$data/upgrades"
note() {
	msg=$(printf '%s' "$2" | tr '"\\\n\r\t' "'/   ")
	printf '{"run":"%s","old":"%s","new":"%s","state":"%s","message":"%s","at":%s}\n' \
		"$run" "$old" "$new" "$1" "$msg" "$(date +%s)" >"$out.tmp" && mv "$out.tmp" "$out"
	echo "[roost] $(date '+%F %T') $1: $2"
}
cleanup() { git --git-dir="$src" branch -D "$ref" >/dev/null 2>&1; }
note applying "正在应用"
# Let the step that started this finish first.
sleep 3
if [ "$(git -C "$plugin" rev-parse HEAD)" != "$old" ]; then
	note refused "插件目录的 HEAD 已不是 $old"; cleanup; exit 0
fi
if [ -n "$(git --no-optional-locks -C "$plugin" status --porcelain --untracked-files=no)" ]; then
	note refused "插件目录有未提交的修改"; cleanup; exit 0
fi
if ! git -C "$plugin" fetch --quiet "$src" "$ref"; then
	note failed "无法把提交取到插件目录"; cleanup; exit 0
fi
cleanup
before=$(cat "$data/boot.txt" 2>/dev/null)
if ! git -C "$plugin" merge --ff-only --quiet "$new"; then
	note failed "fast-forward 失败"; exit 0
fi
ok=0
sleep 2
if tern plugin reload roost >/dev/null 2>&1; then
	i=0
	while [ "$i" -lt 45 ]; do
		now=$(cat "$data/boot.txt" 2>/dev/null)
		if [ -n "$now" ] && [ "$now" != "$before" ]; then ok=1; break; fi
		sleep 2
		i=$((i + 1))
	done
fi
if [ "$ok" -eq 1 ]; then
	note applied "已升级到 $new"
	exit 0
fi
if [ "$(git -C "$plugin" rev-parse HEAD)" = "$new" ] && git -C "$plugin" reset --quiet --keep "$old"; then
	tern plugin reload roost >/dev/null 2>&1
	note rolled_back "新版本没有正常加载,已回退到 $old"
else
	note failed "新版本没有正常加载,且无法回退(HEAD 已变化或有本地修改)"
fi
exit 0
]==]

export type Result = { run: string, old: string, new: string, state: string, message: string, at: number }

function M.boot_path(data: string): string
	return `{data}/boot.txt`
end

function M.results_dir(data: string): string
	return `{data}/upgrades`
end

-- Where an upgrade step's copy of M.APPLY goes: one per run, so a later step never rewrites a
-- script a detached shell is still reading.
function M.apply_path(data: string, run: string): string
	return `{data}/upgrade/{run}.apply.sh`
end

-- Marks a host start for a pending M.APPLY to see.
function M.write_boot(data: string, now: number)
	local ok, err = pcall(function(): string?
		tern.fs.write(M.boot_path(data), string.format("%d-%04x\n", math.floor(now), math.random(0, 0xffff)))
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot write boot.txt", err)
	end
end

-- Writes run `run`'s copy of M.APPLY; its path, or nil and why not.
function M.install(data: string, run: string): (string?, string?)
	local path = M.apply_path(data, run)
	local ok, err = pcall(function(): string?
		tern.fs.mkdir(`{data}/upgrade`)
		tern.fs.write(path, M.APPLY)
		return nil
	end)
	if not ok then
		return nil, tostring(err)
	end
	return path, nil
end

local function result(path: string): Result?
	local ok, text = pcall(tern.fs.read, path, 16 * 1024)
	if not ok then
		return nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	if not ok2 or type(v) ~= "table" then
		return nil
	end
	for _, k in { "run", "old", "new", "state", "message" } do
		if type(v[k]) ~= "string" then
			return nil
		end
	end
	if type(v.at) ~= "number" then
		return nil
	end
	return v :: any
end

-- The upgrade outcomes on disk, newest first, at most `n`.
function M.results(data: string, n: number): { Result }
	local ok, names = pcall(tern.fs.list, M.results_dir(data))
	local out: { Result } = {}
	if not ok or type(names) ~= "table" then
		return out
	end
	for _, name in names :: { string } do
		if string.match(name, "^[%x]+%.json$") then
			local r = result(`{M.results_dir(data)}/{name}`)
			if r then
				table.insert(out, r)
			end
		end
	end
	table.sort(out, function(a, b)
		return a.at > b.at
	end)
	while #out > n do
		table.remove(out)
	end
	return out
end

-- One line for an outcome.
function M.describe(r: Result): string
	local label = ({
		applying = "正在应用",
		applied = "已升级",
		rolled_back = "已回退",
		refused = "未升级",
		failed = "失败",
	} :: { [string]: string })[r.state] or r.state
	return `{label} {string.sub(r.old, 1, 10)} → {string.sub(r.new, 1, 10)}:{util.clip(r.message, 200)}`
end

return M
