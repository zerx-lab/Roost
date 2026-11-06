--!strict
-- Host half: owns the workbench runtime (cron, relay poller, run engine) for the whole daemon,
-- the `roost.console` block that shows and drives it, and the `roost.sessions` sidebar.

local core = require("./lib/core")
local ui = require("./lib/ui")
local sidebar = require("./lib/sidebar")

local C = core.new(tern.plugin.data)
core.start(C)

local function alive(closed: boolean, pane: number, born: number): boolean
	if closed then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	-- `init` can run before the daemon lists the new pane.
	return tern.now() - born < 3000
end

tern.block.define("console", {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, saved: any): ui.State
		local st = ui.new(C, cx, args, saved)
		st.unsubscribe = core.subscribe(C, function()
			if alive(st.closed, st.cx.pane, st.born) then
				ui.refresh(st)
				st.cx:render()
			else
				ui.close(st)
			end
		end)
		return st
	end,
	title = function(st: ui.State): string?
		return ui.title(st)
	end,
	view = function(st: ui.State, cx: BlockCx): BlockView
		st.cx = cx
		return ui.view(st)
	end,
	key = function(st: ui.State, key: Key, cx: BlockCx): boolean?
		st.cx = cx
		return ui.key(st, key)
	end,
	event = function(st: ui.State, ev: UiEvent, cx: BlockCx)
		st.cx = cx
		ui.event(st, ev)
	end,
	resize = function(st: ui.State, cols: number, rows: number, cx: BlockCx)
		st.cx = cx
		ui.resize(st, cols, rows)
	end,
	save = function(st: ui.State): any
		return ui.save(st)
	end,
})

tern.block.define("sessions", {
	font = "sans",
	init = function(cx: BlockCx, _args: { string }, saved: any): sidebar.State
		local st = sidebar.new(C, cx, saved)
		st.unsubscribe = core.subscribe(C, function()
			if alive(st.closed, st.cx.pane, st.born) then
				st.cx:render()
			else
				sidebar.close(st)
			end
		end)
		return st
	end,
	title = function(st: sidebar.State): string?
		return sidebar.title(st)
	end,
	view = function(st: sidebar.State, cx: BlockCx): BlockView
		st.cx = cx
		return sidebar.view(st)
	end,
	key = function(st: sidebar.State, key: Key, cx: BlockCx): boolean?
		st.cx = cx
		return sidebar.key(st, key)
	end,
	event = function(st: sidebar.State, ev: UiEvent, cx: BlockCx)
		st.cx = cx
		sidebar.event(st, ev)
	end,
	save = function(st: sidebar.State): any
		return sidebar.save(st)
	end,
})
