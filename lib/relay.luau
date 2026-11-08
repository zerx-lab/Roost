--!strict
-- The relay agent client: long-polls relayed GitHub events, keeps the agent's subscriptions in
-- line with the local workflows (local first; on failure the UI offers the manual fallback), and
-- runs remote operations (reload, restart, test event). GitHub App calls go through `request`.
--
-- Persistent client state lives in tern.kv, keyed by relay URL so pointing at another agent
-- starts clean: `cursor` = { url, store_id, seq }, `subs` = { url, rev, fp, at?, adopted? }
-- (`adopted`: the server's subscriptions were kept over differing local ones after a conflict),
-- `fleet` = { url, state } (the relay's device record, so the role is known before the relay
-- answers), `takeover` = { url, revision } (the executor assignment whose handover was applied).
--
-- Devices (agent/src/fleet.rs, lib/fleet.luau): with an executor assigned, only it handles
-- events (observers get them through `observe`, for display), pushes subscriptions and gets App
-- tokens. Becoming the executor moves the cursor to where the previous one stopped.

local util = require("./util")
local fleet = require("./fleet")

local M = {}

local POLL_WAIT = 25
local POLL_TIMEOUT_MS = 40000
local STATUS_EVERY_MS = 20000
local MAX_BACKOFF = 60
local NOT_READY_RETRY = 3
-- On first contact, how many already-stored events are fetched for display only.
local BACKFILL = 20

export type Cfg = { url: string?, token: string?, client_name: string? }

export type Sync = {
	-- idle: not yet checked against the relay | pushing | ok: the relay runs exactly the local
	-- subscriptions | adopted: it runs its own (kept after a conflict) until the local ones change |
	-- conflict | invalid | offline | unconfigured
	state: string,
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
	fleet: { [string]: any }?, -- the relay's device record (fleet.rs State), as last seen
	takeover_at: number?, -- when this client last took over as executor at the old one's cursor
}

export type Subs = { [string]: { events: { string } } }

export type Handlers = {
	-- Handles one relayed event; errors are caught and logged.
	event: (e: { [string]: any }) -> (),
	-- An event an observer reads (the executor runs it): shown only.
	observe: (e: { [string]: any }) -> (),
	-- Events already read, for display only (no payloads; never run): see `backfill`.
	history: (list: { { [string]: any } }) -> (),
	-- Whether the events page has nothing saved yet and wants recent history.
	wants_history: () -> boolean,
	changed: () -> (),
	now: () -> number,
	client_id: string,
	-- Whether events can be consumed now (a valid workflows.toml is loaded).
	ready: () -> boolean,
	-- The current local subscriptions (nil when no valid workflows.toml).
	subs: () -> Subs?,
	-- Workflows outside callers may start: id → SHA-256 of their token (api triggers).
	dispatch: () -> { [string]: string },
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
	backfill_gen: number?, -- a history fetch for this generation is in flight
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
		backfill_gen = nil,
		state = {
			configured = false,
			connected = false,
			sync = { state = "unconfigured" },
			busy = {},
			waiting = false,
		},
	}
end

local kv_get: (key: string) -> any
local mine: (r: Relay, key: string) -> { [string]: any }?

-- The relay's device record: the last one seen, else the one saved for this relay URL.
function M.fleet(r: Relay): { [string]: any }?
	if r.state.fleet then
		return r.state.fleet
	end
	local saved = mine(r, "fleet")
	return if saved and type(saved.state) == "table" then saved.state else nil
end

-- What this client is: solo (no relay, or no executor assigned), executor or observer.
function M.role(r: Relay): fleet.Role
	if not r.state.configured then
		return "solo"
	end
	return fleet.role(M.fleet(r), r.h.client_id)
end

function M.executor(r: Relay): fleet.Executor?
	return if r.state.configured then fleet.executor(M.fleet(r)) else nil
end

-- Why the configured relay can't say who the executor is (its record is unreadable), or nil.
function M.fleet_error(r: Relay): string?
	return if r.state.configured then fleet.error(M.fleet(r)) else nil
end

function kv_get(key: string): any
	local ok, v = pcall(tern.kv.get, key)
	return if ok then v else nil
end

local function kv_set(key: string, v: any)
	pcall(tern.kv.set, key, v)
end

-- The kv record `key` when it belongs to the configured relay URL.
function mine(r: Relay, key: string): { [string]: any }?
	local v = kv_get(key)
	if type(v) == "table" and v.url == r.cfg.url then
		return v
	end
	return nil
end

-- Takes in a device record from any relay answer; saved when the executor or its error changed.
local function note_fleet(r: Relay, f: any)
	if type(f) ~= "table" then
		return
	end
	local before = M.fleet(r)
	r.state.fleet = f
	local was = fleet.executor(before)
	local now_ex = fleet.executor(f)
	local changed = before == nil
		or before.revision ~= f.revision
		or (was and was.id) ~= (now_ex and now_ex.id)
		or fleet.error(before) ~= fleet.error(f)
	if changed then
		kv_set("fleet", { url = r.cfg.url, state = f })
	end
end

local function describe(res: FetchResult, body: any): string
	if res.error then
		return if res.timed_out then "连接超时" else `无法连接:{res.error}`
	end
	if res.status == 401 then
		return "令牌被拒绝(检查 roost.toml 的 relay.token 与服务器 agent.toml 的 [auth].token)"
	end
	local msg = if type(body) == "table" and type(body.error) == "string" then body.error else nil
	if res.status == 403 and type(body) == "table" and body.code == "not_executor" then
		return `本机不是执行者(执行者:{fleet.label(fleet.executor(body.fleet))}):只有执行者能这样做`
	end
	return `HTTP {res.status}{if msg then ":" .. msg else ""}`
end

-- One admin API call. `body` is encoded as JSON (a string is sent as is: already JSON).
-- `cb(ok, status, body, err)`; body is decoded JSON or nil.
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
	if type(body) == "string" then
		opts.body = body
	elseif body ~= nil then
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
			-- A refusal for not being the executor says who is: act on it at once.
			if res.status == 403 and type(decoded) == "table" and decoded.code == "not_executor" then
				note_fleet(r, decoded.fleet)
			end
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
		local evs = table.clone(subs[name].events)
		table.sort(evs)
		out[name] = { events = tern.json.array(evs) }
	end
	return out
end

function M.fingerprint(subs: Subs, dispatch: { [string]: string }?): string
	local parts = {}
	for _, name in util.keys(subs) do
		local evs = table.clone(subs[name].events)
		table.sort(evs)
		table.insert(parts, `{string.lower(name)}={table.concat(evs, ",")}`)
	end
	local d = dispatch or {}
	for _, id in util.keys(d) do
		table.insert(parts, `!{id}={d[id]}`)
	end
	return table.concat(parts, ";")
end

-- What a push of `subs` would send, as compared with the last push.
local function fp_of(r: Relay, subs: Subs): string
	return M.fingerprint(subs, r.h.dispatch())
end

-- Whether `subs` differ from what was last pushed to (or adopted from) this relay.
function M.needs_push(r: Relay, subs: Subs): boolean
	local s = mine(r, "subs")
	return s == nil or s.fp ~= fp_of(r, subs)
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
	if M.role(r) == "observer" then
		-- The executor's subscriptions are the relay's; it refuses an observer's anyway.
		st.sync = { state = "observer" }
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
	local dispatch = r.h.dispatch()
	if next(dispatch) then
		body.dispatch = dispatch
	end
	local saved = mine(r, "subs")
	if not force and saved and type(saved.rev) == "string" then
		body.base_revision = saved.rev
	end
	local fp = fp_of(r, subs)
	local gen, url = r.gen, r.cfg.url
	M.request(r, "PUT", "/api/v1/subscriptions", body, 20000, function(ok, status, resp, err)
		if gen ~= r.gen then
			return
		end
		st.busy.push = nil
		local t = r.h.now()
		if ok and type(resp) == "table" then
			kv_set("subs", { url = url, rev = resp.revision, fp = fp, at = t })
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

-- Settles the sync state against the relay's last /status. The relay runs the revision we last
-- pushed (or adopted) and the local subscriptions still match it → ok/adopted. A different
-- revision on the relay is pushed when `may_push` (a rebuilt, empty agent gets ours outright;
-- anything else goes through the revision check and may conflict).
local function reconcile(r: Relay, may_push: boolean)
	local st = r.state
	local agent = st.agent
	local remote = if agent and type(agent.subscriptions) == "table" then agent.subscriptions else nil
	if remote == nil or st.busy.push or st.sync.state == "conflict" then
		return
	end
	if M.role(r) == "observer" then
		st.sync = { state = "observer" }
		return
	end
	local subs = r.h.subs()
	if subs == nil then
		if st.sync.state == "idle" then
			st.sync.error = "没有有效的 workflows.toml,无法核对订阅"
		end
		return
	end
	local saved = mine(r, "subs")
	if saved == nil or saved.rev ~= remote.revision then
		if may_push then
			M.push_subs(r, subs, remote.repos == 0)
		end
	elseif saved.fp == fp_of(r, subs) then
		st.sync = {
			state = if saved.adopted == true then "adopted" else "ok",
			at = if type(saved.at) == "number" then saved.at else nil,
			revision = saved.rev,
		}
	end
end

-- Pushes the current local subscriptions when they differ from the last push to this relay;
-- otherwise confirms them against the relay's last known state.
function M.sync(r: Relay)
	local subs = r.h.subs()
	if subs == nil or not r.state.configured then
		return
	end
	if M.needs_push(r, subs) then
		M.push_subs(r, subs, false)
	else
		reconcile(r, false)
	end
end

-- An explicit push of the current local subscriptions, even when unchanged since the last push.
function M.push_now(r: Relay, force: boolean)
	local subs = r.h.subs()
	if subs == nil then
		r.state.sync.error = "没有有效的 workflows.toml,无法计算订阅"
		r.h.changed()
		return
	end
	M.push_subs(r, subs, force)
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
	local fp = fp_of(r, subs :: Subs)
	local url = r.cfg.url
	local function keep(rev: string)
		local t = r.h.now()
		kv_set("subs", { url = url, rev = rev, fp = fp, at = t, adopted = true })
		st.sync = { state = "adopted", at = t, revision = rev }
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

-- Events this client already read, shown as history when it has none saved: on first contact
-- (everything up to the head) or when the events page has no saved file yet. Only events at or
-- before `upto` are passed on, so nothing still ahead of the cursor is mistaken for history.
local function backfill(r: Relay, gen: number, upto: number)
	r.backfill_gen = gen
	local after = math.max(0, math.floor(upto) - BACKFILL)
	M.request(r, "GET", `/api/v1/events?wait=0&payload=false&limit={BACKFILL}&after={after}`, nil, 15000, function(ok, _s, body)
		if gen ~= r.gen then
			return
		end
		r.backfill_gen = nil
		if not ok or type(body) ~= "table" or type(body.events) ~= "table" then
			return
		end
		local list: { { [string]: any } } = {}
		for _, e in body.events do
			if type(e) == "table" and type(e.seq) == "number" and e.seq <= upto then
				table.insert(list, e)
			end
		end
		local okh, herr = pcall(function(): string?
			r.h.history(list)
			return nil
		end)
		if not okh then
			tern.log.warn("roost: history handler failed", herr)
		end
		r.h.changed()
	end)
end

-- Which assignment a takeover record is for: the revision alone repeats after the relay loses
-- its device record (it starts again from 0), so the assignment time goes with it.
local function assignment_key(f: { [string]: any }, ex: fleet.Executor): string
	return `{tostring(f.revision)}@{ex.since or ""}`
end

-- The assignment revision this client handles events under, when it is the executor and has
-- taken over (its cursor is then what it has handled): sent as `ack` with its polls.
local function acting(r: Relay): number?
	local f = r.state.fleet
	local ex = fleet.executor(f)
	if f == nil or ex == nil or ex.id ~= r.h.client_id or type(f.revision) ~= "number" then
		return nil
	end
	local done = mine(r, "takeover")
	return if done and done.key == assignment_key(f, ex) then f.revision else nil
end

-- This client was just made the executor: it starts after the cursor the previous executor
-- confirmed (the events up to it were handled there, the later ones were not), and its
-- subscriptions become the relay's (its kv record of the last push is stale after observing).
-- True when the cursor moved: the batch in hand was read from the old position.
local function takeover(r: Relay, cursor: { [string]: any }?, body: { [string]: any }): boolean
	local f = r.state.fleet
	local ex = fleet.executor(f)
	if f == nil or ex == nil or ex.id ~= r.h.client_id then
		return false
	end
	local key = assignment_key(f, ex)
	local done = mine(r, "takeover")
	if done and done.key == key then
		return false
	end
	local to = ex.handover
	local head = body.head
	local moved = false
	if
		to
		and cursor
		and cursor.store_id == body.store_id
		and cursor.seq ~= to
		and (type(head) ~= "number" or to <= head)
	then
		kv_set("cursor", { url = r.cfg.url, store_id = body.store_id, seq = to })
		r.state.takeover_at = r.h.now()
		moved = true
	end
	-- Marked done only once the cursor is where it must be.
	kv_set("takeover", { url = r.cfg.url, key = key })
	local okp, perr = pcall(function(): string?
		local subs = r.h.subs()
		if subs then
			M.push_subs(r, subs, true)
		end
		return nil
	end)
	if not okp then
		tern.log.warn("roost: pushing subscriptions on takeover failed", perr)
	end
	return moved
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
	if st.waiting then
		st.waiting = false
		r.h.changed()
	end
	local cursor = mine(r, "cursor")
	local q: string
	if cursor and type(cursor.seq) == "number" then
		-- Until a poll succeeds (start, reload, outage) don't block: an idle long-poll would
		-- keep the panel on its stale "not connected" state for up to POLL_WAIT seconds.
		local wait = if st.connected then POLL_WAIT else 0
		q = `/api/v1/events?wait={wait}&limit=50&after={math.floor(cursor.seq)}`
		local rev = acting(r)
		if rev and type(cursor.store_id) == "string" and string.match(cursor.store_id, "^%x+$") then
			-- The store goes along: a cursor from a wiped store says nothing about the new one.
			q ..= `&ack={math.floor(rev)}&store={cursor.store_id}`
		end
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
			local was, before = st.connected, st.error
			st.connected = false
			st.error = err or "响应无效"
			r.backoff = math.min(MAX_BACKOFF, r.backoff * 2)
			if was or st.error ~= before then
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
		note_fleet(r, body.fleet)
		if fleet.error(r.state.fleet) then
			-- The relay can't say who the executor is: nobody reads on (the cursor stays), so the
			-- executor assigned next finds these events still ahead of it.
			schedule_poll(r, gen, NOT_READY_RETRY)
			r.h.changed()
			return
		end
		if takeover(r, cursor, body) then
			r.h.changed()
			return
		end

		local upto = if cursor == nil then body.head elseif cursor.store_id == body.store_id then cursor.seq else nil
		if
			(cursor == nil or r.h.wants_history())
			and type(upto) == "number"
			and upto > 0
			and r.backfill_gen ~= gen
		then
			backfill(r, gen, upto)
		end
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
			local observer = M.role(r) == "observer"
			for _, e in list do
				if type(e) == "table" and type(e.seq) == "number" and e.seq > seq then
					local okh, herr = pcall(function(): string?
						if observer then
							r.h.observe(e)
						else
							r.h.event(e)
						end
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
			M.sync(r)
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
			note_fleet(r, body.fleet)
			if st.restarting and body.boot_id ~= st.restarting.from then
				st.restarting = nil
			end
			reconcile(r, true)
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
	-- The record belongs to the relay it came from (the saved one is looked up by URL).
	st.fleet = nil
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
	M.sync(r)
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

function M.test(r: Relay, repo: string?, cb: (boolean, string, any) -> ())
	op(r, "test", "POST", "/api/v1/events/test", { repo = repo }, 10000, cb)
end

-- Clears the agent's webhook delivery counters and recent list.
function M.clear_deliveries(r: Relay, cb: (boolean, string, any) -> ())
	op(r, "clear_deliveries", "DELETE", "/api/v1/deliveries", nil, 10000, cb)
end

-- Deletes the events the agent keeps for clients (sequence numbers carry on, cursors stay valid).
function M.clear_events(r: Relay, cb: (boolean, string, any) -> ())
	op(r, "clear_events", "DELETE", "/api/v1/events", nil, 15000, function(ok, msg, body)
		if ok then
			M.refresh_status(r)
		end
		cb(ok, msg, body)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Devices: the executor, its configuration and its runs (agent/src/fleet.rs)

-- Makes `client` (a device the relay has heard from) the executor. Compare-and-set on the device
-- record's revision, so a choice made on a stale view is refused.
function M.assign(r: Relay, client: string, cb: (boolean, string) -> ())
	local st = r.state
	if st.busy.assign then
		return
	end
	local f = M.fleet(r)
	local base = if f and type(f.revision) == "number" then f.revision else 0
	st.busy.assign = true
	r.h.changed()
	local gen = r.gen
	M.request(r, "PUT", "/api/v1/fleet/executor", { client = client, base_revision = base }, 15000, function(ok, status, body, err)
		if gen ~= r.gen then
			return
		end
		st.busy.assign = nil
		if type(body) == "table" then
			note_fleet(r, body.fleet)
		end
		local msg = err or ""
		if status == 409 then
			msg = "执行者刚被其他设备改过:看一下现在的执行者再决定"
		elseif status == 404 then
			msg = "中继启动以来还没收到这台设备的请求:先让它连上中继"
		end
		cb(ok, msg)
		M.refresh_status(r)
		r.h.changed()
	end)
end

-- A device call whose answer is dropped once the relay settings changed. `body` given as a string
-- is sent as is (already JSON).
local function device_call(r: Relay, method: string, path: string, body: any, cb: (boolean, any, string?) -> ())
	local gen = r.gen
	M.request(r, method, path, body, 30000, function(ok, _s, resp, err)
		if gen == r.gen then
			cb(ok, resp, err)
		end
	end)
end

-- The executor's configuration (Roost's export format). `cb(ok, { config = meta }, err)`.
function M.put_config(r: Relay, text: string, cb: (boolean, any, string?) -> ())
	device_call(r, "PUT", "/api/v1/fleet/config", { text = text }, cb)
end

-- `have`: the revision held here; the answer then has no text when it is still current.
function M.get_config(r: Relay, have: string?, cb: (boolean, any, string?) -> ())
	local q = if have and string.match(have, "^%x+$") then `?have={have}` else ""
	device_call(r, "GET", "/api/v1/fleet/config" .. q, nil, cb)
end

-- The executor's run summaries, `json` already encoded (lib/fleet.luau summaries).
function M.put_runs(r: Relay, json: string, cb: (boolean, any, string?) -> ())
	device_call(r, "PUT", "/api/v1/fleet/runs", json, cb)
end

function M.get_runs(r: Relay, have: string?, cb: (boolean, any, string?) -> ())
	local q = if have and string.match(have, "^%x+$") then `?have={have}` else ""
	device_call(r, "GET", "/api/v1/fleet/runs" .. q, nil, cb)
end

return M
