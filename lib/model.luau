--!strict
-- The two local config files, parsed and validated:
--   roost.toml      binding: relay URL/token, runner settings, the user's GitHub login
--   workflows.toml  repos (local checkouts), workflows, schedule/GitHub triggers, steps
-- Problems come back as issues with 1-based lines where known; callers keep the last good model.
--
-- workflows.toml is also written back by the automation editor: `raw_workflow` hands out the
-- TOML-shaped table of one workflow, `encode_workflow` + `splice_workflow` put an edited one back,
-- and `parse_workflows` of the result is the one validator for hand edits and the editor alike.

local toml = require("./toml")
local cron = require("./cron")
local template = require("./template")
local util = require("./util")

local M = {}

export type Issue = { file: string, path: string, message: string, line: number? }

export type Relay = { url: string?, token: string?, token_env: string?, client_name: string? }
export type Runner = {
	omp: string,
	omp_args: { string },
	session: string, -- the Tern session agent steps open their tabs in
	shell: string,
	git: string,
	max_concurrent: number,
	default_timeout: number,
	extra_path: { string },
	env: { [string]: string },
}
-- `identity`: how runs act on GitHub by default: "app" (the relay's GitHub App) or "local" (your gh).
export type Github = { login: string?, identity: "app" | "local" }
-- What Roost keeps on disk and for how long (seconds; 0 = no age limit).
export type Retention = { runs: number, run_age: number, events: number, event_age: number }
export type Config = { relay: Relay, runner: Runner, github: Github, retention: Retention }

export type Repo = { name: string, path: string?, branch: string?, worktree: boolean }
export type Input = { name: string, description: string?, default: string?, required: boolean }
-- A schedule. `expr` is the compiled 5-field cron (empty for `once`, which fires at `at`).
export type CronTrigger = {
	kind: "cron",
	schedule: string,
	expr: string,
	cron: cron.Cron?,
	at: number?,
	at_text: string?,
	days: { string },
	time: string?,
	between: { string }?,
	day: number?,
	date: string?,
	utc: boolean,
	repo: string?,
	ref: string?,
	line: number?,
}
export type Trigger = CronTrigger | GithubTrigger
-- A GitHub trigger of kind `on` (see GITHUB_KINDS); every list filter is "any" when empty.
export type GithubTrigger = {
	kind: "github",
	on: string,
	events: { string },
	actions: { string },
	repos: { string },
	authors: { string },
	assignees: { string },
	branches: { string },
	labels: { string },
	label_actions: { string },
	conclusions: { string },
	workflows: { string },
	review_states: { string },
	thread_actions: { string },
	comment: string?,
	skip_drafts: boolean,
	include_closed: boolean,
	ignore_bots: boolean,
	ignore_self: boolean,
	forks: boolean,
	associations: { string }?,
	line: number?,
}
-- `when = "out.x"` / `"!input.y"`: the step runs only while that value is truthy (or, with `!`, not).
export type When = { source: "out" | "input", key: string, negate: boolean }
-- A `file` step's script: one of the workflow's own files, or `@<库>/<路径>` in the file library.
export type FileRef = { lib: string?, path: string }
export type Step = {
	name: string,
	kind: "omp" | "run" | "file",
	prompt: template.Template?,
	script: string?,
	file: FileRef?,
	model: string?,
	args: { string },
	timeout: number?,
	continue_on_error: boolean,
	when: When?,
}
export type Workflow = {
	id: string,
	name: string,
	icon: string?,
	description: string?,
	enabled: boolean,
	manual: boolean,
	notify: boolean,
	timeout: number?,
	concurrency: "queue" | "skip" | "replace",
	workspace: "auto" | "worktree" | "repo" | "temp",
	env: { [string]: string },
	identity: ("app" | "local")?, -- nil: roost.toml [github] identity
	daily_budget: number?, -- USD the workflow's omp steps may spend per local day (estimated)
	inputs: { Input },
	triggers: { Trigger },
	steps: { Step },
	-- File libraries every run gets a copy of: `libs` plus those its `file` steps name (sorted).
	libs: { string },
	-- The state group (`state/<名>/`, $ROOST_STATE) kept across runs; the workflow id unless set.
	state: string,
	line: number?,
}
export type Workflows = {
	text: string,
	repos: { [string]: Repo },
	list: { Workflow },
	by_id: { [string]: Workflow },
}

M.DEFAULT_OMP_ARGS = { "--approval-mode", "yolo" }
M.DEFAULT_SESSION = "Roost"
-- omp flags Roost sets itself: agent steps are interactive and keep their conversation in the run.
local RESERVED_OMP_FLAGS = {
	["-p"] = true,
	["--print"] = true,
	["--session-dir"] = true,
	["--no-session"] = true,
	["-r"] = true,
	["--resume"] = true,
	["-c"] = true,
	["--continue"] = true,
	["--restore"] = true,
}
M.DEFAULT_EXTRA_PATH = { "~/.local/bin", "~/.bun/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin" }

-- ---------------------------------------------------------------------------------------------
-- Trigger catalogue: what the editor offers and what each trigger kind accepts.

export type Option = { value: string, label: string }
export type FilterMeta = {
	label: string,
	kind: "list" | "choice" | "text" | "toggle",
	-- Where the editor gets suggestions (core.gh): repos | people | labels | branches | workflows.
	suggest: string?,
	options: { Option }?,
	hint: string?,
	default: boolean?,
}
export type KindMeta = {
	id: string,
	label: string,
	detail: string,
	icon: string,
	-- GitHub events the kind listens to; nil for `event`, whose `event` key names it.
	events: { string }?,
	filters: { string },
}
export type ScheduleMeta = { id: string, label: string, detail: string, keys: { string } }

local CONCLUSIONS: { Option } = {
	{ value = "success", label = "成功" },
	{ value = "failure", label = "失败" },
	{ value = "neutral", label = "中性" },
	{ value = "cancelled", label = "已取消" },
	{ value = "timed_out", label = "超时" },
	{ value = "action_required", label = "需要采取行动" },
	{ value = "stale", label = "陈旧" },
	{ value = "skipped", label = "已跳过" },
	{ value = "startup_failure", label = "启动失败" },
}

M.FILTERS = {
	repos = { label = "仓库", kind = "list", suggest = "repos", hint = "owner/name,支持 owner/*" },
	authors = { label = "作者", kind = "list", suggest = "people", hint = "PR、Issue、评论或推送的作者;@me 表示你自己" },
	assignees = { label = "PR / Issue 负责人", kind = "list", suggest = "people", hint = "@me 表示你自己" },
	branches = { label = "分支", kind = "list", suggest = "branches", hint = "支持 * 通配,如 release/*" },
	labels = { label = "标签", kind = "list", suggest = "labels" },
	workflows = { label = "工作流名称", kind = "list", suggest = "workflows" },
	actions = { label = "动作", kind = "list", hint = "事件的 action,如 opened、published" },
	comment = { label = "评论前缀", kind = "text", hint = "只在评论以此开头时触发,如 /roost" },
	label_actions = {
		label = "标签操作",
		kind = "choice",
		options = { { value = "added", label = "已添加" }, { value = "removed", label = "已移除" } },
	},
	review_states = {
		label = "审阅状态",
		kind = "choice",
		options = {
			{ value = "approved", label = "已批准" },
			{ value = "changes_requested", label = "已请求更改" },
			{ value = "commented", label = "已评论" },
		},
	},
	thread_actions = {
		label = "线程操作",
		kind = "choice",
		options = { { value = "resolved", label = "已解决" }, { value = "unresolved", label = "未解决" } },
	},
	conclusions = { label = "结论", kind = "choice", options = CONCLUSIONS },
	skip_drafts = { label = "跳过草稿 PR", kind = "toggle", default = true },
	include_closed = { label = "关闭时触发,无需合并", kind = "toggle", default = false },
	ignore_bots = { label = "忽略机器人", kind = "toggle", default = true },
	ignore_self = { label = "忽略我自己的活动", kind = "toggle", default = true },
	forks = { label = "接受来自 fork 的代码", kind = "toggle", default = false, hint = "CI 结果可能来自外部贡献者的代码" },
} :: { [string]: FilterMeta }

-- The events the relay's GitHub App subscribes to (agent/src/github.rs APP_EVENTS): no trigger
-- can listen for anything else.
M.APP_EVENTS = {
	"check_suite", "issue_comment", "issues", "pull_request", "pull_request_review",
	"pull_request_review_comment", "pull_request_review_thread", "push", "release", "workflow_run",
}

M.GITHUB_KINDS = {
	{
		id = "pr_opened",
		label = "拉取请求已打开",
		detail = "当拉取请求打开(非草稿)或标记为可审查时触发。",
		icon = "merge",
		events = { "pull_request" },
		filters = { "repos", "authors" },
	},
	{
		id = "pr_draft",
		label = "草稿已打开",
		detail = "当拉取请求作为草稿打开或转换为草稿时触发。",
		icon = "merge",
		events = { "pull_request" },
		filters = { "repos", "authors" },
	},
	{
		id = "pr_pushed",
		label = "拉取请求已推送",
		detail = "当新提交推送到拉取请求(同步)时触发。",
		icon = "push",
		events = { "pull_request" },
		filters = { "repos", "authors", "skip_drafts" },
	},
	{
		id = "pr_merged",
		label = "拉取请求已合并",
		detail = "当拉取请求合并时触发。",
		icon = "merge",
		events = { "pull_request" },
		filters = { "repos", "authors", "include_closed" },
	},
	{
		id = "comment",
		label = "已添加评论",
		detail = "当在拉取请求或议题上添加评论时触发。除非您将自己添加为作者筛选器,否则不会触发您自己的评论。",
		icon = "message",
		events = { "issue_comment" },
		filters = { "repos", "authors", "assignees", "comment", "ignore_bots", "ignore_self" },
	},
	{
		id = "push",
		label = "新的分支推送",
		detail = "当提交推送到分支时触发。",
		icon = "branch",
		events = { "push" },
		filters = { "repos", "authors", "branches" },
	},
	{
		id = "label",
		label = "标签变更",
		detail = "当在拉取请求或议题上添加或移除标签时触发。",
		icon = "tag",
		events = { "issues", "pull_request" },
		filters = { "repos", "authors", "assignees", "label_actions", "labels" },
	},
	{
		id = "check_completed",
		label = "已完成检查",
		detail = "当检查套件完成时,每个 CI 应用每个套件触发一次(不是当 PR 的所有检查完成时)。",
		icon = "list-checks",
		events = { "check_suite" },
		filters = { "repos", "authors", "conclusions", "forks" },
	},
	{
		id = "issue_comment",
		label = "议题评论",
		detail = "当在纯议题(非 PR)上添加评论时触发。除非您将自己添加为作者筛选器,否则不会触发您自己的评论。",
		icon = "message",
		events = { "issue_comment" },
		filters = { "repos", "authors", "assignees", "comment", "ignore_bots", "ignore_self" },
	},
	{
		id = "review_comment",
		label = "PR 审查评论",
		detail = "当在拉取请求上添加审查评论时触发。除非您将自己添加为作者筛选器,否则不会触发您自己的评论。",
		icon = "message",
		events = { "pull_request_review_comment" },
		filters = { "repos", "authors", "assignees", "comment", "ignore_bots", "ignore_self" },
	},
	{
		id = "review",
		label = "PR 审查已提交",
		detail = "当提交拉取请求审查时触发。除非您将自己添加为作者筛选器,否则不会触发您自己的审查。",
		icon = "eye",
		events = { "pull_request_review" },
		filters = { "repos", "authors", "assignees", "review_states", "ignore_bots", "ignore_self" },
	},
	{
		id = "review_thread",
		label = "审查线程",
		detail = "当审查线程被解决或未解决时触发。",
		icon = "eye",
		events = { "pull_request_review_thread" },
		filters = { "repos", "authors", "thread_actions" },
	},
	{
		id = "workflow_run",
		label = "工作流运行已完成",
		detail = "当 GitHub Actions 工作流运行完成时触发。",
		icon = "activity",
		events = { "workflow_run" },
		filters = { "repos", "authors", "branches", "conclusions", "workflows", "forks" },
	},
	{
		id = "issue_opened",
		label = "Issue 已打开",
		detail = "当新的议题被创建时触发。",
		icon = "bug",
		events = { "issues" },
		filters = { "repos", "authors", "labels", "ignore_bots" },
	},
	{
		id = "event",
		label = "自定义事件",
		detail = "任意 GitHub webhook 事件(如 release),按 action 等筛选。",
		icon = "bolt",
		events = nil,
		filters = { "repos", "authors", "actions", "branches", "labels", "comment" },
	},
} :: { KindMeta }

-- GitHub trigger kinds that are always about one pull request.
M.PR_KINDS = {
	pr_opened = true,
	pr_draft = true,
	pr_pushed = true,
	pr_merged = true,
	review_comment = true,
	review = true,
	review_thread = true,
}

-- Whether a manual run of `wf` can target a pull request: "only" when every trigger is a PR
-- trigger (a run without one has nothing to work on), "some" when others exist, else nil.
function M.pr_target(wf: Workflow): string?
	local pr, other = false, false
	for _, t in wf.triggers do
		if t.kind == "github" and M.PR_KINDS[(t :: GithubTrigger).on] then
			pr = true
		else
			other = true
		end
	end
	return if not pr then nil elseif other then "some" else "only"
end

M.SCHEDULES = {
	{ id = "once", label = "一次", detail = "在选定的日期和时间", keys = { "at" } },
	{ id = "hourly", label = "每小时", detail = "在所选小时内每小时", keys = { "days", "between" } },
	{ id = "daily", label = "每天", detail = "每天在选定的时间", keys = { "time" } },
	{ id = "weekly", label = "每周", detail = "每周在选定的几天", keys = { "days", "time" } },
	{ id = "monthly", label = "每月", detail = "每月在选定的一天", keys = { "day", "time" } },
	{ id = "yearly", label = "每年", detail = "每年在选定的日期", keys = { "date", "time" } },
	{ id = "cron", label = "自定义 cron", detail = "5 段 cron 表达式(高级)", keys = { "cron" } },
} :: { ScheduleMeta }

M.DAYS = {
	{ id = "sun", label = "日" },
	{ id = "mon", label = "一" },
	{ id = "tue", label = "二" },
	{ id = "wed", label = "三" },
	{ id = "thu", label = "四" },
	{ id = "fri", label = "五" },
	{ id = "sat", label = "六" },
}

-- Icons the editor offers for a workflow (Tern icon names).
M.ICONS = {
	"bolt", "sparkle", "rocket", "bug", "merge", "message", "eye", "list-checks", "activity", "clock",
	"bell", "newspaper", "shield", "wrench", "brain", "lightbulb", "flame", "chart", "terminal", "branch",
}

local KIND_BY_ID: { [string]: KindMeta } = {}
for _, k in M.GITHUB_KINDS do
	KIND_BY_ID[k.id] = k
end
local SCHEDULE_BY_ID: { [string]: ScheduleMeta } = {}
for _, s in M.SCHEDULES do
	SCHEDULE_BY_ID[s.id] = s
end
local DAY_NUM: { [string]: number } = {}
for i, d in M.DAYS do
	DAY_NUM[d.id] = i - 1
end

function M.kind(id: string): KindMeta?
	return KIND_BY_ID[id]
end

function M.schedule(id: string): ScheduleMeta?
	return SCHEDULE_BY_ID[id]
end

-- Starter workflows the editor opens prefilled (never saved until the user saves).
export type Template = { id: string, name: string, description: string, icon: string, group: string, raw: { [string]: any } }
M.TEMPLATES = {
	{
		id = "pr-review",
		name = "PR 审查",
		description = "新 PR 打开时,审查改动并留下评论。",
		icon = "eye",
		group = "代码审查",
		raw = {
			name = "PR 审查",
			icon = "eye",
			trigger = { { github = "pr_opened" } },
			step = {
				{
					name = "审查",
					omp = "审查 {{repo}} 的拉取请求 #{{number}}「{{title}}」:{{url}}\n\n用 gh pr diff {{number}} 查看改动,找出缺陷、风险和可以改进的地方,再用 gh pr review {{number}} --comment 提交审查意见。",
				},
			},
		},
	},
	{
		id = "issue-triage",
		name = "Issue 分诊",
		description = "新 Issue 打开时,复现、定位并回复初步分析。",
		icon = "bug",
		group = "议题",
		raw = {
			name = "Issue 分诊",
			icon = "bug",
			trigger = { { github = "issue_opened" } },
			step = {
				{
					name = "分诊",
					omp = "分析 {{repo}} 的 Issue #{{number}}「{{title}}」:\n\n{{body}}\n\n在代码里定位相关位置,判断类型与优先级,然后用 gh issue comment {{number}} 回复你的分析和建议的下一步。",
				},
			},
		},
	},
	{
		id = "comment-command",
		name = "评论指令 /roost",
		description = "有人评论「/roost …」时,按评论里的要求处理。",
		icon = "message",
		group = "议题",
		raw = {
			name = "评论指令",
			icon = "message",
			trigger = { { github = "comment", comment = "/roost" } },
			step = {
				{
					name = "执行指令",
					omp = "{{sender}} 在 {{repo}} #{{number}}「{{title}}」上留言:\n\n{{comment}}\n\n按留言中 /roost 之后的要求处理,完成后用 gh 在该 issue/PR 下回复结果。",
				},
			},
		},
	},
	{
		id = "ci-failure",
		name = "CI 失败分析",
		description = "GitHub Actions 运行失败时,找出原因并给出修复建议。",
		icon = "activity",
		group = "CI",
		raw = {
			name = "CI 失败分析",
			icon = "activity",
			trigger = { { github = "workflow_run", conclusions = { "failure" } } },
			step = {
				{
					name = "分析",
					omp = "{{repo}} 的工作流「{{workflow}}」在分支 {{branch}}({{sha}})上失败:{{url}}\n\n用 gh run view --log-failed 查看失败日志,找出根因并给出修复建议。",
				},
			},
		},
	},
	{
		id = "daily-digest",
		name = "每日仓库摘要",
		description = "工作日早上汇总新的 Issue、PR 与 CI 状态。",
		icon = "newspaper",
		group = "定时",
		raw = {
			name = "每日仓库摘要",
			icon = "newspaper",
			trigger = { { schedule = "weekly", days = { "mon", "tue", "wed", "thu", "fri" }, time = "09:00" } },
			step = {
				{
					name = "摘要",
					omp = "用 gh 汇总当前仓库过去 24 小时新增的 Issue、PR 和失败的 CI 运行,按优先级列出需要我处理的事项。",
				},
			},
		},
	},
	{
		id = "weekly-review",
		name = "每周回顾",
		description = "周五下午总结本周合并的改动和遗留问题。",
		icon = "chart",
		group = "定时",
		raw = {
			name = "每周回顾",
			icon = "chart",
			trigger = { { schedule = "weekly", days = { "fri" }, time = "17:00" } },
			step = {
				{
					name = "回顾",
					omp = "总结当前仓库本周合并的 PR、关闭的 Issue 和仍未解决的问题,列出下周的优先事项。",
				},
			},
		},
	},
} :: { Template }

local function valid_id(s: string): boolean
	return #s <= 64 and string.match(s, "^[a-z0-9][a-z0-9_%-]*$") ~= nil
end

function M.valid_repo(s: string): boolean
	local owner, name = string.match(s, "^([%w%-_%.]+)/([%w%-_%.]+)$")
	return owner ~= nil and name ~= nil and owner ~= "." and owner ~= ".." and name ~= "." and name ~= ".."
end

-- A small checker over one table: typed getters that record issues and unknown-key detection.
type Ctx = {
	file: string,
	issues: { Issue },
	pos: toml.Positions,
}

local function issue(c: Ctx, path: string, message: string, line: number?)
	table.insert(c.issues, { file = c.file, path = path, message = message, line = line })
end

local function line_of(c: Ctx, t: any, key: any): number?
	local p = c.pos[t]
	return if p then p[key] else nil
end

local function check_keys(c: Ctx, t: { [string]: any }, path: string, allowed: { string })
	local ok: { [string]: boolean } = {}
	for _, k in allowed do
		ok[k] = true
	end
	for k in t do
		if not ok[k] then
			issue(c, path, `未知字段 {k}(可用:{table.concat(allowed, ", ")})`, line_of(c, t, k))
		end
	end
end

local function get_string(c: Ctx, t: { [string]: any }, key: string, path: string): string?
	local v = t[key]
	if v == nil then
		return nil
	end
	if type(v) ~= "string" then
		issue(c, `{path}.{key}`, "应为字符串", line_of(c, t, key))
		return nil
	end
	return v
end

local function get_bool(c: Ctx, t: { [string]: any }, key: string, path: string, default: boolean): boolean
	local v = t[key]
	if v == nil then
		return default
	end
	if type(v) ~= "boolean" then
		issue(c, `{path}.{key}`, "应为 true 或 false", line_of(c, t, key))
		return default
	end
	return v
end

local function get_int(
	c: Ctx,
	t: { [string]: any },
	key: string,
	path: string,
	default: number,
	lo: number,
	hi: number
): number
	local v = t[key]
	if v == nil then
		return default
	end
	if type(v) ~= "number" or v ~= math.floor(v) or v < lo or v > hi then
		issue(c, `{path}.{key}`, `应为 {lo}..{hi} 的整数`, line_of(c, t, key))
		return default
	end
	return v
end

local function get_strings(c: Ctx, t: { [string]: any }, key: string, path: string): { string }
	local v = t[key]
	if v == nil then
		return {}
	end
	local out = {}
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为字符串数组", line_of(c, t, key))
		return out
	end
	for _, x in v do
		if type(x) ~= "string" then
			issue(c, `{path}.{key}`, "应为字符串数组", line_of(c, t, key))
			return {}
		end
		table.insert(out, x)
	end
	return out
end

-- Flags in `args` that Roost manages itself, as an issue.
local function check_omp_args(c: Ctx, args: { string }, path: string, line: number?)
	for _, a in args do
		local flag = string.match(a, "^([^=]+)=") or a
		if RESERVED_OMP_FLAGS[flag] then
			issue(c, path, `{flag} 由 Roost 管理(omp 步骤以交互式 agent 运行,会话保存在运行目录),请删除`, line)
		end
	end
end

local function get_map(c: Ctx, t: { [string]: any }, key: string, path: string): { [string]: string }
	local v = t[key]
	local out: { [string]: string } = {}
	if v == nil then
		return out
	end
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为表 { KEY = \"值\" }", line_of(c, t, key))
		return out
	end
	for k, x in v do
		if type(k) ~= "string" or type(x) ~= "string" then
			issue(c, `{path}.{key}`, "键和值都应为字符串", line_of(c, t, key))
		else
			out[k] = x
		end
	end
	return out
end

local function get_table(c: Ctx, t: { [string]: any }, key: string, path: string): { [string]: any }
	local v = t[key]
	if v == nil then
		return {}
	end
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为表", line_of(c, t, key))
		return {}
	end
	return v
end

local function get_list(c: Ctx, t: { [string]: any }, key: string, path: string): { any }
	local v = t[key]
	if v == nil then
		return {}
	end
	if type(v) ~= "table" or (next(v) ~= nil and v[1] == nil) then
		issue(c, `{path}.{key}`, `应为 [[{path}.{key}]] 表数组`, line_of(c, t, key))
		return {}
	end
	return v
end

local function get_duration(c: Ctx, t: { [string]: any }, key: string, path: string): number?
	local s = get_string(c, t, key, path)
	if s == nil then
		return nil
	end
	local d, err = util.duration(s)
	if not d then
		issue(c, `{path}.{key}`, err or "时长无效", line_of(c, t, key))
	end
	return d
end

-- A step output name (`key=value` lines a shell step appends to $ROOST_OUTPUT).
function M.valid_output_key(k: string): boolean
	return #k <= 64 and string.match(k, "^[%a_][%w_]*$") ~= nil
end

-- A path among a workflow's or a library's files: 1-8 `/`-separated parts, each starting with a
-- letter, digit or `_` (so no hidden names, `.` or `..`), at most 255 bytes.
function M.valid_file_path(p: string): boolean
	if #p == 0 or #p > 255 then
		return false
	end
	local n = 0
	for seg in string.gmatch(p .. "/", "([^/]*)/") do
		n += 1
		if n > 8 or string.match(seg, "^[%w_][%w_%.%-]*$") == nil then
			return false
		end
	end
	return true
end

-- A file library's name (its directory under `library/`): same rules as a workflow id.
function M.valid_lib(s: string): boolean
	return valid_id(s)
end

-- What runs a `file` step's script, by extension (the program is looked up on the step's PATH).
M.INTERPRETERS = {
	py = { "python3" },
	sh = { "/bin/sh" },
	bash = { "bash" },
	js = { "node" },
	mjs = { "node" },
	cjs = { "node" },
}

function M.interpreter(path: string): { string }?
	local ext = string.match(path, "%.(%w+)$")
	return if ext then M.INTERPRETERS[string.lower(ext)] else nil
end

-- `file = "<路径>"` (the workflow's own file) or `"@<库>/<路径>"` (a library's), or nil when malformed.
function M.file_ref(s: string): FileRef?
	local lib, rest = string.match(s, "^@([^/]+)/(.+)$")
	if lib and rest then
		return if valid_id(lib) and M.valid_file_path(rest) then { lib = lib, path = rest } else nil
	end
	return if M.valid_file_path(s) then { lib = nil, path = s } else nil
end

-- How a file reference is written (`file = …`).
function M.file_ref_text(ref: FileRef): string
	return if ref.lib then `@{ref.lib}/{ref.path}` else ref.path
end

-- Whether a step output or input value counts as "on" for `when`.
function M.truthy(v: string?): boolean
	if v == nil then
		return false
	end
	local s = string.lower(util.trim(v))
	return s ~= "" and s ~= "0" and s ~= "false" and s ~= "no"
end

-- `daily_budget`: US dollars, more than 0.
local function get_budget(c: Ctx, t: { [string]: any }, key: string, path: string): number?
	local v = t[key]
	if v == nil then
		return nil
	end
	if type(v) ~= "number" or v ~= v or v <= 0 or v > 100000 then
		issue(c, `{path}.{key}`, "应为大于 0 的金额(美元),例如 5 或 2.5", line_of(c, t, key))
		return nil
	end
	return v
end

-- `when = "out.<名>"`、`"input.<名>"`,前面加 `!` 取反。
local function get_when(c: Ctx, t: { [string]: any }, path: string, inputs: { [string]: boolean }): When?
	local s = get_string(c, t, "when", path)
	if s == nil then
		return nil
	end
	local neg, src, key = string.match(util.trim(s), "^(!?)%s*(%a+)%.([%w_]+)$")
	local where = `{path}.when`
	local line = line_of(c, t, "when")
	if src == "out" and key and M.valid_output_key(key) then
		return { source = "out", key = key, negate = neg == "!" }
	elseif src == "input" and key then
		if not inputs[key] then
			issue(c, where, `input.{key} 不是已声明的 [[workflow.input]]`, line)
			return nil
		end
		return { source = "input", key = key, negate = neg == "!" }
	end
	issue(c, where, "应为 out.<输出名> 或 input.<输入名>,可加 ! 取反", line)
	return nil
end

local function parse_toml(file: string, text: string): ({ [string]: any }?, toml.Positions?, { Issue })
	local root, extra = toml.parse(text)
	if root == nil then
		local e = extra :: toml.Err
		return nil, nil, { { file = file, path = file, message = e.message, line = e.line } }
	end
	return root, extra :: toml.Positions, {}
end

-- ---------------------------------------------------------------------------------------------
-- roost.toml

function M.parse_config(text: string): (Config?, { Issue })
	local root, pos, errs = parse_toml("roost.toml", text)
	if root == nil or pos == nil then
		return nil, errs
	end
	local c: Ctx = { file = "roost.toml", issues = {}, pos = pos }
	check_keys(c, root, "roost", { "relay", "runner", "github", "retention" })
	local r = get_table(c, root, "relay", "relay")
	check_keys(c, r, "relay", { "url", "token", "token_env", "client_name" })
	local url = get_string(c, r, "url", "relay")
	if url == "" then
		url = nil
	end
	if url then
		url = string.gsub(url, "/+$", "")
		if not string.match(url :: string, "^https?://[^/]") then
			issue(c, "relay.url", "应以 https:// 或 http:// 开头", line_of(c, r, "url"))
		end
	end
	local token = get_string(c, r, "token", "relay")
	local relay: Relay = {
		url = url,
		token = if token == "" then nil else token,
		token_env = get_string(c, r, "token_env", "relay"),
		client_name = get_string(c, r, "client_name", "relay"),
	}

	local u = get_table(c, root, "runner", "runner")
	-- keep_runs is listed only to say where it went (the error keeps the whole file from applying,
	-- so the old retention never runs under the defaults).
	check_keys(c, u, "runner", {
		"omp", "omp_args", "session", "shell", "git", "max_concurrent", "default_timeout", "extra_path", "env", "keep_runs",
	})
	if u.keep_runs ~= nil then
		issue(c, "runner.keep_runs", "已移到 [retention] runs(保留的已结束运行数);改好之前不会自动清理", line_of(c, u, "keep_runs"))
	end
	local runner: Runner = {
		omp = get_string(c, u, "omp", "runner") or "omp",
		omp_args = if u.omp_args ~= nil then get_strings(c, u, "omp_args", "runner") else table.clone(M.DEFAULT_OMP_ARGS),
		session = get_string(c, u, "session", "runner") or M.DEFAULT_SESSION,
		shell = get_string(c, u, "shell", "runner") or "/bin/sh",
		git = get_string(c, u, "git", "runner") or "git",
		max_concurrent = get_int(c, u, "max_concurrent", "runner", 2, 1, 16),
		default_timeout = get_duration(c, u, "default_timeout", "runner") or 1800,
		extra_path = if u.extra_path ~= nil
			then get_strings(c, u, "extra_path", "runner")
			else table.clone(M.DEFAULT_EXTRA_PATH),
		env = get_map(c, u, "env", "runner"),
	}
	check_omp_args(c, runner.omp_args, "runner.omp_args", line_of(c, u, "omp_args"))
	if runner.session == "" or #runner.session > 64 then
		issue(c, "runner.session", "应为 1..64 个字符的会话名", line_of(c, u, "session"))
	end

	local g = get_table(c, root, "github", "github")
	check_keys(c, g, "github", { "login", "identity" })
	local login = get_string(c, g, "login", "github")
	if login and not string.match(login, "^[%w%-]+$") then
		issue(c, "github.login", "应为 GitHub 用户名", line_of(c, g, "login"))
	end
	local identity = get_string(c, g, "identity", "github") or "app"
	if identity ~= "app" and identity ~= "local" then
		issue(c, "github.identity", "应为 app(以 GitHub App 身份)或 local(本机 gh 身份)", line_of(c, g, "identity"))
		identity = "app"
	end

	local k = get_table(c, root, "retention", "retention")
	check_keys(c, k, "retention", { "runs", "run_age", "events", "event_age" })
	local function age(key: string): number
		local d = get_duration(c, k, key, "retention")
		if d == nil then
			return 30 * 86400
		end
		if d > 0 and d < 3600 then
			issue(c, `retention.{key}`, "至少 1h(例如 \"30d\"),或 \"0\" 表示不按时间清理", line_of(c, k, key))
		end
		return d
	end
	local retention: Retention = {
		runs = get_int(c, k, "runs", "retention", 200, 10, 5000),
		run_age = age("run_age"),
		events = get_int(c, k, "events", "retention", 200, 10, 2000),
		event_age = age("event_age"),
	}
	if #c.issues > 0 then
		return nil, c.issues
	end
	return {
		relay = relay,
		runner = runner,
		github = { login = if login == "" then nil else login, identity = identity :: any },
		retention = retention,
	}, {}
end

-- The token to send: literal, else the named environment variable.
function M.token(relay: Relay): string?
	if relay.token then
		return relay.token
	end
	if relay.token_env and tern then
		local v = tern.getenv(relay.token_env)
		if v and v ~= "" then
			return v
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------
-- workflows.toml

local VALID_ASSOCIATIONS: { [string]: boolean } = {
	OWNER = true, MEMBER = true, COLLABORATOR = true, CONTRIBUTOR = true,
	FIRST_TIME_CONTRIBUTOR = true, FIRST_TIMER = true, MANNEQUIN = true, NONE = true,
}

local function parse_hm(s: string): (number?, number?)
	local h, m = string.match(s, "^(%d%d?):(%d%d)$")
	local hn, mn = tonumber(h), tonumber(m)
	if hn == nil or mn == nil or hn > 23 or mn > 59 then
		return nil, nil
	end
	return hn, mn
end

local function days_in_month(y: number?, m: number): number
	if m == 2 then
		if y == nil or (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then
			return 29
		end
		return 28
	end
	return if m == 4 or m == 6 or m == 9 or m == 11 then 30 else 31
end

-- `time` as hour and minute, recording an issue when missing or malformed.
local function get_time(c: Ctx, t: { [string]: any }, path: string, line: number?): (number, number, string?)
	local s = get_string(c, t, "time", path)
	if s == nil then
		issue(c, `{path}.time`, "缺少时间 time = \"HH:MM\"", line)
		return 0, 0, nil
	end
	local h, m = parse_hm(s)
	if h == nil or m == nil then
		issue(c, `{path}.time`, `时间 "{s}" 无效,应为 HH:MM(24 小时制)`, line_of(c, t, "time"))
		return 0, 0, s
	end
	return h, m, s
end

local function get_days(c: Ctx, t: { [string]: any }, path: string, required: boolean, line: number?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in get_strings(c, t, "days", path) do
		local k = string.lower(d)
		if DAY_NUM[k] == nil then
			issue(c, `{path}.days`, `{d} 不是星期(sun mon tue wed thu fri sat)`, line_of(c, t, "days"))
		elseif not seen[k] then
			seen[k] = true
			table.insert(out, k)
		end
	end
	table.sort(out, function(a, b)
		return DAY_NUM[a] < DAY_NUM[b]
	end)
	if required and #out == 0 then
		issue(c, `{path}.days`, "至少选择一天", line_of(c, t, "days") or line)
	end
	return out
end

-- The day-of-week cron field of `days` (sorted day ids): `*` for none or all.
local function dow_field(days: { string }): string
	if #days == 0 or #days == 7 then
		return "*"
	end
	local nums: { string } = {}
	for _, d in days do
		table.insert(nums, tostring(DAY_NUM[d]))
	end
	return table.concat(nums, ",")
end

local function compile_schedule(c: Ctx, t: { [string]: any }, path: string, line: number?, repos: { [string]: Repo }): CronTrigger?
	local sch = get_string(c, t, "schedule", path) or ""
	local meta = SCHEDULE_BY_ID[sch]
	if meta == nil then
		issue(c, `{path}.schedule`, `未知的定时类型 "{sch}"(可用:once、hourly、daily、weekly、monthly、yearly、cron)`, line_of(c, t, "schedule") or line)
		return nil
	end
	local allowed = { "schedule", "tz", "repo", "ref" }
	for _, k in meta.keys do
		table.insert(allowed, k)
	end
	check_keys(c, t, path, allowed)
	local tz = get_string(c, t, "tz", path) or "local"
	if tz ~= "local" and tz ~= "UTC" then
		issue(c, `{path}.tz`, "tz 只能是 \"local\"(本机时区)或 \"UTC\"", line_of(c, t, "tz"))
	end
	local trig: CronTrigger = {
		kind = "cron",
		schedule = sch,
		expr = "",
		cron = nil,
		at = nil,
		at_text = nil,
		days = {},
		time = nil,
		between = nil,
		day = nil,
		date = nil,
		utc = tz == "UTC",
		repo = nil,
		ref = get_string(c, t, "ref", path),
		line = line,
	}
	if sch == "once" then
		local s = get_string(c, t, "at", path)
		local y, mo, d, h, mi = nil, nil, nil, nil, nil
		if s then
			local a, b, cc, dd, ee = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d?):(%d%d)$")
			y, mo, d, h, mi = tonumber(a), tonumber(b), tonumber(cc), tonumber(dd), tonumber(ee)
		end
		local epoch: number? = nil
		if y and mo and d and h and mi and mo >= 1 and mo <= 12 and d >= 1 and d <= days_in_month(y, mo) and h <= 23 and mi <= 59 then
			epoch = cron.epoch(y, mo, d, h, mi, trig.utc)
		end
		if epoch == nil then
			issue(c, `{path}.at`, `时间 {s or "(缺少)"} 无效,应为 at = "YYYY-MM-DD HH:MM"`, line_of(c, t, "at") or line)
		end
		trig.at, trig.at_text = epoch, s
	elseif sch == "cron" then
		local expr = get_string(c, t, "cron", path)
		if expr == nil then
			issue(c, `{path}.cron`, "缺少 cron = \"<5 段表达式>\"", line)
		else
			trig.expr = expr
		end
	elseif sch == "hourly" then
		trig.days = get_days(c, t, path, false, line)
		local hours = "*"
		if t.between ~= nil then
			local b = get_strings(c, t, "between", path)
			local h1, m1 = parse_hm(b[1] or "")
			local h2, m2 = parse_hm(b[2] or "")
			if #b ~= 2 or h1 == nil or h2 == nil or m1 ~= 0 or m2 ~= 0 or h1 > h2 then
				issue(c, `{path}.between`, "between 应为 [\"HH:00\", \"HH:00\"](整点,开始不晚于结束)", line_of(c, t, "between"))
			else
				hours = if h1 == h2 then tostring(h1) else `{h1}-{h2}`
				trig.between = b
			end
		end
		trig.expr = `0 {hours} * * {dow_field(trig.days)}`
	else
		local h, m, s = get_time(c, t, path, line)
		trig.time = s
		if sch == "daily" then
			trig.expr = `{m} {h} * * *`
		elseif sch == "weekly" then
			trig.days = get_days(c, t, path, true, line)
			trig.expr = `{m} {h} * * {dow_field(trig.days)}`
		elseif sch == "monthly" then
			if t.day == nil then
				issue(c, `{path}.day`, "缺少 day = 1..31", line)
			end
			local day = get_int(c, t, "day", path, 1, 1, 31)
			trig.day = day
			trig.expr = `{m} {h} {day} * *`
		elseif sch == "yearly" then
			local s2 = get_string(c, t, "date", path)
			local a, b = string.match(s2 or "", "^(%d%d)%-(%d%d)$")
			local mo, d = tonumber(a), tonumber(b)
			if mo == nil or d == nil or mo < 1 or mo > 12 or d < 1 or d > days_in_month(nil, mo) then
				issue(c, `{path}.date`, `日期 {s2 or "(缺少)"} 无效,应为 date = "MM-DD"`, line_of(c, t, "date") or line)
			else
				trig.date = s2
				trig.expr = `{m} {h} {d} {mo} *`
			end
		end
	end
	if trig.expr ~= "" then
		local parsed, err = cron.parse(trig.expr)
		if parsed then
			trig.cron = parsed
		else
			issue(c, `{path}.{if sch == "cron" then "cron" else "schedule"}`, err or "cron 无效", line_of(c, t, "cron") or line)
		end
	end
	local repo = get_string(c, t, "repo", path)
	if repo then
		local key = util.ifind(repos, repo)
		if not key then
			issue(c, `{path}.repo`, `{repo} 未在 [repos] 中声明`, line_of(c, t, "repo"))
		end
		trig.repo = key
	end
	return trig
end

local function valid_repo_pattern(s: string): boolean
	return M.valid_repo(s) or string.match(s, "^[%w%-_%.]+/%*$") ~= nil
end

local function compile_github(c: Ctx, t: { [string]: any }, path: string, line: number?): GithubTrigger?
	local gh = get_string(c, t, "github", path) or ""
	local meta = KIND_BY_ID[gh]
	if meta == nil then
		local ids: { string } = {}
		for _, k in M.GITHUB_KINDS do
			table.insert(ids, k.id)
		end
		issue(c, `{path}.github`, `未知的 GitHub 触发器 "{gh}"(可用:{table.concat(ids, "、")})`, line_of(c, t, "github") or line)
		return nil
	end
	local allowed = { "github", "associations" }
	for _, k in meta.filters do
		table.insert(allowed, k)
	end
	if gh == "event" then
		table.insert(allowed, "event")
	end
	check_keys(c, t, path, allowed)
	local trig: GithubTrigger = {
		kind = "github",
		on = gh,
		events = if meta.events then table.clone(meta.events) else {},
		actions = {},
		repos = {},
		authors = {},
		assignees = {},
		branches = {},
		labels = {},
		label_actions = {},
		conclusions = {},
		workflows = {},
		review_states = {},
		thread_actions = {},
		comment = nil,
		skip_drafts = false,
		include_closed = false,
		ignore_bots = false,
		ignore_self = false,
		forks = false,
		associations = nil,
		line = line,
	}
	local set = trig :: any
	local filtered = false
	for _, key in meta.filters do
		local f = M.FILTERS[key]
		if f.kind == "toggle" then
			set[key] = get_bool(c, t, key, path, f.default == true)
		elseif f.kind == "text" then
			local s = get_string(c, t, key, path)
			if s and util.trim(s) ~= "" then
				set[key] = s
				filtered = true
			end
		else
			local list: { string } = {}
			for _, v in get_strings(c, t, key, path) do
				local x = util.trim(v)
				if x == "" then
					continue
				end
				local opts = f.options
				if opts then
					local ok = false
					for _, o in opts do
						ok = ok or o.value == x
					end
					if not ok then
						local vals: { string } = {}
						for _, o in opts do
							table.insert(vals, o.value)
						end
						issue(c, `{path}.{key}`, `{x} 无效(可用:{table.concat(vals, "、")})`, line_of(c, t, key))
					end
				elseif key == "repos" and not valid_repo_pattern(x) then
					issue(c, `{path}.repos`, `仓库 "{x}" 应为 owner/name 或 owner/*`, line_of(c, t, key))
				end
				table.insert(list, x)
			end
			set[key] = list
			if #list > 0 then
				filtered = true
			end
		end
	end
	if gh == "event" then
		local ev = get_string(c, t, "event", path)
		if ev == nil or not table.find(M.APP_EVENTS, ev) then
			issue(
				c,
				`{path}.event`,
				`GitHub App 订阅的事件只有 {table.concat(M.APP_EVENTS, "、")}{if ev then `,没有 {ev}` else ""}`,
				line_of(c, t, "event") or line
			)
		else
			trig.events = { ev }
		end
	end
	if not filtered then
		issue(c, path, "至少添加一个筛选器(仓库、作者等)", line)
	end
	if t.associations ~= nil then
		local assoc = get_strings(c, t, "associations", path)
		for _, a in assoc do
			if a ~= "*" and not VALID_ASSOCIATIONS[a] then
				issue(c, `{path}.associations`, `{a} 不是有效的 author_association`, line_of(c, t, "associations"))
			end
		end
		trig.associations = assoc
	end
	return trig
end

local function compile_trigger(c: Ctx, t: any, path: string, line: number?, repos: { [string]: Repo }): Trigger?
	if type(t) ~= "table" then
		issue(c, path, "应为表", line)
		return nil
	end
	if t.github ~= nil and t.schedule ~= nil then
		issue(c, path, "github 与 schedule 只能二选一", line)
		return nil
	elseif t.github ~= nil then
		return compile_github(c, t, path, line)
	elseif t.schedule ~= nil then
		return compile_schedule(c, t, path, line, repos)
	end
	issue(
		c,
		path,
		if t.cron ~= nil
			then "定时触发器需要 schedule = \"cron\"(与 cron 键一起)"
			else "触发器需要 schedule = \"<定时类型>\" 或 github = \"<触发器种类>\"",
		line
	)
	return nil
end

function M.parse_workflows(text: string): (Workflows?, { Issue })
	local root, pos, errs = parse_toml("workflows.toml", text)
	if root == nil or pos == nil then
		return nil, errs
	end
	local c: Ctx = { file = "workflows.toml", issues = {}, pos = pos }
	check_keys(c, root, "workflows", { "repos", "workflow" })

	local repos: { [string]: Repo } = {}
	local rawrepos = get_table(c, root, "repos", "repos")
	for name, r in rawrepos do
		local path = `repos."{name}"`
		local line = line_of(c, rawrepos, name)
		if not M.valid_repo(name) then
			issue(c, path, "仓库名应为 \"owner/name\"", line)
			continue
		end
		if type(r) ~= "table" then
			issue(c, path, "应为表", line)
			continue
		end
		check_keys(c, r, path, { "path", "branch", "worktree" })
		repos[name] = {
			name = name,
			path = get_string(c, r, "path", path),
			branch = get_string(c, r, "branch", path),
			worktree = get_bool(c, r, "worktree", path, true),
		}
	end

	local list: { Workflow } = {}
	local by_id: { [string]: Workflow } = {}
	local wfs = get_list(c, root, "workflow", "workflow")
	for wi, w in wfs do
		local wline = line_of(c, wfs, wi)
		if type(w) ~= "table" then
			continue
		end
		local id = get_string(c, w, "id", `workflow[{wi}]`) or ""
		local base = `workflow.{if id ~= "" then id else tostring(wi)}`
		check_keys(c, w, base, {
			"id", "name", "icon", "description", "enabled", "manual", "notify", "timeout", "concurrency", "workspace",
			"identity", "daily_budget", "state", "libs", "env", "input", "trigger", "step",
		})
		if not valid_id(id) then
			issue(c, `{base}.id`, `id "{id}" 无效:1-64 位 a-z 0-9 _ -,以字母或数字开头`, line_of(c, w, "id") or wline)
		elseif by_id[id] then
			issue(c, `{base}.id`, `重复的 workflow id "{id}"`, line_of(c, w, "id") or wline)
		end

		local conc = get_string(c, w, "concurrency", base) or "queue"
		if conc ~= "queue" and conc ~= "skip" and conc ~= "replace" then
			issue(c, `{base}.concurrency`, "应为 queue、skip 或 replace", line_of(c, w, "concurrency"))
			conc = "queue"
		end
		local ws = get_string(c, w, "workspace", base) or "auto"
		if ws ~= "auto" and ws ~= "worktree" and ws ~= "repo" and ws ~= "temp" then
			issue(c, `{base}.workspace`, "应为 auto、worktree、repo 或 temp", line_of(c, w, "workspace"))
			ws = "auto"
		end
		local identity = get_string(c, w, "identity", base)
		if identity ~= nil and identity ~= "app" and identity ~= "local" then
			issue(c, `{base}.identity`, "应为 app 或 local(省略则用 roost.toml [github] identity)", line_of(c, w, "identity"))
			identity = nil
		end
		local state = get_string(c, w, "state", base)
		if state ~= nil and not valid_id(state) then
			issue(c, `{base}.state`, `状态组 "{state}" 无效:1-64 位 a-z 0-9 _ -,以字母或数字开头`, line_of(c, w, "state"))
			state = nil
		end
		local libs: { [string]: boolean } = {}
		for _, l in get_strings(c, w, "libs", base) do
			if valid_id(l) then
				libs[l] = true
			else
				issue(c, `{base}.libs`, `文件库名 "{l}" 无效:1-64 位 a-z 0-9 _ -,以字母或数字开头`, line_of(c, w, "libs"))
			end
		end

		local inputs: { Input } = {}
		local input_names: { [string]: boolean } = {}
		local rawinputs = get_list(c, w, "input", base)
		for ii, i in rawinputs do
			local ipath = `{base}.input[{ii}]`
			local iline = line_of(c, rawinputs, ii)
			check_keys(c, i, ipath, { "name", "description", "default", "required" })
			local name = get_string(c, i, "name", ipath) or ""
			if not valid_id(name) then
				issue(c, ipath, `输入名 "{name}" 无效`, iline)
			elseif input_names[name] then
				issue(c, ipath, `重复的输入 "{name}"`, iline)
			end
			input_names[name] = true
			table.insert(inputs, {
				name = name,
				description = get_string(c, i, "description", ipath),
				default = get_string(c, i, "default", ipath),
				required = get_bool(c, i, "required", ipath, false),
			})
		end

		local triggers: { Trigger } = {}
		local rawtrig = get_list(c, w, "trigger", base)
		for ti, t in rawtrig do
			local tr = compile_trigger(c, t, `{base}.trigger[{ti}]`, line_of(c, rawtrig, ti), repos)
			if tr then
				table.insert(triggers, tr)
			end
		end

		local steps: { Step } = {}
		local rawsteps = get_list(c, w, "step", base)
		for si, s in rawsteps do
			local spath = `{base}.step[{si}]`
			local sline = line_of(c, rawsteps, si)
			check_keys(c, s, spath, { "name", "omp", "run", "file", "model", "args", "timeout", "continue_on_error", "when" })
			local prompt = get_string(c, s, "omp", spath)
			local script = get_string(c, s, "run", spath)
			local fileref = get_string(c, s, "file", spath)
			local step: Step = {
				name = get_string(c, s, "name", spath) or "",
				kind = "run",
				prompt = nil,
				script = nil,
				model = get_string(c, s, "model", spath),
				args = get_strings(c, s, "args", spath),
				timeout = get_duration(c, s, "timeout", spath),
				continue_on_error = get_bool(c, s, "continue_on_error", spath, false),
				when = get_when(c, s, spath, input_names),
			}
			if (if prompt then 1 else 0) + (if script then 1 else 0) + (if fileref then 1 else 0) > 1 then
				issue(c, spath, "omp、run 与 file 只能选一个", sline)
			elseif prompt then
				local tpl, err = template.parse(prompt)
				if not tpl then
					issue(c, `{spath}.omp`, err or "模板无效", line_of(c, s, "omp"))
				else
					local bad = template.check(tpl, input_names)
					if bad then
						issue(c, `{spath}.omp`, bad, line_of(c, s, "omp"))
					end
				end
				step.kind = "omp"
				step.prompt = tpl
				check_omp_args(c, step.args, `{spath}.args`, line_of(c, s, "args"))
			elseif script then
				if step.model or #step.args > 0 then
					issue(c, spath, "run 步骤不接受 model 与 args(model 只用于 omp 步骤,args 用于 omp 与 file 步骤)", sline)
				end
				step.script = script
			elseif fileref then
				if step.model then
					issue(c, spath, "model 只用于 omp 步骤", sline)
				end
				local ref = M.file_ref(fileref)
				local fline = line_of(c, s, "file")
				if ref == nil then
					issue(
						c,
						`{spath}.file`,
						"应为 \"<路径>\"(本工作流的文件)或 \"@<文件库>/<路径>\";路径各段以字母、数字或 _ 开头",
						fline
					)
				elseif M.interpreter(ref.path) == nil then
					issue(c, `{spath}.file`, "不支持的脚本类型:扩展名应为 .py .sh .bash .js .mjs .cjs", fline)
				else
					step.kind = "file"
					step.file = ref
					if ref.lib then
						libs[ref.lib] = true
					end
				end
			else
				issue(c, spath, "步骤需要 omp = \"<提示词>\"、run = \"<shell 脚本>\" 或 file = \"<脚本文件>\"", sline)
			end
			if step.name == "" then
				step.name = `{step.kind} #{si}`
			end
			table.insert(steps, step)
		end
		if #steps == 0 then
			issue(c, base, "工作流至少需要一个 [[workflow.step]]", wline)
		end

		local name = get_string(c, w, "name", base)
		local icon = get_string(c, w, "icon", base)
		local wf: Workflow = {
			id = id,
			name = if name and name ~= "" then name else id,
			icon = if icon == "" then nil else icon,
			description = get_string(c, w, "description", base),
			enabled = get_bool(c, w, "enabled", base, true),
			manual = get_bool(c, w, "manual", base, true),
			notify = get_bool(c, w, "notify", base, true),
			timeout = get_duration(c, w, "timeout", base),
			concurrency = conc :: any,
			workspace = ws :: any,
			env = get_map(c, w, "env", base),
			identity = identity :: any,
			daily_budget = get_budget(c, w, "daily_budget", base),
			inputs = inputs,
			triggers = triggers,
			steps = steps,
			libs = util.keys(libs),
			state = state or id,
			line = wline,
		}
		table.insert(list, wf)
		if id ~= "" and by_id[id] == nil then
			by_id[id] = wf
		end
	end
	if #c.issues > 0 then
		table.sort(c.issues, function(a, b)
			return (a.line or 0) < (b.line or 0)
		end)
		return nil, c.issues
	end
	return { text = text, repos = repos, list = list, by_id = by_id }, {}
end

export type Subscription = { events: { string } }

-- What the relay must accept: GitHub events per repo (lower-cased) of enabled workflows' triggers;
-- a trigger for any repo (or an `owner/*` pattern) subscribes under "*".
function M.subscriptions(w: Workflows): { [string]: Subscription }
	local sets: { [string]: { [string]: boolean } } = {}
	for _, wf in w.list do
		if not wf.enabled then
			continue
		end
		for _, t in wf.triggers do
			if t.kind ~= "github" then
				continue
			end
			local gt = t :: GithubTrigger
			local targets: { string } = {}
			for _, r in gt.repos do
				table.insert(targets, if string.find(r, "*", 1, true) then "*" else string.lower(r))
			end
			if #targets == 0 then
				targets = { "*" }
			end
			for _, r in targets do
				local set = sets[r] or {}
				sets[r] = set
				for _, e in gt.events do
					set[e] = true
				end
			end
		end
	end
	local out: { [string]: Subscription } = {}
	for name, set in sets do
		out[name] = { events = util.keys(set) }
	end
	return out
end

-- The `subscriptions.toml` text the agent would hold, for the manual fallback.
function M.subscriptions_toml(subs: { [string]: Subscription }): string
	local lines = {
		"# Roost relay subscriptions (manual copy). Save as the agent's subscriptions.toml,",
		"# then press 重新加载 in Roost (or send SIGHUP / POST /api/v1/reload).",
		"",
	}
	for _, name in util.keys(subs) do
		local s = subs[name]
		table.insert(lines, `[repos.{toml.quote(name)}]`)
		local evs = {}
		for _, e in s.events do
			table.insert(evs, toml.quote(e))
		end
		table.insert(lines, `events = [{table.concat(evs, ", ")}]`)
		table.insert(lines, "")
	end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------------------------
-- Descriptions

local function day_names(days: { string }): string
	if #days == 0 or #days == 7 then
		return "每天"
	end
	if table.concat(days, ",") == "mon,tue,wed,thu,fri" then
		return "工作日"
	end
	local parts: { string } = {}
	for _, d in days do
		local n = DAY_NUM[d]
		table.insert(parts, "周" .. (if n then M.DAYS[n + 1].label else d))
	end
	return table.concat(parts, "、")
end

-- One line for a trigger: 「每周 周一、周五 09:00」, 「拉取请求已打开 · 仓库 acme/web」.
-- `omit_repos` leaves the repository scope out (lists show it once, see trigger_repos).
function M.describe_trigger(t: Trigger, omit_repos: boolean?): string
	if t.kind == "cron" then
		local ct = t :: CronTrigger
		local s: string
		local sch = ct.schedule
		local time = ct.time or ""
		if sch == "once" then
			s = `一次 {ct.at_text or ""}`
		elseif sch == "hourly" then
			local b = ct.between
			s = `每小时 · {day_names(ct.days)} · {if b then `{b[1]}–{b[2]}` else "全天"}`
		elseif sch == "daily" then
			s = `每天 {time}`
		elseif sch == "weekly" then
			s = `每周 {day_names(ct.days)} {time}`
		elseif sch == "monthly" then
			s = `每月 {ct.day or "?"} 日 {time}`
		elseif sch == "yearly" then
			local mo, d = string.match(ct.date or "", "^(%d%d)%-(%d%d)$")
			s = `每年 {tonumber(mo) or "?"} 月 {tonumber(d) or "?"} 日 {time}`
		else
			s = if ct.cron then `{cron.describe(ct.cron)}({ct.expr})` else ct.expr
		end
		if ct.utc then
			s ..= " UTC"
		end
		if ct.repo and not omit_repos then
			s ..= ` · {ct.repo}`
		end
		return s
	end
	local gt = t :: GithubTrigger
	local meta = KIND_BY_ID[gt.on]
	if meta == nil then
		return gt.on
	end
	local parts: { string } = { if gt.on == "event" then `{meta.label} {gt.events[1] or "?"}` else meta.label }
	local get = gt :: any
	for _, key in meta.filters do
		if omit_repos and key == "repos" then
			continue
		end
		local f = M.FILTERS[key]
		local v = get[key]
		if f.kind == "text" and type(v) == "string" then
			table.insert(parts, `{f.label} {v}`)
		elseif (f.kind == "list" or f.kind == "choice") and type(v) == "table" and #v > 0 then
			local shown: { string } = {}
			local opts: { Option } = f.options or {}
			for _, x in v do
				local label = x
				for _, o in opts do
					if o.value == x then
						label = o.label
					end
				end
				table.insert(shown, label)
			end
			table.insert(parts, `{f.label} {table.concat(shown, "、")}`)
		end
	end
	return table.concat(parts, " · ")
end

-- The repositories a trigger is limited to; empty means any.
function M.trigger_repos(t: Trigger): { string }
	if t.kind == "cron" then
		local ct = t :: CronTrigger
		return if ct.repo then { ct.repo } else {}
	end
	return (t :: GithubTrigger).repos
end

-- ---------------------------------------------------------------------------------------------
-- Writing workflows.toml back (the editor)

local function deep_copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deep_copy(x)
	end
	return out
end

-- The TOML-shaped table of workflow `id` in `text` (a copy), or nil.
function M.raw_workflow(text: string, id: string): { [string]: any }?
	local root = toml.parse(text)
	if type(root) ~= "table" or type(root.workflow) ~= "table" then
		return nil
	end
	for _, w in root.workflow do
		if type(w) == "table" and w.id == id then
			return deep_copy(w)
		end
	end
	return nil
end

-- A new workflow for the editor: one empty agent step, no triggers.
function M.new_raw(_now: number?): { [string]: any }
	return { name = "我的自动化", trigger = {}, step = { { name = "指令", omp = "" } } }
end

-- A fresh trigger of `kind` (a schedule id or a GitHub kind id) with sensible values.
function M.trigger_defaults(kind: string, now: number): { [string]: any }
	if SCHEDULE_BY_ID[kind] then
		local t: { [string]: any } = { schedule = kind }
		if kind == "once" then
			t.at = (os.date("%Y-%m-%d", now + 86400) :: string) .. " 09:00"
		elseif kind == "hourly" then
			t.between = { "09:00", "18:00" }
		elseif kind == "daily" then
			t.time = "09:00"
		elseif kind == "weekly" then
			t.days = { "mon" }
			t.time = "09:00"
		elseif kind == "monthly" then
			t.day = 1
			t.time = "09:00"
		elseif kind == "yearly" then
			t.date = os.date("%m-%d", now) :: string
			t.time = "09:00"
		else
			t.cron = "0 9 * * 1-5"
		end
		return t
	end
	local t: { [string]: any } = { github = kind }
	if kind == "event" then
		t.event = "release"
	end
	return t
end

-- An unused workflow id from `name` (ASCII letters and digits; "automation" otherwise).
function M.slug(name: string, taken: { [string]: boolean }): string
	local s = string.gsub(string.lower(name), "[^a-z0-9]+", "-")
	s = string.gsub(string.sub(string.gsub(s, "^%-+", ""), 1, 48), "%-+$", "")
	if s == "" then
		s = "automation"
	end
	local id, n = s, 2
	while taken[id] do
		id = `{s}-{n}`
		n += 1
	end
	return id
end

local WF_ORDER = {
	"id", "name", "icon", "description", "enabled", "manual", "notify", "timeout", "concurrency", "workspace", "identity",
	"daily_budget", "state", "libs", "env",
}
local WF_DEFAULTS: { [string]: any } = { enabled = true, manual = true, notify = true, concurrency = "queue", workspace = "auto" }
local SUB_ORDER: { [string]: { string } } = {
	input = { "name", "description", "default", "required" },
	trigger = {
		"schedule", "at", "days", "between", "day", "date", "time", "cron", "tz", "repo", "ref",
		"github", "event", "repos", "authors", "assignees", "actions", "branches", "labels", "label_actions",
		"conclusions", "workflows", "review_states", "thread_actions", "comment",
		"skip_drafts", "include_closed", "ignore_bots", "ignore_self", "forks", "associations",
	},
	step = { "name", "when", "omp", "run", "file", "model", "args", "timeout", "continue_on_error" },
}
local SUB_DEFAULTS: { [string]: { [string]: any } } = {
	input = { required = false },
	trigger = { tz = "local" },
	step = { continue_on_error = false },
}
for key, f in M.FILTERS do
	if f.kind == "toggle" then
		SUB_DEFAULTS.trigger[key] = f.default == true
	end
end

-- An empty `associations` admits nobody, unlike a missing one; an input's `default = ""` is a
-- value too: keep both.
local KEEP_EMPTY: { [string]: boolean } = { associations = true, default = true }

local function enc_key(k: string): string
	return if string.match(k, "^[%w_%-]+$") then k else toml.quote(k)
end

-- A multi-line basic string (`"""…"""`) so prompts and scripts stay readable in the file;
-- quotes and backslashes are escaped, so no `"""` can close it early.
local function mlquote(s: string): string
	local body = string.gsub(s, "[%c\\\"]", function(ch: string): string
		if ch == "\n" or ch == "\t" then
			return ch
		elseif ch == "\\" then
			return "\\\\"
		elseif ch == '"' then
			return '\\"'
		end
		return string.format("\\u%04X", string.byte(ch))
	end)
	return '"""\n' .. body .. '"""'
end

local function enc_value(v: any): string?
	local t = type(v)
	if t == "string" then
		return if string.find(v, "\n", 1, true) then mlquote(v) else toml.quote(v)
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif t == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return tostring(v)
	elseif t == "table" then
		if next(v) == nil then
			return "[]"
		end
		local parts: { string } = {}
		if v[1] ~= nil then
			for _, x in v do
				local e = enc_value(x)
				if e then
					table.insert(parts, e)
				end
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		for _, k in util.keys(v) do
			local e = enc_value(v[k])
			if e then
				table.insert(parts, `{enc_key(k)} = {e}`)
			end
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return nil
end

-- `key = value` lines: `order` first, then any other keys sorted (a stray key reaches the
-- validator instead of vanishing). nil, "", {} and values equal to their default are left out.
local function enc_lines(out: { string }, t: { [string]: any }, order: { string }, defaults: { [string]: any }, skip: { [string]: boolean })
	local done: { [string]: boolean } = {}
	local function emit(k: string)
		done[k] = true
		local v = t[k]
		if v == nil or skip[k] or (v == "" and not KEEP_EMPTY[k]) then
			return
		end
		if type(v) == "table" and next(v) == nil and not KEEP_EMPTY[k] then
			return
		end
		if defaults[k] ~= nil and util.equal(v, defaults[k]) then
			return
		end
		local e = enc_value(v)
		if e then
			table.insert(out, `{enc_key(k)} = {e}`)
		end
	end
	for _, k in order do
		emit(k)
	end
	local rest: { string } = {}
	for k in t do
		if type(k) == "string" and not done[k] and not skip[k] then
			table.insert(rest, k)
		end
	end
	table.sort(rest)
	for _, k in rest do
		emit(k)
	end
end

-- The `[[workflow]]` block for `raw` (TOML-shaped, as from raw_workflow), ending in a newline.
function M.encode_workflow(raw: { [string]: any }): string
	local out: { string } = { "[[workflow]]" }
	enc_lines(out, raw, WF_ORDER, WF_DEFAULTS, { input = true, trigger = true, step = true })
	for _, sub in { "input", "trigger", "step" } do
		local list = raw[sub]
		if type(list) ~= "table" then
			continue
		end
		for _, item in list do
			if type(item) == "table" then
				table.insert(out, "")
				table.insert(out, `[[workflow.{sub}]]`)
				enc_lines(out, item, SUB_ORDER[sub], SUB_DEFAULTS[sub], {})
			end
		end
	end
	return table.concat(out, "\n") .. "\n"
end

-- The table name of a TOML header line (`[x]` or `[[x]]`), or nil.
local function header_name(line: string): string?
	local s = string.gsub(line, "%s+#.*$", "")
	return string.match(s, "^%s*%[%[%s*([^%[%]]-)%s*%]%]%s*$") or string.match(s, "^%s*%[%s*([^%[%]]-)%s*%]%s*$")
end

-- For each line, whether it starts inside a multi-line string (so a prompt line that looks like
-- a header or a comment is never taken for one).
local function in_string(lines: { string }): { boolean }
	local states: { boolean } = {}
	local open: string? = nil -- the delimiter of the multi-line string we are in
	for i, l in lines do
		states[i] = open ~= nil
		local j, n = 1, #l
		while j <= n do
			local three = string.sub(l, j, j + 2)
			local c = string.sub(l, j, j)
			if open then
				if open == '"""' and c == "\\" then
					j += 2
				elseif three == open then
					open = nil
					j += 3
				else
					j += 1
				end
			elseif c == "#" then
				break
			elseif three == '"""' or three == "'''" then
				open = three
				j += 3
			elseif c == '"' or c == "'" then
				-- A one-line string: skip to its closing quote.
				j += 1
				while j <= n do
					local d = string.sub(l, j, j)
					if c == '"' and d == "\\" then
						j += 2
					elseif d == c then
						break
					else
						j += 1
					end
				end
				j += 1
			else
				j += 1
			end
		end
	end
	return states
end

-- `text` with workflow `id` replaced by `block` (nil deletes it); a nil `id` appends `block`.
-- The block runs from its `[[workflow]]` header to the next header outside `workflow.*`, less
-- the blank and comment lines before that header (they belong to what follows).
function M.splice_workflow(text: string, id: string?, block: string?): (string?, string?)
	if id == nil then
		if block == nil then
			return text, nil
		end
		local t = string.gsub(text, "%s+$", "")
		return (if t == "" then "" else t .. "\n\n") .. block, nil
	end
	local root, extra = toml.parse(text)
	if root == nil then
		return nil, "workflows.toml 有语法错误,先在文件中修复"
	end
	local pos = extra :: toml.Positions
	local wfs = root.workflow
	local start: number? = nil
	if type(wfs) == "table" then
		for wi, w in wfs do
			if type(w) == "table" and w.id == id then
				local p = pos[wfs]
				start = if p then p[wi] else nil
				break
			end
		end
	end
	if start == nil then
		return nil, `workflows.toml 中找不到工作流 {id}`
	end
	local first = start :: number
	local lines = string.split(text, "\n")
	local quoted = in_string(lines)
	local stop = #lines
	for i = first + 1, #lines do
		local name = if quoted[i] then nil else header_name(lines[i])
		if name and (name == "workflow" or string.sub(name, 1, 9) ~= "workflow.") then
			stop = i - 1
			break
		end
	end
	while stop > first and not quoted[stop] and (string.match(lines[stop], "^%s*$") or string.match(lines[stop], "^%s*#")) do
		stop -= 1
	end
	-- Deleting also takes the comment lines right above the header (the block's own notes).
	local keep_to = first - 1
	if block == nil then
		while keep_to >= 1 and not quoted[keep_to] and string.match(lines[keep_to], "^%s*#") do
			keep_to -= 1
		end
	end
	local out: { string } = {}
	for i = 1, keep_to do
		table.insert(out, lines[i])
	end
	if block then
		for _, l in string.split((string.gsub(block, "\n+$", "")), "\n") do
			table.insert(out, l)
		end
	else
		-- And the blank lines that separated it from what came before.
		while #out > 0 and string.match(out[#out], "^%s*$") do
			table.remove(out)
		end
	end
	local rest = lines[stop + 1]
	if #out > 0 and rest ~= nil and not string.match(rest, "^%s*$") then
		table.insert(out, "")
	end
	for i = stop + 1, #lines do
		table.insert(out, lines[i])
	end
	return table.concat(out, "\n"), nil
end

return M
