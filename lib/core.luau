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
local loginenv = require("./loginenv")
local files = require("./files")
local bundle = require("./bundle")
local toml = require("./toml")
local evolve = require("./evolve")
local upgrade = require("./upgrade")
local tabs = require("./tabs")
local groups = require("./groups")
local fleet = require("./fleet")

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
export type Cleanup = { at: number, runs: number, events: number, orphans: number, exports: number, manual: boolean }
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
-- Devices (lib/fleet.luau): what this machine uploads as the executor, or mirrors and shows as
-- an observer.
export type Dev = {
	role: string, -- the role the last device tick saw (a change resets the upload state)
	-- executor: the configuration (export format) and run summaries last uploaded
	cfg_text: string?,
	cfg_built: number?,
	cfg_dirty: boolean, -- something it holds changed: build it again on the next tick
	cfg_busy: boolean,
	cfg_err: string?,
	cfg_at: number?,
	cfg_rev: string?, -- the relay's revision of the configuration last uploaded
	exec_noted: boolean, -- kv `mirror_exec` says this machine has been the executor since its last mirror
	runs_json: string?,
	runs_busy: boolean,
	runs_err: string?,
	runs_at: number?,
	-- log tails of recent runs; `failed`: the read failed (tried again after TAIL_RETRY)
	tails: { [string]: { text: string, at: number, state: string, failed: boolean? } },
	tailing: { [string]: boolean }, -- tail reads in flight
	-- observer: the executor's configuration applied here, and its runs
	mirror_busy: boolean,
	mirror_err: string?,
	mirror_at: number?,
	mirror_failed: { rev: string, at: number }?, -- the last revision that failed to apply
	mirror_missing: { string }, -- mirrored repos without a local path (runs there use a temp dir)
	remote: { store.Run },
	remote_tails: { [string]: string },
	remote_rev: string?,
	remote_at: number?, -- when the executor uploaded them
	remote_from: string?, -- the client that uploaded them
	remote_exec: string?, -- the executor whose runs these are
	remote_busy: boolean,
	remote_err: string?,
	timer: any?, -- the next device tick
}

export type Core = {
	data: string,
	paths: { config: string, workflows: string, theme: string, groups: string },
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
	login: loginenv.State, -- the login-shell environment local tools and shell steps inherit
	login_waiters: { () -> () }, -- actions waiting for the first capture
	book: evolve.Book, -- evolvers' revisions and firing record (lib/evolve.luau)
	groups: groups.Groups, -- the workflows page's groups (groups.json, lib/groups.luau)
	groups_err: string?, -- groups.json exists but can't be read: kept as is, never overwritten
	dev: Dev,
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

local function exists(path: string): boolean
	local ok, yes = pcall(tern.fs.exists, path)
	return ok and yes == true
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
		c.dev.cfg_dirty = true
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
		-- Listed before without a run here (observed for the executor, or history), then handed
		-- over to this machine: its row becomes this one.
		for i, x in c.events do
			if x.delivery == delivery and (x.observed or (x.history and #x.runs == 0)) then
				table.remove(c.events, i)
				break
			end
		end
		add_event(c, row)
	end
	M.changed(c)
end

-- Events read while another device is the executor: listed with who runs them, never run here
-- and not marked handled (this machine runs them if it takes over before them).
function M.on_observed(c: Core, list: { { [string]: any } })
	local who = fleet.label(relay.executor(c.relay))
	for _, e in list do
		local info: { [string]: any } = if type(e.info) == "table" then e.info else {}
		local delivery = tostring(e.delivery or e.seq)
		local listed = c.seen[delivery] == true
		for _, x in c.events do
			listed = listed or x.delivery == delivery
		end
		if listed then
			continue
		end
		local row = event_row(e, info, delivery)
		row.observed = who
		row.reasons["*"] = `本机是观察者:由执行者「{who}」运行`
		if row.event == "roost_test" then
			c.relay.state.last_test = now()
			M.notice(c, "success", "中继测试事件已送达本机(观察者,不运行)")
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
	-- Not marked handled: they come before the cursor, so they come back only when this machine
	-- takes over as executor at an earlier point (lib/relay.luau takeover), and then they are its
	-- to run. Those that started runs here are marked through runs.json anyway.
	local listed: { [string]: boolean } = {}
	for _, x in c.events do
		listed[x.delivery] = true
	end
	for _, e in list do
		local info: { [string]: any } = if type(e.info) == "table" then e.info else {}
		local delivery = tostring(e.delivery or e.seq)
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
	local observer = relay.role(c.relay) == "observer"
	-- The relay can't say who the executor is: nobody fires, and nothing counts as fired (the
	-- executor assigned next still finds a `once` schedule within its grace).
	local paused = relay.fleet_error(c.relay) ~= nil
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
				if wf.enabled and due and not paused then
					keep[key] = minute
					fired_any = true
					-- An observer counts the schedule as fired (the executor ran it), so a takeover
					-- within the `once` grace doesn't run it again.
					if not observer then
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

-- Defined with the export functions below.
local prune_exports: (c: Core) -> number
-- Defined with the self-iteration functions at the end.
local evolve_host: (c: Core) -> evolve.Host
local on_finished: (c: Core, run: store.Run) -> ()
local watch_upgrades: (c: Core, run: string?) -> ()
local check_daemon: (c: Core, done: () -> ()) -> ()
-- Defined with the device functions at the end.
local dev_loop: (c: Core) -> ()

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
	local exports = if c.store.policy then prune_exports(c) else 0
	local orphans = store.sweep(c.store, SWEEP_CAP)
	evolve.expire(evolve_host(c), c.book)
	if runs > 0 then
		runner.save(c.runner)
	end
	local done: Cleanup =
		{ at = t, runs = runs, events = events, orphans = orphans, exports = exports, manual = manual :: boolean }
	c.cleanup = done
	if manual then
		M.notice(
			c,
			"success",
			if runs + events + orphans + exports == 0
				then "没有超出保留策略的内容"
				else `已清理 {runs} 个运行、{events} 条事件记录、{exports} 个旧导出文件、{orphans} 个遗留目录`
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

local LOGIN_REFRESH_MS = 10 * 60 * 1000

-- Captures the login-shell environment now and every ten minutes (picks up edits to the shell's
-- config). Runs wait for the first capture; a failure keeps the last good one.
local function login_loop(c: Core)
	local before = c.login.error
	loginenv.capture(c.login, now, function()
		local err = c.login.error
		if err and err ~= before then
			local fallback = if c.login.env then "沿用上次读到的环境" else "本地进程只继承 Tern daemon 的环境"
			M.notice(c, "error", `读取登录 shell 的环境变量失败:{err};{fallback}`)
		end
		runner.schedule(c.runner, 0)
		local waiting = c.login_waiters
		c.login_waiters = {}
		for _, fn in waiting do
			fn()
		end
		M.changed(c)
	end)
	tern.timer(LOGIN_REFRESH_MS, function()
		login_loop(c)
	end)
end

function M.new(data: string): Core
	local paths = {
		config = `{data}/roost.toml`,
		workflows = `{data}/workflows.toml`,
		theme = `{data}/theme.css`,
		groups = `{data}/groups.json`,
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
		login = loginenv.new(),
		login_waiters = {},
		book = evolve.load(data),
		groups = groups.empty(),
		groups_err = nil,
		dev = {
			role = "solo",
			cfg_dirty = true,
			cfg_busy = false,
			exec_noted = false,
			runs_busy = false,
			tails = {},
			tailing = {},
			mirror_busy = false,
			mirror_missing = {},
			remote = {},
			remote_tails = {},
			remote_busy = false,
		},
	}
	c.runner = runner.new({
		data = data,
		home = tern.getenv("HOME"),
		path = tern.getenv("PATH"),
		login = function()
			return c.login
		end,
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
		plugin_dir = tern.plugin.dir,
		evolve_prepare = function(run, wf)
			return evolve.prepare(evolve_host(c), c.book, run, wf)
		end,
		finished = function(run)
			-- Outside the runner's call: applying a revision saves workflows.toml, and firing
			-- submits runs.
			local id = run.id
			tern.timer(0, function()
				local cur = c.store.by_id[id]
				if cur then
					local ok, err = pcall(function(): string?
						on_finished(c, cur :: store.Run)
						return nil
					end)
					if not ok then
						tern.log.warn("roost: after-run hook failed", err)
						M.notice(c, "error", `运行结束后的自迭代处理出错:{err}`)
						-- A revision it was writing stays "applying": undo it now, not at the next start.
						pcall(evolve.recover, evolve_host(c), c.book)
					end
				end
			end)
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
		observe = function(e)
			M.on_observed(c, { e })
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
	c.groups, c.groups_err = groups.load(c.paths.groups)
	if c.groups_err then
		M.notice(c, "error", c.groups_err)
	end
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
		-- Rows that never ran here (observed for the executor, or history listed without a run)
		-- are not "handled": see on_observed and on_history.
		local row = saved[i]
		if not (row.observed or (row.history and #row.runs == 0)) then
			remember(c, row.delivery)
		end
	end
	table.move(saved, 1, #saved, 1, c.events)
	watch_loop(c)
	-- A revision cut off part way by the last VM is undone before anything else runs.
	evolve.recover(evolve_host(c), c.book)
	login_loop(c)
	-- Tab records are checked against the running daemon before a recovered run-end close can
	-- use one.
	-- Operations left from the last VM wait (not announced) until then: recover publishes them again.
	pcall(tern.kv.set, tabs.KV, {})
	check_daemon(c, function()
		runner.recover(c.runner)
	end)
	housekeep_loop(c)
	local wait = 60 - (now() % 60) + 1
	tern.timer(wait * 1000, function()
		cron_tick(c)
	end)
	watch_upgrades(c, nil)
	dev_loop(c)
end

-- Called by host.luau once everything is defined: a pending self-upgrade (lib/upgrade.luau)
-- takes this as the new version having loaded.
function M.booted(c: Core)
	upgrade.write_boot(c.data, now())
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
		elseif t.kind == "github" then
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

-- Why this machine may not start runs: another device is the executor. Nil when it may.
function M.run_block(c: Core): string?
	if relay.role(c.relay) == "observer" then
		local broken = relay.fleet_error(c.relay)
		if broken then
			return `中继读不出设备记录({broken}):在「中继」页重新指定执行者之前,任何设备都不运行`
		end
		return `本机是观察者:运行只在执行者「{fleet.label(relay.executor(c.relay))}」上进行`
	end
	return nil
end

-- Why this machine may not change the workflow configuration: it mirrors the executor's (files,
-- libraries and groups included). Nil when it may.
function M.config_block(c: Core): string?
	if relay.role(c.relay) == "observer" then
		local broken = relay.fleet_error(c.relay)
		if broken then
			return `中继读不出设备记录({broken}):在「中继」页重新指定执行者之前不能修改工作流配置`
		end
		return `本机是观察者:工作流配置以执行者「{fleet.label(relay.executor(c.relay))}」为准,请在执行者上修改`
	end
	return nil
end

-- The workflow a manual run of `id` would use, with its inputs filled from defaults.
local function manual(c: Core, id: string, inputs: { [string]: string }?): (model.Workflow?, { [string]: string }, string?)
	local w = c.workflows
	local wf = w and w.by_id[id]
	if not w or not wf then
		return nil, {}, `没有工作流 {id}`
	end
	local blocked = M.run_block(c)
	if blocked then
		return nil, {}, blocked
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

-- The environment for local tools (gh, omp): the login environment and `[runner] env`, PATH being
-- `[runner] extra_path` before the login shell's (the daemon's until one is known).
local function local_env(c: Core): { [string]: string }
	local home = tern.getenv("HOME")
	local paths: { string } = {}
	for _, p in c.config.runner.extra_path do
		table.insert(paths, util.expand(p, home))
	end
	return loginenv.compose(c.login, { c.config.runner.env }, paths, tern.getenv("PATH") or "/usr/bin:/bin")
end

local PR_FETCH_MS = 20000
local MAX_LOGIN_WAITERS = 32

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
	if c.login.pending then
		-- gh may only be on the login shell's PATH: go on once the first capture ends.
		if #c.login_waiters >= MAX_LOGIN_WAITERS then
			cb("正在读取登录 shell 的环境变量,稍后再试")
			return
		end
		table.insert(c.login_waiters, function()
			M.dispatch_pr(c, id, inputs, pr, cb, wanted)
		end)
		return
	end
	local env = local_env(c)
	local name = `{repo}#{number}`
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", 'exec gh api "repos/$1/pulls/$2"', "roost", repo :: string, tostring(number) },
			{ env = env, timeout_ms = PR_FETCH_MS },
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

-- An ended run's agent steps without recorded models get them from their session files (runs
-- from before steps kept them), once per run; the run's details show them when they land.
function M.fill_models(c: Core, id: string)
	runner.fill_models(c.runner, id)
end

function M.rerun(c: Core, id: string): string?
	local run = c.store.by_id[id]
	local w = c.workflows
	local wf = run and w and w.by_id[run.workflow]
	if not run or not wf then
		return "找不到该运行或其工作流"
	end
	local blocked = M.run_block(c)
	if blocked then
		return blocked
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
		elseif tr.kind == "github" and known and me == nil then
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

-- The workflow's own files as they would be saved: `wfiles` when the editor passes them, else
-- what is on disk for `id`.
local function own_files(c: Core, id: string, wfiles: { [string]: string }?): ({ [string]: string }?, string?)
	if wfiles then
		return wfiles, nil
	end
	local tree, err = files.load(files.workflow_root(c.data, id))
	return if tree then tree.text else nil, err
end

-- Problems with the files a workflow uses: its own (as they would be saved) and its libraries'.
local function file_issues(c: Core, wf: model.Workflow, wfiles: { [string]: string }?, out: { model.Issue })
	local base = `workflow.{wf.id}`
	local own, err = own_files(c, wf.id, wfiles)
	local bad = err or (if own then files.check(own) else nil)
	if bad then
		table.insert(out, { file = "workflows.toml", path = `{base}.files`, message = `工作流文件:{bad}`, line = wf.line })
	end
	local missing: { [string]: boolean } = {}
	for _, lib in wf.libs do
		if not exists(files.lib_root(c.data, lib)) then
			missing[lib] = true
			table.insert(out, { file = "workflows.toml", path = `{base}.libs`, message = `文件库 "{lib}" 不存在`, line = wf.line })
		end
	end
	for i, s in wf.steps do
		local ref = s.file
		if ref then
			local there = if ref.lib
				then missing[ref.lib] or exists(`{files.lib_root(c.data, ref.lib)}/{ref.path}`)
				else own ~= nil and own[ref.path] ~= nil
			if not there then
				table.insert(out, {
					file = "workflows.toml",
					path = `{base}.step[{i}].file`,
					message = if ref.lib
						then `文件库 "{ref.lib}" 里没有 {ref.path}`
						else `本工作流没有文件 {ref.path}`,
					line = wf.line,
				})
			end
		end
	end
end

-- `raw` ready to save: an id (with_id), and when the id changes while the workflow keeps its
-- default state group, `state` pinned to the old id so the kept state isn't left behind.
local function prepared(c: Core, old_id: string?, raw: { [string]: any }): { [string]: any }
	local full = with_id(c, old_id, raw)
	if old_id and full.id ~= old_id and full.state == nil and exists(files.state_dir(c.data, old_id)) then
		full = table.clone(full)
		full.state = old_id
	end
	return full
end

-- Issues of `raw` as it would be saved: its own (path under workflow.<id>) and file-level ones.
-- `wfiles` (path → text): the workflow's own files as they would be saved; nil checks those on
-- disk.
function M.check_workflow(c: Core, old_id: string?, raw: { [string]: any }, wfiles: { [string]: string }?): { model.Issue }
	local full = prepared(c, old_id, raw)
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
		file_issues(c, wf, if wfiles == nil and old_id and old_id ~= full.id then own_files(c, old_id, nil) else wfiles, out)
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

-- Applies `fn` to a copy of the groups and keeps the copy once groups.json holds it. An unreadable
-- groups.json is never overwritten (that would drop the user's groups).
local function edit_groups(c: Core, fn: (groups.Groups) -> string?): string?
	if c.groups_err then
		return c.groups_err
	end
	local g = groups.clone(c.groups)
	local err = fn(g)
	if err then
		return err
	end
	local serr = groups.save(c.paths.groups, g)
	if serr then
		return `无法保存分组:{serr}`
	end
	c.groups = g
	c.dev.cfg_dirty = true
	M.changed(c)
	return nil
end

-- Creates a group named `name` (trimmed) at the end; returns its id.
function M.group_create(c: Core, name: string): (string?, string?)
	local blocked = M.config_block(c)
	if blocked then
		return nil, blocked
	end
	local id: string? = nil
	local err = edit_groups(c, function(g)
		local gid, gerr = groups.create(g, util.trim(name))
		id = gid
		return gerr
	end)
	return if err then nil else id, err
end

function M.group_rename(c: Core, id: string, name: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	return edit_groups(c, function(g)
		return groups.rename(g, id, util.trim(name))
	end)
end

-- Deletes a group; its workflows become ungrouped (the workflows themselves stay).
function M.group_delete(c: Core, id: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	return edit_groups(c, function(g)
		return groups.remove(g, id)
	end)
end

-- Moves a group `delta` places in the page's order.
function M.group_move(c: Core, id: string, delta: number): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	return edit_groups(c, function(g)
		return if groups.move(g, id, delta) then nil else "已经到头了"
	end)
end

function M.group_toggle(c: Core, id: string): string?
	return edit_groups(c, function(g)
		return groups.toggle(g, id)
	end)
end

-- Puts workflow `wf` in group `gid` (nil: ungrouped).
function M.group_assign(c: Core, wf: string, gid: string?): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	local w = c.workflows
	if w == nil or w.by_id[wf] == nil then
		return `没有工作流 {wf}`
	end
	return edit_groups(c, function(g)
		return groups.assign(g, wf, gid)
	end)
end

-- A workflow's group follows it to a new id, and is forgotten when it is deleted (`to` nil).
local function regroup(c: Core, from: string, to: string?)
	if c.groups.of[from] == nil then
		return
	end
	local err = edit_groups(c, function(g)
		local gid = g.of[from]
		g.of[from] = nil
		if to then
			g.of[to] = gid
		end
		return nil
	end)
	if err then
		M.notice(c, "warning", `工作流 {from} 的分组没有跟着更新:{err}`)
	end
end

-- Saves `raw` over workflow `old_id` (nil: a new one). Nil when written and reloaded, else the
-- issues that stopped it. workflows.toml.bak keeps the previous file. `wfiles` replaces the
-- workflow's own files (nil keeps them; a changed id moves them along). `base` is what the editor
-- loaded them as: only files that were in it are removed, and a file changed on disk since is
-- not overwritten. Files are written before workflows.toml, so the new definition never runs
-- without its files.
function M.save_workflow(
	c: Core,
	old_id: string?,
	raw: { [string]: any },
	wfiles: { [string]: string }?,
	base: { [string]: string }?
): { model.Issue }?
	local blocked = M.config_block(c)
	if blocked then
		return file_issue(blocked)
	end
	c.dev.cfg_dirty = true
	local issues = M.check_workflow(c, old_id, raw, wfiles)
	if #issues > 0 then
		return issues
	end
	local full = prepared(c, old_id, raw)
	local text, err, old = compose(c, old_id, full)
	if text == nil or old == nil then
		return file_issue(err or "无法写回 workflows.toml")
	end
	local id = full.id :: string
	local moved = old_id ~= nil and old_id ~= id
	-- Files written into a directory that is about to be deleted would go with it.
	if store.pending(c.store, files.workflow_home(c.data, id)) then
		return file_issue(`工作流 "{id}" 的旧文件正在删除,稍后再保存`)
	end
	local want = wfiles
	if moved then
		-- The new id's directory must not already hold files: replacing them would delete what a
		-- hand-restored or orphaned directory kept.
		local there, terr = files.load(files.workflow_root(c.data, id))
		if there == nil then
			return file_issue(`无法读取 "{id}" 的文件目录:{terr}`)
		elseif #there.paths > 0 then
			return file_issue(`工作流 "{id}" 的文件目录里已有文件,先在「文件」页清理再改 id`)
		end
		if want == nil then
			local cur, lerr = own_files(c, old_id :: string, nil)
			if cur == nil then
				return file_issue(`无法读取原工作流的文件:{lerr}`)
			end
			want = cur
		end
	end
	if want then
		local ferr = files.replace(files.workflow_root(c.data, id), want, if moved then nil else base)
		if ferr then
			return file_issue(`无法保存工作流文件,没有写入 workflows.toml:{ferr}`)
		end
	end
	local werr = write_workflows(c, old, text)
	if werr then
		return file_issue(werr)
	end
	if moved then
		-- Only what the editor loaded leaves the old directory (and only if it is unchanged there):
		-- a file added or edited elsewhere meanwhile, hidden files and the directory itself stay.
		local old_home = files.workflow_home(c.data, old_id :: string)
		local old_root = `{old_home}/files`
		local leftover: string? = nil
		local snapshot = base
		if snapshot then
			local on_disk = files.load(old_root)
			for rel, was in snapshot do
				if on_disk and on_disk.text[rel] == was then
					files.remove(old_root, rel)
				end
			end
		else
			-- No base (the files moved untouched): everything listed was copied, so it can go.
			files.replace(old_root, {})
		end
		local ok, left = pcall(tern.fs.list, old_root)
		if ok and type(left) == "table" and #(left :: { string }) == 0 then
			store.discard(c.store, old_home)
		else
			leftover = old_home
		end
		if leftover then
			M.notice(c, "warning", `工作流 {old_id} 的旧目录里还有没复制的文件,已保留:{leftover}`)
		end
		M.changed(c)
		regroup(c, old_id :: string, id)
	end
	return nil
end

-- Removes workflow `id` from workflows.toml, then its own files (its state stays: see M.states).
function M.delete_workflow(c: Core, id: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	c.dev.cfg_dirty = true
	local old, rerr = current_text(c)
	if old == nil then
		return rerr
	end
	local text, err = model.splice_workflow(old, id, nil)
	if text == nil then
		return err
	end
	local werr = write_workflows(c, old, text)
	if werr == nil then
		regroup(c, id, nil)
		if model.valid_lib(id) then
			store.discard(c.store, files.workflow_home(c.data, id))
		end
		M.changed(c)
	end
	return werr
end

-- The TOML-shaped table of workflow `id` as it is in the file now.
function M.workflow_raw(c: Core, id: string): { [string]: any }?
	local text = read_file(c.paths.workflows)
	return if text then model.raw_workflow(text, id) else nil
end

-- ---------------------------------------------------------------------------------------------
-- Workflow files, the file library, state directories, export and import (lib/files.luau,
-- lib/bundle.luau). Runs use copies (files.stage); everything here edits the originals.

-- Export files kept (newest first) once the retention policy is in force.
M.MAX_EXPORTS = 50

export type LibInfo = { name: string, used_by: { string } }
export type StateInfo = { name: string, used_by: { string } }
export type ImportPlan = {
	path: string,
	workflows: { { id: string, name: string, exists: boolean } },
	libraries: { { name: string, exists: boolean, same: boolean } },
	repos: { { name: string, exists: boolean } },
	files: number,
	-- The export's groups by name: whether one by that name is here, and how many workflows it lists.
	groups: { { name: string, exists: boolean, count: number } },
}

-- The workflow's own files on disk.
function M.workflow_files(c: Core, id: string): (files.Tree?, string?)
	if not model.valid_lib(id) then
		return { paths = {}, text = {} }, nil
	end
	return files.load(files.workflow_root(c.data, id))
end

-- name → ids of the workflows `pick` says use it.
local function users(c: Core, pick: (model.Workflow) -> { string }): { [string]: { string } }
	local out: { [string]: { string } } = {}
	local w = c.workflows
	if w then
		for _, wf in w.list do
			for _, n in pick(wf) do
				out[n] = out[n] or {}
				table.insert(out[n], wf.id)
			end
		end
	end
	return out
end

-- The libraries on disk and which workflows use them.
function M.libraries(c: Core): { LibInfo }
	local used = users(c, function(wf)
		return wf.libs
	end)
	local out: { LibInfo } = {}
	for _, name in files.libs(c.data) do
		table.insert(out, { name = name, used_by = used[name] or {} })
	end
	return out
end

local function lib_root(c: Core, name: string): (string?, string?)
	if not model.valid_lib(name) then
		return nil, `文件库名 "{name}" 无效`
	end
	local root = files.lib_root(c.data, name)
	if not exists(root) then
		return nil, `文件库 "{name}" 不存在`
	end
	return root, nil
end

function M.library_files(c: Core, name: string): (files.Tree?, string?)
	local root, err = lib_root(c, name)
	if root == nil then
		return nil, err
	end
	return files.load(root)
end

function M.create_library(c: Core, name: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	c.dev.cfg_dirty = true
	if not model.valid_lib(name) then
		return `文件库名 "{name}" 无效:1-64 位 a-z 0-9 _ -,以字母或数字开头`
	end
	local root = files.lib_root(c.data, name)
	if store.pending(c.store, root) then
		return `文件库 "{name}" 正在删除,稍后再创建`
	elseif exists(root) then
		return `文件库 "{name}" 已存在`
	end
	local ok, err = pcall(function(): string?
		tern.fs.mkdir(root)
		return nil
	end)
	if not ok then
		return `无法创建文件库:{err}`
	end
	M.changed(c)
	return nil
end

-- The workflows with a step running `@name/path`; "" when none, or why it can't be told.
local function step_users(c: Core, name: string, path: string): (string, string?)
	if c.workflows == nil or #c.workflow_issues > 0 then
		return "", "workflows.toml 有错误,无法确认有没有步骤在用这个文件:修好后再改"
	end
	local out: { string } = {}
	for _, wf in c.workflows.list do
		for _, s in wf.steps do
			local ref = s.file
			if ref and ref.lib == name and ref.path == path then
				table.insert(out, wf.id)
				break
			end
		end
	end
	return table.concat(out, "、"), nil
end

-- Writes one library file (`from` given: renames that file to `path` at the same time). The whole
-- library must stay within the limits.
function M.save_library_file(c: Core, name: string, path: string, text: string, from: string?): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	c.dev.cfg_dirty = true
	local root, err = lib_root(c, name)
	if root == nil then
		return err
	end
	local tree, lerr = files.load(root)
	if tree == nil then
		return lerr
	end
	local all = table.clone(tree.text)
	if from and from ~= path then
		if all[from] == nil then
			return `文件库 "{name}" 里没有 {from}`
		elseif all[path] ~= nil and string.lower(path) ~= string.lower(from) then
			return `{path} 已存在`
		end
		-- A step names the old path: the rename would break its next run.
		local used, uerr = step_users(c, name, from)
		if uerr then
			return uerr
		elseif used ~= "" then
			return `{from} 仍被工作流 {used} 的步骤使用,先改步骤再重命名`
		end
		all[from] = nil
	end
	all[path] = text
	local bad = files.check(all)
	if bad then
		return bad
	end
	local werr: string? = nil
	if from and from ~= path and string.lower(from) == string.lower(path) then
		-- A case-only rename is one file on a case-insensitive disk: writing the new name would
		-- overwrite the old one, and removing the old name afterwards would delete the result.
		-- The content is in `text`, so the old name goes first.
		werr = files.remove(root, from)
		if werr == nil then
			werr = files.write(root, path, text)
		end
	else
		werr = files.write(root, path, text)
		if werr == nil and from and from ~= path then
			werr = files.remove(root, from)
		end
	end
	M.changed(c)
	return werr
end

function M.delete_library_file(c: Core, name: string, path: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	c.dev.cfg_dirty = true
	local root, err = lib_root(c, name)
	if root == nil then
		return err
	end
	local used, uerr = step_users(c, name, path)
	if uerr then
		return uerr
	elseif used ~= "" then
		return `{path} 仍被工作流 {used} 的步骤使用`
	end
	local rerr = files.remove(root, path)
	M.changed(c)
	return rerr
end

-- Deletes a library no workflow uses.
function M.delete_library(c: Core, name: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	c.dev.cfg_dirty = true
	local root, err = lib_root(c, name)
	if root == nil then
		return err
	end
	if c.workflows == nil or #c.workflow_issues > 0 then
		return "workflows.toml 有错误,无法确认文件库是否仍被使用:修好后再删除"
	end
	for _, info in M.libraries(c) do
		if info.name == name and #info.used_by > 0 then
			return `仍被工作流 {table.concat(info.used_by, "、")} 使用`
		end
	end
	store.discard(c.store, root)
	M.changed(c)
	return nil
end

-- The state directories on disk and the workflows whose state group they are.
function M.states(c: Core): { StateInfo }
	local used = users(c, function(wf)
		return { wf.state }
	end)
	local out: { StateInfo } = {}
	for _, name in files.names(`{c.data}/state`) do
		table.insert(out, { name = name, used_by = used[name] or {} })
	end
	return out
end

-- Deletes a state directory (a workflow still using it starts over), unless a queued or running
-- run uses it.
function M.delete_state(c: Core, name: string): string?
	if not model.valid_lib(name) then
		return `状态目录名 "{name}" 无效`
	end
	if #c.workflow_issues > 0 then
		return "workflows.toml 有错误,无法确认哪些工作流在用这个状态目录:修好后再删除"
	end
	local w = c.workflows
	for _, r in c.store.runs do
		if r.state == "queued" or r.state == "running" then
			local wf = if w then w.by_id[r.workflow] else nil
			if wf == nil or wf.state == name then
				return "有排队或正在执行的运行可能在用这个状态目录,等它们结束后再删除"
			end
		end
	end
	store.discard(c.store, files.state_dir(c.data, name))
	M.changed(c)
	return nil
end

-- Ids under workflows/ with no such workflow (left by hand edits of workflows.toml); empty while
-- workflows.toml has errors (the last good copy would call a workflow added since an orphan).
function M.orphan_workflow_files(c: Core): { string }
	local w = c.workflows
	local out: { string } = {}
	if w and #c.workflow_issues == 0 then
		for _, id in files.names(`{c.data}/workflows`) do
			if w.by_id[id] == nil then
				table.insert(out, id)
			end
		end
	end
	return out
end

function M.delete_workflow_files(c: Core, id: string): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	if table.find(M.orphan_workflow_files(c), id) == nil then
		return `工作流 "{id}" 仍在使用这些文件`
	end
	store.discard(c.store, files.workflow_home(c.data, id))
	M.changed(c)
	return nil
end

local function export_file(name: string): boolean
	return string.sub(name, -#bundle.SUFFIX) == bundle.SUFFIX and string.match(name, "^[%w%-_%.]+$") ~= nil
end

-- Export file names, newest first (names start with the time).
function M.exports(c: Core): { string }
	local ok, names = pcall(tern.fs.list, files.exports_dir(c.data))
	local out: { string } = {}
	if ok and type(names) == "table" then
		for _, n in names :: { string } do
			if export_file(n) then
				table.insert(out, n)
			end
		end
	end
	table.sort(out, function(a, b)
		return a > b
	end)
	return out
end

-- Deletes every export file; returns how many were queued.
function M.clear_exports(c: Core): number
	local list = M.exports(c)
	for _, n in list do
		store.discard(c.store, `{files.exports_dir(c.data)}/{n}`)
	end
	M.changed(c)
	return #list
end

-- Queues exports past MAX_EXPORTS; returns how many.
function prune_exports(c: Core): number
	local list = M.exports(c)
	local n = 0
	for i = M.MAX_EXPORTS + 1, #list do
		store.discard(c.store, `{files.exports_dir(c.data)}/{list[i]}`)
		n += 1
	end
	return n
end

local function utf8_text(s: string): boolean
	return utf8.len(s) ~= nil and string.find(s, "%z") == nil
end

-- The bundle of workflows `ids` (with their files, the libraries they use, their repositories'
-- branch settings and their groups), env values blanked (counted in `counts.blanked`). Workflows
-- go in the workflows page's order (groups in order, then the ungrouped); every workflow also
-- keeps the empty groups. `every_repo`: all declared repositories, not just the ones triggers name.
local function make_bundle(
	c: Core,
	ids: { string },
	every_repo: boolean,
	counts: { blanked: number }
): (bundle.Bundle?, string?)
	local w = c.workflows
	if w == nil then
		return nil, "workflows.toml 有错误,修好后再导出"
	end
	local text = read_file(c.paths.workflows)
	if text == nil then
		return nil, "无法读取 workflows.toml"
	end
	local b: bundle.Bundle = { exported_at = now(), repos = {}, workflows = {}, files = {}, groups = {} }
	local wanted: { [string]: boolean } = {}
	for _, id in ids do
		wanted[id] = true
	end
	local all = true
	for _, wf in w.list do
		all = all and wanted[wf.id] == true
	end
	local ordered: { string } = {}
	for _, s in groups.sections(c.groups, w.list, function(wf: model.Workflow): string
		return wf.id
	end) do
		local members: { string } = {}
		for _, wf in s.items do
			if wanted[wf.id] then
				table.insert(members, wf.id)
				table.insert(ordered, wf.id)
			end
		end
		if s.group and (#members > 0 or all) then
			table.insert(b.groups, { name = s.group.name, workflows = members })
		end
	end
	-- Unknown ids stay in so the lookup below names them.
	for _, id in ids do
		if w.by_id[id] == nil and table.find(ordered, id) == nil then
			table.insert(ordered, id)
		end
	end
	local libs: { [string]: boolean } = {}
	for _, id in ordered do
		local wf = w.by_id[id]
		local raw = model.raw_workflow(text, id)
		if wf == nil or raw == nil then
			return nil, `找不到工作流 {id}`
		end
		-- Variables in a workflow's env often hold tokens, and an export gets shared: names stay,
		-- values go.
		if type(raw.env) == "table" then
			local blank: { [string]: string } = {}
			for k in raw.env :: { [string]: any } do
				blank[k] = ""
				counts.blanked += 1
			end
			raw.env = blank
		end
		table.insert(b.workflows, raw)
		for _, tr in wf.triggers do
			for _, name in model.trigger_repos(tr) do
				local repo = w.repos[name]
				if repo then
					b.repos[name] = { branch = repo.branch, worktree = repo.worktree }
				end
			end
		end
		for _, lib in wf.libs do
			libs[lib] = true
		end
		local tree, err = M.workflow_files(c, id)
		if tree == nil then
			return nil, `{id} 的文件:{err}`
		end
		for _, p in tree.paths do
			if not utf8_text(tree.text[p]) then
				return nil, `{id} 的文件 {p} 不是 UTF-8 文本,无法导出`
			end
			table.insert(b.files, { workflow = id, path = p, text = tree.text[p] })
		end
	end
	for _, lib in util.keys(libs) do
		local tree, err = M.library_files(c, lib)
		if tree == nil then
			return nil, `文件库 "{lib}":{err}`
		end
		for _, p in tree.paths do
			if not utf8_text(tree.text[p]) then
				return nil, `文件库 "{lib}" 的 {p} 不是 UTF-8 文本,无法导出`
			end
			table.insert(b.files, { library = lib, path = p, text = tree.text[p] })
		end
	end
	if every_repo then
		for name, repo in w.repos do
			b.repos[name] = { branch = repo.branch, worktree = repo.worktree }
		end
	end
	return b, nil
end

-- Writes workflows `ids` to one file under exports/ (see make_bundle); returns its path.
function M.export_workflows(c: Core, ids: { string }): (string?, string?)
	if c.workflows == nil then
		return nil, "workflows.toml 有错误,修好后再导出"
	elseif #ids == 0 then
		return nil, "没有要导出的工作流"
	end
	local counts = { blanked = 0 }
	local b, berr = make_bundle(c, ids, false, counts)
	if b == nil then
		return nil, berr
	end
	local blanked = counts.blanked
	local stamp = os.date("%Y-%m-%d %H:%M", math.floor(now())) :: string
	local note = if blanked > 0 then `\n工作流 env 里的 {blanked} 个变量只保留了名字,值已清空(可能含令牌),导入后请自行填写。` else ""
	local out = bundle.encode(b, `Roost 工作流导出({stamp},Roost {M.VERSION})。\n在 Roost「工作流」页用「导入」载入;导入的工作流默认停用。{note}`)
	if #out > bundle.MAX_BYTES then
		return nil, `导出内容超过 {bundle.MAX_BYTES // (1024 * 1024)} MiB(文件太多或太大),请分开导出`
	end
	local what = if #ids == 1 then ids[1] else `{#ids}-workflows`
	local dir = files.exports_dir(c.data)
	local path = `{dir}/{os.date("%Y%m%d-%H%M%S", math.floor(now()))}-{what}{bundle.SUFFIX}`
	local ok, err = pcall(function(): string?
		tern.fs.mkdir(dir)
		tern.fs.write(path, out)
		return nil
	end)
	if not ok then
		return nil, `无法写入导出文件:{err}`
	end
	M.changed(c)
	return path, nil
end

-- `path`: an absolute path, `~/…`, or the name of a file under exports/.
local function read_bundle(c: Core, path: string): (bundle.Bundle?, string, string?)
	local p = util.expand(util.trim(path), tern.getenv("HOME"))
	if p == "" then
		return nil, p, "请填写导出文件的路径"
	elseif string.sub(p, 1, 1) ~= "/" then
		p = `{files.exports_dir(c.data)}/{p}`
	end
	local ok, text = pcall(tern.fs.read, p, bundle.MAX_BYTES)
	if not ok or type(text) ~= "string" then
		return nil, p, `无法读取 {p}(不存在、超过 {bundle.MAX_BYTES // (1024 * 1024)} MiB 或不是普通文件)`
	end
	local b, err = bundle.decode(text)
	return b, p, err
end

-- The bundle's files grouped by owner: workflow id → tree, library → tree.
local function trees(b: bundle.Bundle): ({ [string]: { [string]: string } }, { [string]: { [string]: string } })
	local wf: { [string]: { [string]: string } } = {}
	local lib: { [string]: { [string]: string } } = {}
	for _, f in b.files do
		local group = if f.workflow then wf else lib
		local key = (f.workflow or f.library) :: string
		group[key] = group[key] or {}
		group[key][f.path] = f.text
	end
	return wf, lib
end

local function same_tree(a: { [string]: string }, b: { [string]: string }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- The repositories declared in `text` (an unparsable file has none).
local function declared_repos(text: string): { [string]: boolean }
	local root = toml.parse(text)
	local out: { [string]: boolean } = {}
	if type(root) == "table" and type(root.repos) == "table" then
		for name in root.repos do
			out[name] = true
		end
	end
	return out
end

-- What importing `path` would do.
function M.import_preview(c: Core, path: string): (ImportPlan?, string?)
	local b, p, err = read_bundle(c, path)
	if b == nil then
		return nil, err
	end
	local old, rerr = current_text(c)
	if old == nil then
		return nil, rerr
	end
	local _, libtrees = trees(b)
	local repos = declared_repos(old)
	local plan: ImportPlan =
		{ path = p, workflows = {}, libraries = {}, repos = {}, files = #b.files, groups = {} }
	for _, bg in b.groups do
		local here = false
		for _, x in c.groups.list do
			here = here or x.name == bg.name
		end
		table.insert(plan.groups, { name = bg.name, exists = here, count = #bg.workflows })
	end
	for _, raw in b.workflows do
		local id = tostring(raw.id)
		table.insert(plan.workflows, {
			id = id,
			name = if type(raw.name) == "string" then raw.name else id,
			exists = model.raw_workflow(old, id) ~= nil,
		})
	end
	for _, name in util.keys(libtrees) do
		local cur = M.library_files(c, name)
		table.insert(plan.libraries, {
			name = name,
			exists = exists(files.lib_root(c.data, name)),
			same = cur ~= nil and same_tree(cur.text, libtrees[name]),
		})
	end
	for _, name in util.keys(b.repos) do
		table.insert(plan.repos, { name = name, exists = repos[name] == true })
	end
	return plan, nil
end

-- Imports `path`: its workflows go in disabled; existing workflows and differing libraries are
-- replaced only with `overwrite`. Everything is checked before anything is written; files go
-- first, workflows.toml (with its .bak) last. Returns a summary.
function M.import_workflows(c: Core, path: string, overwrite: boolean): (string?, string?)
	local blocked = M.config_block(c)
	if blocked then
		return nil, blocked
	end
	local b, p, err = read_bundle(c, path)
	if b == nil then
		return nil, err
	end
	local old, rerr = current_text(c)
	if old == nil then
		return nil, rerr
	end
	local wftrees, libtrees = trees(b)
	local text = old
	local added: { string } = {}
	local skipped: { string } = {}
	for _, raw in b.workflows do
		local id = tostring(raw.id)
		local there = model.raw_workflow(text, id) ~= nil
		if there and not overwrite then
			table.insert(skipped, id)
			continue
		end
		raw.enabled = false
		-- Exports blank env values; replacing a workflow must not erase the ones it has here.
		if there and type(raw.env) == "table" then
			local keep = model.raw_workflow(text, id)
			local have: { [string]: any } = if keep and type(keep.env) == "table" then keep.env else {}
			for k, v in raw.env :: { [string]: any } do
				if v == "" and type(have[k]) == "string" then
					(raw.env :: { [string]: any })[k] = have[k]
				end
			end
		end
		local next_text, serr = model.splice_workflow(text, if there then id else nil, model.encode_workflow(raw))
		if next_text == nil then
			return nil, `{id}:{serr or "无法写入"}`
		end
		text = next_text
		table.insert(added, id)
	end
	if #added == 0 then
		return nil, `没有可导入的工作流:{table.concat(skipped, "、")} 已存在(选择覆盖才会替换)`
	end
	local repos = declared_repos(old)
	local new_repos: { string } = {}
	for _, name in util.keys(b.repos) do
		if not repos[name] then
			local r = b.repos[name]
			local lines = {
				"",
				`# 导入自 {string.match(p, "[^/]+$") or p}:填写本机检出路径 path 后才会在检出中运行(否则在临时目录中运行)`,
				`[repos.{toml.quote(name)}]`,
			}
			if r.branch then
				table.insert(lines, `branch = {toml.quote(r.branch)}`)
			end
			if r.worktree ~= nil then
				table.insert(lines, `worktree = {if r.worktree then "true" else "false"}`)
			end
			text = (if string.sub(text, -1) == "\n" or text == "" then text else text .. "\n") .. table.concat(lines, "\n") .. "\n"
			table.insert(new_repos, name)
		end
	end
	local w, issues = model.parse_workflows(text)
	if w == nil then
		local msgs: { string } = {}
		for i = 1, math.min(3, #issues) do
			table.insert(msgs, `{issues[i].path}:{issues[i].message}`)
		end
		return nil, `导入后 workflows.toml 无效,没有做任何修改:{table.concat(msgs, ";")}`
	end
	-- A directory still being deleted would take the new files with it.
	for _, id in added do
		if store.pending(c.store, files.workflow_home(c.data, id)) then
			return nil, `工作流 {id} 的旧文件正在删除,稍后再导入`
		end
	end
	for name in libtrees do
		if store.pending(c.store, files.lib_root(c.data, name)) then
			return nil, `文件库 "{name}" 正在删除,稍后再导入`
		end
	end
	-- Check every tree before writing any.
	for id in wftrees do
		local bad = files.check(wftrees[id])
		if bad then
			return nil, `{id} 的文件:{bad}`
		end
	end
	local lib_writes: { string } = {}
	local lib_kept: { string } = {}
	for _, name in util.keys(libtrees) do
		local bad = files.check(libtrees[name])
		if bad then
			return nil, `文件库 "{name}":{bad}`
		end
		local cur = M.library_files(c, name)
		if cur == nil or not exists(files.lib_root(c.data, name)) then
			table.insert(lib_writes, name)
		elseif not same_tree(cur.text, libtrees[name]) then
			table.insert(if overwrite then lib_writes else lib_kept, name)
		end
	end
	for _, name in lib_writes do
		local ferr = files.replace(files.lib_root(c.data, name), libtrees[name])
		if ferr then
			return nil, `写入文件库 "{name}" 失败,workflows.toml 未修改:{ferr}`
		end
	end
	for _, id in added do
		local ferr = files.replace(files.workflow_root(c.data, id), wftrees[id] or {})
		if ferr then
			return nil, `写入 {id} 的文件失败,workflows.toml 未修改:{ferr}`
		end
	end
	local werr = write_workflows(c, old, text)
	if werr then
		return nil, werr
	end
	local parts = { `已导入 {#added} 个工作流(已停用,检查后再启用):{table.concat(added, "、")}` }
	if #skipped > 0 then
		table.insert(parts, `跳过已存在的 {table.concat(skipped, "、")}`)
	end
	if #lib_writes > 0 then
		table.insert(parts, `写入文件库 {table.concat(lib_writes, "、")}`)
	end
	if #lib_kept > 0 then
		table.insert(parts, `文件库 {table.concat(lib_kept, "、")} 与本机内容不同,保留本机版本`)
	end
	if #new_repos > 0 then
		table.insert(parts, `新增仓库 {table.concat(new_repos, "、")}:需在 workflows.toml 填写本机路径`)
	end
	local missing: { string } = {}
	for _, id in added do
		local wf = w.by_id[id]
		local used: { string } = if wf then wf.libs else {}
		for _, lib in used do
			if not exists(files.lib_root(c.data, lib)) and table.find(missing, lib) == nil then
				table.insert(missing, lib)
			end
		end
	end
	if #missing > 0 then
		table.insert(parts, `缺少文件库 {table.concat(missing, "、")}`)
	end
	if #b.groups > 0 then
		-- Imported workflows join the export's groups (by name, added when missing) unless they
		-- are in a group here already.
		local only: { [string]: boolean } = {}
		for _, id in added do
			only[id] = true
		end
		local made: { string }, joined: number, failed: { string } = {}, 0, {}
		local gerr = edit_groups(c, function(g)
			made, joined, failed = groups.merge(g, b.groups, only)
			return nil
		end)
		if gerr then
			table.insert(parts, `分组没有导入:{gerr}`)
		else
			if #made > 0 then
				table.insert(parts, `新建分组 {table.concat(made, "、")}`)
			end
			if joined > 0 then
				table.insert(parts, `{joined} 个工作流归入分组`)
			end
			if #failed > 0 then
				table.insert(parts, `无法新建分组 {table.concat(failed, "、")}`)
			end
		end
	end
	return table.concat(parts, ";"), nil
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
	if c.login.pending then
		-- omp may only be on the login shell's PATH; the capture's end re-renders.
		return { roles = if cur then cur.roles else {}, models = if cur then cur.models else {}, loading = true }
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
	local env = local_env(c)
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
			tern.process.run(argv, { env = env, timeout_ms = OMP_MS }, function(res: ProcessResult)
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
			'cd "$1" 2>/dev/null && du -sk -- runs worktrees workflows library state exports runs.json runs.json.bak events.json events.json.bak 2>/dev/null; exit 0',
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

-- ---------------------------------------------------------------------------------------------
-- Self-iteration: evolvers' revisions (lib/evolve.luau) and Roost's own upgrades (lib/upgrade.luau).

local function issues_text(issues: { model.Issue }): string
	local parts: { string } = {}
	for i, it in issues do
		if i > 3 then
			table.insert(parts, `等 {#issues} 个问题`)
			break
		end
		table.insert(parts, `{it.path}:{it.message}`)
	end
	return table.concat(parts, ";")
end

-- A library's files replaced like an editor save: only what was in `base` goes, and a file
-- changed on disk since `base` stops it.
local function save_library_tree(c: Core, name: string, tree: { [string]: string }, base: { [string]: string }): string?
	local root, err = lib_root(c, name)
	if root == nil then
		return err
	end
	if store.pending(c.store, root :: string) then
		return `文件库 "{name}" 正在删除`
	end
	local ferr = files.replace(root :: string, tree, base)
	if ferr == nil then
		c.dev.cfg_dirty = true
		M.changed(c)
	end
	return ferr
end

function evolve_host(c: Core): evolve.Host
	return {
		data = c.data,
		store = c.store,
		workflows = function()
			return c.workflows
		end,
		valid = function()
			return c.workflows ~= nil and #c.workflow_issues == 0
		end,
		text = function()
			local text = current_text(c)
			return text
		end,
		now = now,
		save_workflow = function(id, raw, wfiles, base)
			local issues = M.save_workflow(c, id, raw, wfiles, base)
			return if issues and #issues > 0 then issues_text(issues) else nil
		end,
		save_library = function(name, tree, base)
			return save_library_tree(c, name, tree, base)
		end,
		save_files = function(id, wfiles, base)
			if not model.valid_lib(id) then
				return `工作流 id "{id}" 无效`
			end
			if store.pending(c.store, files.workflow_home(c.data, id)) then
				return `工作流 "{id}" 的文件正在删除`
			end
			local err = files.replace(files.workflow_root(c.data, id), wfiles, base)
			if err == nil then
				c.dev.cfg_dirty = true
				M.changed(c)
			end
			return err
		end,
		check = function(id)
			local raw = M.workflow_raw(c, id)
			if raw == nil then
				return `workflows.toml 里没有工作流 {id}`
			end
			local issues = M.check_workflow(c, id, raw)
			return if #issues > 0 then issues_text(issues) else nil
		end,
		discard = function(path)
			store.discard(c.store, path)
			M.changed(c)
		end,
		notice = function(level, text)
			M.notice(c, level, text)
		end,
		log = function(id, lines)
			runner.log(c.runner, id, lines)
		end,
	}
end

-- After a run finished: an evolver's success applies its changes; the run counts toward the
-- revisions watching its workflow (which may undo one); a failure may start an evolver (not when
-- it just undid a revision of that workflow: the cause is known).
function on_finished(c: Core, run: store.Run)
	local h = evolve_host(c)
	local w = c.workflows
	local wf = if w then w.by_id[run.workflow] else nil
	-- A run that ends after this machine became an observer (it started as the executor): the
	-- configuration is the new executor's now, so nothing is applied, undone or started here.
	local observer = relay.role(c.relay) == "observer"
	if observer then
		for _, s in run.steps do
			if s.kind == "upgrade" and s.state == "success" then
				watch_upgrades(c, run.id)
			end
		end
		M.changed(c)
		return
	end
	if run.state == "success" and wf and wf.evolve then
		local lines = evolve.apply(h, c.book, run)
		if #lines > 0 then
			runner.log(c.runner, run.id, lines)
		end
	end
	for _, s in run.steps do
		if s.kind == "upgrade" and s.state == "success" then
			-- The handoff happened (or there was nothing to apply): say how it ends.
			watch_upgrades(c, run.id)
		end
	end
	local rolled = evolve.observe(h, c.book, run)
	if table.find(rolled, run.workflow) == nil then
		for _, f in evolve.fire(h, c.book, run) do
			local ws = c.workflows
			local repo = if ws then default_repo(ws, f.workflow) else nil
			local _, err = runner.submit(c.runner, f.workflow, {
				trigger = { kind = "roost", detail = f.detail },
				repo = repo,
				ref = if repo and ws and ws.repos[repo] then ws.repos[repo].branch else nil,
				inputs = defaults(f.workflow),
				evolve = { target = f.target, run = f.run },
			})
			if err then
				M.notice(c, "error", `无法启动 {f.workflow.name}:{err}`)
			end
		end
	end
	M.changed(c)
end

-- Says once how the latest self-upgrade ended (its result file outlives the reload it caused).
-- False while there is nothing final to say yet: it is still being applied, or `want` (a run
-- whose upgrade step just handed off) has no result yet.
local function report_upgrades(c: Core, want: string?): boolean
	local r = upgrade.results(c.data, 1)[1]
	if r == nil or (want and r.run ~= want) then
		return want == nil
	elseif r.state == "applying" then
		return false
	end
	local key = `{r.run}:{r.state}`
	local ok, seen = pcall(tern.kv.get, "upgrade_seen")
	if ok and seen == key then
		return true
	end
	pcall(tern.kv.set, "upgrade_seen", key)
	local level = if r.state == "applied"
		then "success"
		elseif r.state == "rolled_back" or r.state == "failed" then "error"
		else "warning"
	M.notice(c, level, `Roost 自升级:{upgrade.describe(r)}`)
	M.changed(c)
	return true
end

-- How long an upgrade's outcome is waited for, and how often it is looked at meanwhile.
local UPGRADE_WATCH = 300
local UPGRADE_POLL_MS = 3000
local upgrade_watch: { until_: number, want: string? }? = nil

-- Reports the latest upgrade's outcome, looking again every few seconds until there is one (at
-- most UPGRADE_WATCH); `run`: the run whose upgrade step just handed off. One loop at a time.
function watch_upgrades(c: Core, run: string?)
	local running = upgrade_watch ~= nil
	upgrade_watch = { until_ = now() + UPGRADE_WATCH, want = run }
	if running then
		return
	end
	local function look()
		local w = upgrade_watch
		if w == nil or report_upgrades(c, w.want) or now() >= w.until_ then
			upgrade_watch = nil
			return
		end
		tern.timer(UPGRADE_POLL_MS, look)
	end
	look()
end

-- Tabs Roost recorded belong to the Tern daemon that showed them: once another daemon runs (a
-- restart may hand the same pane ids to new panes), the records are dropped so no pane is closed
-- by mistake. The daemon is told apart by its pid and start time (the parent of our processes);
-- when it can't be told, the records go too. `done` runs once that is settled.
function check_daemon(c: Core, done: () -> ())
	local function purge()
		for _, path in tabs.entries(c.data) do
			pcall(tern.fs.remove, path)
		end
	end
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", 'l=$(ps -o lstart= -p "$PPID") && [ -n "$l" ] && printf "%s %s" "$PPID" "$l"' },
			{ timeout_ms = 5000 },
			function(res)
				local id = util.trim(res.stdout or "")
				if res.status ~= 0 or res.timed_out or id == "" then
					purge()
				else
					local okk, was = pcall(tern.kv.get, "daemon")
					if not (okk and was == id) then
						purge()
					end
					pcall(tern.kv.set, "daemon", id)
				end
				done()
			end
		)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot identify the Tern daemon", err)
		purge()
		done()
	end
end

-- Evolvers' revisions, newest first.
function M.revisions(c: Core): { evolve.Revision }
	return evolve.list(c.book)
end

-- Undoes revision `n` by hand.
function M.rollback_revision(c: Core, n: number): string?
	local blocked = M.config_block(c)
	if blocked then
		return blocked
	end
	local err = evolve.rollback(evolve_host(c), c.book, n, "手动回滚")
	if err == nil then
		M.notice(c, "success", `已回滚迭代修订 #{n}`)
	end
	M.changed(c)
	return err
end

-- Roost's own upgrades, newest first.
function M.upgrades(c: Core, n: number): { upgrade.Result }
	return upgrade.results(c.data, n)
end

-- ---------------------------------------------------------------------------------------------
-- Devices (lib/fleet.luau, agent/src/fleet.rs): the executor uploads its configuration and its
-- recent runs; an observer applies the configuration here and shows the runs.

local DEV_MS = 5000
-- The executor rebuilds its configuration at least this often (edits mark it dirty sooner).
local CFG_EVERY = 30
-- A configuration that failed to apply is retried after this long (or when it changes).
local MIRROR_RETRY = 60
-- A running run's log tail is read again after this long; at most this many reads at once.
local TAIL_EVERY = 5
local MAX_TAILING = 4
local TAIL_MS = 5000
-- A tail read that failed (no log yet, a timeout) is tried again after this long.
local TAIL_RETRY = 60
-- Unchanged run summaries are sent again after this long when the relay seems not to have them.
local RUNS_RECHECK = 60

export type Device = {
	id: string,
	name: string?,
	last_seen: number?,
	cursor: number?,
	executor: boolean,
	me: boolean,
}

function M.role(c: Core): fleet.Role
	return relay.role(c.relay)
end

function M.executor(c: Core): fleet.Executor?
	return relay.executor(c.relay)
end

-- Why the relay can't say who the executor is (its device record is unreadable), or nil.
function M.fleet_error(c: Core): string?
	return relay.fleet_error(c.relay)
end

-- The devices the relay has heard from since it started, and the executor even when it hasn't.
function M.devices(c: Core): { Device }
	local out: { Device } = {}
	local ex = relay.executor(c.relay)
	local me = c.relay.h.client_id
	local agent = c.relay.state.agent
	local seen: { [string]: boolean } = {}
	if agent and type(agent.clients) == "table" then
		for _, x in agent.clients do
			if type(x) == "table" and type(x.id) == "string" and not seen[x.id] then
				seen[x.id] = true
				table.insert(out, {
					id = x.id,
					name = if type(x.name) == "string" and x.name ~= "" then x.name else nil,
					last_seen = util.rfc3339(x.last_seen),
					cursor = if type(x.cursor) == "number" then x.cursor else nil,
					executor = ex ~= nil and ex.id == x.id,
					me = x.id == me,
				})
			end
		end
	end
	if ex and not seen[ex.id] then
		table.insert(out, { id = ex.id, name = ex.name, executor = true, me = ex.id == me })
	end
	table.sort(out, function(a, b)
		if a.executor ~= b.executor then
			return a.executor
		end
		return (a.last_seen or 0) > (b.last_seen or 0)
	end)
	return out
end

-- Makes device `id` the executor (this machine or another the relay knows).
function M.assign_executor(c: Core, id: string)
	relay.assign(c.relay, id, function(ok, msg)
		if ok then
			local ex = relay.executor(c.relay)
			M.notice(c, "success", `执行者已改为「{fleet.label(ex)}」`)
			c.dev.cfg_dirty = true
			dev_loop(c)
		else
			M.notice(c, "error", `无法指定执行者:{msg}`)
		end
	end)
end

-- The executor's configuration as uploaded: every workflow, its files, the libraries in use, all
-- repositories (branch settings only) and every group; env values blank. Stable while nothing
-- changes (no time in it).
local function sync_text(c: Core): (string?, string?)
	local w = c.workflows
	if w == nil or #c.workflow_issues > 0 then
		return nil, "workflows.toml 有错误,修好后才会同步配置"
	end
	local ids: { string } = {}
	for _, wf in w.list do
		table.insert(ids, wf.id)
	end
	local b, err = make_bundle(c, ids, true, { blanked = 0 })
	if b == nil then
		return nil, err
	end
	b.exported_at = 0
	local text = bundle.encode(b, "Roost 设备同步:执行者的工作流配置(env 的值不上传)")
	if #text > bundle.MAX_BYTES then
		return nil, `配置超过 {bundle.MAX_BYTES // (1024 * 1024)} MiB,无法同步给观察者`
	end
	return text, nil
end

local function upload_config(c: Core)
	local d = c.dev
	local t = now()
	if d.cfg_busy or (not d.cfg_dirty and d.cfg_built and t - d.cfg_built < CFG_EVERY) then
		return
	end
	d.cfg_dirty, d.cfg_built = false, t
	local text, err = sync_text(c)
	if text == nil then
		if d.cfg_err ~= err then
			d.cfg_err = err
			M.changed(c)
		end
		return
	end
	-- Unchanged and still what the relay holds: nothing to send. A relay that lost it (its files
	-- were reset) gets it again.
	local f = relay.fleet(c.relay)
	local held = if f and type(f.config) == "table" then f.config.revision else nil
	if text == d.cfg_text and held ~= nil and held == d.cfg_rev then
		return
	end
	d.cfg_busy = true
	relay.put_config(c.relay, text, function(ok, body, perr)
		d.cfg_busy = false
		if ok then
			local meta = if type(body) == "table" then body.config else nil
			d.cfg_text, d.cfg_err, d.cfg_at = text, nil, now()
			d.cfg_rev = if type(meta) == "table" and type(meta.revision) == "string" then meta.revision else nil
		else
			d.cfg_err = perr or "上传失败"
			d.cfg_dirty = true
		end
		M.changed(c)
	end)
end

-- Reads the last bytes of run `r`'s log into the tail cache.
local function read_tail(c: Core, r: store.Run)
	local d = c.dev
	local id, state = r.id, r.state
	d.tailing[id] = true
	local path = `{store.run_dir(c.store, id)}/log.txt`
	local ok = pcall(function(): string?
		tern.process.run(
			{ "/usr/bin/tail", "-c", tostring(fleet.TAIL_BYTES + 1), path },
			{ timeout_ms = TAIL_MS },
			function(res: ProcessResult)
				d.tailing[id] = nil
				local got = res.status == 0 and not res.timed_out
				local raw = if got then res.stdout or "" else ""
				local full = #raw <= fleet.TAIL_BYTES
				if not full then
					raw = string.sub(raw, -fleet.TAIL_BYTES)
				end
				local text = fleet.clean_tail(raw, full)
				if utf8.len(text) == nil then
					text = "(日志结尾不是有效的 UTF-8 文本)"
				end
				d.tails[id] = { text = text, at = now(), state = state, failed = not got }
			end
		)
		return nil
	end)
	if not ok then
		d.tailing[id] = nil
	end
end

-- Keeps the tails of the newest runs current: read again when a run's state changed, and every
-- TAIL_EVERY seconds while it runs. Tails of runs no longer among the newest are dropped.
local function refresh_tails(c: Core, list: { store.Run })
	local d = c.dev
	local keep: { [string]: boolean } = {}
	local busy = 0
	for _ in d.tailing do
		busy += 1
	end
	local t = now()
	for i = 1, math.min(fleet.TAILS, #list) do
		local r = list[i]
		keep[r.id] = true
		local have = d.tails[r.id]
		local stale = have == nil
			or have.state ~= r.state
			or (r.state == "running" and t - have.at >= TAIL_EVERY)
			or (have.failed == true and t - have.at >= TAIL_RETRY)
		if stale and r.state ~= "queued" and not d.tailing[r.id] and busy < MAX_TAILING then
			busy += 1
			read_tail(c, r)
		end
	end
	for id in d.tails do
		if not keep[id] then
			d.tails[id] = nil
		end
	end
end

local function upload_runs(c: Core)
	local d = c.dev
	if d.runs_busy then
		return
	end
	local list = store.list(c.store, fleet.MAX_RUNS, nil)
	refresh_tails(c, list)
	local tails: { [string]: string } = {}
	for id, x in d.tails do
		tails[id] = x.text
	end
	-- A log that isn't valid UTF-8 can't be encoded: send the runs without tails then.
	local ok, json = pcall(fleet.summaries, list, tails)
	if not ok then
		ok, json = pcall(fleet.summaries, list, {})
	end
	-- Unchanged: sent already, unless the relay no longer has it (checked at most every minute;
	-- its record of the runs comes with the status, not at once).
	local f = relay.fleet(c.relay)
	local held = f ~= nil and type(f.runs) == "table"
	if not ok or (json == d.runs_json and (held or now() - (d.runs_at or 0) < RUNS_RECHECK)) then
		return
	end
	d.runs_busy = true
	relay.put_runs(c.relay, json, function(pok, _body, err)
		d.runs_busy = false
		if pok then
			d.runs_json, d.runs_err, d.runs_at = json, nil, now()
		else
			d.runs_err = err or "上传失败"
		end
		M.changed(c)
	end)
end

-- How many `workflows.toml.before-sync-<time>` copies are kept (oldest go first).
local MAX_SYNC_BACKUPS = 10

-- Before this machine's configuration is replaced by the executor's, when it may hold something
-- of its own: it never mirrored (no `workflows.toml.mirrored`), it has been the executor since the
-- last mirror, or workflows.toml changed since the mirror wrote it. Then workflows.toml (env values
-- included) is copied to `workflows.toml.before-sync-<time>` and the workflows are exported.
local function backup_before_mirror(c: Core, old: string)
	local oke, ran = pcall(tern.kv.get, "mirror_exec")
	local executed = oke and type(ran) == "string" and ran ~= ""
	if not executed and read_file(`{c.data}/workflows.toml.mirrored`) == old then
		return
	end
	local stamp = os.date("%Y%m%d-%H%M%S", math.floor(now())) :: string
	local path = `{c.data}/workflows.toml.before-sync-{stamp}`
	if old ~= "" then
		pcall(tern.fs.write, path, old)
	end
	local okl, names = pcall(tern.fs.list, c.data)
	if okl and type(names) == "table" then
		local copies: { string } = {}
		for _, n in names do
			if string.match(n, "^workflows%.toml%.before%-sync%-%d+%-%d+$") then
				table.insert(copies, n)
			end
		end
		table.sort(copies)
		for i = 1, #copies - MAX_SYNC_BACKUPS do
			pcall(tern.fs.remove, `{c.data}/{copies[i]}`)
		end
	end
	local w = c.workflows
	if w and #w.list > 0 and #c.workflow_issues == 0 then
		local ids: { string } = {}
		for _, wf in w.list do
			table.insert(ids, wf.id)
		end
		local p, err = M.export_workflows(c, ids)
		if p then
			M.notice(c, "warning", `同步执行者的配置前,已备份本机的工作流:{path},并导出到 {p}`)
		elseif err then
			M.notice(c, "error", `同步前导出本机工作流失败(workflows.toml 已另存为 {path}):{err}`)
		end
	end
end

-- Makes this machine's configuration the executor's (`text`, export format, revision `rev`):
-- libraries and workflow files it carries are written, workflows.toml replaced (repo paths and
-- env values kept, see fleet.mirror_text), files of workflows it no longer has removed, groups
-- replaced. Everything is checked before anything is written.
local function apply_mirror(c: Core, text: string, rev: string): string?
	local b, berr = bundle.decode(text, true)
	if b == nil then
		return `执行者的配置无法读取:{berr}`
	end
	local old, rerr = current_text(c)
	if old == nil then
		return rerr
	end
	local new, missing = fleet.mirror_text(b, old, fleet.label(relay.executor(c.relay)))
	local w, issues = model.parse_workflows(new)
	if w == nil then
		return `执行者的配置在本机无效:{issues_text(issues)}`
	end
	local wftrees, libtrees = trees(b)
	for _, raw in b.workflows do
		local id = tostring(raw.id)
		if not model.valid_lib(id) then
			return `工作流 id "{id}" 无效`
		elseif store.pending(c.store, files.workflow_home(c.data, id)) then
			return `工作流 {id} 的旧文件正在删除,稍后再同步`
		end
		local bad = files.check(wftrees[id] or {})
		if bad then
			return `{id} 的文件:{bad}`
		end
	end
	for name, tree in libtrees do
		if store.pending(c.store, files.lib_root(c.data, name)) then
			return `文件库 "{name}" 正在删除,稍后再同步`
		end
		local bad = files.check(tree)
		if bad then
			return `文件库 "{name}":{bad}`
		end
	end
	backup_before_mirror(c, old)
	for _, name in util.keys(libtrees) do
		local cur = M.library_files(c, name)
		if cur == nil or not exists(files.lib_root(c.data, name)) or not same_tree(cur.text, libtrees[name]) then
			local ferr = files.replace(files.lib_root(c.data, name), libtrees[name])
			if ferr then
				return `写入文件库 "{name}" 失败:{ferr}`
			end
		end
	end
	local mirrored: { [string]: boolean } = {}
	for _, raw in b.workflows do
		local id = tostring(raw.id)
		mirrored[id] = true
		local tree = wftrees[id] or {}
		local cur = M.workflow_files(c, id)
		if cur == nil or not same_tree(cur.text, tree) then
			local ferr = files.replace(files.workflow_root(c.data, id), tree)
			if ferr then
				return `写入 {id} 的文件失败:{ferr}`
			end
		end
	end
	local before = c.workflows
	if new ~= old then
		local werr = write_workflows(c, old, new)
		if werr then
			return werr
		end
	end
	-- What the next mirror compares with to tell whether this machine changed anything since;
	-- written now, so a step failing below doesn't make every retry back up again.
	pcall(tern.fs.write, `{c.data}/workflows.toml.mirrored`, new)
	pcall(tern.kv.set, "mirror_exec", false)
	if before then
		for _, wf in before.list do
			local home = files.workflow_home(c.data, wf.id)
			if not mirrored[wf.id] and model.valid_lib(wf.id) and exists(home) then
				store.discard(c.store, home)
			end
		end
	end
	if c.groups_err == nil then
		local g = groups.empty()
		local all: { [string]: boolean } = {}
		for id in mirrored do
			all[id] = true
		end
		groups.merge(g, b.groups, all)
		-- Folding is this machine's view: kept by group name.
		for _, x in g.list do
			for _, y in c.groups.list do
				if y.name == x.name then
					x.collapsed = y.collapsed
				end
			end
		end
		if groups.encode(g) ~= groups.encode(c.groups) then
			local serr = groups.save(c.paths.groups, g)
			if serr then
				return `无法保存分组:{serr}`
			end
			c.groups = g
		end
	end
	c.dev.mirror_missing = missing
	pcall(tern.kv.set, "mirror", { url = c.relay.cfg.url, revision = rev })
	return nil
end

local function fetch_config(c: Core)
	local d = c.dev
	local f = relay.fleet(c.relay)
	local meta = if f and type(f.config) == "table" then f.config else nil
	if d.mirror_busy or meta == nil or type(meta.revision) ~= "string" then
		return
	end
	local rev = meta.revision :: string
	local okk, applied = pcall(tern.kv.get, "mirror")
	if okk and type(applied) == "table" and applied.url == c.relay.cfg.url and applied.revision == rev then
		return
	end
	local failed = d.mirror_failed
	if failed and failed.rev == rev and now() - failed.at < MIRROR_RETRY then
		return
	end
	d.mirror_busy = true
	relay.get_config(c.relay, nil, function(ok, body, err)
		d.mirror_busy = false
		local cfg = if type(body) == "table" then body.config else nil
		local merr: string?
		if not ok or type(body) ~= "table" or type(body.text) ~= "string" or type(cfg) ~= "table" then
			merr = err or "中继没有返回配置"
		elseif relay.role(c.relay) ~= "observer" then
			-- Took over while this was in flight: this machine's configuration is the truth now.
			M.changed(c)
			return
		else
			local ok2, res = pcall(apply_mirror, c, body.text :: string, tostring(cfg.revision))
			merr = if ok2 then res else `同步执行者的配置时出错:{res}`
		end
		if merr then
			d.mirror_err = merr
			d.mirror_failed = { rev = rev, at = now() }
		else
			d.mirror_err, d.mirror_failed, d.mirror_at = nil, nil, now()
			M.notice(c, "success", "已同步执行者的工作流配置")
		end
		M.changed(c)
	end)
end

local function fetch_runs(c: Core)
	local d = c.dev
	if d.remote_busy then
		return
	end
	d.remote_busy = true
	relay.get_runs(c.relay, d.remote_rev, function(ok, body, err)
		d.remote_busy = false
		if not ok or type(body) ~= "table" then
			if d.remote_err ~= err then
				d.remote_err = err or "响应无效"
				M.changed(c)
			end
			return
		end
		d.remote_err = nil
		local meta = body.runs
		if type(meta) ~= "table" then
			-- Nothing uploaded yet.
			if d.remote_rev ~= nil or #d.remote > 0 then
				d.remote, d.remote_tails, d.remote_rev, d.remote_at, d.remote_from = {}, {}, nil, nil, nil
				M.changed(c)
			end
			return
		end
		if body.unchanged == true then
			return
		end
		-- Still the previous executor's upload (the new one hasn't sent its own yet): show none.
		local ex = relay.executor(c.relay)
		if ex and meta.client ~= ex.id then
			d.remote, d.remote_tails = {}, {}
		else
			d.remote, d.remote_tails = fleet.decode_runs(body.body)
		end
		d.remote_rev = if type(meta.revision) == "string" then meta.revision else nil
		d.remote_at = util.rfc3339(meta.at)
		d.remote_from = if type(meta.client) == "string" then meta.client else nil
		M.changed(c)
	end)
end

local function dev_tick(c: Core)
	local d = c.dev
	local role = relay.role(c.relay)
	if role ~= d.role then
		d.role = role
		-- New role: upload everything afresh, fetch everything afresh.
		d.cfg_text, d.cfg_dirty, d.runs_json, d.exec_noted = nil, true, nil, false
		d.remote_rev, d.mirror_failed = nil, nil
		M.changed(c)
	end
	if role == "executor" and not d.exec_noted then
		-- Edits made here from now on exist nowhere else until uploaded: a later mirror backs up first.
		d.exec_noted = pcall(tern.kv.set, "mirror_exec", c.relay.cfg.url)
	end
	local ex = relay.executor(c.relay)
	local exid = if ex then ex.id else nil
	if d.remote_exec ~= exid then
		-- Another executor: the runs shown were the previous one's.
		d.remote_exec = exid
		d.remote, d.remote_tails, d.remote_rev, d.remote_at, d.remote_from = {}, {}, nil, nil, nil
		M.changed(c)
	end
	if not c.relay.state.connected then
		return
	end
	if role == "executor" then
		upload_config(c)
		upload_runs(c)
	elseif role == "observer" then
		fetch_config(c)
		fetch_runs(c)
	end
end

-- One tick now (errors logged, never fatal), and the loop's next when none is scheduled.
function dev_loop(c: Core)
	local ok, err = pcall(function(): string?
		dev_tick(c)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: device sync failed", err)
	end
	if c.dev.timer == nil then
		c.dev.timer = tern.timer(DEV_MS, function()
			c.dev.timer = nil
			dev_loop(c)
		end)
	end
end

return M
