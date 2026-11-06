--!strict
-- The events page's history: one row per relayed event (what it was, which runs it started or
-- why it didn't), kept in `events.json` so a reload keeps it. Newest first, bounded by a count
-- and an age (roost.toml [retention]).
--
-- Saved like runs.json: `events.json.bak` first, then `events.json`; load falls back to the
-- backup. Rows are rebuilt field by field on load, so no decoded (metatable-tagged) table stays.

local M = {}

export type Row = {
	seq: number,
	delivery: string,
	at: number, -- when the relay received it (epoch seconds)
	event: string,
	repo: string?,
	summary: string,
	url: string?,
	runs: { string },
	reasons: { [string]: string }, -- workflow id ("*": all) -> why it didn't fire
	history: boolean?, -- arrived before this machine was bound to the relay: shown, never run
	-- Read while this machine was an observer: the executor named here ran it. Not "handled" here,
	-- so this machine still runs it if it takes over before the event (lib/relay.luau takeover).
	observed: string?,
}

local MAX_BYTES = 8 * 1024 * 1024

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function row_of(v: any): Row?
	if type(v) ~= "table" or type(v.seq) ~= "number" or type(v.at) ~= "number" then
		return nil
	end
	local runs: { string } = {}
	if type(v.runs) == "table" then
		for _, id in v.runs do
			if type(id) == "string" then
				table.insert(runs, id)
			end
		end
	end
	local reasons: { [string]: string } = {}
	if type(v.reasons) == "table" then
		for k, why in v.reasons do
			if type(k) == "string" and type(why) == "string" then
				reasons[k] = why
			end
		end
	end
	return {
		seq = v.seq,
		delivery = str(v.delivery) or tostring(v.seq),
		at = v.at,
		event = str(v.event) or "?",
		repo = str(v.repo),
		summary = str(v.summary) or "",
		url = str(v.url),
		runs = runs,
		reasons = reasons,
		history = if v.history == true then true else nil,
		observed = str(v.observed),
	}
end

local function decode(path: string): { Row }?
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	if not ok then
		return nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	if not ok2 or type(v) ~= "table" then
		return nil
	end
	local out: { Row } = {}
	for _, x in v :: { any } do
		local r = row_of(x)
		if r then
			table.insert(out, r)
		end
	end
	return out
end

-- The saved rows, newest first (empty when neither file is usable).
function M.load(path: string): { Row }
	return decode(path) or decode(path .. ".bak") or {}
end

function M.save(path: string, rows: { Row }): string?
	local list = {}
	for _, r in rows do
		-- json.array tags its argument in place: tag copies, never the live tables.
		table.insert(list, {
			seq = r.seq,
			delivery = r.delivery,
			at = r.at,
			event = r.event,
			repo = r.repo,
			summary = r.summary,
			url = r.url,
			runs = tern.json.array(table.move(r.runs, 1, #r.runs, 1, {})),
			reasons = r.reasons,
			history = r.history,
			observed = r.observed,
		})
	end
	local text = tern.json.encode(tern.json.array(list))
	local ok, err = pcall(function(): string?
		tern.fs.write(path .. ".bak", text)
		tern.fs.write(path, text)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot save events", err)
		return tostring(err)
	end
	return nil
end

-- Drops rows past `keep` or older than `max_age` seconds (0: no age limit), in place. Returns
-- how many went.
function M.prune(rows: { Row }, keep: number, max_age: number, now: number): number
	local cutoff = if max_age > 0 then now - max_age else nil
	local n = 0
	for i = #rows, 1, -1 do
		if i > keep or (cutoff ~= nil and rows[i].at < cutoff) then
			table.remove(rows, i)
			n += 1
		end
	end
	return n
end

return M
