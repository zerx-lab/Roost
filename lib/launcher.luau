--!strict
-- Window side of agent steps (protocol in lib/agent.luau). Every window runs one launcher: it
-- claims the jobs the host lists in kv `agent_jobs` (a `mkdir` claim, so exactly one window opens
-- each), opens each as a native agent block in a new tab of the Roost session, and records how it
-- ended; the block is then closed whatever the result. Any window that knows the pane (from
-- s<i>.pane) may record the end, so a reloaded or second window carries on where another left.
--
-- Also handles the `roost://` links the console and the sidebar open: toggling the sidebar, and
-- showing a step's conversation (its live tab, or the saved session resumed in a new tab).

local agent = require("./agent")

local M = {}

M.SIDEBAR = "roost.sessions"
-- Ticks an agent may be missing from cx.agents:list() before it counts as closed by hand.
local MISSING_TICKS = 3
-- Ticks an agent must look finished (idle, last message from the assistant) before it counts.
local IDLE_TICKS = 2

type Tracked = {
	key: string,
	pane: number,
	files: agent.Files,
	missing: number,
	idle: number,
}

export type Launcher = {
	data: string,
	tracked: { [string]: Tracked },
	claiming: { [string]: boolean },
}

function M.new(data: string): Launcher
	return { data = data, tracked = {}, claiming = {} }
end

local function key_of(run: string, step: number): string
	return `{run}:{step}`
end

local function files_of(L: Launcher, run: string, step: number): agent.Files
	return agent.files(agent.run_dir(L.data, run), step)
end

local function write(path: string, text: string)
	local ok, err = pcall(function(): string?
		tern.fs.write(path, text)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot write", path, err)
	end
end

local function stop_pane(cx: WindowCx, pane: number)
	pcall(function(): string?
		cx.agents:stop(pane)
		return nil
	end)
end

-- Agent blocks by pane, or nil when the list can't be read.
local function agent_map(cx: WindowCx): { [number]: AgentBlock }?
	local ok, list = pcall(function(): { AgentBlock }
		return cx.agents:list()
	end)
	if not ok then
		return nil
	end
	local out: { [number]: AgentBlock } = {}
	for _, a in list :: { AgentBlock } do
		out[a.pane] = a
	end
	return out
end

-- The agent's last assistant message, if it has one.
local function last_reply(cx: WindowCx, pane: number): string?
	local ok, msgs = pcall(function(): { AgentMessage }
		return cx.agents:transcript(pane, { last = 1 })
	end)
	if ok then
		local m = (msgs :: { AgentMessage })[1]
		if m and m.role == "assistant" and type(m.text) == "string" then
			return m.text
		end
	end
	return nil
end

local function untrack(L: Launcher, t: Tracked)
	L.tracked[t.key] = nil
end

-- Records how the step ended (unless something already did), then closes its block.
local function finish(L: Launcher, cx: WindowCx, t: Tracked, code: number, note: string?)
	untrack(L, t)
	if not tern.fs.exists(t.files.exit) then
		local reply = note or last_reply(cx, t.pane)
		if reply then
			write(t.files.reply, string.sub(reply, 1, agent.MAX_REPLY))
		end
		write(t.files.exit, tostring(code))
	end
	stop_pane(cx, t.pane)
end

local function track(L: Launcher, key: string, files: agent.Files, pane: number): Tracked
	local t: Tracked = { key = key, pane = pane, files = files, missing = 0, idle = 0 }
	L.tracked[key] = t
	return t
end

local function local_host_id(cx: WindowCx): number?
	local ok, hosts = pcall(function(): { ManagedHost }
		return cx.hosts:list()
	end)
	if ok then
		for _, h in hosts :: { ManagedHost } do
			if h.kind == "local" then
				return h.id
			end
		end
	end
	return nil
end

-- The local session named `name`, created (then the shown session restored) when missing.
local function roost_session(cx: WindowCx, name: string, cwd: string): number?
	local host = local_host_id(cx)
	local ok, id = pcall(function(): number?
		for _, s in cx.sessions:list() do
			if s.name == name and s.host == host then
				return s.id
			end
		end
		local shown = cx.sessions:current()
		local created = cx.sessions:create({ name = name, cwd = cwd })
		cx.sessions:switch(shown.id)
		return created.id
	end)
	if not ok then
		tern.log.warn("roost: cannot find or create session", name, id)
		return nil
	end
	return id :: number?
end

local function name_tab(cx: WindowCx, pane: number, title: string)
	pcall(function(): string?
		local tab = cx.session:tab_of(pane)
		if tab then
			cx.layout:name_tab(tab, title)
		end
		return nil
	end)
end

-- What the host's list says of `key` now: "run", "stop", "gone", or nil when kv can't be read.
local function listing(key: string): string?
	local ok, v = pcall(tern.kv.get, agent.KV)
	if not ok then
		return nil
	end
	if type(v) == "table" then
		for _, j in v do
			if type(j) == "table" and type(j.run) == "string" and type(j.step) == "number" and key_of(j.run, j.step) == key then
				return if j.stop == true then "stop" else "run"
			end
		end
	end
	return "gone"
end

-- Opens a claimed job as an agent block in a new tab of its session, leaving focus where it was.
local function launch(L: Launcher, cx: WindowCx, key: string, files: agent.Files)
	if tern.fs.exists(files.exit) then
		return
	end
	local state = listing(key)
	if state == "gone" then
		return
	elseif state == "stop" then
		-- Cancelled or timed out between the claim and now: nothing to open.
		write(files.exit, tostring(agent.CODE.stopped))
		return
	end
	local job = agent.read_job(files.job)
	if not job then
		write(files.reply, "[roost] 读不到 agent 任务文件")
		write(files.exit, tostring(agent.CODE.launch))
		return
	end
	local current_ok, current = pcall(function(): ManagedHost
		return cx.hosts:current()
	end)
	if not current_ok or (current :: ManagedHost).kind ~= "local" then
		-- This window shows another machine: let go, so a later tick (or another window) takes it.
		pcall(tern.fs.remove, files.claim)
		return
	end
	local focused = cx.session:focused()
	local sid = roost_session(cx, job.session, job.cwd)
	local ok, res = pcall(function(): number
		return cx.agents:start({ prompt = job.prompt, cwd = job.cwd, command = job.command, how = "tab" })
	end)
	if not ok then
		write(files.reply, `[roost] 无法打开 agent:{res}`)
		write(files.exit, tostring(agent.CODE.launch))
		return
	end
	local pane = res :: number
	write(files.pane, tostring(pane))
	local t = track(L, key, files, pane)
	local shown_ok, shown = pcall(function(): ManagedSession
		return cx.sessions:current()
	end)
	local tab: number? = nil
	if sid and not (shown_ok and (shown :: ManagedSession).id == sid) then
		local moved_ok, moved, why = pcall(function(): (number?, string?)
			return cx.layout:move_to_new_tab(pane, sid, { focus = false })
		end)
		if moved_ok and moved then
			tab = moved
		else
			tern.log.warn("roost: agent stays in the shown session", if moved_ok then why else moved)
		end
	end
	if tab then
		pcall(function(): string?
			cx.layout:name_tab(tab :: number, job.title)
			return nil
		end)
	else
		name_tab(cx, pane, job.title)
	end
	if focused then
		pcall(function(): string?
			cx.layout:focus(focused)
			return nil
		end)
	end
	if tern.fs.exists(files.exit) then
		-- The host gave up on the step while we were opening it.
		untrack(L, t)
		stop_pane(cx, pane)
	end
end

local function claim(L: Launcher, key: string, files: agent.Files)
	L.claiming[key] = true
	local ok, err = pcall(function(): string?
		tern.process.run({ "/bin/mkdir", files.claim }, { timeout_ms = 5000 }, function(res: ProcessResult, cx: WindowCx?)
			L.claiming[key] = nil
			-- A failed mkdir means another window (or an earlier VM) holds the claim.
			if res.status == 0 and not res.timed_out and cx then
				launch(L, cx, key, files)
			end
		end)
		return nil
	end)
	if not ok then
		L.claiming[key] = nil
		tern.log.warn("roost: cannot claim agent job", err)
	end
end

-- Whether the agent's turn is over: idle with the assistant's message last.
local function settled(cx: WindowCx, t: Tracked, info: AgentBlock): boolean
	if info.state ~= "idle" or last_reply(cx, t.pane) == nil then
		t.idle = 0
		return false
	end
	t.idle += 1
	return t.idle >= IDLE_TICKS
end

-- One pass over the host's job list: claim new jobs, adopt known panes, stop what the host
-- stopped, and notice agents that finished, exited or were closed.
function M.tick(L: Launcher, cx: WindowCx)
	local ok, v = pcall(tern.kv.get, agent.KV)
	if not ok then
		return
	end
	local jobs: { any } = if type(v) == "table" then v else {}
	local listed: { [string]: boolean } = {}
	local agents: { [number]: AgentBlock }? = nil
	local looked = false
	for _, j in jobs do
		if type(j) ~= "table" or type(j.run) ~= "string" or type(j.step) ~= "number" then
			continue
		end
		local key = key_of(j.run, j.step)
		listed[key] = true
		local files = files_of(L, j.run, j.step)
		local t = L.tracked[key]
		if tern.fs.exists(files.exit) then
			if t then
				untrack(L, t)
				stop_pane(cx, t.pane)
			end
			continue
		end
		if t == nil then
			local pane = agent.read_number(files.pane)
			if pane then
				t = track(L, key, files, pane)
			elseif not L.claiming[key] and not tern.fs.exists(files.claim) and not j.stop then
				claim(L, key, files)
			end
		end
		if t == nil then
			continue
		end
		local tr = t :: Tracked
		if j.stop == true then
			finish(L, cx, tr, agent.CODE.stopped)
			continue
		end
		if not looked then
			agents = agent_map(cx)
			looked = true
		end
		if agents == nil then
			continue
		end
		local info = (agents :: { [number]: AgentBlock })[tr.pane]
		if info == nil then
			tr.missing += 1
			if tr.missing >= MISSING_TICKS then
				finish(L, cx, tr, agent.CODE.closed)
			end
		elseif info.state == "exited" then
			finish(L, cx, tr, agent.CODE.failed)
		else
			tr.missing = 0
			if settled(cx, tr, info) then
				finish(L, cx, tr, agent.CODE.done)
			end
		end
	end
	-- Steps the host no longer lists have ended: their agents go too.
	for key, t in table.clone(L.tracked) do
		if not listed[key] then
			untrack(L, t)
			stop_pane(cx, t.pane)
		end
	end
end

local RESULT_CODE: { [string]: number } = {
	done = agent.CODE.done,
	failed = agent.CODE.failed,
	exited = agent.CODE.failed,
	closed = agent.CODE.closed,
}

-- `agent_finished`: the turn of a tracked agent ended, or the agent did.
function M.on_finished(L: Launcher, ev: AgentFinishedEvent, cx: WindowCx)
	for _, t in table.clone(L.tracked) do
		if t.pane == ev.pane then
			finish(L, cx, t, RESULT_CODE[ev.result] or agent.CODE.failed)
			return
		end
	end
end

-- Opens the sessions sidebar at the left of the focused block, or closes the one this tab has.
function M.toggle_sidebar(cx: WindowCx)
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	for _, p in cx.session:panes() do
		if p.block == M.SIDEBAR and tab and p.tab == tab then
			cx.layout:close(p.pane)
			return
		end
	end
	local opts: BlockOpts = { dir = "left", ratio = 0.22, focus = false }
	if focused then
		opts.target = focused
	end
	if cx:new_block(M.SIDEBAR, {}, "beside", opts) == nil then
		cx:toast("error", "Roost 未就绪", "当前主机没有加载 roost 插件")
	end
end

-- The session a pane belongs to, from the window's session list.
local function session_of(cx: WindowCx, pane: number): number?
	local tab = cx.session:tab_of(pane)
	if tab == nil then
		return nil
	end
	for _, s in cx.session:sessions() do
		for _, id in s.tabs do
			if id == tab then
				return s.id
			end
		end
	end
	return nil
end

-- Shows step `step` of run `run`: its agent while it runs, else its saved conversation resumed
-- in a new tab of the shown session.
local function show_session(L: Launcher, cx: WindowCx, run: string, step: number)
	local files = files_of(L, run, step)
	local pane = agent.read_number(files.pane)
	if pane and not tern.fs.exists(files.exit) then
		local agents = agent_map(cx)
		if agents and agents[pane] then
			local sid = session_of(cx, pane)
			if sid then
				cx.sessions:switch(sid)
			end
			cx.layout:focus(pane)
			return
		end
	end
	local file = agent.session_file(files.session)
	local job = agent.read_job(files.job)
	if file == nil or job == nil then
		cx:toast("info", "这一步没有保存的 omp 会话", "可能还没开始,或 omp 没有写入会话文件")
		return
	end
	local j = job :: agent.Job
	local cwd = if tern.fs.exists(j.cwd) then j.cwd else (tern.getenv("HOME") or "/")
	local opened = cx.layout:new_tab({ cwd = cwd, command = agent.resume_command(j.omp, files.session, file :: string) })
	if opened then
		name_tab(cx, opened, `↺ {j.title}`)
	end
end

-- `tern.route.link` for `roost://` links; false when the link isn't one.
function M.route(L: Launcher, cx: WindowCx, url: string): boolean
	local r = agent.parse_url(url)
	if r == nil then
		return false
	end
	local ok, err = pcall(function(): string?
		if r.kind == "sidebar" then
			M.toggle_sidebar(cx)
		elseif r.kind == "session" then
			show_session(L, cx, r.run, r.step)
		end
		return nil
	end)
	if not ok then
		cx:toast("error", "Roost 无法打开会话", tostring(err))
	end
	return true
end

return M
