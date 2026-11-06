--!strict
-- Window half: the palette command that opens the console, a status-line segment fed by the
-- host's `status` kv record, the user's theme.css applied live, and the agent launcher that opens
-- omp steps as agent blocks (lib/launcher.luau) and answers `roost://` links.

local launcher = require("./lib/launcher")

local KIND = "roost.console"
local THEME = tern.plugin.data .. "/theme.css"
local POLL_MS = 2000
local AGENT_MS = 1000
local MAX_THEME = 256 * 1024

local function open(cx: WindowCx)
	local focused = cx.session:focused()
	local here = if focused then cx.session:pane(focused) else nil
	if here and here.block == KIND then
		return
	end
	for _, p in cx.session:panes() do
		if p.block == KIND then
			cx.layout:focus(p.pane)
			return
		end
	end
	if cx:new_block(KIND, {}, "tab") == nil then
		cx:toast("error", "Roost 未就绪", "当前主机没有加载 roost 插件")
	end
end

tern.command({ id = "open", title = "Roost:打开工作台", icon = "flow", run = open })

-- Agent steps: claim and watch on a timer, end turns as soon as Tern reports them.
local L = launcher.new(tern.plugin.data)

local function agent_loop(cx: WindowCx?)
	-- Rescheduled first: a tick that trips the call budget can't run past this point again.
	tern.timer(AGENT_MS, agent_loop)
	if cx then
		local ok, err = pcall(function(): string?
			launcher.tick(L, cx)
			return nil
		end)
		if not ok then
			tern.log.warn("roost: agent tick failed", err)
		end
	end
end
tern.timer(AGENT_MS, agent_loop)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	launcher.on_finished(L, ev, cx)
end)

-- A tab Roost opened was closed (by hand or otherwise): it leaves the registry.
tern.on("pane_closed", function(ev: PaneEvent, _cx: WindowCx)
	local ok, err = pcall(function(): string?
		launcher.on_pane_closed(L, ev)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: pane_closed failed", err)
	end
end)

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if launcher.route(L, cx, link.url) then
		return { handled = true }
	end
	return nil
end)

-- Status segment: what the host last published, read on a timer (formatters must stay cheap).
type Done = { id: string, name: string?, title: string?, state: string? }
type Status = { running: number?, queued: number?, relay: string?, failed: number?, done: { Done }? }
local status: Status = {}
-- Finished runs already toasted (or present when this window VM started: never re-announced).
local announced: { [string]: boolean }? = nil

local STATE_TEXT: { [string]: string } = {
	success = "完成",
	failed = "失败",
	timed_out = "超时",
	cancelled = "已取消",
	interrupted = "中断",
	skipped = "已跳过",
}

-- One toast per newly finished run of a workflow with notify on (status.done).
local function announce(cx: WindowCx?)
	local list: { Done } = status.done or {}
	local seen: { [string]: boolean }? = announced
	if seen == nil then
		-- First look in this VM: what is already listed was announced before a reload.
		local first: { [string]: boolean } = {}
		for _, d in list do
			first[d.id] = true
		end
		announced = first
		return
	end
	if cx == nil then
		-- No window to toast in on this tick: keep them pending for the next one.
		return
	end
	for _, d in list do
		if not seen[d.id] then
			local state = d.state or ""
			local level: ToastLevel = if state == "success" then "success" elseif state == "failed" or state == "timed_out" then "error" else "info"
			cx:toast(level, `Roost:{d.name or "工作流"} {STATE_TEXT[state] or state}`, d.title)
		end
	end
	-- Keep only ids still listed, so the set stays as small as the published list.
	local keep: { [string]: boolean } = {}
	for _, d in list do
		keep[d.id] = true
	end
	announced = keep
end
local status_json = ""

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local running = status.running or 0
	local queued = status.queued or 0
	local text: string
	if running > 0 then
		text = if queued > 0 then `Roost ▶{running} +{queued}` else `Roost ▶{running}`
	elseif status.relay == "down" then
		text = "Roost 中继断开"
	elseif (status.failed or 0) > 0 then
		text = `Roost ✗{status.failed}`
	else
		return nil
	end
	return { { text = text, icon = "flow", command = "plugin.roost.open" } }
end)

-- theme.css in the data directory restyles the console without touching the plugin folder.
local theme = ""

local function poll(cx: WindowCx?)
	local ok, s = pcall(tern.kv.get, "status")
	if ok and type(s) == "table" then
		local enc = tern.json.encode(s)
		if enc ~= status_json then
			status_json = enc
			status = s
			tern.chrome.refresh()
		end
	end
	announce(cx)
	if tern.fs.exists(THEME) then
		local okr, css = pcall(tern.fs.read, THEME, MAX_THEME)
		if okr and css ~= theme then
			theme = css :: string
			local okc, err = pcall(function(): string?
				tern.css("theme", theme)
				return nil
			end)
			if not okc then
				tern.log.warn("roost: theme.css rejected", err)
			end
		end
	elseif theme ~= "" then
		theme = ""
		pcall(tern.css, "theme", "")
	end
	tern.timer(POLL_MS, poll)
end

poll()
