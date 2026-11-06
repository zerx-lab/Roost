--!strict
-- The workbench runtime, one per host VM: watches the local config files, schedules cron
-- triggers, turns relayed GitHub events into runs, and exposes state and actions to the views.

local model = require("./model")
local store = require("./store")
local runner = require("./runner")
local relay = require("./relay")
local cron = require("./cron")
local match = require("./match")
local util = require("./util")
local eventlog = require("./eventlog")

local M = {}

M.VERSION = "0.1.0"

local WATCH_MS = 3000
local MAX_FILE = 1024 * 1024
local MAX_NOTICES = 30
-- How long a finished run stays in the published status for the window's notification toast.
local NOTIFY_WINDOW = 600
-- Retention runs at start, hourly and on demand; directories go a few per tick.
local HOUSEKEEP_MS = 3600 * 1000
local DRAIN_BATCH = 8
local DRAIN_MS = 30
local SWEEP_CAP = 500
-- Disk usage and webhook delivery stats are fetched when shown, at most this often.
local DISK_TTL = 60
local DELIVERIES_TTL = 30

export type Notice = { at: number, level: string, text: string }
export type EventRow = eventlog.Row
-- The last retention pass: what it removed and whether someone asked for it.
export type Cleanup = { at: number, runs: number, events: number, orphans: number, manual: boolean }
export type Disk = { loading: boolean, at: number?, error: string?, sizes: { [string]: number } }
export type Deliveries = { loading: boolean, at: number?, error: string?, body: { [string]: any }? }
export type CronRow = {
	key: string,
	workflow: string,
	name: string,
	expr: string,
	desc: string,
	utc: boolean,
	repo: string?,
	enabled: boolean,
	next: number?,
}
-- Editor suggestions fetched through the relay (core.gh).
export type GhList = { items: { string }, loading: boolean, error: string?, at: number? }
-- omp's model roles (`modelRoles`, role → selector) and chat models, for the editor's model select.
export type OmpRole = { name: string, model: string }
export type OmpModel = { selector: string, provider: string }
export type OmpModels = { roles: { OmpRole }, models: { OmpModel }, loading: boolean, error: string?, at: number? }
export type AppInfo = {
	configured: boolean,
	name: string?,
	slug: string?,
	owner: string?,
	owner_type: string?,
	html_url: string?,
	install_url: string?,
	settings_url: string?, -- the App's settings page on GitHub (logo, permissions)
	bot: string?, -- `<slug>[bot]`, the account runs acting as the App appear as
	installations: number?,
	missing: { string }?, -- wanted permissions (`name:level`) some installation hasn't granted
}

export type Core = {
	data: string,
	paths: { config: string, workflows: string, theme: string },
	config: model.Config,
	config_issues: { model.Issue },
	config_text: string?,
	workflows: model.Workflows?,
	workflow_issues: { model.Issue },
	workflows_text: string?,
	loaded_at: number?,
	store: store.Store,
	runner: runner.Runner,
	relay: relay.Relay,
	crons: { CronRow },
	events: { EventRow },
	events_path: string,
	cleanup: Cleanup?,
	draining: boolean, -- a store.drain batch is scheduled or running
	disk: Disk,
	deliveries: Deliveries,
	history_wanted: boolean, -- no events.json yet: the relay fetches recent events to show
	notices: { Notice },
	seen: { [string]: boolean },
	seen_order: { string },
	listeners: { [number]: () -> () },
	next_listener: number,
	notify_timer: any?,
	status_json: string?,
	started: boolean,
	gh_cache: { [string]: GhList },
	gh_order: { string },
	omp_models: OmpModels?,
}

local DEFAULT_CONFIG = [[
# Roost 本地绑定配置(只保存在本机 plugin-data 目录,不会同步到服务器)。
# 修改后自动生效。

[relay]
# 服务器上 roost-agent 的地址与令牌(对应 agent.toml 的 [server].public_url 与 [auth].token)。
# 不配置时 cron 与手动运行照常工作,只是收不到 GitHub 事件。
# url = "https://roost.example.com"
# token = "..."            # 或 token_env = "ROOST_TOKEN"(读取 Tern daemon 的环境变量)
# client_name = "my-mac"   # 在中继状态里显示的本机名称

[runner]
# omp 步骤以原生 agent 标签页运行:由 Tern 窗口在下面的会话里新开标签页,结束后自动关闭;
# 会话记录保存在该运行的目录里(--session-dir),随运行一起按 [retention] 清理。没有打开的 Tern 窗口时,
# omp 步骤会一直等到窗口出现或超时;已经打开的 agent 若所有窗口都关了,取消/超时要等窗口回来才会关掉它。
# -p / --session-dir / --resume 等由 Roost 管理,不要写进 omp_args。
# omp = "omp"
# omp_args = ["--approval-mode", "yolo"]
# session = "Roost"
# max_concurrent = 2
# default_timeout = "30m"
# extra_path = ["~/.local/bin", "~/.bun/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
# env = { RUST_LOG = "info" }

[github]
# 运行在 GitHub 上以谁的身份操作(评论、审查、推送):
#   "app"   中继的 GitHub App(<slug>[bot]),每次运行向中继申请只限该仓库的令牌;中继先确认默认分支禁止强推与删除
#   "local" 本机 gh / git 的登录身份
# 工作流里可用 identity = "app" | "local" 单独覆盖;没有关联仓库的运行总是用本机身份。
# identity = "app"
# login = "your-name"      # 你的 GitHub 用户名(@me 与「忽略我自己的活动」),默认取个人 App 的所有者

[retention]
# 自动清理:启动时、每小时、以及改动这里之后执行;「配置」页的「存储与清理」可手动清理。
# 运行包括 runs.json 记录、运行目录(日志、事件负载、omp 会话)与遗留的 worktree;只清理已结束的运行。
# runs = 200               # 最多保留的已结束运行
# run_age = "30d"          # 结束超过这么久的运行会被删除;"0" 表示不按时间清理
# events = 200             # 「事件」页最多保留的记录(events.json)
# event_age = "30d"
]]

local DEFAULT_WORKFLOWS = [==[
# Roost 自动化。推荐在 Roost 面板的「工作流」页用表单新建和编辑;手改保存后同样自动生效,
# GitHub 事件订阅会自动同步到中继(GitHub App)。
#
# [repos."owner/name"]          # 可选:GitHub 仓库 → 本机检出;没有声明的仓库在临时目录中运行
# path = "~/code/name"
# branch = "main"               # 定时 / 手动运行时检出的分支
# worktree = true               # false:直接在 path 中运行
#
# [[workflow]]
# id = "pr-review"              # a-z 0-9 _ -
# name = "PR 审查"
# notify = true                 # 运行结束时弹出通知
# identity = "local"            # GitHub 身份:app(GitHub App)或 local(本机 gh);省略则用 roost.toml [github]
#
# [[workflow.trigger]]          # GitHub:pr_opened pr_draft pr_pushed pr_merged comment push label
# github = "pr_opened"          #   check_completed issue_comment review_comment review review_thread
# repos = ["owner/name"]        #   workflow_run issue_opened event;至少一个筛选器
# authors = ["@me"]
#
# [[workflow.trigger]]          # 定时:once hourly daily weekly monthly yearly cron(本机时区,或 tz = "UTC")
# schedule = "weekly"
# days = ["mon", "fri"]
# time = "09:00"
#
# [[workflow.step]]             # omp 步骤:提示词可用 {{...}} 模板;不会收到 env / ROOST_* 环境变量(App 身份变量除外)
# omp = "审查 PR #{{number}}:{{title}}\n\n{{url}}"
#
# [[workflow.step]]
# run = "gh pr comment $ROOST_NUMBER --body-file review.md"

[[workflow]]
id = "hello"
name = "示例:每日问候"
enabled = false
workspace = "temp"

[[workflow.trigger]]
schedule = "weekly"
days = ["mon", "tue", "wed", "thu", "fri"]
time = "09:00"

[[workflow.step]]
name = "问候"
run = "echo 'Roost 运行于' \"$(date)\""
]==]

local function read_file(path: string): string?
	local ok, text = pcall(tern.fs.read, path, MAX_FILE)
	return if ok then text :: string else nil
end

-- Wall clock in epoch seconds; tests replace it.
M.clock = function(): number
	return os.time()
end

local function now(): number
	return M.clock()
end

function M.notice(c: Core, level: string, text: string)
	table.insert(c.notices, 1, { at = now(), level = level, text = text })
	while #c.notices > MAX_NOTICES do
		table.remove(c.notices)
	end
	M.changed(c)
end

local function publish_status(c: Core)
	local running, queued = runner.active(c.runner)
	local rs = c.relay.state
	local relay_state = if not rs.configured then "off" elseif rs.connected then "ok" else "down"
	local failed = 0
	local since = now() - 86400
	for _, r in c.store.runs do
		if (r.state == "failed" or r.state == "timed_out") and (r.finished_at or 0) >= since then
			failed += 1
		end
	end
	local next_cron: number? = nil
	for _, row in c.crons do
		if row.next and (next_cron == nil or row.next < next_cron) then
			next_cron = row.next
		end
	end
	-- Finished runs of workflows with notify on, for the window's toasts (recent ones only); a
	-- skipped run (nothing to do, or over budget) stays quiet.
	local done: { { [string]: any } } = {}
	local w = c.workflows
	-- Newest first (runs append), so a burst of more than ten still announces the latest.
	for i = #c.store.runs, 1, -1 do
		local r = c.store.runs[i]
		local wf = if w then w.by_id[r.workflow] else nil
		local recent = r.finished_at and now() - r.finished_at < NOTIFY_WINDOW and r.state ~= "skipped"
		if recent and wf and wf.notify and #done < 10 then
			table.insert(done, { id = r.id, name = r.workflow_name, title = r.title, state = r.state })
		end
	end
	local s = {
		running = running,
		queued = queued,
		relay = relay_state,
		failed = failed,
		next_cron = next_cron,
		done = tern.json.array(done),
	}
	local enc = tern.json.encode(s)
	if enc ~= c.status_json then
		c.status_json = enc
		pcall(tern.kv.set, "status", s)
	end
end

-- Deletes queued run directories a batch at a time (store.drain runs rm out of process).
local function drain(c: Core)
	if c.draining or #c.store.trash == 0 then
		return
	end
	c.draining = true
	local ok, err = pcall(function(): string?
		tern.timer(DRAIN_MS, function()
			store.drain(c.store, DRAIN_BATCH, function(left)
				c.draining = false
				if left > 0 then
					drain(c)
				else
					c.disk.at = nil -- sizes changed: measure again when next shown
					M.changed(c)
				end
			end)
		end)
		return nil
	end)
	if not ok then
		c.draining = false
		tern.log.warn("roost: cannot schedule removals", err)
	end
end

-- Coalesces change notifications into one render per listener.
function M.changed(c: Core)
	-- Runs pruned on submit leave their directories queued.
	drain(c)
	if c.notify_timer then
		return
	end
	c.notify_timer = tern.timer(120, function()
		c.notify_timer = nil
		publish_status(c)
		for _, fn in c.listeners do
			local ok, err = pcall(function(): string?
				fn()
				return nil
			end)
			if not ok then
				tern.log.warn("roost: listener failed", err)
			end
		end
	end)
end

function M.subscribe(c: Core, fn: () -> ()): () -> ()
	c.next_listener += 1
	local id = c.next_listener
	c.listeners[id] = fn
	return function()
		c.listeners[id] = nil
	end
end

local function refresh_crons(c: Core)
	local rows: { CronRow } = {}
	local w = c.workflows
	if w then
		local t = now()
		for _, wf in w.list do
			for i, tr in wf.triggers do
				if tr.kind == "cron" then
					local ct = tr :: model.CronTrigger
					local nxt: number? = nil
					if wf.enabled then
						if ct.schedule == "once" then
							nxt = if ct.at and ct.at > t then ct.at else nil
						elseif ct.cron then
							nxt = cron.next(ct.cron, t, ct.utc)
						end
					end
					table.insert(rows, {
						key = `{wf.id}#{i}`,
						workflow = wf.id,
						name = wf.name,
						expr = if ct.schedule == "once" then ct.at_text or "" else ct.expr,
						desc = model.describe_trigger(ct),
						utc = ct.utc,
						repo = ct.repo,
						enabled = wf.enabled,
						next = nxt,
					})
				end
			end
		end
	end
	table.sort(rows, function(a, b)
		local x, y = a.next or math.huge, b.next or math.huge
		if x ~= y then
			return x < y
		end
		return a.key < b.key
	end)
	c.crons = rows
end

local function sync_subscriptions(c: Core)
	relay.sync(c.relay)
end

local function apply_retention(c: Core)
	local k = c.config.retention
	c.store.policy = true
	c.store.keep, c.store.max_age = k.runs, k.run_age
end

-- Re-reads both files; applies them when they changed and are valid.
function M.reload_files(c: Core)
	local ctext = read_file(c.paths.config)
	if ctext ~= c.config_text then
		c.config_text = ctext
		local cfg, issues = model.parse_config(ctext or "")
		c.config_issues = issues
		if cfg then
			local before, known = c.config.retention, c.store.policy
			c.config = cfg
			apply_retention(c)
			relay.configure(c.relay, {
				url = cfg.relay.url,
				token = model.token(cfg.relay),
				client_name = cfg.relay.client_name,
			})
			-- A policy that is new or changed applies at once; before M.start's first pass that
			-- pass does it.
			if c.cleanup and (not known or not util.equal(before, cfg.retention)) then
				M.housekeep(c, false)
			end
		else
			M.notice(c, "error", "roost.toml 有错误,继续使用上一次的有效配置")
		end
		M.changed(c)
	end
	local wtext = read_file(c.paths.workflows)
	if wtext ~= c.workflows_text then
		c.workflows_text = wtext
		local w, issues = model.parse_workflows(wtext or "")
		c.workflow_issues = issues
		if w then
			c.workflows = w
			c.loaded_at = now()
			refresh_crons(c)
			sync_subscriptions(c)
		else
			M.notice(
				c,
				"error",
				if c.workflows
					then "workflows.toml 有错误,继续使用上一次的有效版本"
					else "workflows.toml 有错误:修好之前不会运行任何工作流,也不会领取中继事件"
			)
		end
		M.changed(c)
	end
end

-- Deliveries already handled, so a redelivery (GitHub "Redeliver", a relay replay) never runs
-- twice; seeded at start from runs.json and events.json.
local MAX_SEEN = 2000

local function remember(c: Core, delivery: string): boolean
	if c.seen[delivery] then
		return false
	end
	c.seen[delivery] = true
	table.insert(c.seen_order, delivery)
	while #c.seen_order > MAX_SEEN do
		c.seen[table.remove(c.seen_order, 1) :: string] = nil
	end
	return true
end

local function defaults(wf: model.Workflow): { [string]: string }
	local out: { [string]: string } = {}
	for _, i in wf.inputs do
		if i.default then
			out[i.name] = i.default
		end
	end
	return out
end

local function save_events(c: Core): string?
	return eventlog.save(c.events_path, c.events)
end

-- Without a policy yet (no valid roost.toml), only the hard ceiling applies, so the file stays
-- loadable.
local function prune_events(c: Core, t: number): number
	if not c.store.policy then
		return eventlog.prune(c.events, 2000, 0, t)
	end
	local k = c.config.retention
	return eventlog.prune(c.events, k.events, k.event_age, t)
end

local function add_event(c: Core, row: EventRow)
	table.insert(c.events, 1, row)
	prune_events(c, now())
	save_events(c)
end

local function event_row(e: { [string]: any }, info: { [string]: any }, delivery: string): EventRow
	return {
		seq = if type(e.seq) == "number" then e.seq else 0,
		delivery = delivery,
		at = util.rfc3339(e.received_at) or now(),
		event = info.event or e.event or "?",
		repo = info.repo,
		summary = match.summary(info),
		url = info.url,
		runs = {},
		reasons = {},
	}
end

-- Relayed events: match every enabled workflow's GitHub triggers; a workflow fires once per event.
-- Repos declared in [repos] run in their checkout; any other repo runs in a temporary directory.
function M.on_events(c: Core, list: { { [string]: any } })
	local w = c.workflows
	local app = M.app(c)
	local ctx: match.Ctx = { me = M.me(c), bot = if app then app.bot else nil }
	for _, e in list do
		local info: { [string]: any } = if type(e.info) == "table" then e.info else {}
		local delivery = tostring(e.delivery or e.seq)
		if not remember(c, delivery) then
			continue
		end
		local row = event_row(e, info, delivery)
		if row.event == "roost_test" then
			c.relay.state.last_test = now()
			M.notice(c, "success", "中继测试事件已送达本机")
		elseif w and info.repo then
			local key = util.ifind(w.repos, info.repo) or info.repo
			for _, wf in w.list do
				if not wf.enabled then
					continue
				end
				local why: string? = nil
				local fired = false
				for _, tr in wf.triggers do
					if tr.kind == "github" then
						local miss = match.mismatch(tr :: model.GithubTrigger, info, ctx)
						if miss == nil then
							fired = true
							break
						end
						why = why or miss
					end
				end
				if fired then
					local payload = if e.payload ~= nil then tern.json.encode(e.payload) else nil
					local run, err = runner.submit(c.runner, wf, {
						trigger = { kind = "github", detail = row.summary, delivery = delivery },
						repo = key,
						ref = info.fetch_ref,
						inputs = defaults(wf),
						event = info,
						payload = payload,
					})
					if run then
						table.insert(row.runs, run.id)
					else
						row.reasons[wf.id] = err or "未能排队"
					end
				elseif why then
					row.reasons[wf.id] = why
				end
			end
		end
		add_event(c, row)
	end
	M.changed(c)
end

-- Events already read but missing from the events page (first contact with a relay, or no
-- events.json yet): listed for reference, never run here. Runs they started earlier are found
-- by delivery id.
function M.on_history(c: Core, list: { { [string]: any } })
	c.history_wanted = false
	local started: { [string]: { string } } = {}
	for _, r in c.store.runs do
		local d = if r.trigger then r.trigger.delivery else nil
		if d then
			started[d] = started[d] or {}
			table.insert(started[d], r.id)
		end
	end
	-- `seen` can't decide here: runs.json seeds it with these very deliveries.
	local listed: { [string]: boolean } = {}
	for _, x in c.events do
		listed[x.delivery] = true
	end
	for _, e in list do
		local info: { [string]: any } = if type(e.info) == "table" then e.info else {}
		local delivery = tostring(e.delivery or e.seq)
		remember(c, delivery)
		if not listed[delivery] then
			listed[delivery] = true
			local row = event_row(e, info, delivery)
			row.history = true
			row.runs = started[delivery] or {}
			if #row.runs == 0 then
				row.reasons["*"] = "历史事件:本机没有它的处理记录,只作展示"
			end
			-- Newest first, among what is already listed.
			local at = #c.events + 1
			for i, x in c.events do
				if x.at < row.at then
					at = i
					break
				end
			end
			table.insert(c.events, at, row)
		end
	end
	prune_events(c, now())
	-- Saved even when empty: the file's presence means history was looked up.
	save_events(c)
	M.changed(c)
end

-- How late a missed `once` schedule still fires (the machine was asleep at that minute).
local ONCE_GRACE = 3600

local function cron_tick(c: Core)
	local t = now()
	local minute = t - t % 60
	local w = c.workflows
	if w then
		local last = (function(): { [string]: number }
			local ok, v = pcall(tern.kv.get, "cron_last")
			return if ok and type(v) == "table" then v else {}
		end)()
		local fired_any = false
		local keep: { [string]: number } = {}
		for _, wf in w.list do
			for i, tr in wf.triggers do
				if tr.kind ~= "cron" then
					continue
				end
				local ct = tr :: model.CronTrigger
				local key: string
				local due: boolean
				if ct.schedule == "once" then
					-- Keyed by its time, so a once trigger fires once however the list is reordered.
					key = `{wf.id}#once:{ct.at_text or ""}`
					local at = ct.at
					due = at ~= nil and last[key] == nil and at <= minute and minute - at < ONCE_GRACE
				else
					key = `{wf.id}#{i}`
					due = last[key] ~= minute and ct.cron ~= nil and cron.matches(ct.cron :: cron.Cron, minute, ct.utc)
				end
				keep[key] = last[key]
				if wf.enabled and due then
					keep[key] = minute
					fired_any = true
					local repo = ct.repo
					local ref = ct.ref or (if repo and w.repos[repo] then w.repos[repo].branch else nil)
					local run, err = runner.submit(c.runner, wf, {
						trigger = { kind = "cron", detail = model.describe_trigger(ct) },
						repo = repo,
						ref = ref,
						inputs = defaults(wf),
					})
					if not run then
						M.notice(c, "error", `{wf.name} 定时运行未排队:{err}`)
					end
				end
			end
		end
		if fired_any then
			pcall(tern.kv.set, "cron_last", keep)
		end
	end
	refresh_crons(c)
	M.changed(c)
	local wait = 60 - (now() % 60) + 1
	tern.timer(wait * 1000, function()
		cron_tick(c)
	end)
end

local function watch_loop(c: Core)
	M.reload_files(c)
	tern.timer(WATCH_MS, function()
		watch_loop(c)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Retention: roost.toml [retention] applied at start, hourly, after the policy changes and on
-- demand. Only finished runs go; their directories are deleted in the background (drain).

function M.housekeep(c: Core, manual: boolean)
	if manual and not c.store.policy then
		M.notice(c, "error", "roost.toml 有错误,保留策略还没有生效:修好后再清理")
		return
	end
	local t = now()
	-- Both are no-ops until a valid roost.toml set the policy (store.policy).
	local runs = store.prune(c.store, t)
	local events = prune_events(c, t)
	if events > 0 then
		save_events(c)
	end
	local orphans = store.sweep(c.store, SWEEP_CAP)
	if runs > 0 then
		runner.save(c.runner)
	end
	local done: Cleanup = { at = t, runs = runs, events = events, orphans = orphans, manual = manual :: boolean }
	c.cleanup = done
	if manual then
		M.notice(
			c,
			"success",
			if runs + events + orphans == 0
				then "没有超出保留策略的内容"
				else `已清理 {runs} 个运行、{events} 条事件记录、{orphans} 个遗留目录`
		)
	end
	M.changed(c)
end

local function housekeep_loop(c: Core)
	M.housekeep(c, false)
	tern.timer(HOUSEKEEP_MS, function()
		housekeep_loop(c)
	end)
end

function M.new(data: string): Core
	local paths = {
		config = `{data}/roost.toml`,
		workflows = `{data}/workflows.toml`,
		theme = `{data}/theme.css`,
	}
	local st = store.new(data, 200, 30 * 86400)
	local c: Core
	local cfg0 = (model.parse_config("")) :: model.Config
	c = {
		data = data,
		paths = paths,
		config = cfg0,
		config_issues = {},
		config_text = nil,
		workflows = nil,
		workflow_issues = {},
		workflows_text = nil,
		loaded_at = nil,
		store = st,
		runner = nil :: any,
		relay = nil :: any,
		crons = {},
		events = {},
		events_path = `{data}/events.json`,
		cleanup = nil,
		draining = false,
		disk = { loading = false, sizes = {} },
		deliveries = { loading = false },
		notices = {},
		seen = {},
		seen_order = {},
		listeners = {},
		next_listener = 0,
		notify_timer = nil,
		status_json = nil,
		started = false,
		history_wanted = false,
		gh_cache = {},
		gh_order = {},
		omp_models = nil,
	}
	c.runner = runner.new({
		data = data,
		home = tern.getenv("HOME"),
		path = tern.getenv("PATH"),
		store = st,
		config = function()
			return c.config
		end,
		workflows = function()
			return c.workflows
		end,
		changed = function()
			M.changed(c)
		end,
		now = now,
		app_token = function(repo, cb)
			M.app_token(c, repo, cb)
		end,
	})
	local client_id = (function(): string
		local ok, v = pcall(tern.kv.get, "client_id")
		if ok and type(v) == "string" and v ~= "" then
			return v
		end
		local id = string.format("roost-%08x%04x", now(), math.random(0, 0xffff))
		pcall(tern.kv.set, "client_id", id)
		return id
	end)()
	c.relay = relay.new({
		event = function(e)
			M.on_events(c, { e })
		end,
		history = function(list)
			M.on_history(c, list)
		end,
		wants_history = function()
			return c.history_wanted
		end,
		changed = function()
			M.changed(c)
		end,
		now = now,
		client_id = client_id,
		ready = function()
			-- Events wait for the relay status too unless roost.toml names the login: matching
			-- `@me` and ignore_self needs it (the App owner comes with the status).
			return c.workflows ~= nil and (c.config.github.login ~= nil or c.relay.state.agent ~= nil)
		end,
		subs = function()
			local w = c.workflows
			return if w then model.subscriptions(w) else nil
		end,
	})
	return c
end

-- Creates missing files, loads everything and starts the loops.
function M.start(c: Core)
	if c.started then
		return
	end
	c.started = true
	c.history_wanted = not (tern.fs.exists(c.events_path) or tern.fs.exists(c.events_path .. ".bak"))
	pcall(tern.fs.mkdir, c.data)
	pcall(tern.fs.mkdir, `{c.data}/runs`)
	if not tern.fs.exists(c.paths.config) then
		pcall(tern.fs.write, c.paths.config, DEFAULT_CONFIG)
	end
	if not tern.fs.exists(c.paths.workflows) then
		pcall(tern.fs.write, c.paths.workflows, DEFAULT_WORKFLOWS)
	end
	store.load(c.store)
	-- Deliveries already handled: those that started runs (runs.json keeps them however the
	-- events page was trimmed or cleared), then the events page, each oldest first, so the
	-- dedup window keeps the newest.
	for _, r in c.store.runs do
		if r.trigger and r.trigger.delivery then
			remember(c, r.trigger.delivery)
		end
	end
	local saved = eventlog.load(c.events_path)
	for i = #saved, 1, -1 do
		remember(c, saved[i].delivery)
	end
	table.move(saved, 1, #saved, 1, c.events)
	watch_loop(c)
	runner.recover(c.runner)
	housekeep_loop(c)
	local wait = 60 - (now() % 60) + 1
	tern.timer(wait * 1000, function()
		cron_tick(c)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Actions for the views. Each returns an error message or nil.

-- The repo a run started without one works in: the only declared repo the workflow's triggers
-- name (a schedule's `repo`, a GitHub trigger's literal `repos`), else the only declared repo.
local function default_repo(w: model.Workflows, wf: model.Workflow): string?
	local found: { [string]: boolean } = {}
	local open = false
	for _, t in wf.triggers do
		if t.kind == "cron" then
			local repo = (t :: model.CronTrigger).repo
			if repo then
				found[repo] = true
			end
		else
			local repos = (t :: model.GithubTrigger).repos
			open = open or #repos == 0
			for _, name in repos do
				local key = if string.find(name, "*", 1, true) then nil else util.ifind(w.repos, name)
				if key then
					found[key] = true
				else
					open = true
				end
			end
		end
	end
	local names = util.keys(found)
	if not open and #names == 1 then
		return names[1]
	end
	local declared = util.keys(w.repos)
	return if #declared == 1 then declared[1] else nil
end

-- The repo a bare PR number means: the one literal repo the workflow's GitHub triggers name.
local function pr_repo(wf: model.Workflow): string?
	local only: string? = nil
	for _, t in wf.triggers do
		if t.kind == "github" then
			local repos = (t :: model.GithubTrigger).repos
			if #repos == 0 then
				return nil
			end
			for _, name in repos do
				if string.find(name, "*", 1, true) or (only and string.lower(only) ~= string.lower(name)) then
					return nil
				end
				only = name
			end
		end
	end
	return only
end

-- The workflow a manual run of `id` would use, with its inputs filled from defaults.
local function manual(c: Core, id: string, inputs: { [string]: string }?): (model.Workflow?, { [string]: string }, string?)
	local w = c.workflows
	local wf = w and w.by_id[id]
	if not w or not wf then
		return nil, {}, `没有工作流 {id}`
	end
	if not wf.manual then
		return nil, {}, `{wf.name} 不允许手动运行(manual = false)`
	end
	local given = inputs or {}
	local final: { [string]: string } = {}
	for _, i in wf.inputs do
		local v = given[i.name] or i.default
		if v == nil and i.required then
			return nil, {}, `缺少必填输入 {i.name}`
		end
		if v then
			final[i.name] = v
		end
	end
	return wf, final, nil
end

function M.dispatch(c: Core, id: string, inputs: { [string]: string }?, repo: string?, ref: string?): string?
	local wf, final, why = manual(c, id, inputs)
	local w = c.workflows
	if not wf or not w then
		return why
	end
	repo = repo or default_repo(w, wf)
	local r = if repo then w.repos[repo] else nil
	if (wf.workspace == "worktree" or wf.workspace == "repo") and not (r and r.path) then
		return `{wf.name} 要在仓库检出中运行(workspace = {wf.workspace}),但无法确定用哪个仓库:请在触发器上设置 repo`
	end
	if r and not ref then
		ref = r.branch
	end
	local run, err = runner.submit(c.runner, wf, {
		trigger = { kind = "manual", detail = "Roost 面板" },
		repo = repo,
		ref = ref,
		inputs = final,
	})
	if not run then
		return err
	end
	return nil
end

-- PATH for local tools (gh, omp): `[runner] extra_path` before the daemon's own.
local function local_path(c: Core): string
	local home = tern.getenv("HOME")
	local paths: { string } = {}
	for _, p in c.config.runner.extra_path do
		table.insert(paths, util.expand(p, home))
	end
	table.insert(paths, tern.getenv("PATH") or "/usr/bin:/bin")
	return table.concat(paths, ":")
end

local PR_FETCH_MS = 20000

-- Runs PR workflow `id` on one pull request (`owner/name#12`, its URL, or a bare number when the
-- workflow names one repository) the way a PR event would: the same event fields and payload
-- shape, the PR head checked out. The PR is read with the local gh (the relay serves no PR
-- reads); `cb` gets nil once the run is queued, else why not. When `wanted` says no by the time
-- the PR has been read, nothing is queued.
function M.dispatch_pr(
	c: Core,
	id: string,
	inputs: { [string]: string }?,
	pr: string,
	cb: (string?) -> (),
	wanted: (() -> boolean)?
)
	local wf, _, why = manual(c, id, inputs)
	local w = c.workflows
	if not wf or not w then
		cb(why)
		return
	end
	local repo, number = match.pr_ref(pr)
	if number == nil then
		cb(`无法识别 PR「{pr}」:写 owner/name#12、PR 链接或编号`)
		return
	end
	repo = repo or pr_repo(wf)
	if repo == nil then
		cb(`{wf.name} 不只一个仓库:写 owner/name#{number} 或 PR 链接`)
		return
	end
	local path = local_path(c)
	local name = `{repo}#{number}`
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", 'exec gh api "repos/$1/pulls/$2"', "roost", repo :: string, tostring(number) },
			{ env = { PATH = path }, timeout_ms = PR_FETCH_MS },
			function(res: ProcessResult)
				if res.timed_out then
					cb(`读取 {name} 超时`)
					return
				elseif res.status ~= 0 then
					local msg = util.first_line(util.trim(res.stderr or ""))
					cb(`gh 读取 {name} 失败:{if msg ~= "" then util.clip(msg, 200) else `退出码 {res.status}`}`)
					return
				end
				local dok, body = pcall(tern.json.decode, res.stdout or "")
				if not dok or type(body) ~= "table" or type(body.number) ~= "number" then
					cb(`gh 返回的 {name} 不是拉取请求`)
					return
				end
				if wanted and not wanted() then
					cb("已取消")
					return
				end
				-- The configuration may have changed while gh ran.
				local cur, final, why2 = manual(c, id, inputs)
				local ws = c.workflows
				if not cur or not ws then
					cb(why2)
					return
				end
				local info = match.pr_info(repo :: string, body, "manual")
				info.sender = M.me(c)
				local base = if type(body.base) == "table" then body.base else {}
				local run, serr = runner.submit(c.runner, cur, {
					trigger = { kind = "manual", detail = `Roost 面板 · {info.repo}#{number}` },
					repo = util.ifind(ws.repos, info.repo) or info.repo,
					ref = info.fetch_ref,
					inputs = final,
					event = info,
					payload = tern.json.encode({ action = "manual", pull_request = body, repository = base.repo }),
				})
				cb(if run then nil else serr or "未能排队")
			end
		)
		return nil
	end)
	if not ok then
		cb(`无法启动 gh:{tostring(err)}`)
	end
end

function M.cancel(c: Core, id: string): string?
	if runner.cancel(c.runner, id) then
		return nil
	end
	return "该运行已结束"
end

function M.rerun(c: Core, id: string): string?
	local run = c.store.by_id[id]
	local w = c.workflows
	local wf = run and w and w.by_id[run.workflow]
	if not run or not wf then
		return "找不到该运行或其工作流"
	end
	local _, err = runner.submit(c.runner, wf, runner.request_of(c.runner, run))
	return err
end

-- Pushes now even when unchanged, so the button always reports the relay's answer.
function M.push_subscriptions(c: Core, force: boolean)
	relay.push_now(c.relay, force)
end

function M.adopt_remote(c: Core)
	relay.adopt_remote(c.relay)
end

local function report(c: Core, okmsg: string): (boolean, string, any) -> ()
	return function(ok, msg, _body)
		M.notice(c, if ok then "success" else "error", if ok then okmsg else msg)
	end
end

function M.remote_reload(c: Core)
	relay.reload_remote(c.relay, report(c, "中继已重新加载 subscriptions.toml"))
end

function M.remote_restart(c: Core)
	relay.restart_remote(c.relay, report(c, "中继正在重启…"))
end

-- ---------------------------------------------------------------------------------------------
-- The automation editor: workflows.toml written back one workflow at a time.

local function file_issue(message: string): { model.Issue }
	return { { file = "workflows.toml", path = "workflows", message = message } }
end

-- `raw` with an id: its own, else a fresh one from its name (unique among the other workflows).
local function with_id(c: Core, old_id: string?, raw: { [string]: any }): { [string]: any }
	if type(raw.id) == "string" and raw.id ~= "" then
		return raw
	end
	local taken: { [string]: boolean } = {}
	local list: { model.Workflow } = if c.workflows then c.workflows.list else {}
	for _, wf in list do
		if wf.id ~= old_id then
			taken[wf.id] = true
		end
	end
	local out = table.clone(raw)
	out.id = model.slug(if type(raw.name) == "string" then raw.name else "", taken)
	return out
end

-- The current workflows.toml: "" only when there is no file yet; an unreadable file is an error,
-- never an empty one (saving over it would drop every other workflow).
local function current_text(c: Core): (string?, string?)
	if not tern.fs.exists(c.paths.workflows) then
		return "", nil
	end
	local text = read_file(c.paths.workflows)
	if text == nil then
		return nil, "无法读取 workflows.toml(文件过大或没有权限),没有做任何修改"
	end
	return text, nil
end

-- The whole new workflows.toml text with `raw` in place of `old_id` (appended when nil), and the
-- text it was made from.
local function compose(c: Core, old_id: string?, raw: { [string]: any }): (string?, string?, string?)
	local old, err = current_text(c)
	if old == nil then
		return nil, err, nil
	end
	local text, serr = model.splice_workflow(old, old_id, model.encode_workflow(raw))
	return text, serr, old
end

-- Problems the file alone can't show: a `once` time already past, and `@me` / ignore_self
-- without a known GitHub login (once the relay status is known).
local function runtime_issues(c: Core, wf: model.Workflow, out: { model.Issue })
	local base = `workflow.{wf.id}`
	local known = M.app(c) ~= nil
	local me = M.me(c)
	for i, tr in wf.triggers do
		local path = `{base}.trigger[{i}]`
		if tr.kind == "cron" then
			local ct = tr :: model.CronTrigger
			if ct.schedule == "once" and ct.at and ct.at <= now() then
				table.insert(out, { file = "workflows.toml", path = `{path}.at`, message = "这个时间已经过去,不会再触发", line = ct.line })
			end
		elseif known and me == nil then
			local gt = tr :: model.GithubTrigger
			local uses_me = table.find(gt.authors, "@me") ~= nil or table.find(gt.assignees, "@me") ~= nil
			if uses_me or gt.ignore_self then
				table.insert(out, {
					file = "workflows.toml",
					path = if uses_me then `{path}.authors` else `{path}.ignore_self`,
					message = if uses_me
						then "不知道你的 GitHub 用户名(@me):在 roost.toml 设置 [github] login"
						else "「忽略我自己的活动」需要你的 GitHub 用户名:在 roost.toml 设置 [github] login,或关闭此项",
					line = gt.line,
				})
			end
		end
	end
end

-- Issues of `raw` as it would be saved: its own (path under workflow.<id>) and file-level ones.
function M.check_workflow(c: Core, old_id: string?, raw: { [string]: any }): { model.Issue }
	local full = with_id(c, old_id, raw)
	local text, err = compose(c, old_id, full)
	if text == nil then
		return file_issue(err or "无法写回 workflows.toml")
	end
	local w, issues = model.parse_workflows(text)
	local base = `workflow.{full.id}`
	local out: { model.Issue } = {}
	for _, i in issues do
		local p = i.path
		if p == "workflows.toml" or p == base or string.sub(p, 1, #base + 1) == base .. "." then
			table.insert(out, i)
		end
	end
	local wf = if w then w.by_id[full.id] else nil
	if wf then
		runtime_issues(c, wf, out)
	end
	return out
end

-- Writes `text` over workflows.toml after copying `old` (what it was made from) to .bak; a failed
-- backup stops the write.
local function write_workflows(c: Core, old: string, text: string): string?
	if old ~= "" then
		local ok, err = pcall(function(): string?
			tern.fs.write(c.paths.workflows .. ".bak", old)
			return nil
		end)
		if not ok then
			return `无法备份 workflows.toml,没有写入:{err}`
		end
	end
	local ok, err = pcall(function(): string?
		tern.fs.write(c.paths.workflows, text)
		return nil
	end)
	if not ok then
		return `无法写入 workflows.toml:{err}`
	end
	M.reload_files(c)
	return nil
end

-- Saves `raw` over workflow `old_id` (nil: a new one). Nil when written and reloaded, else the
-- issues that stopped it. workflows.toml.bak keeps the previous file.
function M.save_workflow(c: Core, old_id: string?, raw: { [string]: any }): { model.Issue }?
	local issues = M.check_workflow(c, old_id, raw)
	if #issues > 0 then
		return issues
	end
	local text, err, old = compose(c, old_id, with_id(c, old_id, raw))
	if text == nil or old == nil then
		return file_issue(err or "无法写回 workflows.toml")
	end
	local werr = write_workflows(c, old, text)
	return if werr then file_issue(werr) else nil
end

function M.delete_workflow(c: Core, id: string): string?
	local old, rerr = current_text(c)
	if old == nil then
		return rerr
	end
	local text, err = model.splice_workflow(old, id, nil)
	if text == nil then
		return err
	end
	return write_workflows(c, old, text)
end

-- The TOML-shaped table of workflow `id` as it is in the file now.
function M.workflow_raw(c: Core, id: string): { [string]: any }?
	local text = read_file(c.paths.workflows)
	return if text then model.raw_workflow(text, id) else nil
end

-- ---------------------------------------------------------------------------------------------
-- GitHub (through the relay's GitHub App)

local GH_TTL = 300
local GH_MAX = 64
local GH_RETRY = 15

local function query_escape(s: string): string
	return (string.gsub(s, "[^%w%-_%.~/]", function(ch: string): string
		return string.format("%%%02X", string.byte(ch))
	end))
end

-- Suggestions for the editor (`what`: repos | people | labels | branches | workflows), cached for
-- five minutes. Returns what is known now and starts a fetch when stale; listeners hear when it lands.
function M.gh(c: Core, what: string, repo: string?): GhList
	if what ~= "repos" and repo == nil then
		return { items = {}, loading = false }
	end
	if not c.relay.state.configured then
		return { items = {}, loading = false, error = "中继未配置" }
	end
	local key = if what == "repos" then "repos" else `{what}:{string.lower(repo :: string)}`
	local cur = c.gh_cache[key]
	if cur and (cur.loading or (cur.at and now() - cur.at < GH_TTL)) then
		return cur
	end
	local entry: GhList = { items = if cur then cur.items else {}, loading = true, error = nil, at = nil }
	c.gh_cache[key] = entry
	if cur == nil then
		table.insert(c.gh_order, key)
		while #c.gh_order > GH_MAX do
			c.gh_cache[table.remove(c.gh_order, 1) :: string] = nil
		end
	end
	local path = `/api/v1/github/{what}`
	if repo then
		path ..= `?repo={query_escape(repo)}`
	end
	relay.request(c.relay, "GET", path, nil, 20000, function(ok, _status, body, err)
		entry.loading = false
		if ok and type(body) == "table" and type(body.items) == "table" then
			local items: { string } = {}
			for _, x in body.items do
				if type(x) == "string" then
					table.insert(items, x)
				end
			end
			entry.items, entry.error, entry.at = items, nil, now()
		else
			-- Errors are retried soon (the App may have just been installed on the repo).
			entry.error = err or "响应无效"
			entry.at = now() - GH_TTL + GH_RETRY
		end
		M.changed(c)
	end)
	return entry
end

-- ---------------------------------------------------------------------------------------------
-- omp model catalog (local omp, for the editor's model select)

local OMP_TTL = 300
local OMP_RETRY = 15
local OMP_MS = 15000
local OMP_MAX_OUT = 2 * 1024 * 1024
local OMP_MAX_ROLES = 64
local OMP_MAX_MODELS = 400

local function omp_roles(body: any): { OmpRole }
	local roles: { OmpRole } = {}
	if type(body) ~= "table" then
		return roles
	end
	for name, sel in body do
		if #roles >= OMP_MAX_ROLES then
			break
		end
		if type(name) == "string" and name ~= "" and type(sel) == "string" and sel ~= "" then
			table.insert(roles, { name = name, model = sel })
		end
	end
	table.sort(roles, function(a: OmpRole, b: OmpRole): boolean
		if (a.name == "default") ~= (b.name == "default") then
			return a.name == "default"
		end
		return a.name < b.name
	end)
	return roles
end

local function omp_chat_models(body: any): { OmpModel }
	local models: { OmpModel } = {}
	local list = if type(body) == "table" then body.models else nil
	if type(list) ~= "table" then
		return models
	end
	for _, m in list do
		if #models >= OMP_MAX_MODELS then
			break
		end
		if type(m) == "table" and (m.kind == nil or m.kind == "chat") and type(m.selector) == "string" and m.selector ~= "" then
			local provider = if type(m.provider) == "string" and m.provider ~= ""
				then m.provider
				else string.match(m.selector, "^([^/]+)/") or ""
			table.insert(models, { selector = m.selector, provider = provider })
		end
	end
	return models
end

-- omp's roles and chat models, cached for five minutes (errors retried after 15 s). Returns what is
-- known now and starts `omp config get modelRoles` / `omp models --json` when stale; listeners
-- hear when they land.
function M.omp_models(c: Core): OmpModels
	local cur = c.omp_models
	if cur and (cur.loading or (cur.at and now() - cur.at < OMP_TTL)) then
		return cur
	end
	local entry: OmpModels = {
		roles = if cur then cur.roles else {},
		models = if cur then cur.models else {},
		loading = true,
		error = nil,
		at = nil,
	}
	c.omp_models = entry
	local omp = c.config.runner.omp
	local path = local_path(c)
	local pending = 2
	local errors: { string } = {}
	local function settle()
		pending -= 1
		if pending > 0 or c.omp_models ~= entry then
			return
		end
		entry.loading = false
		if #errors > 0 then
			entry.error = table.concat(errors, ";")
			entry.at = now() - OMP_TTL + OMP_RETRY
		else
			entry.at = now()
		end
		M.changed(c)
	end
	local function fetch(what: string, args: { string }, apply: (any) -> ())
		local argv = { "/bin/sh", "-c", 'exec "$@"', "roost", omp }
		for _, a in args do
			table.insert(argv, a)
		end
		local ok, err = pcall(function(): string?
			tern.process.run(argv, { env = { PATH = path }, timeout_ms = OMP_MS }, function(res: ProcessResult)
				local out = res.stdout or ""
				if res.timed_out then
					table.insert(errors, `{what}超时`)
				elseif res.status == 127 then
					-- Both fetches hit the same missing binary: report it once.
					local msg = `找不到 {omp}:在 roost.toml 的 [runner] 把 omp 设为绝对路径,或把它所在目录加进 extra_path`
					if not table.find(errors, msg) then
						table.insert(errors, msg)
					end
				elseif res.status ~= 0 then
					local msg = util.first_line(util.trim(res.stderr or ""))
					table.insert(errors, `{what}失败:{if msg ~= "" then util.clip(msg, 200) else `退出码 {res.status}`}`)
				elseif #out > OMP_MAX_OUT then
					table.insert(errors, `{what}输出过大`)
				else
					local dok, body = pcall(tern.json.decode, out)
					if dok then
						apply(body)
					else
						table.insert(errors, `{what}返回的不是 JSON`)
					end
				end
				settle()
			end)
			return nil
		end)
		if not ok then
			table.insert(errors, `无法启动 {omp}:{tostring(err)}`)
			settle()
		end
	end
	fetch("读取 omp 角色", { "config", "get", "modelRoles" }, function(body: any)
		entry.roles = omp_roles(body)
	end)
	fetch("读取 omp 模型", { "models", "--json" }, function(body: any)
		entry.models = omp_chat_models(body)
	end)
	return entry
end

-- The relay's GitHub App, or nil while the relay status is unknown.
function M.app(c: Core): AppInfo?
	local agent = c.relay.state.agent
	if type(agent) ~= "table" then
		return nil
	end
	local gh = if type(agent.github) == "table" then agent.github else {}
	local a = gh.app
	if type(a) ~= "table" then
		return { configured = false }
	end
	return {
		configured = true,
		name = a.name,
		slug = a.slug,
		owner = a.owner,
		owner_type = a.owner_type,
		html_url = a.html_url,
		install_url = a.install_url,
		settings_url = if type(a.settings_url) == "string" then a.settings_url else nil,
		bot = if type(a.bot) == "string" then a.bot else nil,
		installations = a.installations,
		missing = if type(a.missing) == "table" then a.missing else nil,
	}
end

-- An App token for one run on `repo` (the runner's app_token). The relay hands one out only once
-- the repository's default branch can't be force-pushed or deleted; any error stops the run.
function M.app_token(c: Core, repo: string, cb: (runner.AppToken?, string?) -> ())
	if not c.relay.state.configured then
		cb(nil, '中继未配置:在 roost.toml [relay] 中设置,或把 [github] identity 改为 "local"')
		return
	end
	-- A token that can push must not cross the network in the clear (loopback is fine).
	local url = c.config.relay.url or ""
	local local_host = string.match(url, "^http://localhost[:/]") or string.match(url, "^http://localhost$")
		or string.match(url, "^http://127%.0%.0%.1[:/]") or string.match(url, "^http://127%.0%.0%.1$")
		or string.match(url, "^http://%[::1%]")
	if string.sub(url, 1, 8) ~= "https://" and not local_host then
		cb(nil, `中继地址 {url} 不是 https:App 令牌带写权限,不经明文传输。改用 https,或把 [github] identity 改为 "local"`)
		return
	end
	relay.request(c.relay, "POST", "/api/v1/github/token", { repo = repo }, 30000, function(ok, _s, body, err)
		local b: { [string]: any } = if type(body) == "table" then body else {}
		local valid = type(b.token) == "string" and b.token ~= "" and type(b.login) == "string" and type(b.email) == "string"
		if not (ok and valid) then
			cb(nil, err or "中继的响应无效")
			return
		end
		cb({
			token = b.token,
			expires_in = if type(b.expires_in) == "number" and b.expires_in > 0 then b.expires_in else 3000,
			login = b.login,
			email = b.email,
			branch = if type(b.branch) == "string" then b.branch else nil,
			protection = if type(b.protection) == "string" then b.protection else nil,
			permissions = if type(b.permissions) == "table" then b.permissions else nil,
		}, nil)
	end)
end

-- The user's GitHub login: roost.toml [github] login, else the owner of a personal GitHub App.
function M.me(c: Core): string?
	if c.config.github.login then
		return c.config.github.login
	end
	local a = M.app(c)
	if a and a.configured and a.owner_type == "User" then
		return a.owner
	end
	return nil
end

-- Starts creating the GitHub App: `cb` gets the agent page that registers it on GitHub.
function M.create_app(c: Core, org: string?, cb: (string?, string?) -> ())
	local body: { [string]: any } = {}
	if org and util.trim(org) ~= "" then
		body.org = util.trim(org)
	end
	relay.request(c.relay, "POST", "/api/v1/github/app/manifest", body, 15000, function(ok, _s, resp, err)
		if ok and type(resp) == "table" and type(resp.url) == "string" then
			cb(resp.url, nil)
		else
			cb(nil, err or "响应无效")
		end
	end)
end

-- Drops the App credentials on the relay (the App itself stays on GitHub).
function M.forget_app(c: Core)
	relay.request(c.relay, "DELETE", "/api/v1/github/app", nil, 15000, function(ok, _s, _b, err)
		M.notice(c, if ok then "success" else "error", if ok then "已删除中继上的 GitHub App 凭据" else err or "失败")
		relay.refresh_status(c.relay)
	end)
end

function M.test_relay(c: Core)
	local w = c.workflows
	local repo = if w then util.keys(w.repos)[1] else nil
	relay.test(c.relay, repo, function(ok, msg)
		if not ok then
			M.notice(c, "error", msg)
		end
	end)
end

function M.read_log(c: Core, id: string, offset: number, limit: number, cb: (string?, boolean) -> ())
	runner.read_log(c.runner, id, offset, limit, cb)
end

-- ---------------------------------------------------------------------------------------------
-- Manual cleanup and storage facts for the views.

-- Deletes one finished run: its record, log, payload, omp sessions and leftover worktree.
function M.delete_run(c: Core, id: string): string?
	local r = c.store.by_id[id]
	if not r then
		return "找不到该运行"
	end
	if not store.TERMINAL[r.state] then
		return "运行还没有结束:先取消它"
	end
	store.drop(c.store, { id })
	runner.save(c.runner)
	return nil
end

-- Deletes every finished run; queued and running ones stay.
function M.clear_runs(c: Core): number
	local n = store.drop(c.store, store.finished(c.store))
	if n > 0 then
		runner.save(c.runner)
	end
	M.notice(c, "success", if n > 0 then `已删除 {n} 个已结束的运行` else "没有已结束的运行")
	return n
end

-- Empties the events page (events.json). Deliveries already seen stay deduplicated: in memory,
-- and after a reload through the runs they started.
function M.clear_events(c: Core): number
	local n = #c.events
	for i = n, 1, -1 do
		c.events[i] = nil
	end
	local err = save_events(c)
	if err then
		M.notice(c, "error", `已清空列表,但 events.json 写入失败:{err}`)
	else
		M.notice(c, "success", `已清空 {n} 条事件记录`)
	end
	return n
end

-- Bytes used under the data directory, by entry (runs, worktrees, runs.json, events.json and
-- their backups), measured with du when shown and at most once a minute.
function M.disk(c: Core): Disk
	local d = c.disk
	if d.loading or (d.at and now() - d.at < DISK_TTL) then
		return d
	end
	d.loading = true
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'cd "$1" 2>/dev/null && du -sk -- runs worktrees runs.json runs.json.bak events.json events.json.bak 2>/dev/null; exit 0',
			"roost",
			c.data,
		}, { timeout_ms = 10000 }, function(res: ProcessResult)
			d.loading, d.at = false, now()
			local sizes: { [string]: number } = {}
			for kb, name in string.gmatch(res.stdout or "", "(%d+)%s+([^\n]+)") do
				sizes[name :: string] = (tonumber(kb) :: number) * 1024
			end
			d.sizes = sizes
			d.error = if res.timed_out then "统计超时" else nil
			M.changed(c)
		end)
		return nil
	end)
	if not ok then
		d.loading, d.at, d.error = false, now(), tostring(err)
	end
	return d
end

-- The relay's webhook deliveries (recent list, counts by outcome and by event/repo), fetched
-- when shown and at most every DELIVERIES_TTL seconds.
function M.deliveries(c: Core, force: boolean?): Deliveries
	local d = c.deliveries
	if not c.relay.state.configured or d.loading then
		return d
	end
	if not force and d.at and now() - d.at < DELIVERIES_TTL then
		return d
	end
	d.loading = true
	relay.request(c.relay, "GET", "/api/v1/deliveries?limit=50", nil, 10000, function(ok, _s, body, err)
		d.loading, d.at = false, now()
		if ok and type(body) == "table" then
			d.body, d.error = body, nil
		else
			d.error = err or "响应无效"
		end
		M.changed(c)
	end)
	return d
end

function M.clear_deliveries(c: Core)
	relay.clear_deliveries(c.relay, function(ok, msg)
		M.notice(c, if ok then "success" else "error", if ok then "已清空中继的投递统计" else msg)
		if ok then
			M.deliveries(c, true)
		end
	end)
end

-- Deletes the events cached on the relay; clients that hadn't read them yet will see a gap.
function M.clear_relay_events(c: Core)
	relay.clear_events(c.relay, function(ok, msg, body)
		local n = if type(body) == "table" and type(body.removed) == "number" then body.removed else 0
		M.notice(c, if ok then "success" else "error", if ok then `已删除中继缓存的 {n} 个事件` else msg)
	end)
end

return M
