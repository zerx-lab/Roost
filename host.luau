--!strict
-- Host half: owns the workbench runtime (cron, relay poller, run engine) for the whole daemon,
-- and the `roost.console` block that shows and drives it.

local core = require("./lib/core")
local ui = require("./lib/ui")

local C = core.new(tern.plugin.data)
core.start(C)

local function alive(st: ui.State): boolean
	if st.closed then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == st.cx.pane then
			return true
		end
	end
	-- `init` can run before the daemon lists the new pane.
	return tern.now() - st.born < 3000
end

tern.block.define("console", {
	font = "sans",
	init = function(cx: BlockCx, args: { string }, saved: any): ui.State
		local st = ui.new(C, cx, args, saved)
		st.unsubscribe = core.subscribe(C, function()
			if alive(st) then
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
