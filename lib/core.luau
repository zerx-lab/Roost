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

local M = {}

M.VERSION = "0.1.0"

local WATCH_MS = 3000
local MAX_FILE = 1024 * 1024
local MAX_EVENTS = 100
local MAX_NOTICES = 30
-- How long a finished run stays in the published status for the window's notification toast.
local NOTIFY_WINDOW = 600

export type Notice = { at: number, level: string, text: string }
export type EventRow = {
	seq: number,
	at: number,
	event: string,
	repo: string?,
	summary: string,
	url: string?,
	runs: { string },
	reasons: { [string]: string },
}
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
export type AppInfo = {
	configured: boolean,
	name: string?,
	slug: string?,
	owner: string?,
	owner_type: string?,
	html_url: string?,
	install_url: string?,
	installations: number?,
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
# 会话记录保存在该运行的目录里(--session-dir),随 keep_runs 一起清理。没有打开的 Tern 窗口时,
# omp 步骤会一直等到窗口出现或超时;已经打开的 agent 若所有窗口都关了,取消/超时要等窗口回来才会关掉它。
# -p / --session-dir / --resume 等由 Roost 管理,不要写进 omp_args。
# omp = "omp"
# omp_args = ["--approval-mode", "yolo"]
# session = "Roost"
# max_concurrent = 2
# default_timeout = "30m"
# keep_runs = 200
# extra_path = ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
# env = { RUST_LOG = "info" }
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
# [[workflow.step]]             # omp 步骤:提示词可用 {{...}} 模板;不会收到 env / ROOST_* 环境变量
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
	-- Finished runs of workflows with notify on, for the window's toasts (recent ones only).
	local done: { { [string]: any } } = {}
	local w = c.workflows
	-- Newest first (runs append), so a burst of more than ten still announces the latest.
	for i = #c.store.runs, 1, -1 do
		local r = c.store.runs[i]
		local wf = if w then w.by_id[r.workflow] else nil
		if r.finished_at and now() - r.finished_at < NOTIFY_WINDOW and wf and wf.notify and #done < 10 then
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

-- Coalesces change notifications into one render per listener.
function M.changed(c: Core)
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

local function sync_subscriptions(c: Core, force: boolean)
	relay.sync(c.relay, force)
end

-- Re-reads both files; applies them when they changed and are valid.
function M.reload_files(c: Core)
	local ctext = read_file(c.paths.config)
	if ctext ~= c.config_text then
		c.config_text = ctext
		local cfg, issues = model.parse_config(ctext or "")
		c.config_issues = issues
		if cfg then
			c.config = cfg
			c.store.keep = cfg.runner.keep_runs
			relay.configure(c.relay, {
				url = cfg.relay.url,
				token = model.token(cfg.relay),
				client_name = cfg.relay.client_name,
			})
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
			sync_subscriptions(c, false)
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

local function remember(c: Core, delivery: string): boolean
	if c.seen[delivery] then
		return false
	end
	c.seen[delivery] = true
	table.insert(c.seen_order, delivery)
	while #c.seen_order > 500 do
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

-- Relayed events: match every enabled workflow's GitHub triggers; a workflow fires once per event.
-- Repos declared in [repos] run in their checkout; any other repo runs in a temporary directory.
function M.on_events(c: Core, list: { { [string]: any } })
	local w = c.workflows
	local ctx: match.Ctx = { me = M.me(c) }
	for _, e in list do
		local info: { [string]: any } = if type(e.info) == "table" then e.info else {}
		local delivery = tostring(e.delivery or e.seq)
		if not remember(c, delivery) then
			continue
		end
		local row: EventRow = {
			seq = e.seq,
			at = now(),
			event = info.event or e.event or "?",
			repo = info.repo,
			summary = match.summary(info),
			url = info.url,
			runs = {},
			reasons = {},
		}
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
		table.insert(c.events, 1, row)
		while #c.events > MAX_EVENTS do
			table.remove(c.events)
		end
	end
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

function M.new(data: string): Core
	local paths = {
		config = `{data}/roost.toml`,
		workflows = `{data}/workflows.toml`,
		theme = `{data}/theme.css`,
	}
	local st = store.new(data, 200)
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
		notices = {},
		seen = {},
		seen_order = {},
		listeners = {},
		next_listener = 0,
		notify_timer = nil,
		status_json = nil,
		started = false,
		gh_cache = {},
		gh_order = {},
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
	pcall(tern.fs.mkdir, c.data)
	pcall(tern.fs.mkdir, `{c.data}/runs`)
	if not tern.fs.exists(c.paths.config) then
		pcall(tern.fs.write, c.paths.config, DEFAULT_CONFIG)
	end
	if not tern.fs.exists(c.paths.workflows) then
		pcall(tern.fs.write, c.paths.workflows, DEFAULT_WORKFLOWS)
	end
	store.load(c.store)
	watch_loop(c)
	runner.recover(c.runner)
	local wait = 60 - (now() % 60) + 1
	tern.timer(wait * 1000, function()
		cron_tick(c)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Actions for the views. Each returns an error message or nil.

function M.dispatch(c: Core, id: string, inputs: { [string]: string }?, repo: string?, ref: string?): string?
	local w = c.workflows
	local wf = w and w.by_id[id]
	if not w or not wf then
		return `没有工作流 {id}`
	end
	if not wf.manual then
		return `{wf.name} 不允许手动运行(manual = false)`
	end
	local given = inputs or {}
	local final: { [string]: string } = {}
	for _, i in wf.inputs do
		local v = given[i.name] or i.default
		if v == nil and i.required then
			return `缺少必填输入 {i.name}`
		end
		if v then
			final[i.name] = v
		end
	end
	if repo == nil then
		local names = util.keys(w.repos)
		if #names == 1 then
			repo = names[1]
		end
	end
	if repo and not ref then
		local r = w.repos[repo]
		ref = r and r.branch
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

function M.push_subscriptions(c: Core, force: boolean)
	sync_subscriptions(c, force)
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
		installations = a.installations,
	}
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

return M
