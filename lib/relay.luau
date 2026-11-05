--!strict
-- The relay agent client: long-polls relayed GitHub events, keeps the agent's subscriptions in
-- line with the local workflows (local first; on failure the UI offers the manual fallback), and
-- runs remote operations (reload, restart, hook sync, test event).
--
-- Persistent client state lives in tern.kv, keyed by relay URL so pointing at another agent
-- starts clean: `cursor` = { url, store_id, seq }, `subs` = { url, rev, fp }.

local util = require("./util")

local M = {}

local POLL_WAIT = 25
local POLL_TIMEOUT_MS = 40000
local STATUS_EVERY_MS = 20000
local MAX_BACKOFF = 60
local NOT_READY_RETRY = 3

export type Cfg = { url: string?, token: string?, client_name: string? }

export type Sync = {
	state: string, -- idle | pushing | ok | conflict | invalid | offline | unconfigured
	at: number?,
	revision: string?,
	error: string?,
	issues: { any }?,
	remote_text: string?,
	-- The conflict comes from an edit on the server's disk that isn't reloaded yet.
	unreloaded: boolean?,
}

export type State = {
	configured: boolean,
	connected: boolean,
	error: string?,
	last_ok: number?,
	last_event: number?,
	head: number?,
	store_id: string?,
	gap_at: number?,
	reset_at: number?,
	agent: { [string]: any }?, -- last /status answer
	agent_at: number?,
	sync: Sync,
	restarting: { from: string, since: number }?,
	busy: { [string]: boolean? },
	last_test: number?,
	waiting: boolean, -- polling paused until a valid workflows.toml loads
}

export type Subs = { [string]: { events: { string }, hook: boolean } }

export type Handlers = {
	-- Handles one relayed event; errors are caught and logged.
	event: (e: { [string]: any }) -> (),
	changed: () -> (),
	now: () -> number,
	client_id: string,
	-- Whether events can be consumed now (a valid workflows.toml is loaded).
	ready: () -> boolean,
	-- The current local subscriptions (nil when no valid workflows.toml).
	subs: () -> Subs?,
}

export type Relay = {
	cfg: Cfg,
	gen: number,
	backoff: number,
	poll_timer: any?,
	status_timer: any?,
	state: State,
	h: Handlers,
	push_again: { force: boolean }?,
}

function M.new(h: Handlers): Relay
	return {
		cfg = {},
		gen = 0,
		backoff = 2,
		poll_timer = nil,
		status_timer = nil,
		h = h,
		push_again = nil,
		state = {
			configured = false,
			connected = false,
			sync = { state = "unconfigured" },
			busy = {},
			waiting = false,
		},
	}
end

local function kv_get(key: string): any
	local ok, v = pcall(tern.kv.get, key)
	return if ok then v else nil
end

local function kv_set(key: string, v: any)
	pcall(tern.kv.set, key, v)
end

-- The kv record `key` when it belongs to the configured relay URL.
local function mine(r: Relay, key: string): { [string]: any }?
	local v = kv_get(key)
	if type(v) == "table" and v.url == r.cfg.url then
		return v
	end
	return nil
end

local function describe(res: FetchResult, body: any): string
	if res.error then
		return if res.timed_out then "连接超时" else `无法连接:{res.error}`
	end
	if res.status == 401 then
		return "令牌被拒绝(检查 roost.toml 的 relay.token 与服务器 agent.toml 的 [auth].token)"
	end
	local msg = if type(body) == "table" and type(body.error) == "string" then body.error else nil
	return `HTTP {res.status}{if msg then ":" .. msg else ""}`
end

-- One admin API call. `cb(ok, status, body, err)`; body is decoded JSON or nil.
function M.request(
	r: Relay,
	method: string,
	path: string,
	body: any,
	timeout_ms: number,
	cb: (boolean, number, any, string?) -> ()
)
	local url, token = r.cfg.url, r.cfg.token
	if not url or not token then
		cb(false, 0, nil, "未配置中继:在 roost.toml 的 [relay] 填写 url 与 token")
		return
	end
	local headers: { [string]: string } = {
		Authorization = `Bearer {token}`,
		["X-Roost-Client"] = r.h.client_id,
		["Content-Type"] = "application/json",
	}
	if r.cfg.client_name then
		headers["X-Roost-Client-Name"] = r.cfg.client_name
	end
	local opts: FetchOptions = { method = method, headers = headers, timeout_ms = timeout_ms }
	if body ~= nil then
		opts.body = tern.json.encode(body)
	end
	local ok, err = pcall(function(): string?
		tern.fetch(url .. path, opts, function(res)
			local decoded: any = nil
			if res.body ~= "" then
				local okd, v = pcall(tern.json.decode, res.body)
				decoded = if okd then v else nil
			end
			local good = res.error == nil and res.status >= 200 and res.status < 300
			cb(good, res.status, decoded, if good then nil else describe(res, decoded))
		end)
		return nil
	end)
	if not ok then
		cb(false, 0, nil, `请求无效:{err}`)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Subscriptions

-- Canonical JSON body of subscriptions (sorted, arrays tagged), for sending.
function M.encode_subs(subs: Subs): { [string]: any }
	local out: { [string]: any } = {}
	for _, name in util.keys(subs) do
		local s = subs[name]
		local evs = table.clone(s.events)
		table.sort(evs)
		out[name] = { events = tern.json.array(evs), hook = s.hook }
	end
	return out
end

function M.fingerprint(subs: Subs): string
	local parts = {}
	for _, name in util.keys(subs) do
		local s = subs[name]
		local evs = table.clone(s.events)
		table.sort(evs)
		table.insert(parts, `{string.lower(name)}={table.concat(evs, ",")}:{tostring(s.hook)}`)
	end
	return table.concat(parts, ";")
end

-- Whether `subs` differ from what was last pushed to (or adopted from) this relay.
function M.needs_push(r: Relay, subs: Subs): boolean
	local s = mine(r, "subs")
	return s == nil or s.fp ~= M.fingerprint(subs)
end

-- Pushes `subs`; `force` overwrites a server-side change instead of reporting a conflict. A push
-- requested while one is in flight runs right after it, with the subscriptions current then.
function M.push_subs(r: Relay, subs: Subs, force: boolean)
	local st = r.state
	if not st.configured then
		st.sync = { state = "unconfigured" }
		r.h.changed()
		return
	end
	if st.busy.push then
		r.push_again = { force = force or (r.push_again ~= nil and r.push_again.force) }
		return
	end
	st.busy.push = true
	st.sync = { state = "pushing", at = r.h.now(), revision = st.sync.revision }
	r.h.changed()
	local body: { [string]: any } = { repos = M.encode_subs(subs) }
	local saved = mine(r, "subs")
	if not force and saved and type(saved.rev) == "string" then
		body.base_revision = saved.rev
	end
	local fp = M.fingerprint(subs)
	local gen, url = r.gen, r.cfg.url
	M.request(r, "PUT", "/api/v1/subscriptions", body, 20000, function(ok, status, resp, err)
		if gen ~= r.gen then
			return
		end
		st.busy.push = nil
		local t = r.h.now()
		if ok and type(resp) == "table" then
			kv_set("subs", { url = url, rev = resp.revision, fp = fp })
			st.sync = { state = "ok", at = t, revision = resp.revision }
			M.refresh_status(r)
		elseif status == 409 and type(resp) == "table" then
			st.sync = {
				state = "conflict",
				at = t,
				revision = resp.revision,
				remote_text = resp.text,
				unreloaded = resp.unreloaded == true,
				error = resp.error or "服务器上的订阅被手动改过",
			}
		elseif status == 422 and type(resp) == "table" then
			st.sync = { state = "invalid", at = t, issues = resp.issues, error = "服务器拒绝了订阅" }
		else
			st.sync = { state = "offline", at = t, error = err }
		end
		r.h.changed()
		local again = r.push_again
		r.push_again = nil
		if again and st.sync.state ~= "conflict" then
			local cur = r.h.subs()
			if cur and (again.force or M.needs_push(r, cur)) then
				M.push_subs(r, cur, again.force)
			end
		end
	end)
end

-- Pushes the current local subscriptions when they differ from the last push to this relay.
function M.sync(r: Relay, force: boolean)
	local subs = r.h.subs()
	if subs == nil or not r.state.configured then
		return
	end
	if force or M.needs_push(r, subs) then
		M.push_subs(r, subs, force)
	end
end

-- Keeps the server's subscriptions after a conflict: they become the base, and the current local
-- subscriptions count as pushed until they change. An edit that is only on the server's disk is
-- applied (remote reload) first, so the kept version is the one the agent actually uses.
function M.adopt_remote(r: Relay)
	local st = r.state
	local subs = r.h.subs()
	if st.sync.state ~= "conflict" or subs == nil then
		return
	end
	local fp = M.fingerprint(subs :: Subs)
	local url = r.cfg.url
	local function keep(rev: string)
		kv_set("subs", { url = url, rev = rev, fp = fp })
		st.sync = { state = "idle", at = r.h.now(), revision = rev }
		r.h.changed()
	end
	if st.sync.unreloaded then
		M.reload_remote(r, function(ok, msg, body)
			if ok and type(body) == "table" and type(body.revision) == "string" then
				keep(body.revision)
			else
				st.sync.error = `重新加载服务器上的 subscriptions.toml 失败:{msg}`
				r.h.changed()
			end
		end)
	elseif st.sync.revision then
		keep(st.sync.revision :: string)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Event polling

local poll: (Relay, number) -> ()

local function schedule_poll(r: Relay, gen: number, seconds: number)
	if r.poll_timer then
		r.poll_timer:cancel()
	end
	r.poll_timer = tern.timer(seconds * 1000, function()
		r.poll_timer = nil
		poll(r, gen)
	end)
end

function poll(r: Relay, gen: number)
	if gen ~= r.gen or not r.state.configured then
		return
	end
	local st = r.state
	if not r.h.ready() then
		-- Without valid workflows events would be consumed without runs; wait.
		if not st.waiting then
			st.waiting = true
			r.h.changed()
		end
		schedule_poll(r, gen, NOT_READY_RETRY)
		return
	end
	st.waiting = false
	local cursor = mine(r, "cursor")
	local q: string
	if cursor and type(cursor.seq) == "number" then
		q = `/api/v1/events?wait={POLL_WAIT}&limit=50&after={math.floor(cursor.seq)}`
	else
		-- First contact: learn the head at once; events after it come with the next poll.
		q = "/api/v1/events?wait=0&limit=1"
	end
	local url = r.cfg.url
	M.request(r, "GET", q, nil, POLL_TIMEOUT_MS, function(ok, _status, body, err)
		if gen ~= r.gen then
			return
		end
		if not ok or type(body) ~= "table" then
			local was = st.connected
			st.connected = false
			st.error = err or "响应无效"
			r.backoff = math.min(MAX_BACKOFF, r.backoff * 2)
			if was or st.error ~= err then
				r.h.changed()
			end
			schedule_poll(r, gen, r.backoff)
			return
		end
		r.backoff = 2
		local fresh = not st.connected
		st.connected, st.error, st.last_ok = true, nil, r.h.now()
		st.head, st.store_id = body.head, body.store_id
		-- Straight back into the next long-poll, whatever happens below.
		schedule_poll(r, gen, 0.05)

		if cursor == nil then
			kv_set("cursor", { url = url, store_id = body.store_id, seq = body.head })
		elseif cursor.store_id ~= body.store_id then
			-- The agent's store was wiped and its numbering restarted: everything in the new
			-- store arrived after the wipe, so read it from the start.
			st.reset_at = r.h.now()
			kv_set("cursor", { url = url, store_id = body.store_id, seq = 0 })
		elseif type(body.head) == "number" and cursor.seq > body.head then
			-- Same store but behind our cursor (restored from a backup): continue from its head
			-- rather than spinning until it catches up.
			st.reset_at = r.h.now()
			kv_set("cursor", { url = url, store_id = body.store_id, seq = body.head })
		else
			if body.gap then
				st.gap_at = r.h.now()
			end
			local seq = cursor.seq
			local list = body.events or {}
			for _, e in list do
				if type(e) == "table" and type(e.seq) == "number" and e.seq > seq then
					local okh, herr = pcall(function(): string?
						r.h.event(e)
						return nil
					end)
					if not okh then
						tern.log.warn("roost: event handler failed", herr)
					end
					seq = e.seq
					kv_set("cursor", { url = url, store_id = body.store_id, seq = seq })
					st.last_event = r.h.now()
				end
			end
		end
		if fresh then
			-- Reconnected: catch up on a push that failed while the relay was away.
			M.sync(r, false)
		end
		r.h.changed()
	end)
end

function M.refresh_status(r: Relay)
	local gen = r.gen
	M.request(r, "GET", "/api/v1/status", nil, 10000, function(ok, _s, body, err)
		if gen ~= r.gen then
			return
		end
		local st = r.state
		if ok and type(body) == "table" then
			st.agent, st.agent_at = body, r.h.now()
			if st.restarting and body.boot_id ~= st.restarting.from then
				st.restarting = nil
			end
			-- The server's subscriptions aren't the ones we pushed: a rebuilt agent (empty) gets
			-- ours outright; anything else goes through the revision check (and may conflict).
			local remote = type(body.subscriptions) == "table" and body.subscriptions or nil
			local saved = mine(r, "subs")
			if remote and st.sync.state ~= "conflict" and not st.busy.push and (saved == nil or saved.rev ~= remote.revision) then
				local empty = remote.repos == 0
				local subs = r.h.subs()
				if subs then
					M.push_subs(r, subs, empty)
				end
			end
		else
			st.agent_at = nil
			if not st.connected then
				st.error = err
			end
		end
		r.h.changed()
	end)
end

local function status_loop(r: Relay, gen: number)
	if gen ~= r.gen then
		return
	end
	M.refresh_status(r)
	r.status_timer = tern.timer(if r.state.restarting then 2000 else STATUS_EVERY_MS, function()
		r.status_timer = nil
		status_loop(r, gen)
	end)
end

-- Applies (possibly new) settings; restarts polling when the target changed.
function M.configure(r: Relay, cfg: Cfg)
	local same = cfg.url == r.cfg.url and cfg.token == r.cfg.token and cfg.client_name == r.cfg.client_name
	if same and r.gen > 0 then
		return
	end
	r.cfg = cfg
	r.gen += 1
	r.push_again = nil
	if r.poll_timer then
		r.poll_timer:cancel()
		r.poll_timer = nil
	end
	if r.status_timer then
		r.status_timer:cancel()
		r.status_timer = nil
	end
	local st = r.state
	st.configured = cfg.url ~= nil and cfg.token ~= nil
	st.connected, st.error, st.agent, st.restarting = false, nil, nil, nil
	st.busy = {}
	if not st.configured then
		st.sync = { state = "unconfigured" }
		r.h.changed()
		return
	end
	st.sync = { state = "idle" }
	local gen = r.gen
	schedule_poll(r, gen, 0.05)
	status_loop(r, gen)
	M.sync(r, false)
	r.h.changed()
end

function M.stop(r: Relay)
	r.gen += 1
	if r.poll_timer then
		r.poll_timer:cancel()
	end
	if r.status_timer then
		r.status_timer:cancel()
	end
	r.poll_timer, r.status_timer = nil, nil
end

-- ---------------------------------------------------------------------------------------------
-- Remote operations; `cb(ok, message, body)`.

local function op(r: Relay, key: string, method: string, path: string, body: any, timeout: number, cb: (boolean, string, any) -> ())
	local st = r.state
	if st.busy[key] then
		return
	end
	st.busy[key] = true
	r.h.changed()
	local gen = r.gen
	M.request(r, method, path, body, timeout, function(ok, _s, resp, err)
		if gen ~= r.gen then
			return
		end
		st.busy[key] = nil
		cb(ok, err or "", resp)
		r.h.changed()
	end)
end

function M.reload_remote(r: Relay, cb: (boolean, string, any) -> ())
	op(r, "reload", "POST", "/api/v1/reload", {}, 15000, function(ok, msg, body)
		if ok then
			M.refresh_status(r)
		end
		cb(ok, msg, body)
	end)
end

function M.restart_remote(r: Relay, cb: (boolean, string, any) -> ())
	local from = r.state.agent and r.state.agent.boot_id
	op(r, "restart", "POST", "/api/v1/restart", {}, 10000, function(ok, msg, body)
		if ok then
			r.state.restarting = { from = from or (body and body.boot_id) or "", since = r.h.now() }
			-- Watch for the new boot id; the status loop speeds up while restarting.
			if r.status_timer then
				r.status_timer:cancel()
				r.status_timer = nil
			end
			local gen = r.gen
			r.status_timer = tern.timer(1500, function()
				r.status_timer = nil
				status_loop(r, gen)
			end)
		end
		cb(ok, msg, body)
	end)
end

function M.sync_hooks(r: Relay, dry: boolean, cb: (boolean, string, any) -> ())
	op(r, "hooks", "POST", "/api/v1/github/sync", { dry_run = dry }, 90000, function(ok, msg, body)
		if ok then
			M.refresh_status(r)
		end
		cb(ok, msg, body)
	end)
end

function M.test(r: Relay, repo: string?, cb: (boolean, string, any) -> ())
	op(r, "test", "POST", "/api/v1/events/test", { repo = repo }, 10000, cb)
end

function M.deliveries(r: Relay, cb: (boolean, string, any) -> ())
	op(r, "deliveries", "GET", "/api/v1/deliveries?limit=50", nil, 10000, cb)
end

return M
