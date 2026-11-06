--!strict
-- The `roost.sessions` block: the omp agent sessions Roost ran, newest first, sized for a left
-- split. Activating a row (double-click, Enter, or the row menu) hands `roost://session/<run>/<i>`
-- to the window, which focuses the live agent or resumes the saved conversation in a new tab.
-- The sessions live in each run's directory and go when keep_runs prunes the run.
--
-- Theming: data-role `roost.sessions`.

local core = require("./core")
local store = require("./store")
local agent = require("./agent")
local util = require("./util")

local ui = tern.ui
local N = ui.node

local M = {}

local MAX_ROWS = 300

export type State = {
	core: core.Core,
	cx: BlockCx,
	born: number,
	closed: boolean,
	unsubscribe: (() -> ())?,
	selected: string?,
}

export type Row = { id: string, run: store.Run, step: number }

local STATE_LABEL: { [string]: string } = {
	running = "运行中",
	success = "完成",
	failed = "失败",
}
local STATE_TONE: { [string]: string } = {
	running = "accent",
	success = "success",
	failed = "error",
}

-- Every step that ran as an agent, newest run first; a run's steps in order.
function M.rows(c: core.Core): { Row }
	local out: { Row } = {}
	for _, r in store.list(c.store, c.store.keep, nil) do
		for i, s in r.steps do
			if s.agent then
				table.insert(out, { id = `{r.id}:{i}`, run = r, step = i })
				if #out >= MAX_ROWS then
					return out
				end
			end
		end
	end
	return out
end

function M.new(c: core.Core, cx: BlockCx, saved: any): State
	local s: { [string]: any } = if type(saved) == "table" then saved else {}
	return {
		core = c,
		cx = cx,
		born = tern.now(),
		closed = false,
		unsubscribe = nil,
		selected = if type(s.selected) == "string" then s.selected else nil,
	}
end

function M.close(st: State)
	if st.closed then
		return
	end
	st.closed = true
	if st.unsubscribe then
		st.unsubscribe()
		st.unsubscribe = nil
	end
end

function M.save(st: State): any
	return { selected = st.selected }
end

function M.title(_st: State): string?
	return "Roost 会话"
end

local function keyed(node: Node, key: string): Node
	local p: { [string]: any } = node.p or {}
	p.key = key
	node.p = p
	return node
end

function M.view(st: State): BlockView
	local t = core.clock()
	local rows: { any } = {}
	local running = 0
	for _, row in M.rows(st.core) do
		local r, s = row.run, row.run.steps[row.step]
		if s.state == "running" then
			running += 1
		end
		table.insert(rows, {
			id = row.id,
			cells = {
				{ badge = { text = STATE_LABEL[s.state] or s.state, tone = STATE_TONE[s.state] or "muted" } } :: any,
				`{r.workflow_name} · {s.name}`,
				util.ago(s.started_at, t),
			},
			title = r.title,
			menu = { "open" },
		})
	end
	local head = { ui.span("Roost 会话", "strong") }
	if running > 0 then
		table.insert(head, ui.span(`  {running} 运行中`, "accent"))
	end
	local main = N("col", { key = "sessions", role = "roost.sessions", gap = "sm" }, {
		keyed(ui.text(head), "head"),
		keyed(
			ui.table({
				{ id = "state", head = "状态" },
				{ id = "name", head = "会话", grow = 1, truncate = "end" },
				{ id = "at", head = "开始", align = "end", priority = 1 },
			}, rows, { selectable = true, selected = st.selected, empty = "还没有 omp 会话" }),
			"list"
		),
	})
	local dock = N("col", {}, {
		ui.text({ ui.span("Enter", "key"), ui.span(" / 双击 打开:运行中的跳到其标签页,已结束的续开会话", "muted") }),
	})
	return { main = main, dock = dock }
end

local function open(st: State, id: string)
	local run, step = string.match(id, "^(%x+):(%d+)$")
	if run and step then
		st.cx:open(agent.session_url(run, tonumber(step) :: number))
	end
end

function M.event(st: State, ev: UiEvent)
	local item = ev.item
	if type(item) ~= "string" then
		return
	end
	if ev.ev == "select" then
		st.selected = item
	elseif ev.ev == "activate" then
		st.selected = item
		open(st, item)
	elseif ev.ev == "action" and ev.act == "open" then
		open(st, item)
	end
end

local function move(st: State, delta: number): boolean
	local rows = M.rows(st.core)
	if #rows == 0 then
		return false
	end
	local idx = 0
	for i, row in rows do
		if row.id == st.selected then
			idx = i
			break
		end
	end
	local nxt = if idx == 0 then 1 else math.clamp(idx + delta, 1, #rows)
	if rows[nxt].id == st.selected then
		return false
	end
	st.selected = rows[nxt].id
	return true
end

function M.key(st: State, key: Key): boolean?
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if key.name == "j" or key.name == "down" then
		return move(st, 1)
	elseif key.name == "k" or key.name == "up" then
		return move(st, -1)
	elseif key.name == "enter" and st.selected then
		open(st, st.selected)
		return true
	end
	return false
end

return M
