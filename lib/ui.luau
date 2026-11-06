--!strict
-- The `roost.console` block: overview, runs (with a live log), workflows, relayed events, relay
-- sync and remote operations, and config diagnostics. Views are built from state only; every
-- repeated node carries a stable key so Tern's diff sends small frames, and the log grows by
-- suffix so new output goes out as appends.
--
-- Theming contract (roost.css, the user's theme.css): data-role hooks `roost.header`,
-- `roost.tabs`, `roost.overview`, `roost.runs`, `roost.run`, `roost.log`, `roost.workflows`,
-- `roost.workflow`, `roost.events`, `roost.relay`, `roost.config`, `roost.form`.

local core = require("./core")
local store = require("./store")
local model = require("./model")
local field = require("./field")
local util = require("./util")
local agent = require("./agent")
local editor = require("./editor")

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
}
local TAB_IDS: { [string]: boolean } = {}
for _, t in TABS do
	TAB_IDS[t.id] = true
end

local LOG_CHUNK = 256 * 1024
local LOG_MAX = 512 * 1024
local LOG_POLL_MS = 1000
local MAX_RUN_ROWS = 200

export type FormField = field.Field & { label: string, hint: string?, required: boolean }
export type Form = { workflow: string, title: string, fields: { FormField }, focus: number, error: string? }
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
}

export type State = {
	core: core.Core,
	cx: BlockCx,
	born: number,
	closed: boolean,
	unsubscribe: (() -> ())?,
	tab: string,
	run_id: string?,
	filter: string, -- all | active | failed
	form: Form?,
	log: Log,
	cols: number,
	rows: number,
	editor: any, -- lib/editor.luau's state while the automation editor is open
	tpl: string, -- template gallery group
	app_org: field.Field?, -- organization typed for a new GitHub App
	app_focus: boolean,
	app_busy: boolean,
	app_confirm: boolean, -- 忘记本地凭据 armed by a first click
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
local STEP_ICON: { [string]: string } = { omp = "omp", run = "terminal", prepare = "folder-plus", cleanup = "trash" }
local SYNC_LABEL: { [string]: string } = {
	idle = "待同步",
	pushing = "推送中",
	ok = "已同步",
	conflict = "冲突",
	invalid = "被拒绝",
	offline = "推送失败",
	unconfigured = "未配置",
}
local SYNC_TONE: { [string]: string } = {
	idle = "muted",
	pushing = "pending",
	ok = "success",
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

-- Agent timestamps are RFC 3339 (UTC); returns epoch seconds.
local function rfc3339(s: any): number?
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = string.match(s, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local Y, Mo, D = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	-- Days from civil (proleptic Gregorian), UTC.
	local yy = if Mo <= 2 then Y - 1 else Y
	local era = math.floor(yy / 400)
	local yoe = yy - era * 400
	local mp = (Mo + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + D - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	local days = era * 146097 + doe - 719468
	local t = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(se) :: number)
	local sign, oh, om = string.match(s, "([%+%-])(%d%d):?(%d%d)$")
	if sign and oh and om then
		local off = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		t = if sign == "+" then t - off else t + off
	end
	return t
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
	end
	lg.text = text
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
		filter = if s.filter == "active" or s.filter == "failed" then s.filter else "all",
		form = nil,
		log = { id = nil, text = "", offset = 0, eof = false, done = false, gen = 0, busy = false, timer = nil, cut = false },
		cols = cx.cols,
		rows = cx.rows,
		editor = nil,
		tpl = "全部",
		app_org = nil,
		app_focus = false,
		app_busy = false,
		app_confirm = false,
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
	return { tab = st.tab, run_id = st.run_id, filter = st.filter }
end

function M.resize(st: State, cols: number, rows: number)
	st.cols, st.rows = cols, rows
end

local function select_run(st: State, id: string?)
	st.run_id = id
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
	return N("row", { key = "head", role = "roost.header", justify = "between", align = "center", gap = "md" }, {
		N("row", { key = "title", gap = "sm", align = "center" }, {
			ui.text({ ui.span("Roost", "title"), ui.span(`  v{core.VERSION}`, "muted") }),
			N("row", { key = "badges", gap = "xs" }, badges),
		}),
		N("row", { key = "tools", gap = "xs" }, {
			btn("", "sidebar", { icon = "omp", variant = "quiet", title = "会话侧栏:Roost 运行过的 omp 会话", key = "sidebar" }),
			btn("", "reload_files", { icon = "repeat", variant = "quiet", title = "重新读取配置文件", key = "reload" }),
			btn("", "open=workflows", { icon = "file-code", variant = "quiet", title = "编辑 workflows.toml", key = "edit" }),
		}),
	})
end

-- ---------------------------------------------------------------------------------------------
-- Overview

local function run_row(r: store.Run, t: number): any
	local trig = r.trigger.kind
	return {
		id = r.id,
		cells = list_of(
			{ badge = { text = STATE_LABEL[r.state] or r.state, tone = STATE_TONE[r.state] or "muted" } },
			r.workflow_name,
			r.title,
			{ text = TRIGGER_LABEL[trig] or trig, icon = TRIGGER_ICON[trig] or "dot" },
			util.ago(r.created_at, t),
			duration(r.started_at, r.finished_at)
		),
		menu = if r.state == "queued" or r.state == "running" then { "cancel", "open-log" } else { "rerun", "open-log" },
	}
end

local RUN_COLS: { Col } = {
	{ id = "state", head = "状态" },
	{ id = "workflow", head = "工作流", priority = 2 },
	{ id = "title", head = "标题", grow = 1, truncate = "end" },
	{ id = "trigger", head = "触发", priority = 1 },
	{ id = "at", head = "创建", priority = 1 },
	{ id = "took", head = "耗时", align = "end", mono = true, priority = 3 },
}

local function overview(st: State): Node
	local c = st.core
	local t = now()
	local running, queued, ok, bad = 0, 0, 0, 0
	for _, r in c.store.runs do
		if r.state == "running" then
			running += 1
		elseif r.state == "queued" then
			queued += 1
		elseif (r.finished_at or 0) >= t - 86400 then
			if r.state == "success" then
				ok += 1
			elseif r.state == "failed" or r.state == "timed_out" then
				bad += 1
			end
		end
	end
	local rate = if ok + bad > 0 then `{math.floor(ok * 100 / (ok + bad) + 0.5)}%` else "—"
	local next_row = c.crons[1]
	local next_txt = if next_row and next_row.next then util.until_(next_row.next, t) else "—"
	local stats = ui.stats({
		{ label = "运行中", value = tostring(running), tone = if running > 0 then "accent" else nil },
		{ label = "排队", value = tostring(queued) },
		{ label = "24 小时成功率", value = rate, sub = `{ok} 成功 · {bad} 失败`, tone = if bad > 0 then "warning" else nil },
		{ label = "下一次定时", value = next_txt, sub = if next_row and next_row.next then next_row.name else "无定时触发" },
	})

	local recent = store.list(c.store, 8, nil)
	local rows = {}
	for _, r in recent do
		table.insert(rows, run_row(r, t))
	end
	local runs_card = ui.card("最近运行", {
		keyed(ui.table(RUN_COLS, rows :: any, { selectable = true, empty = "还没有运行。到「工作流」手动运行一次,或等待定时 / GitHub 事件。" }), "recent"),
	}, { icon = "history", key = "recent_card" })

	local cron_items: { Node } = {}
	for _, row in c.crons do
		if #cron_items >= 8 then
			break
		end
		table.insert(
			cron_items,
			N("item", {
				key = row.key,
				label = row.name,
				detail = { ui.span(row.desc), ui.span(`  {row.expr}{if row.utc then " UTC" else ""}`, "muted mono") },
				value = if row.next then util.until_(row.next, t) elseif row.enabled then "—" else "已停用",
				icon = "clock",
				tone = if row.enabled then nil else "muted",
			})
		)
	end
	local cron_card = ui.card("即将触发", {
		if #cron_items > 0
			then N("list", { key = "crons" }, cron_items)
			else N("empty", { key = "crons", variant = "inline", title = "没有定时触发", text = "在工作流里添加 [[workflow.trigger]] cron = \"…\"" }),
	}, { icon = "clock", key = "cron_card" })

	local notice_items: { Node } = {}
	for i, n in c.notices do
		if i > 6 then
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
	local children: { Node } = { keyed(stats, "stats"), runs_card, cron_card }
	if #notice_items > 0 then
		table.insert(children, ui.card("通知", { N("list", { key = "notices" }, notice_items) }, { icon = "bell", key = "notice_card" }))
	end
	return N("col", { key = "overview", role = "roost.overview", gap = "md" }, children)
end

-- ---------------------------------------------------------------------------------------------
-- Runs

local function steps_table(r: store.Run): Node
	local rows = {}
	for i, s in r.steps do
		table.insert(rows, {
			id = `s{i}`,
			cells = list_of(
				{ text = s.name, icon = STEP_ICON[s.kind] or "dot" },
				{ badge = { text = STATE_LABEL[s.state] or s.state, tone = STATE_TONE[s.state] or "muted" } },
				if s.exit_code then tostring(s.exit_code) else "",
				duration(s.started_at, s.finished_at)
			),
		})
	end
	return keyed(
		ui.table({
			{ id = "name", head = "步骤", grow = 1 },
			{ id = "state", head = "状态" },
			{ id = "code", head = "退出码", align = "end", mono = true, priority = 1 },
			{ id = "took", head = "耗时", align = "end", mono = true, priority = 2 },
		}, rows :: any),
		"steps"
	)
end

local function run_detail(st: State, r: store.Run): Node
	local t = now()
	local active = r.state == "queued" or r.state == "running"
	local actions: { Node } = {}
	if active then
		table.insert(actions, btn("取消", `cancel={r.id}`, { variant = "danger", icon = "stop", keys = { "c" }, key = "cancel" }))
	else
		table.insert(actions, btn("重跑", `rerun={r.id}`, { icon = "redo", keys = { "r" }, key = "rerun" }))
	end
	table.insert(actions, btn("日志文件", `open-log={r.id}`, { icon = "file", variant = "quiet", key = "log" }))
	for i = #r.steps, 1, -1 do
		local s = r.steps[i]
		if s.agent then
			table.insert(actions, btn("omp 会话", `session={r.id}:{i}`, { icon = "omp", variant = "quiet", key = "session" }))
			break
		end
	end
	if r.cwd and r.workspace ~= "temp" then
		table.insert(actions, btn("工作区", `open-ws={r.id}`, { icon = "folder-open", variant = "quiet", key = "ws" }))
	end
	local trig = r.trigger.kind
	local items: any = {
		{ "工作流", r.workflow_name },
		{ "触发", `{TRIGGER_LABEL[trig] or trig} · {r.trigger.detail}` },
	}
	if r.repo then
		table.insert(items, pair("仓库", { ui.span(r.repo, "mono"), ui.span(`  @ {r.fetch_ref or r.ref or "HEAD"}`, "muted mono") }))
	end
	if r.event and r.event.url then
		table.insert(items, pair("链接", { ui.link(r.event.url, r.event.url) }))
	end
	local inputs = {}
	for _, k in util.keys(r.inputs) do
		table.insert(inputs, `{k}={r.inputs[k]}`)
	end
	if #inputs > 0 then
		table.insert(items, pair("输入", { ui.span(table.concat(inputs, "  "), "mono") }))
	end
	table.insert(items, { "创建", `{util.clock(r.created_at)} ({util.ago(r.created_at, t)})` })
	if r.started_at then
		table.insert(items, { "开始", util.clock(r.started_at) })
	end
	if r.finished_at then
		table.insert(items, { "结束", `{util.clock(r.finished_at)} · 用时 {duration(r.started_at, r.finished_at)}` })
	end
	if r.reason then
		table.insert(items, pair("原因", { ui.span(r.reason, if r.state == "success" then "muted" else "warning") }))
	end
	local lg = st.log
	local log_body: Node
	if lg.id == r.id and (lg.text ~= "" or lg.eof) then
		log_body = N("scroll", { key = "log", role = "roost.log", stick = "end", max = { h = `{math.max(10, st.rows - 24)}lines` } }, {
			N("ansi", { key = "text", text = if lg.text == "" then "(还没有输出)" else lg.text }),
		})
	else
		log_body = N("spinner", { key = "log", style = "dots", label = { ui.span("读取日志…", "muted") } })
	end
	local head_spans = { ui.span(r.title, "strong") }
	local body: { Node } = {
		N("row", { key = "state", gap = "sm", align = "center" }, {
			keyed(state_badge(r.state), "badge"),
			if r.state == "running" and r.started_at
				then N("elapsed", { key = "elapsed", age = math.max(0, t - r.started_at) * 1000, format = "short" })
				else ui.text({ ui.span(r.id, "muted mono") }),
			N("row", { key = "actions", gap = "xs" }, actions),
		}),
		keyed(ui.kv(items :: any), "info"),
		steps_table(r),
		keyed(ui.rule(if lg.cut then "日志(仅显示最近 512 KiB)" else "日志"), "rule"),
		log_body,
	}
	return ui.card(head_spans, body, { key = "run", role = "roost.run", icon = TRIGGER_ICON[trig] or "run" })
end

local function runs_tab(st: State): Node
	local t = now()
	local rows = {}
	for _, r in runs_list(st) do
		table.insert(rows, run_row(r, t))
	end
	local left = N("col", { key = "left", gap = "sm" }, {
		N("tabs", {
			key = "filter",
			variant = "segmented",
			active = st.filter,
			items = { { id = "all", label = "全部" }, { id = "active", label = "进行中" }, { id = "failed", label = "失败" } },
		}),
		keyed(
			ui.table(RUN_COLS, rows :: any, { selectable = true, selected = st.run_id, empty = "没有符合条件的运行" }),
			"runs"
		),
	})
	local r = selected_run(st)
	local right = if r
		then run_detail(st, r)
		else N("empty", { key = "run", title = "选择一条运行", text = "j / k 选择,c 取消,r 重跑" })
	if st.cols < 110 then
		return N("col", { key = "runs", role = "roost.runs", gap = "md" }, { left, right })
	end
	return N("split", { key = "runs", role = "roost.runs", sizes = { 0.46, 0.54 }, variant = "hairline" }, { left, right })
end

-- ---------------------------------------------------------------------------------------------
-- Workflows

local function workflows_tab(st: State): Node
	local c = st.core
	local w = c.workflows
	local head = N("row", { key = "head", gap = "xs", align = "center" }, {
		btn("新建自动化", "editor-new", { variant = "primary", icon = "sparkle", key = "new" }),
		N("spacer", { key = "sp" }),
		btn("编辑 workflows.toml", "open=workflows", { variant = "quiet", icon = "file", key = "file" }),
	})
	if not w then
		return N("col", { key = "workflows", role = "roost.workflows", gap = "md" }, {
			head,
			N("empty", {
				key = "broken",
				tone = "error",
				title = "workflows.toml 还没有可用的版本",
				text = "修好「配置」页列出的错误后自动加载。",
			}),
		})
	end
	local latest = store.latest(c.store)
	local t = now()
	local cards: { Node } = {}
	for _, wf in w.list do
		local body: { Node } = {}
		if wf.description then
			table.insert(body, keyed(muted(wf.description), "desc"))
		end
		local trig_nodes: { Node } = {}
		for i, tr in wf.triggers do
			table.insert(trig_nodes, keyed(ui.text(model.describe_trigger(tr)), `t{i}`))
		end
		if #trig_nodes == 0 then
			table.insert(trig_nodes, keyed(muted("仅手动运行"), "t0"))
		end
		table.insert(body, N("col", { key = "triggers", gap = "xs" }, trig_nodes))
		local step_spans: { any } = {}
		for i, s in wf.steps do
			if i > 1 then
				table.insert(step_spans, ui.span("  →  ", "muted"))
			end
			table.insert(step_spans, ui.span(s.name, if s.kind == "omp" then "accent" else nil))
		end
		table.insert(body, keyed(ui.text(step_spans), "steps"))
		local last = latest[wf.id]
		local meta = {
			ui.span(`{wf.concurrency} · {wf.workspace}`, "muted"),
		}
		local row: { Node } = {
			btn("运行", `dispatch={wf.id}`, {
				variant = "primary",
				icon = "play",
				key = "run",
				disabled = if not wf.manual then "manual = false:只允许自动触发" else false,
			}),
			btn("编辑", `edit={wf.id}`, { variant = "quiet", icon = "pen", key = "edit" }),
		}
		if last then
			table.insert(row, keyed(with(state_badge(last.state), { actions = { click = `open-run={last.id}` }, title = "查看最近一次运行" }), "last"))
			table.insert(row, keyed(muted(`最近 {util.ago(last.created_at, t)}`), "last_at"))
		end
		table.insert(body, N("row", { key = "actions", gap = "xs", align = "center" }, row))
		table.insert(
			cards,
			ui.card(
				{ ui.span(wf.name, "strong"), ui.span(if wf.enabled then "" else "  已停用", "muted") },
				body,
				{
					key = wf.id,
					role = "roost.workflow",
					icon = wf.icon or if wf.enabled then "flow" else "pause",
					meta = meta,
					tone = if wf.enabled then nil else "muted",
				}
			)
		)
	end
	local body: { Node } = { head, editor.templates(st) }
	if #cards == 0 then
		table.insert(body, N("empty", { key = "none", title = "还没有工作流", text = "从模板开始,或新建一个自动化。" }))
	else
		for _, card in cards do
			table.insert(body, card)
		end
	end
	return N("col", { key = "workflows", role = "roost.workflows", gap = "md" }, body)
end

-- ---------------------------------------------------------------------------------------------
-- Events

local function events_tab(st: State): Node
	local c = st.core
	local t = now()
	local rows = {}
	for _, e in c.events do
		local result: any
		if #e.runs > 0 then
			result = { text = `启动 {#e.runs} 个运行`, dot = "success" }
		else
			local why = {}
			for wf, reason in e.reasons do
				table.insert(why, if wf == "*" then reason else `{wf}:{reason}`)
			end
			table.sort(why)
			result = { text = if #why > 0 then why[1] else "无匹配的工作流", dot = "muted", title = table.concat(why, "\n") }
		end
		table.insert(rows, {
			id = `e{e.seq}`,
			cells = { util.ago(e.at, t), e.summary, e.repo or "—", result },
			title = e.url,
		})
	end
	local rs = c.relay.state
	local note = if not rs.configured
		then "中继未配置:只有本机的定时与手动运行。"
		elseif rs.waiting then "workflows.toml 无效,暂停领取中继事件。"
		else `中继游标 {rs.head or "—"} · 最近事件 {util.ago(rs.last_event, t)}`
	return N("col", { key = "events", role = "roost.events", gap = "sm" }, {
		keyed(muted(note), "note"),
		keyed(
			ui.table({
				{ id = "at", head = "时间" },
				{ id = "event", head = "事件", grow = 1, truncate = "end" },
				{ id = "repo", head = "仓库", mono = true, priority = 1 },
				{ id = "result", head = "结果", grow = 1, truncate = "end" },
			}, rows :: any, { selectable = true, empty = "还没有收到中继事件" }),
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
		local started = rfc3339(agent.started_at)
		table.insert(conn, { "中继", `roost-agent {agent.version} · 启动于 {util.ago(started, t)} · boot {agent.boot_id or "—"}` })
	end

	if type(agent.store) == "table" then
		table.insert(conn, { "事件缓存", `{agent.store.count or 0} 条 · 头 {agent.store.head or 0} · 本机游标 {rs.head or "—"}` })
	end
	if type(agent.clients) == "table" and #agent.clients > 0 then
		local names = {}
		for _, cl in agent.clients do
			table.insert(names, `{cl.name or cl.id} ({util.ago(rfc3339(cl.last_seen), t)})`)
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
		N("row", { key = "ops", gap = "xs", align = "center" }, {
			btn("重新加载订阅", "reload_remote", { icon = "repeat", busy = busy.reload == true, key = "reload", title = "让中继重新读取服务器上的 subscriptions.toml" }),
			btn(if rs.restarting then "重启中…" else "重启中继", "restart_remote", {
				icon = "power",
				variant = "danger",
				busy = busy.restart == true or rs.restarting ~= nil,
				key = "restart",
				title = "agent.toml 或二进制更新后,原地重启服务器上的 roost-agent",
			}),
			btn("发送测试事件", "test", { icon = "send", busy = busy.test == true, key = "test" }),
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
	if sync.error then
		table.insert(sub_body, keyed(ui.text({ ui.span(sync.error, "warning") }), "error"))
	end
	local sub_actions: { Node } = {
		btn("推送订阅", "push", { icon = "push", busy = busy.push == true, key = "push" }),
	}
	if sync.state == "conflict" then
		table.insert(sub_actions, btn("以本地覆盖", "force_push", { variant = "danger", key = "force" }))
		table.insert(sub_actions, btn("采用云端", "adopt", { key = "adopt", title = "保留服务器上的订阅,直到本地再次修改" }))
	end
	table.insert(sub_body, N("row", { key = "actions", gap = "xs" }, sub_actions))
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
				muted("roost-agent 以 GitHub App 接收所装仓库的事件(只读权限),不需要个人令牌,也不用逐个仓库配置 webhook。"),
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
		table.insert(app_body, N("row", { key = "actions", gap = "xs" }, {
			btn("创建 GitHub App", "app-create", { key = "create", variant = "primary", icon = "plug", busy = st.app_busy }),
		}))
	else
		table.insert(app_body, ui.kv({
			pair("名称", { ui.span(info.name or "—", "strong"), ui.span(`  {info.slug or ""}`, "mono muted") }),
			pair("所有者", { ui.span(info.owner or "—", "mono"), ui.span(`  {info.owner_type or ""}`, "muted") }),
			pair("已安装", if info.installations then `{info.installations} 个账号或组织` else "—"),
		} :: any))
		table.insert(app_body, N("row", { key = "actions", gap = "xs" }, {
			btn("安装到仓库", "app-install", { key = "install", icon = "plus" }),
			btn("在 GitHub 上管理", "app-manage", { key = "manage", icon = "open" }),
			btn(
				if st.app_confirm then "确认删除本地凭据" else "忘记本地凭据",
				"app-forget",
				{
					key = "forget",
					variant = "danger",
					icon = "trash",
					title = "只删除中继上的 App 凭据;App 本身要到 GitHub 设置里删除,删除后只能重新创建",
				}
			),
		}))
	end
	local app_card = ui.card("GitHub App", app_body, { key = "app", icon = "plug" })

	return N("col", { key = "relay", role = "roost.relay", gap = "md" }, { conn_card, sub_card, app_card })
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
		table.insert(body, N("row", { key = "actions", gap = "xs" }, {
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
		{ "保留运行", tostring(r.keep_runs) },
		pair("PATH 追加", { ui.span(table.concat(r.extra_path, ":"), "mono") }),
	} :: any)
	return N("col", { key = "config", role = "roost.config", gap = "md" }, {
		file_card("config", "roost.toml", p.config, c.config_issues, "有效"),
		file_card("workflows", "workflows.toml", p.workflows, c.workflow_issues, wf_ok),
		ui.card("运行设置", { keyed(runner_kv, "kv") }, { key = "runner", icon = "sliders" }),
		ui.card("外观", {
			keyed(muted("theme.css 放在数据目录中,保存后实时注入,覆盖 roost.css 的样式(钩子:data-role = roost.*)。"), "note"),
			keyed(ui.text({ ui.path(p.theme) }), "path"),
			N("row", { key = "actions", gap = "xs" }, {
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

local function submit_form(st: State)
	local f = st.form
	if not f then
		return
	end
	local inputs: { [string]: string } = {}
	for _, fl in f.fields do
		if fl.required and util.trim(fl.text) == "" then
			f.error = `{fl.label} 是必填项`
			return
		end
		if fl.text ~= "" then
			inputs[fl.name :: string] = fl.text
		end
	end
	local err = core.dispatch(st.core, f.workflow, inputs)
	if err then
		f.error = err
		return
	end
	st.form = nil
	st.cx:frame({ pair("focus", tern.json.null) })
	st.tab = "runs"
	local newest = store.list(st.core.store, 1, f.workflow)[1]
	if newest then
		select_run(st, newest.id)
	end
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
	end
	table.insert(
		children,
		N("row", { key = "foot", justify = "end", gap = "sm" }, {
			btn("取消", "form_cancel", { variant = "quiet", keys = { "esc" }, key = "cancel", size = "md" }),
			btn("运行", "form_submit", { variant = "primary", keys = { "enter" }, key = "submit", size = "md", icon = "play" }),
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
	else
		body = overview(st)
	end
	local main = N("col", { gap = "md" }, {
		header(st),
		N("tabs", { key = "nav", role = "roost.tabs", variant = "segmented", active = st.tab, items = TABS }),
		N("col", { key = "body", gap = "md" }, { body }),
	})
	local dock = N("col", {}, {
		ui.text({
			ui.span("1-6", "key"),
			ui.span(" 切换页面  ", "muted"),
			ui.span("j/k", "key"),
			ui.span(" 选择运行  ", "muted"),
			ui.span("c", "key"),
			ui.span(" 取消  ", "muted"),
			ui.span("r", "key"),
			ui.span(" 重跑", "muted"),
		}),
	})
	return { main = main, dock = dock, layer = editor.view(st) or form_view(st) }
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

local function do_action(st: State, act: string, value: string?, item: string?)
	local c = st.core
	local target = value or item
	if act ~= "app-forget" then
		-- 忘记本地凭据 needs two clicks in a row; anything in between disarms it.
		st.app_confirm = false
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
		elseif #wf.inputs > 0 then
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
	elseif act == "app-install" or act == "app-manage" then
		local info = core.app(c)
		local url = info and (if act == "app-install" then info.install_url else info.html_url)
		if url and url ~= "" then
			st.cx:open(url)
		end
	elseif act == "app-forget" then
		-- The private key can't be fetched again: the first click only arms the button.
		if st.app_confirm then
			st.app_confirm = false
			core.forget_app(c)
		else
			st.app_confirm = true
		end
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
			st.app_confirm = false
		elseif name == "tpl" then
			st.tpl = item
		elseif name == "filter" then
			st.filter = item
		elseif name == "runs" then
			select_run(st, item)
		elseif name == "recent" then
			st.tab = "runs"
			select_run(st, item)
		elseif name == "table" and st.tab == "events" then
			local seq = tonumber(string.match(item, "^e(%d+)$") or "")
			for _, e in st.core.events do
				if e.seq == seq and #e.runs > 0 then
					st.tab = "runs"
					select_run(st, e.runs[1])
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
		if st.form then
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
	end
	return false
end

return M
