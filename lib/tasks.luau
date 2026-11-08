--!strict
-- Built-in runs that no workflows.toml entry describes (store.Task): a task typed on the home page
-- or a follow-up of a run (one omp step), and opening a PR from a run's changes (one shell step).
-- The runner rebuilds their workflow from the run record (runner.resolve), so they survive reloads
-- and never touch workflows.toml. Every such run has its own workflow id, `task.<hex>`, so tasks
-- run side by side within `max_concurrent`.
--
-- Changes: a worktree run's prepare step writes the commit it started at (`base.txt`); its cleanup
-- step stages everything and writes the diff against that commit (`changes.patch`, `--binary`)
-- and its numstat (`changes.numstat`) before removing the worktree. A follow-up's worktree starts
-- at the parent's base with the parent's patch applied, so its patch holds the whole chain.

local model = require("./model")
local store = require("./store")
local util = require("./util")

local M = {}

M.PREFIX = "task."
-- The state group every built-in run shares ($ROOST_STATE).
M.STATE = "tasks"
-- Largest patch kept; a bigger one leaves only its numstat (`changes.too_big`).
M.MAX_PATCH = 8 * 1024 * 1024
-- Most of a numstat read back, and most file rows kept from it.
M.MAX_NUMSTAT = 256 * 1024
M.MAX_FILES = 2000
-- Longest task text accepted.
M.MAX_PROMPT = 32 * 1024

function M.is(id: string): boolean
	return string.sub(id, 1, #M.PREFIX) == M.PREFIX
end

function M.new_id(): string
	return string.format("%s%x%06x", M.PREFIX, math.floor(os.time()), math.random(0, 0xffffff))
end

-- A task's title: the first non-empty line of its text, clipped.
function M.title(text: string): string
	for line in string.gmatch(text, "[^\n]+") do
		local t = util.trim(line)
		if t ~= "" then
			return util.clip(t, 80)
		end
	end
	return "任务"
end

-- What the agent is told around the task's text.
local function prompt(task: store.Task, repo: string?): string
	local where = if task.workspace == "worktree"
		then `你在仓库 {repo or "?"} 的一个临时 git worktree 里工作(与维护者的检出隔离)。直接修改文件即可;不要推送,也不必提交,Roost 会在结束时收集全部改动供人审阅、开 PR 或建本地分支。`
		elseif task.workspace == "repo" then `你在仓库 {repo or "?"} 的本机检出里工作,改动会直接留在这个检出中。`
		else "你在一个空的临时目录里工作,结束后目录会被删除。"
	return `{where}\n结束时用几句中文说明做了什么、改了哪些文件、还有什么没做完。\n\n任务:\n{task.prompt}`
end

-- Opens the PR from the worktree prepared at the parent's base with its patch applied.
M.PR_SCRIPT = [[
set -e
cd "$ROOST_WORKSPACE"
git add -A
if git diff --cached --quiet; then
	echo "[roost] 没有可提交的改动" >&2
	exit 1
fi
git commit --quiet --no-verify -m "$ROOST_PR_TITLE"
echo "[roost] 推送分支 $ROOST_PR_BRANCH"
# The branch is Roost's own (roost/<run id>): a retry after a failed `gh pr create` replaces it.
git push --quiet origin "+HEAD:refs/heads/$ROOST_PR_BRANCH"
printf '%s\n' "$ROOST_PR_BODY" >"$ROOST_TMP/pr-body.md"
set -- --repo "$ROOST_REPO" --head "$ROOST_PR_BRANCH" --title "$ROOST_PR_TITLE" --body-file "$ROOST_TMP/pr-body.md"
if [ -n "$ROOST_PR_BASE" ]; then
	set -- "$@" --base "$ROOST_PR_BASE"
fi
url=$(gh pr create "$@")
echo "[roost] 已开 PR:$url"
printf 'pr=%s\n' "$url" >>"$ROOST_OUTPUT"
]]

-- `sh -c BRANCH_SCRIPT roost REPO BRANCH BASE PATCH MESSAGE`: a local branch at BASE with PATCH
-- committed, made in a throwaway worktree, so the checkout's own branch and files stay as they are.
M.BRANCH_SCRIPT = [[
repo=$1; br=$2; base=$3; patch=$4; msg=$5
if git -C "$repo" show-ref --verify --quiet "refs/heads/$br"; then
	echo "分支 $br 已存在" >&2
	exit 3
fi
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$repo" fetch --quiet origin "$base" || {
	echo "仓库里找不到提交 $base" >&2
	exit 4
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/roost-branch.XXXXXX") || exit 5
trap 'git -C "$repo" worktree remove --force "$tmp/wt" >/dev/null 2>&1; rm -rf "$tmp"; git -C "$repo" worktree prune >/dev/null 2>&1' EXIT
git -C "$repo" worktree add --quiet -b "$br" "$tmp/wt" "$base" || exit 6
if git -C "$tmp/wt" config user.email >/dev/null 2>&1; then
	set --
else
	set -- -c user.name=Roost -c user.email=roost@localhost
fi
if ! git -C "$tmp/wt" apply --index "$patch"; then
	why="补丁无法应用到 $base"
elif ! git "$@" -C "$tmp/wt" commit --quiet --no-verify -m "$msg"; then
	why="提交失败"
else
	echo "$br"
	exit 0
fi
git -C "$repo" worktree remove --force "$tmp/wt" >/dev/null 2>&1
git -C "$repo" branch -D "$br" >/dev/null 2>&1
echo "$why" >&2
exit 7
]]

-- The workflow a built-in run follows. `repo`: the run's repository (for the agent's instructions).
function M.workflow(id: string, task: store.Task, repo: string?): model.Workflow
	local workspace: "worktree" | "repo" | "temp" = if task.workspace == "worktree"
		then "worktree"
		elseif task.workspace == "repo" then "repo"
		else "temp"
	local wf: model.Workflow = {
		id = id,
		name = if task.kind == "pr" then "开 PR" else "任务",
		icon = if task.kind == "pr" then "push" else "omp",
		enabled = true,
		manual = true,
		notify = true,
		reply = false,
		concurrency = "queue",
		workspace = workspace,
		env = {},
		inputs = {},
		triggers = {},
		steps = {},
		libs = {},
		state = M.STATE,
		environment = task.environment,
	}
	if task.kind == "pr" then
		wf.env = {
			ROOST_PR_TITLE = task.prompt,
			ROOST_PR_BODY = task.body or "",
			ROOST_PR_BRANCH = task.branch or "",
			ROOST_PR_BASE = task.base or "",
		}
		wf.steps = {
			{ name = "提交并开 PR", kind = "run", script = M.PR_SCRIPT, args = {}, continue_on_error = false },
		}
	else
		wf.steps = {
			{
				name = "执行任务",
				kind = "omp",
				-- Literal: the text is the user's, never a template.
				prompt = { parts = { { lit = prompt(task, repo) } } },
				model = task.model,
				args = {},
				continue_on_error = false,
			},
		}
	end
	return wf
end

export type FileChange = { path: string, add: number?, del: number? } -- nil counts: binary

-- `git diff --numstat` output: one row per file (binary files show "-"), and the totals.
function M.parse_numstat(text: string): ({ FileChange }, store.Changes)
	local rows: { FileChange } = {}
	local sum: store.Changes = { files = 0, add = 0, del = 0 }
	for line in string.gmatch(text, "[^\n]+") do
		local a, d, path = string.match(line, "^(%S+)\t(%S+)\t(.+)$")
		if a and d and path then
			sum.files += 1
			local na, nd = tonumber(a), tonumber(d)
			sum.add += na or 0
			sum.del += nd or 0
			if #rows < M.MAX_FILES then
				table.insert(rows, { path = path, add = na, del = nd })
			end
		end
	end
	return rows, sum
end

return M
