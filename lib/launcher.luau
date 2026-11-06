--!strict
-- Window side of agent steps (protocol in lib/agent.luau) and tab steps (lib/tabs.luau). Every
-- window runs one launcher: it claims the jobs the host lists in kv `agent_jobs` (a `mkdir` claim,
-- so exactly one window opens each), opens each as a native agent block in a new tab of the Roost
-- session, and records how it ended; the block is then closed whatever the result. Any window that
-- knows the pane (from s<i>.pane) may record the end, so a reloaded or second window carries on
-- where another left. Tab operations (kv `tab_ops`) are claimed the same way and carried out at
-- once; the tabs they open are recorded so only those are ever closed.
--
-- Also handles the `roost://` links the console opens: a step's conversation (its live tab, or
-- the saved session resumed in a split beside the console) and a run's log (in a glimpse).

local agent = require("./agent")
local tabs = require("./tabs")

local M = {}

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
	tab_claiming: { [string]: boolean },
	swept: boolean, -- the tab registry was checked against this window's panes
	sweep: { list: { string }, at: number }?, -- that check, while it runs a slice per tick
	index: { [number]: string }, -- pane → registry entry, for the tabs this window knows of
}

function M.new(data: string): Launcher
	return { data = data, tracked = {}, claiming = {}, tab_claiming = {}, swept = false, sweep = nil, index = {} }
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
	M.tab_tick(L, cx)
end

-- ---------------------------------------------------------------------------------------------
-- Tab operations

local function is_local(cx: WindowCx): boolean
	local ok, cur = pcall(function(): ManagedHost
		return cx.hosts:current()
	end)
	return ok and (cur :: ManagedHost).kind == "local"
end

local function pane_info(cx: WindowCx, pane: number): PaneInfo?
	local ok, info = pcall(function(): PaneInfo?
		return cx.session:pane(pane)
	end)
	return if ok then info :: PaneInfo? else nil
end

local function forget(L: Launcher, path: string, pane: number?)
	pcall(tern.fs.remove, path)
	if pane and L.index[pane] == path then
		L.index[pane] = nil
	end
end

-- Closes the tab an entry records, if its pane is still the one Roost opened; the entry goes either
-- way (after the close, so a reload in between leaves it recorded). Returns what happened.
local function close_entry(L: Launcher, cx: WindowCx, path: string, e: tabs.Entry): string
	local info = pane_info(cx, e.pane)
	if info == nil then
		forget(L, path, e.pane)
		return `标签页「{e.key}」已经不在了`
	elseif info.kind ~= e.kind then
		forget(L, path, e.pane)
		return `标签页「{e.key}」记录的 pane 已不是 Roost 打开的那个,没有关闭`
	end
	cx.layout:close(e.pane)
	forget(L, path, e.pane)
	return `已关闭标签页「{e.key}」`
end

-- Entries checked against this window's panes per tick, so the first look stays within budget.
local SWEEP_SLICE = 20

-- The first ticks of a window: drops registry entries whose pane is gone, or now names another
-- kind of block, and indexes the rest by pane (for pane_closed). A slice per call.
local function sweep_entries(L: Launcher, cx: WindowCx)
	if L.sweep == nil then
		L.sweep = { list = tabs.entries(L.data), at = 1 }
	end
	local sw = L.sweep :: { list: { string }, at: number }
	local stop = math.min(#sw.list, sw.at + SWEEP_SLICE - 1)
	for k = sw.at, stop do
		local path = sw.list[k]
		local e = tabs.read_entry(path)
		local info = if e then pane_info(cx, e.pane) else nil
		if e == nil or info == nil or info.kind ~= e.kind then
			pcall(tern.fs.remove, path)
		else
			L.index[e.pane] = path
		end
	end
	sw.at = stop + 1
	if sw.at > #sw.list then
		L.swept = true
		L.sweep = nil
	end
end

local function home(): string
	return tern.getenv("HOME") or "/"
end

local function open_tab(L: Launcher, cx: WindowCx, op: tabs.Op): tabs.Result
	local path = tabs.entry_path(L.data, op.workflow, op.key)
	local old = tabs.read_entry(path)
	local replaced = ""
	if old then
		replaced = close_entry(L, cx, path, old) .. ";"
	end
	if #tabs.entries(L.data) >= tabs.MAX_ENTRIES then
		return { ok = false, message = `Roost 记录的标签页已达 {tabs.MAX_ENTRIES} 个,先关闭一些` }
	end
	local cwd = if op.cwd and tern.fs.exists(op.cwd) then op.cwd else home()
	local focused = cx.session:focused()
	local pane = cx.layout:new_tab({ cwd = cwd, command = op.command }, { focus = op.focus == true })
	if pane == nil then
		return { ok = false, message = `{replaced}无法打开标签页「{op.key}」` }
	end
	local where = "当前会话"
	local tab: number? = nil
	if not op.focus then
		-- In the background: the Roost session, with focus left where it was.
		local sid = roost_session(cx, op.session, cwd)
		local shown_ok, shown = pcall(function(): ManagedSession
			return cx.sessions:current()
		end)
		if sid and not (shown_ok and (shown :: ManagedSession).id == sid) then
			local moved_ok, moved, _why = pcall(function(): (number?, string?)
				return cx.layout:move_to_new_tab(pane, sid, { focus = false })
			end)
			if moved_ok and moved then
				tab = moved :: number
				where = `会话「{op.session}」`
			end
		elseif sid then
			where = `会话「{op.session}」`
		end
		if focused then
			pcall(function(): string?
				cx.layout:focus(focused)
				return nil
			end)
		end
	end
	local title = op.title or op.key
	if tab then
		pcall(function(): string?
			cx.layout:name_tab(tab :: number, title)
			return nil
		end)
	else
		name_tab(cx, pane, title)
	end
	local info = pane_info(cx, pane)
	local err = tabs.write_entry(L.data, {
		workflow = op.workflow,
		key = op.key,
		pane = pane,
		kind = if info and info.kind then info.kind else "terminal",
		run = op.run,
		keep = op.keep == true,
		at = os.time(),
	})
	if err then
		-- Unrecorded, it could never be closed by Roost: don't leave it open.
		cx.layout:close(pane)
		return { ok = false, message = `{replaced}无法记录标签页,已关掉它:{err}` }
	end
	L.index[pane] = path
	return { ok = true, message = `{replaced}已在{where}打开标签页「{title}」`, pane = pane }
end

local function close_tab(L: Launcher, cx: WindowCx, op: tabs.Op): tabs.Result
	local path = tabs.entry_path(L.data, op.workflow, op.key)
	local e = tabs.read_entry(path)
	if e == nil then
		return { ok = true, message = `没有打开的标签页「{op.key}」` }
	elseif op.only_run and (e.run ~= op.run or e.keep) then
		-- A run-end close: the tab was taken over by a later run, or reopened to stay.
		return { ok = true, message = `标签页「{op.key}」已由后来的运行或保留的步骤接管,保留` }
	end
	return { ok = true, message = close_entry(L, cx, path, e :: tabs.Entry) }
end

local function carry_out(L: Launcher, cx: WindowCx, id: string)
	local p = tabs.paths(L.data, id)
	local op = tabs.read_op(p.op)
	if op == nil then
		-- The host withdrew it meanwhile.
		pcall(tern.fs.remove, p.claim)
		return
	end
	local o = op :: tabs.Op
	if not (string.match(o.workflow, "^[%w_%-]+$") and string.match(o.key, "^[%w_%-]+$")) then
		tabs.write_result(p.done, { ok = false, message = "标签页操作的工作流或键无效" })
		return
	end
	local ok, res = pcall(function(): tabs.Result
		return if o.action == "open" then open_tab(L, cx, o) else close_tab(L, cx, o)
	end)
	tabs.write_result(p.done, if ok then res :: tabs.Result else { ok = false, message = `标签页操作失败:{res}` })
end

local function claim_tab(L: Launcher, id: string, claim: string)
	L.tab_claiming[id] = true
	local ok, err = pcall(function(): string?
		tern.process.run({ "/bin/mkdir", claim }, { timeout_ms = 5000 }, function(res: ProcessResult, cx: WindowCx?)
			L.tab_claiming[id] = nil
			if res.status == 0 and not res.timed_out then
				if cx and is_local(cx) then
					carry_out(L, cx, id)
				else
					-- Nowhere to carry it out: let go, so a later tick (or another window) takes it.
					pcall(tern.fs.remove, claim)
				end
			end
		end)
		return nil
	end)
	if not ok then
		L.tab_claiming[id] = nil
		tern.log.warn("roost: cannot claim tab operation", err)
	end
end

-- One pass over kv `tab_ops`: claims the operations nobody took yet. Only a window showing this
-- machine takes them (it sees the panes Roost opened here).
function M.tab_tick(L: Launcher, cx: WindowCx)
	if not is_local(cx) then
		return
	end
	if not L.swept then
		sweep_entries(L, cx)
	end
	local ok, v = pcall(tern.kv.get, tabs.KV)
	if not ok or type(v) ~= "table" then
		return
	end
	for _, id in v do
		if type(id) == "string" and tabs.valid_id(id) and not L.tab_claiming[id] then
			local p = tabs.paths(L.data, id)
			if tern.fs.exists(p.op) and not tern.fs.exists(p.done) and not tern.fs.exists(p.claim) then
				claim_tab(L, id, p.claim)
			end
		end
	end
end

-- `pane_closed`: a tab this window recorded (or found in its first sweep) was closed by hand or
-- otherwise; forget it. Entries other windows recorded are dropped by them, or when a close
-- finds their pane gone.
function M.on_pane_closed(L: Launcher, ev: PaneEvent)
	local path = L.index[ev.pane]
	if path then
		L.index[ev.pane] = nil
		-- Another window may have reopened the key under a new pane since: only this pane's record goes.
		local e = tabs.read_entry(path)
		if e and e.pane == ev.pane then
			pcall(tern.fs.remove, path)
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

-- Shows step `step` of run `run`: its agent while it runs (in its own tab: moving it out would
-- tie the step to a pane the user closes at will), else its saved conversation resumed in a
-- split beside `over` (the console the link came from).
local function show_session(L: Launcher, cx: WindowCx, run: string, step: number, over: number?)
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
	local launch = { cwd = cwd, command = agent.resume_command(j.omp, files.session, file :: string) }
	local target = over or cx.session:focused()
	local opened = if target then cx.layout:split(target, "right", launch, { focus = true }) else nil
	if opened == nil then
		-- Nothing to split: a tab of its own.
		local tabbed = cx.layout:new_tab(launch)
		if tabbed then
			name_tab(cx, tabbed, `↺ {j.title}`)
		end
	end
end

-- Shows run `run`'s log in a glimpse: over the whole tab until the next click outside it.
local function show_log(L: Launcher, cx: WindowCx, run: string)
	local path = `{agent.run_dir(L.data, run)}/log.txt`
	if not tern.fs.exists(path) then
		cx:toast("info", "这条运行还没有日志")
		return
	end
	cx:open(path, "glimpse")
end

-- `tern.route.link` for `roost://` links; false when the link isn't one.
function M.route(L: Launcher, cx: WindowCx, link: LinkRequest): boolean
	local r = agent.parse_url(link.url)
	if r == nil then
		return false
	end
	local ok, err = pcall(function(): string?
		if r.step then
			show_session(L, cx, r.run, r.step, link.pane)
		else
			show_log(L, cx, r.run)
		end
		return nil
	end)
	if not ok then
		cx:toast("error", if r.step then "Roost 无法打开会话" else "Roost 无法打开日志", tostring(err))
	end
	return true
end

return M
