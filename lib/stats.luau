--!strict
-- The numbers the overview draws, computed from the run history: runs per local day, run
-- durations, and each workflow's health over a window. Pure over the run list (local time from
-- os.date), so tests can check the buckets.

local store = require("./store")

local M = {}

type Run = store.Run

-- Finished runs that count toward a success rate; cancelled, interrupted and skipped runs don't.
M.OK = { success = true }
M.BAD = { failed = true, timed_out = true }

export type Day = {
	label: string, -- MM-DD
	start: number,
	ok: number,
	bad: number,
	other: number, -- queued, running, cancelled, interrupted, skipped
	p50: number?, -- seconds, of runs that finished that day
	p95: number?,
}

export type Health = {
	runs: number,
	ok: number,
	bad: number,
	rate: number?, -- ok / (ok + bad), nil without finished runs
	p50: number?,
	p95: number?,
	daily: { number }, -- runs per day, oldest first, one entry per window day
}

-- How long a finished run took, in seconds.
function M.took(r: Run): number?
	if r.started_at and r.finished_at then
		return math.max(0, r.finished_at - r.started_at)
	end
	return nil
end

-- Nearest-rank percentile of an ascending list.
function M.percentile(sorted: { number }, p: number): number?
	if #sorted == 0 then
		return nil
	end
	return sorted[math.clamp(math.ceil(p * #sorted), 1, #sorted)]
end

local function day_start(t: number): number
	local d = os.date("*t", t) :: any
	d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
	return os.time(d)
end

-- Local midnight of the day `t` falls in.
M.day_start = day_start

-- Estimated USD of the agent steps that started at or after `since` (one workflow, or all).
function M.cost_since(runs: { Run }, workflow: string?, since: number): number
	local sum = 0
	for _, r in runs do
		if workflow == nil or r.workflow == workflow then
			for _, s in r.steps do
				if s.cost and (s.started_at or 0) >= since then
					sum += s.cost
				end
			end
		end
	end
	return sum
end

-- Estimated USD and tokens of one run's agent steps (nil when none has a tally yet).
function M.run_cost(r: Run): (number?, number?)
	local cost: number?, tokens: number? = nil, nil
	for _, s in r.steps do
		if s.cost then
			cost = (cost or 0) + s.cost
			tokens = (tokens or 0) + (s.tokens or 0)
		end
	end
	return cost, tokens
end

-- Midnight (local) of each of the last `n` days ending today, oldest first.
function M.day_starts(now: number, n: number): { number }
	local today = day_start(now)
	local out = table.create(n)
	for k = n - 1, 0, -1 do
		-- Noon of that day, so a DST change never lands on the wrong date.
		table.insert(out, day_start(today - k * 86400 + 43200))
	end
	return out
end

-- Index of the day `t` falls in, or nil outside the window.
local function day_of(starts: { number }, t: number): number?
	if t < starts[1] then
		return nil
	end
	for i = #starts, 1, -1 do
		if t >= starts[i] then
			return i
		end
	end
	return nil
end

-- Runs per day over the last `n` days, by the day they were created.
function M.days(runs: { Run }, now: number, n: number): { Day }
	local starts = M.day_starts(now, n)
	local out: { Day } = {}
	local took: { { number } } = {}
	for i, s in starts do
		out[i] = { label = os.date("%m-%d", s) :: string, start = s, ok = 0, bad = 0, other = 0, p50 = nil, p95 = nil }
		took[i] = {}
	end
	for _, r in runs do
		local i = day_of(starts, r.created_at)
		if i then
			local d = out[i]
			if M.OK[r.state] then
				d.ok += 1
			elseif M.BAD[r.state] then
				d.bad += 1
			else
				d.other += 1
			end
			local t = M.took(r)
			if t then
				table.insert(took[i], t)
			end
		end
	end
	for i, d in out do
		table.sort(took[i])
		d.p50 = M.percentile(took[i], 0.5)
		d.p95 = M.percentile(took[i], 0.95)
	end
	return out
end

-- Each workflow's runs over the last `n` days.
function M.health(runs: { Run }, now: number, n: number): { [string]: Health }
	local starts = M.day_starts(now, n)
	local out: { [string]: Health } = {}
	local took: { [string]: { number } } = {}
	for _, r in runs do
		local i = day_of(starts, r.created_at)
		if i then
			local h = out[r.workflow]
			if not h then
				local daily = table.create(n, 0)
				h = { runs = 0, ok = 0, bad = 0, rate = nil, p50 = nil, p95 = nil, daily = daily }
				out[r.workflow] = h
				took[r.workflow] = {}
			end
			h.runs += 1
			h.daily[i] += 1
			if M.OK[r.state] then
				h.ok += 1
			elseif M.BAD[r.state] then
				h.bad += 1
			end
			local t = M.took(r)
			if t then
				table.insert(took[r.workflow], t)
			end
		end
	end
	for id, h in out do
		local list = took[id]
		table.sort(list)
		h.p50 = M.percentile(list, 0.5)
		h.p95 = M.percentile(list, 0.95)
		h.rate = if h.ok + h.bad > 0 then h.ok / (h.ok + h.bad) else nil
	end
	return out
end

-- `87%`, or `—` without finished runs.
function M.percent(rate: number?): string
	return if rate then `{math.floor(rate * 100 + 0.5)}%` else "—"
end

return M
