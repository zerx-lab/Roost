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
# omp = "omp"
# omp_args = ["-p", "--approval-mode", "yolo", "--no-title"]
# max_concurrent = 2
# default_timeout = "30m"
# keep_runs = 200
# extra_path = ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
# env = { RUST_LOG = "info" }
]]

local DEFAULT_WORKFLOWS = [==[
# Roost 工作流。保存后自动生效;GitHub 事件订阅会自动同步到中继。
#
# [repos."owner/name"]          # GitHub 仓库 → 本机检出
# path = "~/code/name"          # 本机路径;事件运行默认在临时 git worktree 中进行
# branch = "main"               # cron / 手动运行时检出的分支
# worktree = true               # false:直接在 path 中运行
# hook = true                   # false:中继不自动管理该仓库的 webhook
#
# [[workflow]]
# id = "triage"                 # a-z 0-9 _ -
# name = "Issue 分诊"
# repos = ["owner/name"]        # 留空 = 所有 [repos]
# concurrency = "queue"         # queue | skip | replace
# workspace = "auto"            # auto | worktree | repo | temp
# timeout = "20m"
#
# [[workflow.trigger]]          # 被动:GitHub 事件(经中继)
# github = "issues"
# actions = ["opened", "labeled"]
# labels = ["roost"]
#
# [[workflow.trigger]]          # 主动:定时(本机时区,或 tz = "UTC")
# cron = "0 9 * * 1-5"
#
# [[workflow.step]]
# omp = "分析 issue #{{number}}:{{title}}\n\n{{body}}"
#
# [[workflow.step]]
# run = "gh issue comment $ROOST_NUMBER --body-file reply.md"

[[workflow]]
id = "hello"
name = "示例:每日问候"
enabled = false
workspace = "temp"

[[workflow.trigger]]
cron = "0 9 * * 1-5"

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
	local s = { running = running, queued = queued, relay = relay_state, failed = failed, next_cron = next_cron }
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
					table.insert(rows, {
						key = `{wf.id}#{i}`,
						workflow = wf.id,
						name = wf.name,
						expr = ct.expr,
						desc = cron.describe(ct.cron),
						utc = ct.utc,
						repo = ct.repo,
						enabled = wf.enabled,
						next = if wf.enabled then cron.next(ct.cron, t, ct.utc) else nil,
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

-- Relayed events: match every enabled workflow serving the repo; a workflow fires once per event.
function M.on_events(c: Core, list: { { [string]: any } })
	local w = c.workflows
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
			local key = util.ifind(w.repos, info.repo)
			for _, wf in w.list do
				if not key then
					break
				end
				if not wf.enabled or not model.serves(wf, key :: string) then
					continue
				end
				local why: string? = nil
				local fired = false
				for _, tr in wf.triggers do
					if tr.kind == "github" then
						local miss = match.mismatch(tr :: any, info)
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
			if not key then
				row.reasons["*"] = "仓库未在 workflows.toml 的 [repos] 中声明"
			end
		end
		table.insert(c.events, 1, row)
		while #c.events > MAX_EVENTS do
			table.remove(c.events)
		end
	end
	M.changed(c)
end

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
				if tr.kind == "cron" then
					local ct = tr :: model.CronTrigger
					local key = `{wf.id}#{i}`
					keep[key] = last[key]
					if wf.enabled and last[key] ~= minute and cron.matches(ct.cron, minute, ct.utc) then
						keep[key] = minute
						fired_any = true
						local repo = ct.repo
						local ref = ct.ref or (if repo and w.repos[repo] then w.repos[repo].branch else nil)
						local run, err = runner.submit(c.runner, wf, {
							trigger = { kind = "cron", detail = ct.expr },
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
			return c.workflows ~= nil
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
		if #wf.repos == 1 then
			repo = wf.repos[1]
		elseif #wf.repos == 0 then
			local names = util.keys(w.repos)
			if #names == 1 then
				repo = names[1]
			end
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

function M.hook_sync(c: Core)
	relay.sync_hooks(c.relay, false, function(ok, msg, body)
		if not ok then
			M.notice(c, "error", msg)
			return
		end
		local manual = 0
		for _, r in (type(body) == "table" and body.repos) or {} do
			if r.status == "manual" or r.status == "error" then
				manual += 1
			end
		end
		if manual > 0 then
			M.notice(c, "error", `{manual} 个仓库需要在 GitHub 上手动配置 webhook(见「中继」页)`)
		else
			M.notice(c, "success", "webhook 已同步")
		end
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
