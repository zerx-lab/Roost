--!strict
-- The `roost.console` block: overview, runs (with a live log), workflows, relayed events, relay
-- sync and remote operations, and config diagnostics. Views are built from state only; every
-- repeated node carries a stable key so Tern's diff sends small frames, and the log grows by
-- suffix so new output goes out as appends.
--
-- Theming contract (roost.css, the user's theme.css): data-role hooks `roost.header`,
-- `roost.tabs`, `roost.overview`, `roost.runs`, `roost.run`, `roost.log`, `roost.workflows`,
-- `roost.workflow`, `roost.events`, `roost.relay`, `roost.deliveries`, `roost.config`, `roost.form`.

local core = require("./core")
local store = require("./store")
local model = require("./model")
local field = require("./field")
local util = require("./util")
local agent = require("./agent")
local editor = require("./editor")
local stats = require("./stats")
local evolve = require("./evolve")
local upgrade = require("./upgrade")
local files = require("./files")
local groups = require("./groups")

local ui = tern.ui
local N = ui.node

local M = {}

local TABS = {
	{ id = "overview", label = "概览" },
	{ id = "runs", label = "运行" },
	{ id = "workflows", label = "工作流" },
	{ id = "events", label = "事件" },
	{ id = "relay", label = "中继" },
	{ id = "config", label = "配置" },
	{ id = "files", label = "文件" },
}
local TAB_IDS: { [string]: boolean } = {}
for _, t in TABS do
	TAB_IDS[t.id] = true
end

local LOG_CHUNK = 256 * 1024
local LOG_MAX = 512 * 1024
local LOG_POLL_MS = 1000
local MAX_RUN_ROWS = 200
-- A destructive button's second click counts between these many ms after the first: above a
-- slow double click (macOS's default interval is about 500 ms), within a deliberate retry.
local CONFIRM_MIN_MS = 800
local CONFIRM_MAX_MS = 5000

-- `pr`: the pull request to run on (PR workflows), not one of the workflow's inputs.
export type FormField = field.Field & { label: string, hint: string?, required: boolean, pr: boolean? }
-- `busy`: a PR run is reading its pull request.
export type Form = { workflow: string, title: string, fields: { FormField }, focus: number, error: string?, busy: boolean? }
export type Log = {
	id: string?,
	text: string,
	offset: number,
	eof: boolean,
	done: boolean, -- read to the end of a finished run's log
	gen: number,
	busy: boolean,
	timer: any?,
	cut: boolean, -- older output dropped to stay under LOG_MAX
	measured: number, -- bytes of `text` whose complete lines `width` covers
	width: number, -- widest complete line in terminal cells (unwrapped view)
}

-- The files page: the library shown, its open file, and the text fields on the page.
export type FilesPage = {
	lib: string?, -- the file library shown
	sel: string?, -- its file in the editor
	tree: files.Tree?, -- that library's files as last read
	tree_err: string?,
	loaded: string, -- text of `sel` as read: the editor is dirty while it differs
	focus: string?, -- newlib | newfile | ren | edit: the field the keys go to
	fields: { [string]: field.Field },
}
-- The import overlay: the file to read and what importing it would do.
export type Import = { path: field.Field, plan: core.ImportPlan?, error: string? }
-- The group name dialog: a new group (moving workflow `wf` into it when set), or renaming `id`.
export type GroupDialog = { id: string?, wf: string?, name: field.Field, error: string? }

local function text_field(text: string, lines: boolean?): field.Field
	return { text = text, cursor = utf8.len(text) or #text, lines = lines }
end

local function new_fp(): FilesPage
	return {
		lib = nil,
		sel = nil,
		tree = nil,
		tree_err = nil,
		loaded = "",
		focus = nil,
		fields = { newlib = text_field(""), newfile = text_field(""), ren = text_field(""), edit = text_field("", true) },
	}
end

export type State = {
	core: core.Core,
	cx: BlockCx,
	born: number,
	closed: boolean,
	unsubscribe: (() -> ())?,
	tab: string,
	run_id: string?,
	wf_id: string?, -- the workflow shown beside the list on the workflows page
	filter: string, -- all | active | failed
	form: Form?,
	log: Log,
	log_wrap: boolean, -- the run log wraps at the pane's width; off, long lines scroll sideways
	cols: number,
	rows: number,
	editor: any, -- lib/editor.luau's state while the automation editor is open
	tpl: string, -- template gallery group
	app_org: field.Field?, -- organization typed for a new GitHub App
	app_focus: boolean,
	app_busy: boolean,
	confirm: string?, -- the destructive action armed by a first click (delete, clear, forget)
	confirm_at: number?, -- tern.now() of that click
	fp: FilesPage,
	imp: Import?, -- the import overlay while open
	grp: GroupDialog?, -- the group name dialog while open
}

-- ---------------------------------------------------------------------------------------------
-- Small helpers

local STATE_LABEL: { [string]: string } = {
	queued = "排队",
	running = "运行中",
	success = "成功",
	failed = "失败",
	cancelled = "已取消",
	timed_out = "超时",
	interrupted = "已中断",
	skipped = "已跳过",
	pending = "待运行",
}
local STATE_TONE: { [string]: string } = {
	queued = "pending",
	running = "accent",
	success = "success",
	failed = "error",
	cancelled = "warning",
	timed_out = "error",
	interrupted = "warning",
	skipped = "muted",
	pending = "muted",
}
local TRIGGER_LABEL: { [string]: string } = { github = "GitHub", cron = "定时", manual = "手动", rerun = "重跑" }
local TRIGGER_ICON: { [string]: string } = { github = "branch", cron = "clock", manual = "user", rerun = "redo" }
local STEP_ICON: { [string]: string } = {
	auth = "plug",
	omp = "omp",
	run = "terminal",
	file = "file-code",
	prepare = "folder-plus",
	cleanup = "trash",
	evolve = "pen",
	tab = "open",
	upgrade = "repeat",
}
-- Step kinds whose icon alone doesn't say what they are.
local STEP_LABEL: { [string]: string } = { evolve = "迭代材料", tab = "标签页", upgrade = "升级 Roost" }
local REV_LABEL: { [string]: string } = {
	applying = "应用中",
	watching = "观察中",
	kept = "已保留",
	rolled_back = "已回滚",
	superseded = "已被取代",
	failed = "失败",
}
local REV_TONE: { [string]: string } = {
	watching = "accent",
	kept = "success",
	rolled_back = "warning",
	superseded = "muted",
	failed = "error",
}
local SYNC_LABEL: { [string]: string } = {
	idle = "待核对",
	pushing = "推送中",
	ok = "已同步",
	adopted = "沿用云端",
	conflict = "冲突",
	invalid = "被拒绝",
	offline = "推送失败",
	unconfigured = "未配置",
}
local SYNC_TONE: { [string]: string } = {
	idle = "muted",
	pushing = "pending",
	ok = "success",
	adopted = "warning",
	conflict = "warning",
	invalid = "error",
	offline = "error",
	unconfigured = "muted",
}


local function state_badge(state: string): Node
	return ui.badge(STATE_LABEL[state] or state, STATE_TONE[state] or "muted")
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function keyed(node: Node, key: string): Node
	return with(node, { key = key })
end

local function now(): number
	return core.clock()
end

local function last_segment(id: string?): string
	return string.match(id or "", "([^.]+)$") or ""
end

local function btn(text: string, act: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { actions = { click = act }, size = "sm" }
	local extra: { [string]: any } = props or {}
	for k, v in extra do
		p[k] = v
	end
	return ui.button(text, p)
end

-- A destructive button that takes two clicks: the first arms it (st.confirm, new label), the
-- second runs `what` (see `confirmed`); any other action in between disarms it.
local function confirm_btn(st: State, text: string, armed: string, what: string, props: { [string]: any }?): Node
	local p: { [string]: any } = {}
	local extra: { [string]: any } = props or {}
	for k, v in extra do
		p[k] = v
	end
	if st.confirm == what then
		p.variant = "danger"
		p.title = "5 秒内再点一次确认;按键或其他操作会取消"
	end
	return btn(if st.confirm == what then armed else text, `confirm={what}`, p)
end

-- A heterogeneous list (table cells), typed loosely for the checker.
local function list_of(...: any): { any }
	return { ... }
end

-- A kv pair whose value may be spans.
local function pair(k: string, v: any): { any }
	return { k, v }
end

local function muted(t: string): Node
	return ui.text({ ui.span(t, "muted") })
end

local function duration(a: number?, b: number?): string
	if a == nil then
		return "—"
	end
	return util.fmt_duration((b or now()) - a)
end

-- `$0.42`. Estimates stay at cents; the log keeps the finer tally.
local function fmt_usd(n: number): string
	return string.format("$%.2f", n)
end

-- `128k` / `1.5m`; under 1000 the count itself.
local function fmt_tokens(n: number): string
	local function compact(div: number, suffix: string): string
		local s = string.format("%.1f", n / div)
		return (string.gsub(s, "%.0$", "")) .. suffix
	end
	if n >= 1000000 then
		return compact(1000000, "m")
	elseif n >= 1000 then
		return compact(1000, "k")
	end
	return string.format("%d", math.floor(n + 0.5))
end

-- `条件 out.verify` / `条件 !input.dry_run`.
local function when_label(w: model.When): string
	return `条件 {if w.negate then "!" else ""}{w.source}.{w.key}`
end

local function runs_list(st: State): { store.Run }
	local all = store.list(st.core.store, MAX_RUN_ROWS, nil)
	if st.filter == "all" then
		return all
	end
	local out = {}
	for _, r in all do
		local active = r.state == "queued" or r.state == "running"
		local bad = r.state == "failed" or r.state == "timed_out" or r.state == "cancelled" or r.state == "interrupted"
		if (st.filter == "active" and active) or (st.filter == "failed" and bad) then
			table.insert(out, r)
		end
	end
	return out
end

local function selected_run(st: State): store.Run?
	return if st.run_id then st.core.store.by_id[st.run_id] else nil
end

local function run_dir(st: State, id: string): string
	return store.run_dir(st.core.store, id)
end

local function toast_err(st: State, err: string?)
	if err then
		st.cx:toast("error", err)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Log tail

local pull: (State) -> ()

local function stop_log_timer(st: State)
	if st.log.timer then
		st.log.timer:cancel()
		st.log.timer = nil
	end
end

local function reset_log(st: State, id: string?)
	stop_log_timer(st)
	st.log = {
		id = id,
		text = "",
		offset = 0,
		eof = false,
		done = false,
		gen = st.log.gen + 1,
		busy = false,
		timer = nil,
		cut = false,
		measured = 0,
		width = 0,
	}
	if id then
		pull(st)
	end
end

local function append_log(st: State, chunk: string)
	local lg = st.log
	lg.offset += #chunk
	local text = lg.text .. chunk
	if #text > LOG_MAX then
		-- Keep the tail, cut at a line start (one non-append frame).
		local start = #text - LOG_MAX + 1
		local nl = string.find(text, "\n", start, true)
		text = string.sub(text, (nl or start) + (if nl then 1 else 0))
		lg.cut = true
		-- The kept text starts elsewhere: measure it again.
		lg.measured, lg.width = 0, 0
	end
	lg.text = text
end

-- Widest line the log can hold unwrapped, in cells: a terminal this wide (a `min.w`) stays bounded
-- even when a program prints one huge line; longer lines wrap.
local LOG_MAX_CELLS = 1000

-- The log's widest line in terminal cells. Complete lines are measured once as the log grows
-- (`measured`, `width`); only the unfinished last line is measured on every call.
local function log_cells(lg: Log): number
	local text = lg.text
	local i = lg.measured + 1
	-- Bounded by the text: every pass moves `i` past a newline.
	while true do
		local nl = string.find(text, "\n", i, true)
		if nl == nil then
			break
		end
		lg.width = math.max(lg.width, util.cells(string.sub(text, i, nl - 1)))
		i = nl + 1
	end
	lg.measured = i - 1
	return math.min(LOG_MAX_CELLS, math.max(lg.width, util.cells(string.sub(text, i))))
end

function pull(st: State)
	local lg = st.log
	local id = lg.id
	if st.closed or not id or lg.busy or lg.done then
		return
	end
	lg.busy = true
	local gen = lg.gen
	core.read_log(st.core, id, lg.offset, LOG_CHUNK, function(text, eof)
		if st.closed or st.log.gen ~= gen then
			return
		end
		local l = st.log
		l.busy = false
		if text and #text > 0 then
			append_log(st, text)
			st.cx:render()
		end
		l.eof = eof
		local run = st.core.store.by_id[id]
		local finished = run == nil or store.TERMINAL[run.state] == true
		if text == nil then
			-- Read failed: try again later.
			eof = true
		end
		if not eof then
			l.timer = tern.timer(10, function()
				l.timer = nil
				pull(st)
			end)
		elseif finished then
			l.done = true
		else
			stop_log_timer(st)
			l.timer = tern.timer(LOG_POLL_MS, function()
				l.timer = nil
				pull(st)
			end)
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle

function M.new(c: core.Core, cx: BlockCx, _args: { string }, saved: any): State
	local s: { [string]: any } = if type(saved) == "table" then saved else {}
	local st: State = {
		core = c,
		cx = cx,
		born = tern.now(),
		closed = false,
		unsubscribe = nil,
		tab = if type(s.tab) == "string" and TAB_IDS[s.tab] then s.tab else "overview",
		run_id = if type(s.run_id) == "string" then s.run_id else nil,
		wf_id = if type(s.wf_id) == "string" then s.wf_id else nil,
		filter = if s.filter == "active" or s.filter == "failed" then s.filter else "all",
		form = nil,
		log = {
			id = nil,
			text = "",
			offset = 0,
			eof = false,
			done = false,
			gen = 0,
			busy = false,
			timer = nil,
			cut = false,
			measured = 0,
			width = 0,
		},
		log_wrap = s.log_wrap ~= false,
		cols = cx.cols,
		rows = cx.rows,
		editor = nil,
		tpl = "全部",
		app_org = nil,
		app_focus = false,
		app_busy = false,
		confirm = nil,
		confirm_at = nil,
		fp = new_fp(),
		imp = nil,
		grp = nil,
	}
	if st.run_id and c.store.by_id[st.run_id] == nil then
		st.run_id = nil
	end
	if st.run_id then
		reset_log(st, st.run_id)
	end
	return st
end

function M.refresh(st: State)
	if st.closed then
		return
	end
	local lg = st.log
	if st.run_id ~= lg.id then
		reset_log(st, st.run_id)
	elseif lg.id and not lg.done and not lg.busy and lg.timer == nil then
		-- A finished run whose final output hasn't been read yet.
		pull(st)
	end
end

function M.close(st: State)
	if st.closed then
		return
	end
	st.closed = true
	stop_log_timer(st)
	st.log.gen += 1
	if st.unsubscribe then
		st.unsubscribe()
		st.unsubscribe = nil
	end
end

function M.title(st: State): string?
	local running = select(1, require("./runner").active(st.core.runner))
	return if running > 0 then `Roost · {running} 运行中` else "Roost"
end

function M.save(st: State): any
	return { tab = st.tab, run_id = st.run_id, wf_id = st.wf_id, filter = st.filter, log_wrap = st.log_wrap }
end

function M.resize(st: State, cols: number, rows: number)
	st.cols, st.rows = cols, rows
end

local function select_run(st: State, id: string?)
	st.run_id = id
	st.confirm = nil
	if id ~= st.log.id then
		reset_log(st, id)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Views: header

local function header(st: State): Node
	local c = st.core
	local running, queued = 0, 0
	for _, r in c.store.runs do
		if r.state == "running" then
			running += 1
		elseif r.state == "queued" then
			queued += 1
		end
	end
	local rs = c.relay.state
	local relay_badge = if not rs.configured
		then ui.badge("中继未配置", "muted")
		elseif rs.waiting then ui.badge("中继等待配置", "warning")
		elseif rs.connected then ui.badge("中继已连接", "success")
		else ui.badge("中继断开", "error")
	local badges: { Node } = {}
	if running > 0 then
		table.insert(badges, keyed(ui.badge(`{running} 运行中`, "accent"), "running"))
	end
	if queued > 0 then
		table.insert(badges, keyed(ui.badge(`{queued} 排队`, "pending"), "queued"))
	end
	table.insert(badges, keyed(relay_badge, "relay"))
	local issues = #c.config_issues + #c.workflow_issues
	if issues > 0 then
		table.insert(badges, keyed(with(ui.badge(`{issues} 个配置错误`, "error"), { actions = { click = "tab=config" } }), "issues"))
	end
	local meta = `   v{core.VERSION}`
	if c.workflows then
		meta ..= ` · {#c.workflows.list} 个工作流`
	end
	local host = string.match(c.config.relay.url or "", "^%a+://([^/]+)")
	if host then
		meta ..= ` · {host}`
	end
	local tools: { Node } = badges
	table.insert(tools, btn("", "sidebar", { icon = "omp", variant = "quiet", size = "md", title = "会话侧栏:Roost 运行过的 omp 会话", key = "sidebar" }))
	table.insert(tools, btn("", "reload_files", { icon = "repeat", variant = "quiet", size = "md", title = "重新读取配置文件", key = "reload" }))
	return N("row", { key = "head", role = "roost.header", justify = "between", align = "center" }, {
		ui.text({ ui.span("Roost", "title"), ui.span(meta, "muted") }),
		N("row", { key = "end", gap = "sm", align = "center" }, tools),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Overview

-- What a run was about beyond its workflow: the event's summary; manual and scheduled runs
-- have none (their title only repeats the workflow and trigger).
local function run_subject(r: store.Run): string?
	return if r.event then r.title else nil
end

local function run_row(r: store.Run, t: number): any
	local trig = r.trigger.kind
	local subject = run_subject(r)
	local name: { any } = { ui.span(r.workflow_name) }
	if subject then
		table.insert(name, ui.span(`  {subject}`, "muted"))
	end
	return {
		id = r.id,
		cells = list_of(
			{ text = STATE_LABEL[r.state] or r.state, dot = STATE_TONE[r.state] or "muted" },
			r.id,
			{ text = name },
			{ text = TRIGGER_LABEL[trig] or trig, icon = TRIGGER_ICON[trig] or "dot" },
			util.ago(r.created_at, t),
			duration(r.started_at, r.finished_at)
		),
		title = `运行 {r.id}`,
		menu = if r.state == "queued" or r.state == "running"
			then { "cancel", "open-log", "copy-id" }
			else { "rerun", "open-log", "copy-id" },
	}
end

-- The run id is in the list and the detail: people quote it when they report or look into a run,
-- and runs/<id>/ on disk carries the same name.
local RUN_COLS: { Col } = {
	{ id = "state", head = "状态", priority = 8 },
	{ id = "id", head = "ID", mono = true, priority = 4 },
	{ id = "run", head = "运行", grow = 1, truncate = "end", priority = 9 },
	{ id = "trigger", head = "触发", priority = 3 },
	{ id = "at", head = "创建", align = "end", priority = 5 },
	{ id = "took", head = "耗时", align = "end", mono = true, priority = 7 },
}

-- Days the overview's trends cover.
local TREND_DAYS = 14

-- A section's title on the page: the name, then muted facts.
local function heading(key: string, title: string, sub: string?): Node
	return keyed(ui.text({ ui.span(title, "strong"), ui.span(if sub then `   {sub}` else "", "muted") }), key)
end

local function secs(v: number?): string
	return if v then util.fmt_duration(v) else "—"
end

local function trend_charts(st: State, days: { stats.Day }): Node
	local labels, ok, bad, p50, p95 = {}, {}, {}, {}, {}
	local any = false
	for i, d in days do
		labels[i] = d.label
		ok[i] = { value = d.ok, title = `{d.label} · 成功 {d.ok}` }
		bad[i] = { value = d.bad, title = `{d.label} · 失败 {d.bad}` }
		-- A day without finished runs is a gap in the duration lines.
		p50[i] = if d.p50 then { value = d.p50, title = `{d.label} · P50 {secs(d.p50)}` } else { title = `{d.label} · 无运行` }
		p95[i] = if d.p95 then { value = d.p95, title = `{d.label} · P95 {secs(d.p95)}` } else { title = `{d.label} · 无运行` }
		any = any or d.ok + d.bad + d.other > 0
	end
	if not any then
		return N("empty", {
			key = "trends",
			variant = "inline",
			icon = "activity",
			title = `近 {TREND_DAYS} 天没有运行`,
			text = "到「工作流」手动运行一次,或等待定时 / GitHub 事件。",
		})
	end
	local runs_chart = N("col", { key = "runs", gap = "sm", grow = 1, basis = 0 }, {
		heading("h", "运行次数", `近 {TREND_DAYS} 天`),
		N("chart", {
			key = "chart",
			kind = "line",
			labels = labels,
			series = {
				{ label = "成功", token = "success", values = ok },
				{ label = "失败", token = "error", values = bad },
			},
		}),
	})
	local took_chart = N("col", { key = "took", gap = "sm", grow = 1, basis = 0 }, {
		heading("h", "运行耗时", "P50 / P95"),
		N("chart", {
			key = "chart",
			kind = "line",
			unit = "s",
			labels = labels,
			series = {
				{ label = "P50", token = "accent", values = p50 },
				{ label = "P95", token = "warning", values = p95 },
			},
		}),
	})
	if st.cols < 110 then
		return N("col", { key = "trends", gap = "lg" }, { runs_chart, took_chart })
	end
	return N("row", { key = "trends", gap = "lg", align = "stretch" }, { runs_chart, took_chart })
end

-- One row per workflow: how it has been doing (the services table of an APM).
local function health_table(st: State, t: number): Node
	local c = st.core
	local w = c.workflows
	local health = stats.health(c.store.runs, t, TREND_DAYS)
	local latest = store.latest(c.store)
	local rows = {}
	local list: { model.Workflow } = if w then w.list else {}
	for _, wf in list do
		local h = health[wf.id]
		local last = latest[wf.id]
		local spark: { number } = if h then h.daily else table.create(TREND_DAYS, 0)
		local nxt: number? = nil
		for _, row in c.crons do
			if row.workflow == wf.id and row.next and (nxt == nil or row.next < (nxt :: number)) then
				nxt = row.next
			end
		end
		local rate_cell: any = stats.percent(h and h.rate)
		if h and h.bad > 0 then
			rate_cell = { ui.span(rate_cell, if (h.rate or 0) < 0.8 then "error" else "warning") }
		end
		table.insert(rows, {
			id = wf.id,
			title = wf.description,
			cells = list_of(
				{
					text = { ui.span(wf.name), ui.span(if wf.enabled then "" else "  已停用", "muted") },
					dot = if last then STATE_TONE[last.state] or "muted" else "muted",
				},
				if h then tostring(h.runs) else "0",
				rate_cell,
				secs(h and h.p50),
				secs(h and h.p95),
				{ spark = { values = spark, tone = if h and h.bad > 0 then "warning" else "accent", title = `近 {TREND_DAYS} 天每日运行次数` } },
				{ ui.span(if last then util.ago(last.created_at, t) else "—", "muted") },
				{ ui.span(if nxt then util.until_(nxt, t) else "—", "muted") }
			),
		})
	end
	return keyed(
		ui.table({
			{ id = "name", head = "工作流", grow = 1, truncate = "end", priority = 9 },
			{ id = "runs", head = "运行", align = "end", mono = true, priority = 7 },
			{ id = "rate", head = "成功率", align = "end", mono = true, priority = 8 },
			{ id = "p50", head = "P50", align = "end", mono = true, priority = 5 },
			{ id = "p95", head = "P95", align = "end", mono = true, priority = 4 },
			{ id = "trend", head = "趋势", priority = 2 },
			{ id = "last", head = "最近运行", align = "end", priority = 3 },
			{ id = "next", head = "下次", align = "end", priority = 1 },
		}, rows :: any, { selectable = true, selected = st.wf_id, empty = "还没有工作流" }),
		"health"
	)
end

local function changed_line(workflows: { string }, libs: { string }): string
	local parts: { string } = table.clone(workflows)
	for _, lib in libs do
		table.insert(parts, `@{lib}`)
	end
	return if #parts == 0 then "—" else table.concat(parts, "、")
end

-- Revisions an evolver applied, and Roost's own upgrades. Lists, not tables: a card must not wrap a table.
local function evolve_card(st: State, t: number): Node
	local c = st.core
	local rows: { Node } = {}
	local revs = core.revisions(c)
	local shown = math.min(#revs, 20)
	for i = 1, shown do
		local rev: evolve.Revision = revs[i]
		local bits: { Node } = {
			keyed(ui.badge(REV_LABEL[rev.state] or rev.state, REV_TONE[rev.state] or "muted"), "state"),
			keyed(ui.text({
				ui.span(`#{rev.n}`, "mono"),
				ui.span(`  {changed_line(rev.workflows, rev.libs)}`),
				ui.span(`  {rev.reviewer}`, "muted"),
			}), "what"),
			keyed(muted(util.clock(rev.at)), "at"),
		}
		if rev.note and rev.note ~= "" then
			table.insert(bits, keyed(muted(util.clip(rev.note, 80)), "note"))
		end
		if rev.state == "watching" or rev.state == "kept" then
			table.insert(bits, confirm_btn(st, "回滚", "确认回滚", `rollback-rev:{rev.n}`, { key = "rollback", variant = "quiet" }))
		end
		table.insert(rows, N("row", { key = `r{rev.n}`, gap = "sm", align = "center" }, bits))
	end
	if #rows == 0 then
		table.insert(rows, keyed(muted("还没有迭代修订"), "none"))
	end
	local ups: { Node } = {}
	for i, r in core.upgrades(c, 10) do
		table.insert(ups, N("row", { key = `u{i}_{r.run}`, gap = "sm", align = "center" }, {
			keyed(muted(util.clock(r.at)), "at"),
			keyed(ui.text({ ui.span(upgrade.describe(r)) }), "what"),
		}))
	end
	if #ups == 0 then
		table.insert(ups, keyed(muted("还没有自升级记录"), "none"))
	end
	return ui.card("自迭代", {
		N("col", { key = "revs", gap = "xs" }, rows),
		keyed(ui.text({ ui.span("Roost 自升级") }), "up-h"),
		N("col", { key = "ups", gap = "xs" }, ups),
	}, { key = "evolve", icon = "repeat" })
end

local function overview(st: State): Node
	local c = st.core
	local t = now()
	local running, queued, ok, bad, total = 0, 0, 0, 0, 0
	for _, r in c.store.runs do
		if r.state == "running" then
			running += 1
		elseif r.state == "queued" then
			queued += 1
		end
		if r.created_at >= t - 86400 then
			total += 1
			if stats.OK[r.state] then
				ok += 1
			elseif stats.BAD[r.state] then
				bad += 1
			end
		end
	end
	local next_row = c.crons[1]
	local tiles = ui.stats({
		{
			label = "运行中",
			value = tostring(running),
			tone = if running > 0 then "accent" else nil,
			sub = if queued > 0 then `{queued} 个排队` else "没有排队",
		},
		{ label = "24 小时运行", value = tostring(total), sub = `{ok} 成功 · {bad} 失败` },
		{
			label = "24 小时成功率",
			value = stats.percent(if ok + bad > 0 then ok / (ok + bad) else nil),
			tone = if bad > 0 then "warning" else nil,
			sub = "不含取消与跳过",
		},
		{
			label = "下一次定时",
			value = if next_row and next_row.next then util.until_(next_row.next, t) else "—",
			sub = if next_row and next_row.next then next_row.name else "没有定时触发",
		},
	})
	local children: { Node } = {
		keyed(tiles, "stats"),
		trend_charts(st, stats.days(c.store.runs, t, TREND_DAYS)),
		N("col", { key = "health_view", gap = "sm" }, {
			heading("h", "工作流", `近 {TREND_DAYS} 天 · 双击打开`),
			health_table(st, t),
		}),
	}
	local cron_items: { Node } = {}
	for _, row in c.crons do
		if #cron_items >= 5 then
			break
		end
		table.insert(
			cron_items,
			N("item", {
				key = row.key,
				label = row.name,
				detail = { ui.span(row.desc), ui.span(`  {row.expr}{if row.utc then " UTC" else ""}`, "muted mono") },
				value = if row.next then `{util.clock(row.next)} · {util.until_(row.next, t)}` elseif row.enabled then "—" else "已停用",
				icon = "clock",
				tone = if row.enabled then nil else "muted",
			})
		)
	end
	if #cron_items > 0 then
		table.insert(children, N("col", { key = "cron_view", gap = "sm" }, {
			heading("h", "即将触发"),
			N("list", { key = "crons" }, cron_items),
		}))
	end
	local notice_items: { Node } = {}
	for i, n in c.notices do
		if i > 5 then
			break
		end
		table.insert(
			notice_items,
			N("item", {
				key = `n{n.at}_{i}`,
				label = n.text,
				value = util.ago(n.at, t),
				icon = if n.level == "error" then "warn" elseif n.level == "success" then "check" else "info",
				tone = if n.level == "error" then "error" elseif n.level == "success" then "success" else nil,
			})
		)
	end
	if #notice_items > 0 then
		table.insert(children, N("col", { key = "notice_view", gap = "sm" }, {
			heading("h", "通知"),
			N("list", { key = "notices" }, notice_items),
		}))
	end
	table.insert(children, evolve_card(st, t))
	return N("col", { key = "overview", role = "roost.overview", gap = "lg" }, children)
end

-- ---------------------------------------------------------------------------------------------
-- Runs

-- Span-token colors of a step's bar in the waterfall.
local BAR_TOKEN: { [string]: string } = {
	running = "accent",
	success = "success",
	failed = "error",
	timed_out = "error",
	cancelled = "warning",
	skipped = "muted",
}

-- A run's steps as a waterfall (a trace's spans): each bar starts where its step started within
-- the run and is as long as the step took.
local function steps_table(r: store.Run, t: number): Node
	local from = r.started_at or r.created_at
	local span = math.max(1, (r.finished_at or t) - from)
	local rows = {}
	for i, s in r.steps do
		local label = STATE_LABEL[s.state] or s.state
		if s.exit_code and s.exit_code ~= 0 then
			label ..= ` · {s.exit_code}`
		end
		local bar: any = ""
		if s.started_at then
			-- At least a visible sliver, so a step that took no time at the run's end still shows.
			local off = math.clamp((s.started_at - from) / span, 0, 0.99)
			local len = math.clamp(((s.finished_at or t) - s.started_at) / span, 0.01, 1 - off)
			bar = {
				meter = {
					parts = {
						{ value = off, token = "track" },
						{ value = len, token = BAR_TOKEN[s.state] or "muted", label = s.name },
					},
					title = `+{util.fmt_duration(s.started_at - from)} 开始 · 用时 {duration(s.started_at, s.finished_at)}`,
				},
			}
		end
		local state: any = { text = label, dot = STATE_TONE[s.state] or "muted" }
		-- Agent steps only: a shell step never has a tally. Compact, in the existing state cell.
		if (s.kind == "omp" or s.agent == true) and s.tokens ~= nil and s.tokens > 0 then
			state.text = {
				ui.span(label),
				ui.span(`  {fmt_usd(s.cost or 0)} · {fmt_tokens(s.tokens)}`, "muted"),
			}
		end
		-- The kinds without an obvious icon say what they are.
		local kind_label = STEP_LABEL[s.kind]
		local name_cell: any = {
			text = if kind_label then { ui.span(s.name), ui.span(`  {kind_label}`, "muted") } else s.name,
			icon = STEP_ICON[s.kind] or "dot",
		}
		table.insert(rows, {
			id = `s{i}`,
			cells = list_of(
				name_cell,
				state,
				bar,
				duration(s.started_at, s.finished_at)
			),
		})
	end
	return keyed(
		ui.table({
			{ id = "name", head = "步骤", truncate = "end", priority = 9 },
			{ id = "state", head = "状态", priority = 8 },
			{ id = "bar", head = "时间线", grow = 1, priority = 2 },
			{ id = "took", head = "耗时", align = "end", mono = true, priority = 7 },
		}, rows :: any),
		"steps"
	)
end

-- Lines the page head, the page tabs, their gaps and the key legend take: the narrow runs page
-- (one column, no split) bounds its list and log by what is left.
local CHROME_LINES = 9

local function pane_lines(st: State): number
	return math.max(18, st.rows - CHROME_LINES)
end

-- Wide enough for the runs page's list | detail split. The split then fills the block below the
-- tabs (roost.css: `roost.fill`, the split, `roost.runlist`, `roost.run`, `roost.log`), so the run
-- list and the log scroll inside their panes: a height counted in lines can't match the pixels the
-- head and tabs take, and a long log scrolled the whole page.
local function runs_split(st: State): boolean
	return st.cols >= 110
end

-- A detail pane's head: the item's name and muted facts at the left, its state and actions at
-- the right (the split already frames the pane, so no card around it).
local function pane_head(title: { any }, right: { Node }): Node
	return N("row", { key = "head", justify = "between", align = "center", gap = "md" }, {
		ui.text(title),
		N("row", { key = "end", gap = "sm", align = "center" }, right),
	})
end

-- The run's facts as one aligned key/value grid (the design guide's detail facts): why it ended
-- first, then where it came from, who it acts as, what it was given, when and what it cost. Its
-- took is in the head. Returns the node and its row count (the narrow page sizes the log by it).
local function run_facts(r: store.Run, t: number): (Node, number)
	local items: { any } = { pair("ID", { ui.span(r.id, "mono") }) }
	if r.reason then
		local calm = r.state == "success" or r.state == "skipped"
		table.insert(items, pair(if calm then "说明" else "原因", { ui.span(r.reason, if calm then "muted" else "warning") }))
	end
	local trig = r.trigger.kind
	local label = TRIGGER_LABEL[trig] or trig
	if r.event then
		-- An event run's summary is already in the head: its link is what's left to show.
		local trigger: { any } = { ui.span(label) }
		if r.event.url then
			local short = string.gsub(r.event.url, "^https://github%.com/", "")
			table.insert(trigger, ui.span("  "))
			table.insert(trigger, ui.link(short, r.event.url))
		end
		table.insert(items, pair("触发", trigger))
	else
		table.insert(items, pair("触发", { ui.span(label), ui.span(`  {r.trigger.detail}`, "muted") }))
	end
	if r.repo then
		table.insert(items, pair("仓库", { ui.span(r.repo, "mono"), ui.span(`  @ {r.fetch_ref or r.ref or "HEAD"}`, "muted mono") }))
	end
	if r.identity == "app" then
		table.insert(items, pair("身份", { ui.span(if r.app then r.app.login else "GitHub App", "mono"), ui.span("  App 令牌", "muted") }))
	end
	local inputs = {}
	for _, k in util.keys(r.inputs) do
		local v = r.inputs[k]
		table.insert(inputs, if v == "" then `{k}=""` else `{k}={v}`)
	end
	if #inputs > 0 then
		table.insert(items, pair("输入", { ui.span(table.concat(inputs, "  "), "mono") }))
	end
	table.insert(items, pair("创建", { ui.span(util.clock(r.created_at), "mono"), ui.span(`  {util.ago(r.created_at, t)}`, "muted") }))
	local cost, tokens = stats.run_cost(r)
	if tokens ~= nil and tokens > 0 then
		table.insert(items, pair("费用", {
			ui.span(`{fmt_usd(cost or 0)} · {fmt_tokens(tokens)} tokens`, "mono"),
			ui.span("  估算", "muted"),
		}))
	end
	return keyed(ui.kv(items :: any), "facts"), #items
end

local function run_detail(st: State, r: store.Run, fill: boolean): Node
	local t = now()
	local active = r.state == "queued" or r.state == "running"
	local primary = if active
		then btn("取消", `cancel={r.id}`, { variant = "danger", icon = "stop", keys = { "c" }, key = "cancel" })
		else btn("重跑", `rerun={r.id}`, { variant = "primary", icon = "redo", keys = { "r" }, key = "rerun" })
	local tools: { Node } = {}
	for i = #r.steps, 1, -1 do
		local s = r.steps[i]
		if s.agent then
			table.insert(tools, btn("omp 会话", `session={r.id}:{i}`, { icon = "omp", variant = "quiet", key = "session" }))
			break
		end
	end
	table.insert(tools, btn("日志文件", `open-log={r.id}`, { icon = "file", variant = "quiet", key = "log" }))
	table.insert(tools, btn("复制 ID", `copy-id={r.id}`, { icon = "copy", variant = "quiet", key = "copy-id", title = `复制运行 ID {r.id}` }))
	table.insert(tools, btn("自动换行", "log-wrap", {
		icon = "align-left",
		variant = "quiet",
		on = st.log_wrap,
		key = "wrap",
		title = if st.log_wrap then "日志按窗格宽度换行;关闭后长行横向滚动" else "长行横向滚动;打开后按窗格宽度换行",
	}))
	if store.TERMINAL[r.state] then
		table.insert(tools, confirm_btn(st, "删除", "确认删除", `delete-run:{r.id}`, {
			icon = "trash",
			variant = "quiet",
			key = "delete",
			title = "删除这条运行的记录、日志、事件负载、omp 会话与遗留 worktree",
		}))
	end
	if r.cwd and r.workspace ~= "temp" then
		table.insert(tools, btn("工作区", `open-ws={r.id}`, { icon = "folder-open", variant = "quiet", key = "ws" }))
	end
	local facts, fact_rows = run_facts(r, t)
	local lg = st.log
	local log_body: Node
	if lg.id == r.id and (lg.text ~= "" or lg.eof) then
		-- The terminal sits in a col: an `ansi` ignores a `min` of its own, a layout node takes it.
		local frame: { [string]: any } = { key = "term" }
		if not st.log_wrap then
			-- As wide as the widest line (and a little, in case a cell is wider than a `ch`): the
			-- terminal wraps at its col's width, and the log's view scrolls it sideways (roost.css).
			frame.min = { w = `{log_cells(lg) + 2}ch` }
		end
		local p: { [string]: any } = { key = "log", role = "roost.log", stick = "end" }
		if not fill then
			-- The rest of the column under the head, the facts, the steps and the tools. In the split,
			-- roost.css gives the log what the pane leaves instead.
			p.max = { h = `{math.max(8, pane_lines(st) - 9 - fact_rows - math.ceil(#r.steps * 1.3))}lines` }
		end
		log_body = N("scroll", p, {
			N("col", frame, {
				N("ansi", { key = "text", text = if lg.text == "" then "(还没有输出)" else lg.text }),
			}),
		})
	else
		log_body = N("skeleton", { key = "log", shape = "text", lines = 4 })
	end
	local subject = run_subject(r)
	local title: { any } = { ui.span(r.workflow_name, "strong") }
	if subject then
		table.insert(title, ui.span(`   {subject}`, "muted"))
	end
	local took = if r.state == "running" and r.started_at
		then N("elapsed", { key = "took", age = math.max(0, t - r.started_at) * 1000, format = "short" })
		else ui.text({ ui.span(duration(r.started_at, r.finished_at), "muted mono") })
	return N("col", { key = "run", role = "roost.run", gap = "md" }, {
		pane_head(title, { keyed(state_badge(r.state), "state"), keyed(took, "took"), primary }),
		facts,
		steps_table(r, t),
		N("row", { key = "tools", gap = "sm", align = "center" }, tools),
		keyed(ui.rule(if lg.cut then "日志(仅显示最近 512 KiB)" else "日志"), "rule"),
		log_body,
	})
end

local function runs_tab(st: State): Node
	local t = now()
	local rows = {}
	local list = runs_list(st)
	for _, r in list do
		table.insert(rows, run_row(r, t))
	end
	local running, failed = 0, 0
	for _, r in st.core.store.runs do
		if r.state == "running" or r.state == "queued" then
			running += 1
		elseif r.state == "failed" or r.state == "timed_out" then
			failed += 1
		end
	end
	local fill = runs_split(st)
	-- In the split, roost.css makes the list fill its pane (`roost.runlist`); one column bounds it.
	local lp: { [string]: any } = { key = "list" }
	if not fill then
		lp.max = { h = `{pane_lines(st) - 3}lines` }
	end
	local left = N("col", { key = "left", role = "roost.runlist", gap = "sm" }, {
		N("row", { key = "bar", justify = "between", align = "center" }, {
			ui.text({ ui.span(`{#list} 条运行`, "muted") }),
			N("tabs", {
				key = "filter",
				variant = "segmented",
				active = st.filter,
				items = list_of(
					{ id = "all", label = "全部" },
					{ id = "active", label = { ui.span("进行中 "), ui.span(tostring(running), "muted") } },
					{ id = "failed", label = { ui.span("失败 "), ui.span(tostring(failed), "muted") } }
				),
			}),
		}),
		N("scroll", lp, {
			keyed(
				ui.table(RUN_COLS, rows :: any, { selectable = true, selected = st.run_id, empty = "没有符合条件的运行" }),
				"runs"
			),
		}),
	})
	local r = selected_run(st)
	local right = if r
		then run_detail(st, r, fill)
		else N("empty", { key = "run", icon = "activity", title = "选择一条运行", text = "j / k 选择,c 取消,r 重跑" })
	if not fill then
		return N("col", { key = "runs", role = "roost.runs", gap = "lg" }, { left, right })
	end
	return N("split", {
		key = "runs",
		role = "roost.runs",
		sizes = { 0.4, 0.6 },
		min = { "40ch", "60ch" },
		grow = 1,
		variant = "hairline",
	}, { left, right })
end

-- ---------------------------------------------------------------------------------------------
-- Workflows

-- The repositories every trigger shares (nil when they differ), and all of them together.
local function workflow_repos(wf: model.Workflow): ({ string }?, { string })
	local shared: { string }? = nil
	local same = true
	local all: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, tr in wf.triggers do
		local repos = model.trigger_repos(tr)
		if shared == nil then
			shared = repos
		elseif not util.equal(shared, repos) then
			same = false
		end
		for _, repo in repos do
			if not seen[repo] then
				seen[repo] = true
				table.insert(all, repo)
			end
		end
	end
	return if same then shared else nil, all
end

-- The workflow the keys act on: the one picked with j/k or on the overview; none until then, so
-- no card wears the selection ring by default.
local function selected_workflow(st: State, w: model.Workflows): model.Workflow?
	return if st.wf_id then w.by_id[st.wf_id] else nil
end

local function next_fire(c: core.Core, id: string): number?
	local best: number? = nil
	for _, row in c.crons do
		if row.workflow == id and row.next and (best == nil or row.next < best) then
			best = row.next
		end
	end
	return best
end

-- Repositories on one line: up to two names, then how many there are.
local function repos_line(all: { string }): string
	if #all <= 2 then
		return table.concat(all, "、")
	end
	return `{all[1]}、{all[2]} 等 {#all} 个`
end

-- How many recent runs a card's history strip shows.
local HISTORY = 24

-- Lines a card's description shows (and always takes, so the facts under it line up across a
-- row of cards); the whole text is in its hover card.
local DESC_LINES = 3

-- The card's "分组" menu: move it to another group (a radio group), or into a new one.
local function group_menu(g: groups.Groups, wf: string): Node
	local cur = groups.group_of(g, wf)
	local items: { any } = { { header = "移动到分组" } }
	for _, x in g.list do
		table.insert(items, { id = `mv:{wf}:{x.id}`, label = x.name, radio = "group", checked = cur == x.id })
	end
	table.insert(items, { id = `mv:{wf}:`, label = "未分组", radio = "group", checked = cur == nil })
	table.insert(items, "-")
	table.insert(items, { id = `grp-new-for:{wf}`, label = "新建分组并移入…", icon = "folder-plus" })
	return N("menu", {
		key = "group",
		text = "分组",
		icon = "folder",
		trigger = "quiet",
		size = "sm",
		align = "end",
		title = "移动到分组",
		items = items,
	})
end

-- One workflow as a card among its siblings: what fires it, where, its steps, then how it has
-- been doing (the last run, the rate, a strip of recent runs colored by outcome). `path`: the id
-- of the row the card sits in (the head's controls are named by id).
local function workflow_card(
	st: State,
	wf: model.Workflow,
	health: stats.Health?,
	t: number,
	basis: number,
	picked: boolean,
	path: string
): Node
	local c = st.core
	local items: { any } = {}
	local shared, all = workflow_repos(wf)
	for i, tr in wf.triggers do
		table.insert(items, { if i == 1 then "触发" else "", model.describe_trigger(tr, shared ~= nil) })
	end
	if #wf.triggers == 0 then
		table.insert(items, pair("触发", { ui.span("仅手动运行", "muted") }))
	end
	if shared and #all > 0 then
		table.insert(items, pair("仓库", { ui.span(repos_line(all), "mono") }))
	end
	local step_spans: { any } = {}
	for i, s in wf.steps do
		if i > 1 then
			table.insert(step_spans, ui.span("  →  ", "muted"))
		end
		table.insert(step_spans, ui.span(s.name, if s.kind == "omp" then "accent" else nil))
		local kind_label = STEP_LABEL[s.kind]
		if kind_label then
			table.insert(step_spans, ui.span(` {kind_label}`, "muted"))
		end
		if s.when then
			table.insert(step_spans, ui.span(` {when_label(s.when)}`, "muted"))
		end
	end
	table.insert(items, pair("步骤", step_spans))
	local spent = stats.cost_since(c.store.runs, wf.id, stats.day_start(t))
	if wf.daily_budget ~= nil or spent > 0 then
		local text = fmt_usd(spent)
		if wf.daily_budget ~= nil then
			text ..= ` / 预算 {fmt_usd(wf.daily_budget)}`
		end
		table.insert(items, pair("今日费用", { ui.span(text, "mono") }))
	end
	local nxt = next_fire(c, wf.id)
	if nxt then
		table.insert(items, pair("下次", { ui.span(util.clock(nxt), "mono"), ui.span(`  {util.until_(nxt, t)}`, "muted") }))
	end
	local body: { Node } = {
		N("row", { key = "end", gap = "sm", align = "center" }, {
			group_menu(c.groups, wf.id),
			btn("编辑", `edit={wf.id}`, { variant = "quiet", icon = "pen", key = "edit" }),
			btn("导出", `export={wf.id}`, { variant = "quiet", icon = "file-code", key = "export", title = "导出这个工作流(含脚本文件)到 exports 目录" }),
			btn("运行", `dispatch={wf.id}`, {
				icon = "play",
				key = "run",
				disabled = if not wf.manual then "manual = false:只允许自动触发" else false,
			}),
		}),
	}
	local desc: Node
	if wf.description then
		local full = wf.description
		local hover = ui.col({ ui.text(full) })
		hover.p = { gap = "sm", max = { w = "72ch" } }
		desc = N("text", {
			key = "text",
			spans = { ui.span(full, "muted") },
			lines = DESC_LINES,
			title = full,
			hovercard = hover,
		})
	else
		desc = keyed(ui.text({ ui.span("没有描述", "muted") }), "text")
	end
	-- A col takes the reserved height (a text node's own `min` is not a layout bound everywhere).
	table.insert(body, N("col", { key = "desc", min = { h = `{DESC_LINES}lines` } }, { desc }))
	table.insert(body, keyed(ui.kv(items :: any), "info"))
	local runs = store.list(c.store, HISTORY, wf.id)
	local foot: { Node } = {}
	if #runs > 0 then
		local last = runs[1]
		table.insert(foot, keyed(with(ui.text({
			ui.span(`{STATE_LABEL[last.state] or last.state}`, STATE_TONE[last.state] or "muted"),
			ui.span(` · {util.ago(last.created_at, t)}`, "muted"),
		}), { actions = { click = `open-run={last.id}` }, title = "查看最近一次运行" }), "last"))
		local strip = {}
		for i = #runs, 1, -1 do
			local r = runs[i]
			table.insert(strip, {
				value = 1,
				tone = STATE_TONE[r.state] or "muted",
				title = `{STATE_LABEL[r.state] or r.state} · {util.clock(r.created_at)} · {duration(r.started_at, r.finished_at)}`,
			})
		end
		table.insert(foot, N("chart", { key = "history", kind = "spark", min = 0, max = 1, series = strip, grow = 1 }))
		if health then
			table.insert(foot, keyed(ui.text({ ui.span(`{TREND_DAYS} 天 {health.runs} 次 · 成功率 {stats.percent(health.rate)}`, "muted") }), "rate"))
		end
	else
		table.insert(foot, keyed(muted("还没有运行"), "last"))
	end
	-- The tail sits at the card's bottom (roost.css): in a row of cards stretched to the tallest,
	-- the spare room goes above it, not under it.
	table.insert(body, N("col", { key = "tail", role = "roost.wftail", gap = "sm" }, {
		keyed(ui.rule(""), "rule"),
		N("row", { key = "foot", gap = "md", align = "center" }, foot),
	}))
	return ui.card({ ui.span(wf.name, "strong") }, body, {
		key = wf.id,
		role = "roost.workflow",
		icon = wf.icon or if wf.enabled then "flow" else "pause",
		meta = if wf.enabled then nil else "已停用",
		tone = if wf.enabled then nil else "muted",
		selected = picked,
		basis = basis,
		grow = 1,
		["end"] = `{path}.{wf.id}.end`,
	})
end

local function workflows_toolbar(count: string?): Node
	return N("row", { key = "bar", justify = "between", align = "center" }, {
		ui.text({ ui.span(count or "", "muted") }),
		N("row", { key = "end", gap = "sm", align = "center" }, {
			btn("新建自动化", "editor-new", { icon = "plus", size = "md", key = "new" }),
			editor.template_menu(),
			btn("新建分组", "grp-new", { variant = "quiet", icon = "folder-plus", size = "md", key = "group", title = "新建一个工作流分组" }),
			btn("导入", "imp-open", { variant = "quiet", icon = "plus", size = "md", key = "import", title = "从导出文件导入工作流" }),
			btn("导出全部", "export-all", { variant = "quiet", icon = "file-code", size = "md", key = "export", title = "把全部工作流导出到一个文件" }),
			btn("", "open=workflows", { variant = "quiet", icon = "file-code", size = "md", title = "编辑 workflows.toml", key = "file" }),
		}),
	})
end

local function workflows_tab(st: State): Node
	local c = st.core
	local w = c.workflows
	if not w then
		return N("col", { key = "workflows", role = "roost.workflows", gap = "lg" }, {
			workflows_toolbar(nil),
			N("empty", {
				key = "broken",
				tone = "error",
				icon = "warn",
				title = "workflows.toml 还没有可用的版本",
				text = "修好「配置」页列出的错误后自动加载。",
			}),
		})
	end
	if #w.list == 0 then
		return N("col", { key = "workflows", role = "roost.workflows", gap = "lg" }, {
			workflows_toolbar(nil),
			N("empty", { key = "none", icon = "flow", title = "还没有工作流", text = "从下面的模板开始,或新建一个自动化。" }),
			editor.templates(st),
		})
	end
	local t = now()
	local health = stats.health(c.store.runs, t, TREND_DAYS)
	-- Cards per row by width; basis leaves room for the gaps.
	local basis = if st.cols >= 190 then 0.31 elseif st.cols >= 110 then 0.48 else 1
	local sel = selected_workflow(st, w)
	local off = 0
	for _, wf in w.list do
		if not wf.enabled then
			off += 1
		end
	end
	local function card_row(key: string, path: string, list: { model.Workflow }): Node
		local cards: { Node } = {}
		for _, wf in list do
			table.insert(cards, workflow_card(st, wf, health[wf.id], t, basis, sel ~= nil and sel.id == wf.id, path))
		end
		return N("row", { key = key, role = "roost.wfcards", gap = "lg", wrap = true, align = "stretch" }, cards)
	end
	local count = `{#w.list} 个工作流{if off > 0 then ` · {off} 个已停用` else ""}`
	local children: { Node } = { workflows_toolbar(count) }
	local g = c.groups
	if #g.list == 0 then
		-- No groups yet: the page is one grid, as before groups existed.
		table.insert(children, card_row("cards", "main.body.workflows.cards", w.list))
	else
		local secs = groups.sections(g, w.list, function(wf: model.Workflow): string
			return wf.id
		end)
		local nth = 0
		for _, s in secs do
			local x = s.group
			local key = if x then `g_{x.id}` else "ungrouped"
			local head_end: { Node } = {}
			local title: { any }
			local fold: Node? = nil
			local open = true
			if x then
				nth += 1
				open = not x.collapsed
				fold = btn("", `grp-toggle={x.id}`, {
					variant = "quiet",
					icon = if open then "chev" else "chev-r",
					key = "fold",
					title = if open then "收起分组" else "展开分组",
				})
				title = { ui.span(x.name, "strong"), ui.span(`   {#s.items} 个工作流`, "muted") }
				head_end = {
					btn("", `grp-up={x.id}`, {
						variant = "quiet",
						icon = "arrow-up",
						key = "up",
						title = "上移分组",
						disabled = if nth == 1 then "已经在最前" else false,
					}),
					btn("", `grp-down={x.id}`, {
						variant = "quiet",
						icon = "arrow-down",
						key = "down",
						title = "下移分组",
						disabled = if nth == #g.list then "已经在最后" else false,
					}),
					btn("重命名", `grp-ren={x.id}`, { variant = "quiet", icon = "pen", key = "ren" }),
					confirm_btn(st, "删除分组", "确认删除", `grp-del:{x.id}`, {
						variant = "quiet",
						icon = "trash",
						key = "del",
						title = "删除分组:其中的工作流回到「未分组」,工作流本身不受影响",
					}),
				}
			else
				title = { ui.span("未分组", "strong"), ui.span(`   {#s.items} 个工作流`, "muted") }
			end
			local lead: { Node } = {}
			if fold then
				table.insert(lead, fold)
			end
			table.insert(lead, keyed(ui.text(title), "name"))
			local section: { Node } = {
				N("row", { key = "head", role = "roost.wfgroup.head", justify = "between", align = "center", gap = "md" }, {
					N("row", { key = "lead", gap = "sm", align = "center" }, lead),
					N("row", { key = "end", gap = "sm", align = "center" }, head_end),
				}),
			}
			if open then
				if #s.items == 0 then
					table.insert(section, keyed(muted("空分组:在工作流卡片的「分组」菜单里把工作流移进来。"), "none"))
				else
					table.insert(section, card_row("cards", `main.body.workflows.{key}.cards`, s.items))
				end
			end
			table.insert(children, N("col", { key = key, role = "roost.wfgroup", gap = "md" }, section))
		end
	end
	return N("col", { key = "workflows", role = "roost.workflows", gap = "lg" }, children)
end

-- The workflows the page shows, in its order (groups in order, then the ungrouped; folded groups
-- hide theirs): what j/k walk.
local function shown_workflows(st: State, w: model.Workflows): { model.Workflow }
	local g = st.core.groups
	if #g.list == 0 then
		return w.list
	end
	local out: { model.Workflow } = {}
	for _, s in groups.sections(g, w.list, function(wf: model.Workflow): string
		return wf.id
	end) do
		if not (s.group and s.group.collapsed) then
			table.move(s.items, 1, #s.items, #out + 1, out)
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- Files: the file library, state directories, and files left behind by deleted workflows

-- Node ids of the page's text fields (the keys the page routes by hand, like the editor's).
local FP_IDS: { [string]: string } = {
	newlib = "main.body.files.libs.new.name.input",
	newfile = "main.body.files.libfiles.new.name.input",
	ren = "main.body.files.libfiles.ren.name.input",
	edit = "main.body.files.libfiles.edit.input",
}

local function fp_focus(st: State, name: string?)
	st.fp.focus = name
	if name then
		st.cx:frame({ { "focus", FP_IDS[name] } })
	else
		st.cx:frame({ pair("focus", tern.json.null) })
	end
end

local function fp_dirty(st: State): boolean
	local fp = st.fp
	return fp.sel ~= nil and fp.fields.edit.text ~= fp.loaded
end

-- Moving off a file with unsaved edits would drop them: refuse and say why.
local function fp_guard(st: State): boolean
	if fp_dirty(st) then
		st.cx:toast("error", "文件有未保存的修改:先保存或还原")
		return false
	end
	return true
end

-- (Re)reads the shown library; its selected file (else the first) goes into the editor.
local function fp_load(st: State)
	local fp = st.fp
	fp.tree, fp.tree_err = nil, nil
	if fp.lib then
		local tree, err = core.library_files(st.core, fp.lib)
		fp.tree, fp.tree_err = tree, err
	end
	local tree = fp.tree
	if tree == nil then
		fp.sel = nil
	elseif fp.sel == nil or tree.text[fp.sel] == nil then
		fp.sel = tree.paths[1]
	end
	local sel = fp.sel
	local text = if tree and sel then tree.text[sel] else ""
	fp.loaded = text
	fp.fields.edit = text_field(text, true)
	fp.fields.ren = text_field(sel or "")
end

local function fp_newlib(st: State)
	local fp = st.fp
	if not fp_guard(st) then
		return
	end
	local name = util.trim(fp.fields.newlib.text)
	local err = core.create_library(st.core, name)
	if err then
		toast_err(st, err)
		return
	end
	fp.fields.newlib = text_field("")
	fp.lib, fp.sel = name, nil
	fp_load(st)
end

local function fp_newfile(st: State)
	local fp = st.fp
	local lib = fp.lib
	if lib == nil or not fp_guard(st) then
		return
	end
	local path = util.trim(fp.fields.newfile.text)
	if path == "" then
		toast_err(st, "请填写文件路径")
		return
	elseif fp.tree and fp.tree.text[path] ~= nil then
		toast_err(st, `{path} 已存在`)
		return
	end
	local err = core.save_library_file(st.core, lib, path, "", nil)
	if err then
		toast_err(st, err)
		return
	end
	fp.fields.newfile = text_field("")
	fp.sel = path
	fp_load(st)
end

-- Renames the open file; what is in the editor is saved under the new name.
local function fp_rename(st: State)
	local fp = st.fp
	local lib, sel = fp.lib, fp.sel
	local to = util.trim(fp.fields.ren.text)
	if lib == nil or sel == nil or to == "" or to == sel then
		return
	end
	local err = core.save_library_file(st.core, lib, to, fp.fields.edit.text, sel)
	if err then
		toast_err(st, err)
		return
	end
	fp.sel = to
	fp_load(st)
end

local function fp_save(st: State)
	local fp = st.fp
	local lib, sel = fp.lib, fp.sel
	if lib == nil or sel == nil then
		return
	end
	local err = core.save_library_file(st.core, lib, sel, fp.fields.edit.text, nil)
	if err then
		toast_err(st, err)
		return
	end
	fp_load(st)
	st.cx:toast("success", `已保存 {sel}`)
end

local function file_lang(path: string): string
	local ext = string.lower(string.match(path, "%.(%w+)$") or "")
	if ext == "py" then
		return "python"
	elseif ext == "sh" or ext == "bash" then
		return "bash"
	elseif ext == "js" or ext == "mjs" or ext == "cjs" then
		return "javascript"
	elseif ext == "md" then
		return "markdown"
	end
	return "text"
end

local function files_tab(st: State): Node
	local c = st.core
	local fp = st.fp
	local libs = core.libraries(c)
	if fp.lib then
		local there = false
		for _, info in libs do
			there = there or info.name == fp.lib
		end
		if not there then
			fp.lib, fp.sel = nil, nil
			fp_load(st)
		end
	end
	local function input(name: string, placeholder: string): Node
		local f = fp.fields[name]
		return N("input", { key = "input", text = f.text, cursor = field.utf16_cursor(f), placeholder = placeholder, variant = "field" })
	end

	local lib_rows: { Node } = {}
	for _, info in libs do
		local used = if #info.used_by > 0 then `{#info.used_by} 个工作流使用:{table.concat(info.used_by, "、")}` else "未被使用"
		table.insert(lib_rows, N("row", { key = `l_{info.name}`, gap = "sm", align = "center" }, {
			btn(info.name, `fp-lib={info.name}`, { key = "pick", variant = if fp.lib == info.name then "primary" else "quiet" }),
			keyed(muted(used), "used"),
			confirm_btn(st, "删除", "确认删除", `lib-del:{info.name}`, { key = "del", variant = "quiet" }),
		}))
	end
	if #libs == 0 then
		table.insert(lib_rows, keyed(muted("还没有文件库。文件库放多个工作流共用的脚本和提示词,工作流用 libs 或 file = \"@库/路径\" 引用。"), "none"))
	end
	table.insert(lib_rows, N("row", { key = "new", gap = "sm", align = "end" }, {
		N("field", { key = "name", label = "新建文件库", hint = "a-z 0-9 _ -" }, { input("newlib", "例如 tools") }),
		btn("新建", "fp-newlib", { key = "go", icon = "plus" }),
	}))

	local children: { Node } = {
		N("row", { key = "bar", justify = "between", align = "center" }, {
			muted("脚本和提示词由 Roost 保管;运行时使用的是开始时复制的副本。"),
			btn("刷新", "fp-reload", { variant = "quiet", icon = "repeat", key = "reload" }),
		}),
		ui.card("文件库", lib_rows, { key = "libs", icon = "folder-open" }),
	}

	if fp.lib then
		local rows: { Node } = {}
		local tree = fp.tree
		if fp.tree_err then
			table.insert(rows, keyed(ui.text({ ui.span(fp.tree_err, "error") }), "err"))
		end
		if tree then
			for i, path in tree.paths do
				table.insert(rows, N("row", { key = `f{i}`, gap = "sm", align = "center" }, {
					btn(path, `fp-file={path}`, { key = "pick", variant = if fp.sel == path then "primary" else "quiet" }),
					keyed(muted(util.fmt_bytes(#tree.text[path])), "size"),
					confirm_btn(st, "删除", "确认删除", `file-del:{path}`, { key = "del", variant = "quiet" }),
				}))
			end
			if #tree.paths == 0 then
				table.insert(rows, keyed(muted("这个文件库还没有文件。"), "none"))
			end
		end
		table.insert(rows, N("row", { key = "new", gap = "sm", align = "end" }, {
			N("field", { key = "name", label = "添加文件", hint = "相对路径,如 scan.py 或 prompts/triage.md" }, { input("newfile", "script.py") }),
			btn("添加", "fp-newfile", { key = "go", icon = "plus" }),
		}))
		local sel = fp.sel
		if sel then
			local dirty = fp_dirty(st)
			table.insert(rows, N("row", { key = "ren", gap = "sm", align = "end" }, {
				N("field", { key = "name", label = "重命名" }, { input("ren", sel) }),
				btn("重命名", "fp-ren", { key = "go" }),
			}))
			table.insert(rows, N("field", { key = "edit", label = sel }, {
				N("editor", {
					key = "input",
					text = fp.fields.edit.text,
					cursor = field.utf16_cursor(fp.fields.edit),
					lang = file_lang(sel),
					maxLines = 24,
					placeholder = "文件内容",
				}),
			}))
			table.insert(rows, N("row", { key = "save", gap = "sm", align = "center" }, {
				keyed(muted(if dirty then "有未保存的修改" else "已保存"), "state"),
				btn("还原", "fp-revert", { key = "revert", variant = "quiet", disabled = if dirty then false else "没有修改" }),
				btn("保存", "fp-save", { key = "save", variant = "primary", disabled = if dirty then false else "没有修改" }),
			}))
		end
		table.insert(children, ui.card(`文件库 {fp.lib}`, rows, { key = "libfiles", icon = "file-code" }))
	end

	local state_rows: { Node } = {}
	for _, info in core.states(c) do
		local used = if #info.used_by > 0 then `工作流 {table.concat(info.used_by, "、")}` else "没有工作流使用"
		table.insert(state_rows, N("row", { key = `s_{info.name}`, gap = "sm", align = "center" }, {
			keyed(ui.text({ ui.span(info.name, "mono") }), "name"),
			keyed(muted(used), "used"),
			confirm_btn(st, "删除", "确认删除", `state-del:{info.name}`, { key = "del", variant = "quiet" }),
		}))
	end
	if #state_rows == 0 then
		table.insert(state_rows, keyed(muted("还没有状态目录。"), "none"))
	end
	table.insert(children, ui.card("状态目录", {
		keyed(muted("跨运行保留的数据($ROOST_STATE)。不会自动删除:删除后使用它的工作流从头开始。"), "note"),
		N("col", { key = "list", gap = "xs" }, state_rows),
	}, { key = "states", icon = "folder-open" }))

	local orphans = core.orphan_workflow_files(c)
	if #orphans > 0 then
		local rows: { Node } = {}
		for _, id in orphans do
			table.insert(rows, N("row", { key = `o_{id}`, gap = "sm", align = "center" }, {
				keyed(ui.text({ ui.span(id, "mono") }), "name"),
				confirm_btn(st, "删除", "确认删除", `orphan-del:{id}`, { key = "del", variant = "quiet" }),
			}))
		end
		table.insert(children, ui.card("遗留的工作流文件", {
			keyed(muted("这些目录对应的工作流已不在 workflows.toml 里(例如手工删掉的)。"), "note"),
			N("col", { key = "list", gap = "xs" }, rows),
		}, { key = "orphans", icon = "trash" }))
	end
	return N("col", { key = "files", role = "roost.files", gap = "lg" }, children)
end

-- ---------------------------------------------------------------------------------------------
-- Events

-- How long a retention age is, for people ("30 天"; 0: no limit).
local function fmt_age(sec: number): string
	if sec <= 0 then
		return "不限时长"
	end
	if sec % 86400 == 0 then
		return `{sec // 86400} 天`
	end
	return util.fmt_duration(sec)
end

local RUN_STATES = { "running", "queued", "success", "failed", "timed_out", "cancelled", "interrupted", "skipped" }

-- The result cell of an event: the runs it started (with how they went), else why not.
local function event_result(c: core.Core, e: core.EventRow): any
	if #e.runs == 0 then
		local why = {}
		for wf, reason in e.reasons do
			table.insert(why, if wf == "*" then reason else `{wf}:{reason}`)
		end
		table.sort(why)
		return { text = if #why > 0 then why[1] else "无匹配的工作流", dot = "muted", title = table.concat(why, "\n") }
	end
	if #e.runs == 1 then
		local r = c.store.by_id[e.runs[1]]
		if r == nil then
			return { text = "已触发运行(记录已清理)", dot = "muted" }
		end
		return {
			text = `{r.workflow_name} · {STATE_LABEL[r.state] or r.state}`,
			dot = STATE_TONE[r.state] or "muted",
			title = "选中这一行打开运行",
		}
	end
	local counts: { [string]: number } = {}
	local gone = 0
	for _, id in e.runs do
		local r = c.store.by_id[id]
		if r then
			counts[r.state] = (counts[r.state] or 0) + 1
		else
			gone += 1
		end
	end
	local parts = {}
	for _, s in RUN_STATES do
		if counts[s] then
			table.insert(parts, `{counts[s]} {STATE_LABEL[s]}`)
		end
	end
	if gone > 0 then
		table.insert(parts, `{gone} 已清理`)
	end
	local bad = (counts.failed or 0) + (counts.timed_out or 0) > 0
	local live = (counts.running or 0) + (counts.queued or 0) > 0
	return {
		text = `{#e.runs} 个运行 · {table.concat(parts, " ")}`,
		dot = if bad then "error" elseif live then "accent" else "success",
		title = "选中这一行打开第一个运行",
	}
end

local function events_tab(st: State): Node
	local c = st.core
	local t = now()
	local rows = {}
	for _, e in c.events do
		table.insert(rows, {
			id = `d:{e.delivery}`,
			cells = { util.ago(e.at, t), e.summary, e.repo or "—", event_result(c, e) },
			title = e.url,
		})
	end
	local rs = c.relay.state
	local k = c.config.retention
	local note = if not rs.configured
		then "中继未配置:只有本机的定时与手动运行。"
		elseif rs.waiting then "workflows.toml 无效,暂停领取中继事件。"
		else `中继游标 {rs.head or "—"} · 最近事件 {util.ago(rs.last_event, t)}`
	return N("col", { key = "events", role = "roost.events", gap = "sm" }, {
		N("row", { key = "bar", justify = "between", align = "center", gap = "sm" }, {
			keyed(muted(`{note} · 保留 {k.events} 条 / {fmt_age(k.event_age)}`), "note"),
			N("row", { key = "end", gap = "sm", align = "center" }, {
				confirm_btn(st, "清空记录", "确认清空", "clear-events", {
					key = "clear",
					variant = "quiet",
					icon = "trash",
					disabled = if #c.events == 0 then "没有记录" else false,
				}),
			}),
		}),
		keyed(
			ui.table({
				{ id = "at", head = "时间" },
				{ id = "event", head = "事件", grow = 1, truncate = "end" },
				{ id = "repo", head = "仓库", mono = true, priority = 1 },
				{ id = "result", head = "结果", grow = 1, truncate = "end" },
			}, rows :: any, {
				selectable = true,
				empty = if rs.configured
					then "还没有收到中继事件。只有已订阅的事件才会转发到本机,见「中继」页的 Webhook 投递"
					else "还没有收到中继事件",
			}),
			"table"
		),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Relay

local function manual_subs_text(st: State): string?
	local w = st.core.workflows
	if not w then
		return nil
	end
	local ok, text = pcall(function(): string
		return model.subscriptions_toml(model.subscriptions(w))
	end)
	return if ok then text :: string else nil
end

local OUTCOMES = { "relayed", "ignored", "duplicate", "ping", "rejected" }
local OUTCOME_LABEL: { [string]: string } =
	{ relayed = "已转发", ignored = "已忽略", duplicate = "重复", ping = "ping", rejected = "已拒绝" }
local OUTCOME_TONE: { [string]: string } =
	{ relayed = "success", ignored = "muted", duplicate = "muted", ping = "muted", rejected = "error" }
-- Most rows of the delivery summary shown.
local MAX_DELIVERY_ROWS = 40

-- The agent's reasons are English; the common ones read better translated.
local function delivery_reason(reason: any): string
	if type(reason) ~= "string" or reason == "" then
		return ""
	end
	if string.find(reason, "not subscribed", 1, true) then
		return "没有工作流订阅这个事件"
	elseif reason == "not about a repository" then
		return "与仓库无关"
	elseif reason == "synthetic test event" then
		return "测试事件"
	end
	return reason
end

-- What GitHub sent the relay and what became of it: counts by outcome, then by event and repo.
-- Ignored deliveries never reach this machine, so this is the only place they show.
local function deliveries_view(st: State, t: number): Node
	local d = core.deliveries(st.core)
	local body = d.body
	local busy = st.core.relay.state.busy
	local meta: string
	if body then
		local by: { [string]: any } = if type(body.by_outcome) == "table" then body.by_outcome else {}
		local parts = {}
		for _, o in OUTCOMES do
			if type(by[o]) == "number" and by[o] > 0 then
				table.insert(parts, `{OUTCOME_LABEL[o]} {by[o]}`)
			end
		end
		local since = util.rfc3339(body.since)
		meta = `{if since then util.ago(since, t) .. "起" else "自中继启动起"} 共 {body.total or 0} 次`
		if #parts > 0 then
			meta ..= " · " .. table.concat(parts, " · ")
		end
	elseif d.error then
		meta = `读取失败:{d.error}`
	else
		meta = "读取中…"
	end
	local rows = {}
	local summary: { any } = if body and type(body.summary) == "table" then body.summary else {}
	for i, s in summary do
		if i > MAX_DELIVERY_ROWS then
			break
		end
		if type(s) == "table" then
			local outcome = tostring(s.outcome or "?")
			local event = tostring(s.event or "")
			table.insert(rows, {
				id = `s{i}`,
				cells = list_of(
					{ text = OUTCOME_LABEL[outcome] or outcome, dot = OUTCOME_TONE[outcome] or "muted" },
					if event == "" then "(无)" else event,
					if type(s.repo) == "string" then s.repo else "—",
					tostring(s.count or 0),
					util.ago(util.rfc3339(s.last_at), t),
					delivery_reason(s.reason)
				),
				title = if type(s.reason) == "string" then s.reason else nil,
			})
		end
	end
	local ignored = body and type(body.by_outcome) == "table" and (tonumber(body.by_outcome.ignored) or 0) or 0
	local out: { Node } = {
		keyed(ui.rule("Webhook 投递"), "rule"),
		N("row", { key = "bar", justify = "between", align = "center", gap = "sm" }, {
			keyed(muted(meta), "meta"),
			N("row", { key = "end", gap = "sm", align = "center" }, {
				btn("刷新", "refresh-deliveries", { key = "refresh", variant = "quiet", icon = "repeat", busy = d.loading }),
				confirm_btn(st, "清空统计", "确认清空统计", "clear-deliveries", {
					key = "clear",
					variant = "quiet",
					icon = "trash",
					busy = busy.clear_deliveries == true,
					title = "清空中继内存中的投递计数与最近记录(中继重启也会清空)",
				}),
			}),
		}),
	}
	if ignored > 0 then
		table.insert(
			out,
			keyed(muted("「已忽略」的事件没有任何工作流订阅,不会转发到本机;给工作流加上对应的 GitHub 触发器后会自动订阅。"), "hint")
		)
	end
	table.insert(
		out,
		keyed(
			ui.table({
				{ id = "outcome", head = "结果" },
				{ id = "event", head = "事件", mono = true },
				{ id = "repo", head = "仓库", mono = true, grow = 1, truncate = "end", priority = 1 },
				{ id = "count", head = "次数", align = "end" },
				{ id = "last", head = "最近" },
				{ id = "reason", head = "说明", grow = 1, truncate = "end", priority = 2 },
			}, rows :: any, {
				empty = if body and type(body.summary) ~= "table"
					then "中继版本较旧,不提供投递统计"
					else "还没有收到 webhook",
			}),
			"table"
		)
	)
	if #summary > MAX_DELIVERY_ROWS then
		table.insert(out, keyed(ui.overflow(#summary - MAX_DELIVERY_ROWS), "more"))
	end
	return N("col", { key = "deliveries", role = "roost.deliveries", gap = "sm" }, out)
end

local function relay_tab(st: State): Node
	local c = st.core
	local rs = c.relay.state
	local t = now()
	if not rs.configured then
		return N("empty", {
			key = "relay",
			title = "中继未配置",
			text = "在 roost.toml 的 [relay] 填写 url 与 token 后,GitHub 事件会经服务器上的 roost-agent 送到本机。定时与手动运行不需要中继。",
		}, { btn("编辑 roost.toml", "open=config", { variant = "primary", size = "md" }) })
	end
	local agent: { [string]: any } = rs.agent or {}
	local busy = rs.busy

	-- Connection
	local conn: any = {
		pair("地址", { ui.span(c.config.relay.url or "—", "mono") }),
		pair("状态", if rs.connected then { ui.span("已连接", "success") } else { ui.span(rs.error or "未连接", "error") }),
	}
	if agent.version then
		local started = util.rfc3339(agent.started_at)
		table.insert(conn, { "中继", `roost-agent {agent.version} · 启动于 {util.ago(started, t)} · boot {agent.boot_id or "—"}` })
	end

	if type(agent.store) == "table" then
		table.insert(conn, { "事件缓存", `{agent.store.count or 0} 条 · 头 {agent.store.head or 0} · 本机游标 {rs.head or "—"}` })
	end
	if type(agent.clients) == "table" and #agent.clients > 0 then
		local names = {}
		for _, cl in agent.clients do
			table.insert(names, `{cl.name or cl.id} ({util.ago(util.rfc3339(cl.last_seen), t)})`)
		end
		table.insert(conn, { "客户端", table.concat(names, " · ") })
	end
	local conn_body: { Node } = { keyed(ui.kv(conn :: any), "kv") }
	if rs.gap_at then
		table.insert(conn_body, keyed(ui.text({ ui.span(`{util.ago(rs.gap_at, t)}:有事件在本机读取前已被中继淘汰`, "warning") }), "gap"))
	end
	if rs.reset_at then
		table.insert(conn_body, keyed(ui.text({ ui.span(`{util.ago(rs.reset_at, t)}:中继的事件存储已重建,游标已重置`, "warning") }), "reset"))
	end
	table.insert(
		conn_body,
		N("row", { key = "ops", gap = "sm", align = "center" }, {
			btn("重新加载订阅", "reload_remote", { icon = "repeat", busy = busy.reload == true, key = "reload", title = "让中继重新读取服务器上的 subscriptions.toml" }),
			btn(if rs.restarting then "重启中…" else "重启中继", "restart_remote", {
				icon = "power",
				variant = "danger",
				busy = busy.restart == true or rs.restarting ~= nil,
				key = "restart",
				title = "agent.toml 或二进制更新后,原地重启服务器上的 roost-agent",
			}),
			btn("发送测试事件", "test", { icon = "send", busy = busy.test == true, key = "test" }),
			confirm_btn(st, "清空中继事件缓存", "确认清空中继缓存", "clear-relay-events", {
				key = "clear",
				variant = "quiet",
				icon = "trash",
				busy = busy.clear_events == true,
				title = "删除服务器上为客户端缓存的事件(自动按 agent.toml [store] 的数量/时长/字节上限淘汰);本机还没读到的事件会丢失",
			}),
			keyed(muted(if rs.last_test then `测试事件 {util.ago(rs.last_test, t)} 送达` else ""), "last_test"),
		})
	)
	local conn_card = ui.card("连接", conn_body, { key = "conn", icon = "server", tone = if rs.connected then nil else "error" })

	-- Subscriptions
	local sync = rs.sync
	local sub_body: { Node } = {
		N("row", { key = "state", gap = "sm", align = "center" }, {
			keyed(ui.badge(SYNC_LABEL[sync.state] or sync.state, SYNC_TONE[sync.state] or "muted"), "badge"),
			keyed(muted(`{if sync.revision then "版本 " .. sync.revision else ""}{if sync.at then " · " .. util.ago(sync.at, t) else ""}`), "meta"),
		}),
	}
	if sync.state == "idle" and not sync.error then
		table.insert(sub_body, keyed(muted(if rs.connected then "等待中继状态以核对订阅…" else "连上中继后核对订阅"), "hint"))
	elseif sync.state == "adopted" then
		table.insert(sub_body, keyed(muted("中继使用服务器上的订阅,与本地工作流不同;修改工作流或点「推送订阅」会改为本地版本"), "hint"))
	end
	if sync.error then
		table.insert(sub_body, keyed(ui.text({ ui.span(sync.error, "warning") }), "error"))
	end
	local sub_actions: { Node } = {
		btn("推送订阅", "push", { icon = "push", busy = busy.push == true, key = "push", title = "把本地工作流算出的订阅推送到中继" }),
	}
	if sync.state == "conflict" then
		table.insert(sub_actions, btn("以本地覆盖", "force_push", { variant = "danger", key = "force" }))
		table.insert(sub_actions, btn("采用云端", "adopt", { key = "adopt", title = "保留服务器上的订阅,直到本地再次修改" }))
	end
	table.insert(sub_body, N("row", { key = "actions", gap = "sm" }, sub_actions))
	if sync.state == "conflict" and sync.remote_text then
		table.insert(sub_body, keyed(ui.section("服务器上的版本", { ui.code(sync.remote_text, "toml") }), "remote"))
	end
	if sync.state == "offline" or sync.state == "invalid" or sync.state == "conflict" then
		local text = manual_subs_text(st)
		if text then
			local path = if type(agent.subscriptions) == "table" and type(agent.subscriptions.path) == "string"
				then agent.subscriptions.path
				else "subscriptions.toml"
			table.insert(
				sub_body,
				keyed(
					ui.section("手动设置(回退)", {
						ui.text({ ui.span(`把以下内容保存为服务器上的 {path},然后点「重新加载订阅」。`, "muted") }),
						ui.code(text, "toml"),
						btn("复制", "copy=subs", { icon = "copy", key = "copy" }),
					}),
					"manual"
				)
			)
		end
	end
	local sub_card = ui.card("事件订阅", sub_body, { key = "subs", icon = "broadcast" })

	-- GitHub App
	local info = core.app(c)
	local app_body: { Node } = {}
	if info == nil then
		table.insert(app_body, keyed(muted("中继未连接:连接后可在这里创建 GitHub App"), "state"))
	elseif not info.configured then
		table.insert(
			app_body,
			keyed(
				muted("roost-agent 以 GitHub App 接收所装仓库的事件,运行也以它的身份评论、审查与推送(默认分支禁止强推);不需要个人令牌,也不用逐个仓库配置 webhook。"),
				"explain"
			)
		)
		local org = st.app_org or { text = "", cursor = 0 }
		st.app_org = org
		table.insert(
			app_body,
			N("field", { key = "org", label = "组织", hint = "留空则建在你的个人账号下" }, {
				N("input", {
					key = "input",
					text = org.text,
					cursor = field.utf16_cursor(org),
					placeholder = "my-org",
					variant = "field",
				}),
			})
		)
		table.insert(app_body, N("row", { key = "actions", gap = "sm" }, {
			btn("创建 GitHub App", "app-create", { key = "create", variant = "primary", icon = "plug", busy = st.app_busy }),
		}))
	else
		table.insert(app_body, ui.kv({
			pair("名称", { ui.span(info.name or "—", "strong"), ui.span(`  {info.slug or ""}`, "mono muted") }),
			pair("所有者", { ui.span(info.owner or "—", "mono"), ui.span(`  {info.owner_type or ""}`, "muted") }),
			pair("运行身份", {
				ui.span(info.bot or "—", "mono"),
				ui.span(if c.config.github.identity == "app" then "  默认" else "  roost.toml 设为本机身份", "muted"),
			}),
			pair("已安装", if info.installations then `{info.installations} 个账号或组织` else "—"),
		} :: any))
		local missing = info.missing
		if missing and #missing > 0 then
			table.insert(
				app_body,
				keyed(
					ui.text({
						ui.span("权限尚未生效:", "warning"),
						ui.span(table.concat(missing, " "), "mono"),
						ui.span("。在 App 设置的 Permissions 里开启后,到安装页接受新权限。", "muted"),
					}),
					"missing"
				)
			)
		end
		table.insert(app_body, keyed(muted("头像只能在 GitHub 的 App 设置页上传(GitHub 没有对应的 API);Roost 自带的头像在插件目录 assets/app-logo.png。"), "logo"))
		table.insert(app_body, N("row", { key = "actions", gap = "sm" }, {
			btn("安装到仓库", "app-install", { key = "install", icon = "plus" }),
			btn("在 GitHub 上管理", "app-manage", { key = "manage", icon = "open" }),
			btn("权限设置", "app-permissions", { key = "permissions", icon = "open" }),
			btn("设置头像", "app-logo", { key = "logo", icon = "open" }),
			confirm_btn(st, "忘记本地凭据", "确认删除本地凭据", "forget-app", {
				variant = "danger",
				key = "forget",
				icon = "trash",
				title = "只删除中继上的 App 凭据;App 本身要到 GitHub 设置里删除,删除后只能重新创建",
			}),
		}))
	end
	local app_card = ui.card("GitHub App", app_body, { key = "app", icon = "plug" })

	return N("col", { key = "relay", role = "roost.relay", gap = "md" }, {
		conn_card,
		sub_card,
		app_card,
		deliveries_view(st, t),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Config

local THEME_STARTER = [[
/* Roost 自定义样式:保存后实时生效。钩子见插件 roost.css 顶部注释。 */
[data-surface='plugin.roost.console'] [data-role='roost.log'] {
	/* 例:日志区更高 */
}
]]

local function issues_nodes(list: { model.Issue }, path: string): { Node }
	local out: { Node } = {}
	for i, it in list do
		table.insert(
			out,
			keyed(tern.ui.diagnostic({ severity = "error", message = `{it.path}: {it.message}`, path = path, line = it.line }), `i{i}`)
		)
		if i >= 30 then
			table.insert(out, keyed(ui.overflow(#list - i), "more"))
			break
		end
	end
	return out
end

-- What Roost keeps on disk, the retention policy, the last cleanup, and manual cleanup.
local function storage_card(st: State): Node
	local c = st.core
	local k = c.config.retention
	local t = now()
	local d = core.disk(c)
	local finished = #store.finished(c.store)
	local function size(names: { string }): string
		if d.at == nil then
			return if d.loading then "统计中…" else "—"
		end
		local n = 0
		for _, name in names do
			n += d.sizes[name] or 0
		end
		return util.fmt_bytes(n)
	end
	local exports_n = #core.exports(c)
	local cl = c.cleanup
	local last = if cl
		then `{util.ago(cl.at, t)}{if cl.manual then "(手动)" else ""}:{cl.runs} 个运行、{cl.events} 条事件记录、{cl.exports} 个旧导出文件、{cl.orphans} 个遗留目录`
		else "尚未执行"
	local items: { any } = {
		{ "运行", `{#c.store.runs} 条,{finished} 条已结束 · 保留 {k.runs} 条 / {fmt_age(k.run_age)} · {size({ "runs", "runs.json", "runs.json.bak" })}` },
		{ "worktree", size({ "worktrees" }) },
		{ "事件记录", `{#c.events} 条 · 保留 {k.events} 条 / {fmt_age(k.event_age)} · {size({ "events.json", "events.json.bak" })}` },
		{ "脚本与文件", `文件库 {size({ "library" })} · 工作流文件 {size({ "workflows" })}` },
		{ "状态目录", `{size({ "state" })} · 不会自动清理,在「文件」页手动删除` },
		{ "导出文件", `{exports_n} 个 · 保留最新 {core.MAX_EXPORTS} 个 · {size({ "exports" })}` },
		{ "上次自动清理", last },
	}
	if #c.store.trash > 0 then
		table.insert(items, { "删除中", `{#c.store.trash} 个目录` })
	end
	if not c.store.indexed then
		table.insert(items, pair("无主目录", {
			ui.span("runs.json 曾无法读取(副本 runs.json.unreadable):暂不自动删除无主目录;处理完后删除该副本即可恢复", "warning"),
		}))
	end
	if d.error then
		table.insert(items, pair("占用统计", { ui.span(d.error, "warning") }))
	end
	return ui.card("存储与清理", {
		keyed(
			muted(
				"运行目录含日志、事件负载与 omp 会话。启动时、每小时以及修改 roost.toml [retention] 后按策略自动清理;只删除已结束的运行。中继侧的事件缓存与投递统计在「中继」页清理。"
			),
			"note"
		),
		keyed(ui.kv(items :: any), "kv"),
		N("row", { key = "actions", gap = "sm", align = "center", wrap = true }, {
			btn("按策略清理", "housekeep", { icon = "trash", key = "housekeep", title = "立即删除超出保留数量或时长的运行与事件记录,以及无主的遗留目录" }),
			confirm_btn(st, "删除全部已结束运行", `确认删除 {finished} 个运行`, "clear-runs", {
				key = "clear-runs",
				icon = "trash",
				disabled = if finished == 0 then "没有已结束的运行" else false,
			}),
			confirm_btn(st, "清空事件记录", "确认清空", "clear-events", {
				key = "clear-events",
				icon = "trash",
				disabled = if #c.events == 0 then "没有记录" else false,
			}),
			confirm_btn(st, "清空导出文件", "确认清空", "clear-exports", {
				key = "clear-exports",
				icon = "trash",
				disabled = if exports_n == 0 then "没有导出文件" else false,
			}),
			btn("调整保留策略", "open=config", { icon = "pen", variant = "quiet", key = "policy", title = "roost.toml 的 [retention]" }),
			btn("", "refresh-disk", { icon = "repeat", variant = "quiet", key = "refresh", title = "重新统计占用", busy = d.loading }),
		}),
	}, { key = "storage", icon = "folder-open" })
end

local function config_tab(st: State): Node
	local c = st.core
	local p = c.paths
	local r = c.config.runner
	local function file_card(key: string, title: string, path: string, issues: { model.Issue }, ok_text: string): Node
		local body: { Node } = {
			keyed(ui.text({ ui.path(path) }), "path"),
		}
		if #issues == 0 then
			table.insert(body, keyed(ui.text({ ui.span(ok_text, "success") }), "ok"))
		else
			table.insert(body, N("col", { key = "issues", gap = "xs" }, issues_nodes(issues, path)))
		end
		table.insert(body, N("row", { key = "actions", gap = "sm" }, {
			btn("编辑", `open={key}`, { icon = "pen", key = "edit" }),
		}))
		return ui.card(title, body, { key = key, icon = "file-code", tone = if #issues > 0 then "error" else nil })
	end
	local wf_ok = if c.workflows then `已加载 {#c.workflows.list} 个工作流 · {#util.keys(c.workflows.repos)} 个仓库` else "未加载"
	local runner_kv = ui.kv({
		pair("omp", { ui.span(r.omp .. " " .. table.concat(r.omp_args, " "), "mono") }),
		{ "agent 会话", `Tern 会话「{r.session}」中的新标签页` },
		{ "并发", tostring(r.max_concurrent) },
		{ "默认超时", util.fmt_duration(r.default_timeout) },
		pair("PATH 追加", { ui.span(table.concat(r.extra_path, ":"), "mono") }),
	} :: any)
	return N("col", { key = "config", role = "roost.config", gap = "md" }, {
		file_card("config", "roost.toml", p.config, c.config_issues, "有效"),
		file_card("workflows", "workflows.toml", p.workflows, c.workflow_issues, wf_ok),
		ui.card("运行设置", { keyed(runner_kv, "kv") }, { key = "runner", icon = "sliders" }),
		storage_card(st),
		ui.card("外观", {
			keyed(muted("theme.css 放在数据目录中,保存后实时注入,覆盖 roost.css 的样式(钩子:data-role = roost.*)。"), "note"),
			keyed(ui.text({ ui.path(p.theme) }), "path"),
			N("row", { key = "actions", gap = "sm" }, {
				btn(if tern.fs.exists(p.theme) then "编辑 theme.css" else "创建 theme.css", "open=theme", { icon = "palette", key = "edit" }),
			}),
		}, { key = "theme", icon = "palette" }),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Dispatch form

local function form_input_id(i: number): string
	return `layer.form.field{i}.input`
end

local function focus_form(st: State)
	local f = st.form
	if f and f.fields[f.focus] then
		st.cx:frame({ { "focus", form_input_id(f.focus) } })
	end
end

local function open_form(st: State, wf: model.Workflow)
	local fields: { FormField } = {}
	local target = model.pr_target(wf)
	if target then
		table.insert(fields, {
			text = "",
			cursor = 0,
			label = "拉取请求",
			hint = if target == "only"
				then "owner/name#12 或 PR 链接;工作流只有一个仓库时可只写编号"
				else "owner/name#12 或 PR 链接;留空则不针对 PR 运行",
			required = target == "only",
			pr = true,
		})
	end
	for _, i in wf.inputs do
		local text = i.default or ""
		table.insert(fields, {
			text = text,
			cursor = utf8.len(text) or #text,
			name = i.name,
			label = i.name,
			hint = i.description,
			required = i.required,
		})
	end
	st.form = { workflow = wf.id, title = wf.name, fields = fields, focus = 1, error = nil }
	focus_form(st)
end

local function form_done(st: State, f: Form)
	st.form = nil
	st.cx:frame({ pair("focus", tern.json.null) })
	st.tab = "runs"
	local newest = store.list(st.core.store, 1, f.workflow)[1]
	if newest then
		select_run(st, newest.id)
	end
end

local function submit_form(st: State)
	local f = st.form
	if not f or f.busy then
		return
	end
	local inputs: { [string]: string } = {}
	local pr: string? = nil
	for _, fl in f.fields do
		local text = util.trim(fl.text)
		if fl.required and text == "" then
			f.error = `{fl.label} 是必填项`
			return
		end
		if fl.pr then
			pr = if text ~= "" then text else nil
		elseif fl.text ~= "" then
			inputs[fl.name :: string] = fl.text
		end
	end
	if pr == nil then
		local err = core.dispatch(st.core, f.workflow, inputs)
		if err then
			f.error = err
			return
		end
		form_done(st, f)
		return
	end
	f.busy, f.error = true, nil
	local function open(): boolean
		return not st.closed and st.form == f
	end
	core.dispatch_pr(st.core, f.workflow, inputs, pr, function(err)
		-- Cancelled (or the block closed) while gh read the PR: nothing was queued.
		if not open() then
			return
		end
		f.busy = false
		if err then
			f.error = err
		else
			form_done(st, f)
		end
		st.cx:render()
	end, open)
end

local function form_view(st: State): Node?
	local f = st.form
	if not f then
		return nil
	end
	local children: { Node } = {}
	for i, fl in f.fields do
		table.insert(
			children,
			N("field", { key = `field{i}`, label = fl.label, hint = fl.hint, required = fl.required }, {
				N("input", {
					key = "input",
					text = fl.text,
					cursor = field.utf16_cursor(fl),
					placeholder = fl.hint or fl.label,
					variant = "field",
				}),
			})
		)
	end
	if f.error then
		table.insert(children, keyed(ui.text({ ui.span(f.error, "error") }), "error"))
	elseif f.busy then
		table.insert(children, keyed(ui.text({ ui.span("正在用 gh 读取拉取请求…", "muted") }), "busy"))
	end
	table.insert(
		children,
		N("row", { key = "foot", justify = "end", gap = "sm" }, {
			btn("取消", "form_cancel", { variant = "quiet", keys = { "esc" }, key = "cancel", size = "md" }),
			btn("运行", "form_submit", {
				variant = "primary",
				keys = { "enter" },
				key = "submit",
				size = "md",
				icon = "play",
				disabled = if f.busy then "正在读取拉取请求" else false,
			}),
		})
	)
	return N("col", {}, {
		N("overlay", {
			key = "form",
			role = "roost.form",
			head = `运行 {f.title}`,
			icon = "play",
			modal = true,
			size = "md",
			foot = "layer.form.foot",
		}, children),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Export and import

-- Writes `ids` to one export file and copies its path.
local function export_workflows(st: State, ids: { string })
	local path, err = core.export_workflows(st.core, ids)
	if path == nil then
		toast_err(st, err or "导出失败")
		return
	end
	st.cx:copy(path)
	st.cx:toast("success", `已导出到 {path}(路径已复制)`)
end

local IMP_PATH_ID = "layer.imp.path.input"

local function imp_close(st: State)
	st.imp = nil
	st.cx:frame({ pair("focus", tern.json.null) })
end

-- The editor and the run form own the overlay layer: import waits until they are closed.
local function imp_open(st: State)
	if st.editor or st.form or st.imp then
		return
	end
	st.imp = { path = text_field(""), plan = nil, error = nil }
	st.cx:frame({ { "focus", IMP_PATH_ID } })
end

local function imp_preview(st: State)
	local imp = st.imp
	if not imp then
		return
	end
	imp.plan, imp.error = core.import_preview(st.core, util.trim(imp.path.text))
end

local function imp_run(st: State, overwrite: boolean)
	local imp = st.imp
	if not imp then
		return
	end
	local summary, err = core.import_workflows(st.core, util.trim(imp.path.text), overwrite)
	if summary then
		st.cx:toast("success", summary)
		imp_close(st)
	else
		imp.error = err or "导入失败"
	end
end

local function plan_nodes(plan: core.ImportPlan): { Node }
	local out: { Node } = {}
	for i, w in plan.workflows do
		table.insert(out, keyed(ui.text({
			ui.span("工作流 ", "muted"),
			ui.span(w.id, "mono"),
			ui.span(`  {w.name}  `),
			ui.span(if w.exists then "已存在,默认跳过" else "新增,导入后停用", if w.exists then "warning" else "success"),
		}), `w{i}`))
	end
	for i, l in plan.libraries do
		local state = if not l.exists then "新建" elseif l.same then "内容相同" else "内容不同,默认保留本机版本"
		table.insert(out, keyed(ui.text({
			ui.span("文件库 ", "muted"),
			ui.span(l.name, "mono"),
			ui.span("  "),
			ui.span(state, if l.exists and not l.same then "warning" else "success"),
		}), `l{i}`))
	end
	for i, r in plan.repos do
		table.insert(out, keyed(ui.text({
			ui.span("仓库 ", "muted"),
			ui.span(r.name, "mono"),
			ui.span("  "),
			ui.span(if r.exists then "已声明" else "需在 workflows.toml 填写本机路径", if r.exists then "success" else "warning"),
		}), `r{i}`))
	end
	table.insert(out, keyed(muted(`共 {plan.files} 个文件`), "files"))
	return out
end

-- Whether importing would replace something here (so "覆盖导入" has a meaning).
local function plan_overwrites(plan: core.ImportPlan): boolean
	for _, w in plan.workflows do
		if w.exists then
			return true
		end
	end
	for _, l in plan.libraries do
		if l.exists and not l.same then
			return true
		end
	end
	return false
end

local function import_view(st: State): Node?
	local imp = st.imp
	if not imp then
		return nil
	end
	local children: { Node } = {
		N("field", { key = "path", label = "导出文件", hint = "路径,或 exports 目录里的文件名" }, {
			N("input", {
				key = "input",
				text = imp.path.text,
				cursor = field.utf16_cursor(imp.path),
				placeholder = "~/Downloads/xxx.roost.toml",
				variant = "field",
			}),
		}),
	}
	local names = core.exports(st.core)
	if #names > 0 then
		local list: { Node } = {}
		for i = 1, math.min(#names, 6) do
			table.insert(list, btn(names[i], `imp-pick={names[i]}`, { key = `x{i}`, variant = "quiet" }))
		end
		table.insert(children, keyed(muted("最近的导出文件:"), "recent"))
		table.insert(children, N("col", { key = "names", gap = "xs" }, list))
	end
	if imp.error then
		table.insert(children, keyed(ui.text({ ui.span(imp.error, "error") }), "error"))
	end
	if imp.plan then
		table.insert(children, N("col", { key = "plan", gap = "xs" }, plan_nodes(imp.plan)))
	end
	local foot: { Node } = {
		btn("取消", "imp-cancel", { variant = "quiet", keys = { "esc" }, key = "cancel", size = "md" }),
		btn("预览", "imp-preview", { key = "preview", size = "md" }),
	}
	if imp.plan and plan_overwrites(imp.plan) then
		table.insert(foot, confirm_btn(st, "覆盖导入", "确认覆盖", "overwrite-import", { key = "overwrite", size = "md" }))
	end
	table.insert(foot, btn("导入", "imp-run", {
		variant = "primary",
		key = "run",
		size = "md",
		disabled = if imp.plan then false else "先预览",
	}))
	table.insert(children, N("row", { key = "foot", justify = "end", gap = "sm" }, foot))
	return N("col", {}, {
		N("overlay", {
			key = "imp",
			role = "roost.form",
			head = "导入工作流",
			icon = "plus",
			modal = true,
			size = "md",
			foot = "layer.imp.foot",
		}, children),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Group name dialog (workflows page)

local GRP_NAME_ID = "layer.grp.name.input"

-- `id`: rename that group; else a new group, which workflow `wf` (when set) moves into.
local function grp_open(st: State, id: string?, wf: string?)
	if st.editor or st.form or st.imp or st.grp then
		return
	end
	local x = if id then groups.find(st.core.groups, id) else nil
	if id and x == nil then
		toast_err(st, "分组不存在")
		return
	end
	st.grp = { id = id, wf = wf, name = text_field(if x then x.name else ""), error = nil }
	st.cx:frame({ { "focus", GRP_NAME_ID } })
end

local function grp_close(st: State)
	st.grp = nil
	st.cx:frame({ pair("focus", tern.json.null) })
end

local function grp_submit(st: State)
	local d = st.grp
	if not d then
		return
	end
	local c = st.core
	local err: string?
	if d.id then
		err = core.group_rename(c, d.id, d.name.text)
	else
		local gid, cerr = core.group_create(c, d.name.text)
		err = cerr
		if gid and d.wf then
			-- The group exists either way; a failed move is reported, not undone.
			toast_err(st, core.group_assign(c, d.wf, gid))
		end
	end
	if err then
		d.error = err
		return
	end
	grp_close(st)
end

local function group_view(st: State): Node?
	local d = st.grp
	if not d then
		return nil
	end
	local wf = if d.wf and st.core.workflows then st.core.workflows.by_id[d.wf] else nil
	local children: { Node } = {
		N("field", { key = "name", label = "分组名", hint = `最多 {groups.NAME_MAX} 个字符,不能与已有分组重名` }, {
			N("input", {
				key = "input",
				text = d.name.text,
				cursor = field.utf16_cursor(d.name),
				placeholder = "例如 FluxDown",
				variant = "field",
			}),
		}),
	}
	if wf then
		table.insert(children, keyed(muted(`创建后把「{wf.name}」移入这个分组。`), "note"))
	end
	if d.error then
		table.insert(children, keyed(ui.text({ ui.span(d.error, "error") }), "error"))
	end
	table.insert(children, N("row", { key = "foot", justify = "end", gap = "sm" }, {
		btn("取消", "grp-cancel", { variant = "quiet", keys = { "esc" }, key = "cancel", size = "md" }),
		btn(if d.id then "重命名" else "创建", "grp-ok", { variant = "primary", keys = { "enter" }, key = "ok", size = "md" }),
	}))
	return N("col", {}, {
		N("overlay", {
			key = "grp",
			role = "roost.form",
			head = if d.id then "重命名分组" else "新建分组",
			icon = "folder",
			modal = true,
			size = "sm",
			foot = "layer.grp.foot",
		}, children),
	})
end

-- ---------------------------------------------------------------------------------------------
-- View

function M.view(st: State): BlockView
	local body: Node
	if st.tab == "runs" then
		body = runs_tab(st)
	elseif st.tab == "workflows" then
		body = workflows_tab(st)
	elseif st.tab == "events" then
		body = events_tab(st)
	elseif st.tab == "relay" then
		body = relay_tab(st)
	elseif st.tab == "config" then
		body = config_tab(st)
	elseif st.tab == "files" then
		body = files_tab(st)
	else
		body = overview(st)
	end
	local c = st.core
	local active = 0
	for _, r in c.store.runs do
		if r.state == "running" or r.state == "queued" then
			active += 1
		end
	end
	local counts: { [string]: number } = {
		runs = active,
		workflows = if c.workflows then #c.workflows.list else 0,
		events = #c.events,
		config = #c.config_issues + #c.workflow_issues,
	}
	local nav: { any } = {}
	for _, tab in TABS do
		local n = counts[tab.id]
		table.insert(nav, {
			id = tab.id,
			label = if n and n > 0 then { ui.span(`{tab.label} `), ui.span(tostring(n), "muted") } else tab.label,
		})
	end
	-- Only the page scrolls: the head and the tabs stay put. The body always fills the block below
	-- the tabs (roost.css, `roost.fill`); a page that is a `col` becomes a `scroll` of the same key,
	-- role and children, so node ids stay and each page keeps its own scroll position. The wide
	-- runs page is a split whose panes scroll inside themselves.
	if body.k == "col" then
		body.k = "scroll"
	end
	local main = N("col", { gap = "lg" }, {
		header(st),
		N("tabs", { key = "nav", role = "roost.tabs", active = st.tab, items = nav }),
		N("col", { key = "body", role = "roost.fill", gap = "lg" }, { body }),
	})
	local legend: { any } = { ui.span("1-7", "key"), ui.span(" 切换页面", "muted") }
	local function hint(k: string, what: string)
		table.insert(legend, ui.span("   "))
		table.insert(legend, ui.span(k, "key"))
		table.insert(legend, ui.span(` {what}`, "muted"))
	end
	if st.tab == "runs" then
		hint("j/k", "选择运行")
		hint("c", "取消")
		hint("r", "重跑")
	elseif st.tab == "workflows" then
		hint("j/k", "选择工作流")
		hint("r", "运行")
		hint("e", "编辑")
		if #st.core.groups.list > 0 then
			hint("[ ]", "移到上/下一个分组")
		end
		hint("Esc", "取消选中")
	end
	local dock = N("col", {}, { ui.text(legend) })
	return { main = main, dock = dock, layer = editor.view(st) or form_view(st) or import_view(st) or group_view(st) }
end

-- ---------------------------------------------------------------------------------------------
-- Actions

local function open_path(st: State, what: string)
	local c = st.core
	if what == "theme" then
		if not tern.fs.exists(c.paths.theme) then
			pcall(tern.fs.write, c.paths.theme, THEME_STARTER)
		end
		st.cx:open(c.paths.theme)
	elseif what == "config" then
		st.cx:open(c.paths.config)
	elseif what == "workflows" then
		st.cx:open(c.paths.workflows)
	end
end

-- The second click of a confirm_btn.
local function confirmed(st: State, what: string)
	local c = st.core
	local run = string.match(what, "^delete%-run:(%x+)$")
	if run then
		local err = core.delete_run(c, run)
		toast_err(st, err)
		if not err and st.run_id == run then
			st.run_id = nil
			reset_log(st, nil)
		end
	elseif what == "forget-app" then
		core.forget_app(c)
	elseif what == "clear-runs" then
		core.clear_runs(c)
		if st.run_id and c.store.by_id[st.run_id] == nil then
			st.run_id = nil
			reset_log(st, nil)
		end
	elseif what == "clear-events" then
		core.clear_events(c)
	elseif what == "clear-deliveries" then
		core.clear_deliveries(c)
	elseif what == "clear-relay-events" then
		core.clear_relay_events(c)
	elseif what == "clear-exports" then
		core.clear_exports(c)
	elseif what == "overwrite-import" then
		imp_run(st, true)
	elseif string.sub(what, 1, 8) == "lib-del:" then
		local name = string.sub(what, 9)
		local err = core.delete_library(c, name)
		toast_err(st, err)
		if not err and st.fp.lib == name then
			st.fp.lib, st.fp.sel = nil, nil
			fp_load(st)
		end
	elseif string.sub(what, 1, 9) == "file-del:" then
		local path = string.sub(what, 10)
		local fp = st.fp
		-- Deleting another file would reload the editor over unsaved edits.
		if fp.lib and (path == fp.sel or fp_guard(st)) then
			local err = core.delete_library_file(c, fp.lib, path)
			toast_err(st, err)
			-- A refused delete leaves the editor (and any unsaved text in it) alone.
			if err == nil then
				if path == fp.sel then
					fp.sel = nil
				end
				fp_load(st)
			end
		end
	elseif string.sub(what, 1, 10) == "state-del:" then
		toast_err(st, core.delete_state(c, string.sub(what, 11)))
	elseif string.sub(what, 1, 11) == "orphan-del:" then
		toast_err(st, core.delete_workflow_files(c, string.sub(what, 12)))
	elseif string.sub(what, 1, 8) == "grp-del:" then
		toast_err(st, core.group_delete(c, string.sub(what, 9)))
	else
		local n = string.match(what, "^rollback%-rev:(%d+)$")
		if n then
			toast_err(st, core.rollback_revision(c, tonumber(n) :: number))
		end
	end
end

local function do_action(st: State, act: string, value: string?, item: string?)
	local c = st.core
	local target = value or item
	if act ~= "confirm" then
		-- A two-click action is disarmed by anything in between.
		st.confirm = nil
	end
	if act == "tab" and value and TAB_IDS[value] then
		st.tab = value
	elseif act == "open" and value then
		open_path(st, value)
	elseif act == "reload_files" then
		core.reload_files(c)
	elseif act == "dispatch" and value then
		local wf = c.workflows and c.workflows.by_id[value]
		if not wf then
			toast_err(st, `没有工作流 {value}`)
		elseif #wf.inputs > 0 or model.pr_target(wf) then
			open_form(st, wf)
		else
			local err = core.dispatch(c, value)
			if err then
				toast_err(st, err)
			else
				local newest = store.list(c.store, 1, value)[1]
				st.tab = "runs"
				if newest then
					select_run(st, newest.id)
				end
			end
		end
	elseif act == "cancel" and target then
		toast_err(st, core.cancel(c, target))
	elseif act == "rerun" and target then
		local err = core.rerun(c, target)
		toast_err(st, err)
		if not err then
			local r = c.store.by_id[target]
			local newest = if r then store.list(c.store, 1, r.workflow)[1] else nil
			if newest then
				select_run(st, newest.id)
			end
		end
	elseif act == "open-log" and target then
		st.cx:open(`{run_dir(st, target)}/log.txt`)
	elseif act == "copy-id" and target then
		st.cx:copy(target)
		st.cx:toast("success", `已复制运行 ID {target}`)
	elseif act == "log-wrap" then
		st.log_wrap = not st.log_wrap
	elseif act == "sidebar" then
		st.cx:open(agent.SIDEBAR_URL)
	elseif act == "session" and value then
		local run, i = string.match(value, "^(%x+):(%d+)$")
		if run and i then
			st.cx:open(agent.session_url(run, tonumber(i) :: number))
		end
	elseif act == "open-ws" and target then
		local r = c.store.by_id[target]
		if r and r.cwd then
			st.cx:open(r.cwd)
		end
	elseif act == "open-run" and value then
		st.tab = "runs"
		select_run(st, value)
	elseif act == "push" then
		core.push_subscriptions(c, false)
	elseif act == "force_push" then
		core.push_subscriptions(c, true)
	elseif act == "adopt" then
		core.adopt_remote(c)
	elseif act == "reload_remote" then
		core.remote_reload(c)
	elseif act == "restart_remote" then
		core.remote_restart(c)
	elseif act == "test" then
		core.test_relay(c)
	elseif act == "editor-new" then
		editor.open(st, "new", nil)
	elseif act == "edit" and value then
		editor.open(st, "edit", value)
	elseif act == "template" and value then
		editor.open(st, "template", value)
	elseif string.sub(act, 1, 4) == "tpl:" then
		editor.open(st, "template", string.sub(act, 5))
	elseif act == "app-create" then
		local org = st.app_org
		local text = if org then util.trim(org.text) else ""
		st.app_focus = false
		st.app_busy = true
		core.create_app(c, if text == "" then nil else text, function(url, err)
			st.app_busy = false
			if st.closed then
				return
			end
			if type(url) == "string" and url ~= "" then
				st.cx:open(url)
			else
				st.cx:toast("error", if type(err) == "string" and err ~= "" then err else "创建失败")
			end
			st.cx:render()
		end)
	elseif act == "app-install" or act == "app-manage" or act == "app-permissions" or act == "app-logo" then
		local info = core.app(c)
		local url: string? = nil
		if info then
			if act == "app-install" then
				url = info.install_url
			elseif act == "app-manage" then
				url = info.html_url
			elseif act == "app-permissions" then
				url = if info.settings_url then info.settings_url .. "/permissions" else nil
			else
				url = info.settings_url
			end
		end
		if url and url ~= "" then
			st.cx:open(url)
		end
	elseif act == "confirm" and value then
		-- Destructive actions take two separate clicks (see confirm_btn): a double click, or a
		-- second click after the arm expired, only arms it again.
		local t = tern.now()
		local age = t - (st.confirm_at or 0)
		if st.confirm == value and age >= CONFIRM_MIN_MS and age <= CONFIRM_MAX_MS then
			st.confirm = nil
			confirmed(st, value)
		else
			st.confirm, st.confirm_at = value, t
			tern.timer(CONFIRM_MAX_MS, function()
				if not st.closed and st.confirm == value and st.confirm_at == t then
					st.confirm = nil
					st.cx:render()
				end
			end)
		end
	elseif act == "export" and value then
		export_workflows(st, { value })
	elseif act == "export-all" then
		local ids: { string } = {}
		local list: { model.Workflow } = if c.workflows then c.workflows.list else {}
		for _, wf in list do
			table.insert(ids, wf.id)
		end
		export_workflows(st, ids)
	elseif act == "grp-new" then
		grp_open(st, nil, nil)
	elseif string.sub(act, 1, 12) == "grp-new-for:" then
		grp_open(st, nil, string.sub(act, 13))
	elseif act == "grp-ren" and value then
		grp_open(st, value, nil)
	elseif act == "grp-up" and value then
		toast_err(st, core.group_move(c, value, -1))
	elseif act == "grp-down" and value then
		toast_err(st, core.group_move(c, value, 1))
	elseif act == "grp-toggle" and value then
		toast_err(st, core.group_toggle(c, value))
	elseif act == "grp-cancel" then
		grp_close(st)
	elseif act == "grp-ok" then
		grp_submit(st)
	elseif string.sub(act, 1, 3) == "mv:" then
		-- A row of a card's group menu: `mv:<workflow>:<group>` (empty group: ungrouped).
		local wf, gid = string.match(act, "^mv:([^:]+):(.*)$")
		if wf and gid then
			toast_err(st, core.group_assign(c, wf, if gid == "" then nil else gid))
		end
	elseif act == "imp-open" then
		imp_open(st)
	elseif act == "imp-cancel" then
		imp_close(st)
	elseif act == "imp-preview" then
		imp_preview(st)
	elseif act == "imp-run" then
		imp_run(st, false)
	elseif act == "imp-pick" and value then
		if st.imp then
			st.imp.path = text_field(value)
			imp_preview(st)
		end
	elseif act == "fp-lib" and value then
		if fp_guard(st) then
			st.fp.lib, st.fp.sel = value, nil
			fp_load(st)
		end
	elseif act == "fp-file" and value then
		if fp_guard(st) then
			st.fp.sel = value
			fp_load(st)
		end
	elseif act == "fp-reload" then
		if fp_guard(st) then
			fp_load(st)
		end
	elseif act == "fp-revert" then
		fp_load(st)
	elseif act == "fp-save" then
		fp_save(st)
	elseif act == "fp-newlib" then
		fp_newlib(st)
	elseif act == "fp-newfile" then
		fp_newfile(st)
	elseif act == "fp-ren" then
		fp_rename(st)
	elseif act == "housekeep" then
		core.housekeep(c, true)
	elseif act == "refresh-disk" then
		c.disk.at = nil
		core.disk(c)
	elseif act == "refresh-deliveries" then
		core.deliveries(c, true)
	elseif act == "copy" and value == "subs" then
		local text = manual_subs_text(st)
		if text then
			st.cx:copy(text)
			st.cx:toast("success", "已复制 subscriptions.toml")
		end
	elseif act == "form_submit" then
		submit_form(st)
	elseif act == "form_cancel" then
		st.form = nil
	end
end

function M.event(st: State, ev: UiEvent)
	if st.editor and editor.event(st, ev) then
		return
	end
	local name = last_segment(ev.id)
	if ev.ev == "select" or ev.ev == "activate" then
		local item = ev.item
		if type(item) ~= "string" then
			return
		end
		if name == "nav" and TAB_IDS[item] then
			st.tab = item
			st.confirm = nil
		elseif name == "tpl" then
			st.tpl = item
		elseif name == "health" then
			st.wf_id = item
			if ev.ev == "activate" then
				st.tab = "workflows"
			end
		elseif name == "filter" then
			st.filter = item
		elseif name == "runs" then
			select_run(st, item)
		elseif name == "table" and st.tab == "events" then
			local delivery = string.match(item, "^d:(.+)$")
			for _, e in st.core.events do
				local run = if e.delivery == delivery then e.runs[1] else nil
				if run and st.core.store.by_id[run] then
					st.tab = "runs"
					select_run(st, run)
					break
				end
			end
		end
	elseif ev.ev == "action" then
		local act = ev.act
		if type(act) == "string" then
			do_action(st, act, ev.value, if type(ev.item) == "string" then ev.item else nil)
		end
	elseif ev.ev == "focus" then
		if st.imp then
			st.cx:frame({ { "focus", IMP_PATH_ID } })
		elseif st.grp then
			st.cx:frame({ { "focus", GRP_NAME_ID } })
		elseif st.form then
			local i = tonumber(string.match(ev.id or "", "^layer%.form%.field(%d+)%.input$") or "")
			if i and st.form.fields[i] then
				st.form.focus = i
				focus_form(st)
			end
		elseif string.match(ev.id or "", "relay%.app%.org%.input$") then
			st.app_focus = true
			st.cx:frame({ pair("focus", ev.id) })
		else
			st.app_focus = false
			for fname, id in FP_IDS do
				if st.tab == "files" and ev.id == id then
					fp_focus(st, fname)
				end
			end
		end
	end
end

local function move_selection(st: State, delta: number): boolean
	local list = runs_list(st)
	if #list == 0 then
		return false
	end
	local idx = 0
	for i, r in list do
		if r.id == st.run_id then
			idx = i
			break
		end
	end
	local nxt = math.clamp(idx + delta, 1, #list)
	if idx == 0 then
		nxt = 1
	end
	if list[nxt].id == st.run_id then
		return false
	end
	select_run(st, list[nxt].id)
	return true
end

function M.key(st: State, key: Key): boolean?
	-- Keys move selections and pages: an armed destructive button would end up meaning another
	-- item, so any key disarms it.
	st.confirm = nil
	if st.editor and editor.key(st, key) then
		return true
	end
	local f = st.form
	if f then
		if key.name == "escape" then
			st.form = nil
			st.cx:frame({ pair("focus", tern.json.null) })
			return true
		elseif key.name == "enter" then
			submit_form(st)
			return true
		elseif key.name == "tab" then
			if #f.fields > 0 then
				f.focus = (f.focus - 1 + (if key.shift then -1 else 1)) % #f.fields + 1
				focus_form(st)
			end
			return true
		end
		local fl = f.fields[f.focus]
		if fl and field.key(fl, key) then
			f.error = nil
			return true
		end
		return false
	end
	local gd = st.grp
	if gd then
		if key.name == "escape" then
			grp_close(st)
			return true
		elseif key.name == "enter" then
			grp_submit(st)
			return true
		end
		if field.key(gd.name, key) then
			gd.error = nil
			return true
		end
		return false
	end
	local imp = st.imp
	if imp then
		if key.name == "escape" then
			imp_close(st)
			return true
		elseif key.name == "enter" then
			if imp.plan then
				imp_run(st, false)
			else
				imp_preview(st)
			end
			return true
		end
		if field.key(imp.path, key) then
			imp.plan, imp.error = nil, nil
			return true
		end
		return false
	end
	local fpn = st.fp.focus
	if st.tab == "files" and fpn then
		if key.name == "escape" then
			fp_focus(st, nil)
			return true
		elseif key.name == "enter" and fpn ~= "edit" then
			if fpn == "newlib" then
				fp_newlib(st)
			elseif fpn == "newfile" then
				fp_newfile(st)
			else
				fp_rename(st)
			end
			return true
		end
		if field.key(st.fp.fields[fpn], key) then
			return true
		end
	end
	local app = if st.tab == "relay" and st.app_focus and st.app_org then core.app(st.core) else nil
	-- Keys go to the org field only while it is drawn (no App yet, relay status known).
	if app and not app.configured and st.app_org then
		if key.name == "escape" or key.name == "enter" then
			st.app_focus = false
			st.cx:frame({ pair("focus", tern.json.null) })
			return true
		end
		if field.key(st.app_org, key) then
			return true
		end
	end
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local n = tonumber(key.name)
	if n and TABS[n] then
		if st.tab == TABS[n].id then
			return false
		end
		st.tab = TABS[n].id
		return true
	end
	if st.tab == "runs" then
		if key.name == "j" or key.name == "down" then
			return move_selection(st, 1)
		elseif key.name == "k" or key.name == "up" then
			return move_selection(st, -1)
		elseif key.name == "c" and st.run_id then
			toast_err(st, core.cancel(st.core, st.run_id))
			return true
		elseif key.name == "r" and st.run_id then
			do_action(st, "rerun", st.run_id, nil)
			return true
		end
	elseif st.tab == "workflows" and st.core.workflows then
		local w = st.core.workflows :: model.Workflows
		if key.name == "escape" and st.wf_id then
			st.wf_id = nil
			return true
		end
		local shown = shown_workflows(st, w)
		local sel = selected_workflow(st, w)
		if not sel then
			-- Nothing picked yet: j/k pick the first card; r/e need a pick.
			if (key.name == "j" or key.name == "down" or key.name == "k" or key.name == "up") and shown[1] then
				st.wf_id = shown[1].id
				return true
			end
			return false
		end
		if key.name == "j" or key.name == "down" or key.name == "k" or key.name == "up" then
			if #shown == 0 then
				return false
			end
			local delta = if key.name == "j" or key.name == "down" then 1 else -1
			local idx = table.find(shown, sel)
			-- The pick is in a folded group: start over from the first shown card.
			local nxt = if idx then shown[math.clamp(idx + delta, 1, #shown)] else shown[1]
			if nxt.id == sel.id then
				return false
			end
			st.wf_id = nxt.id
			return true
		elseif (key.name == "[" or key.name == "]") and #st.core.groups.list > 0 then
			-- The picked workflow to the previous / next group; past the last group is 未分组.
			local g = st.core.groups
			local order: { string } = {}
			for _, x in g.list do
				table.insert(order, x.id)
			end
			local cur = groups.group_of(g, sel.id)
			local at = if cur then table.find(order, cur) :: number else #order + 1
			local to = math.clamp(at + (if key.name == "]" then 1 else -1), 1, #order + 1)
			if to == at then
				return false
			end
			toast_err(st, core.group_assign(st.core, sel.id, order[to]))
			return true
		elseif key.name == "r" and sel.manual then
			do_action(st, "dispatch", sel.id, nil)
			return true
		elseif key.name == "e" then
			editor.open(st, "edit", sel.id)
			return true
		end
	end
	return false
end

return M
