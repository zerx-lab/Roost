--!strict
-- Window half: the palette command that opens the console, a status-line segment fed by the
-- host's `status` kv record, and the user's theme.css applied live.

local KIND = "roost.console"
local THEME = tern.plugin.data .. "/theme.css"
local POLL_MS = 2000
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

-- Status segment: what the host last published, read on a timer (formatters must stay cheap).
type Status = { running: number?, queued: number?, relay: string?, failed: number? }
local status: Status = {}
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

local function poll()
	local ok, s = pcall(tern.kv.get, "status")
	if ok and type(s) == "table" then
		local enc = tern.json.encode(s)
		if enc ~= status_json then
			status_json = enc
			status = s
			tern.chrome.refresh()
		end
	end
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
