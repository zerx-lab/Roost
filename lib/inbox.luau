--!strict
-- The inbox: what workflows report needs a person (a PR waiting for approval, an issue handed to
-- the maintainer, …), shown on the home page with what Roost itself knows needs attention.
--
-- Protocol: a shell or file step gets `$ROOST_INBOX` (runs/<id>/s<i>.inbox.json) and may write one
-- JSON object there before it exits:
--
--   { "replace": true,                      -- this workflow's items become exactly `items`
--     "items": [ { "id": "pr-1073", "title": "PR #1073 等待批准", "detail": "…",
--                  "url": "https://…", "kind": "approve",
--                  "run": { "workflow": "<id>", "pr": "1073", "inputs": { "k": "v" } } } ],
--     "resolve": ["pr-1001"] }              -- without replace: these ids go
--
-- Items belong to the workflow whose run reported them. `kind` is failed | approve | decide |
-- review | info. Lengths count characters (UTF-8). Saved in plugin-data/roost/inbox.json (.bak
-- first), together with what this machine dismissed: an item stays hidden until it changes.

local util = require("./util")

local M = {}

M.FILE = "inbox.json"
M.MAX_FILE = 64 * 1024
M.MAX_ITEMS = 100 -- per workflow
M.MAX_TOTAL = 200 -- across workflows
M.MAX_WORKFLOWS = 50
M.MAX_DISMISSED = 500
-- Most characters of an action's inputs together.
local MAX_INPUT_CHARS = 2000
local MAX_STORE = 8 * 1024 * 1024

M.KINDS = { "failed", "approve", "decide", "review", "info" }
local RANK: { [string]: number } = {}
for i, k in M.KINDS do
	RANK[k] = i
end

export type Action = { workflow: string, pr: string?, inputs: { [string]: string }? }
export type Item = {
	id: string,
	title: string,
	detail: string?,
	url: string?,
	kind: string,
	run: Action?,
	at: number, -- when it was last reported (changed or not)
}
export type Box = { at: number, run: string, items: { Item } }
export type Book = { boxes: { [string]: Box }, dismissed: { [string]: string } }
export type Payload = { replace: boolean, items: { Item }, resolve: { string } }
-- One item as listed: with the workflow that owns it.
export type Entry = Item & { workflow: string }

function M.empty(): Book
	return { boxes = {}, dismissed = {} }
end

-- At most `n` characters of `s` (invalid UTF-8 counts bytes).
local function chars(s: string, n: number): string
	if utf8.len(s) == nil then
		return string.sub(s, 1, n)
	end
	local cut = utf8.offset(s, n + 1)
	return if cut then string.sub(s, 1, cut - 1) else s
end

local function text(v: any, n: number): string?
	if type(v) ~= "string" then
		return nil
	end
	local t = util.trim(v)
	return if t ~= "" then chars(t, n) else nil
end

local function valid_id(v: any): boolean
	return type(v) == "string" and #v >= 1 and #v <= 64 and string.match(v, "^[%w._:-]+$") ~= nil
end

local function valid_workflow(v: any): boolean
	return type(v) == "string" and #v <= 64 and string.match(v, "^[%w][%w._-]*$") ~= nil
end

local function action(v: any): Action?
	if type(v) ~= "table" or not valid_workflow(v.workflow) then
		return nil
	end
	local inputs: { [string]: string }? = nil
	if type(v.inputs) == "table" then
		local got: { [string]: string } = {}
		local n, left = 0, MAX_INPUT_CHARS
		for k, x in v.inputs do
			if type(k) == "string" and type(x) == "string" and #k <= 64 and n < 32 and left > 0 then
				local s = chars(x, left)
				got[k] = s
				left -= utf8.len(s) or #s
				n += 1
			end
		end
		inputs = if n > 0 then got else nil
	end
	return { workflow = v.workflow, pr = text(v.pr, 200), inputs = inputs }
end

local function item(v: any, now: number): Item?
	if type(v) ~= "table" or not valid_id(v.id) then
		return nil
	end
	local title = text(v.title, 120)
	if not title then
		return nil
	end
	local url = text(v.url, 500)
	if url and not string.match(url, "^https://[^%s]+$") then
		url = nil
	end
	return {
		id = v.id,
		title = title,
		detail = text(v.detail, 400),
		url = url,
		kind = if type(v.kind) == "string" and RANK[v.kind] then v.kind else "info",
		run = action(v.run),
		at = now,
	}
end

-- What a step wrote to $ROOST_INBOX, or why it can't be used.
function M.parse(raw: string, now: number): (Payload?, string?)
	local ok, v = pcall(tern.json.decode, raw)
	if not ok or type(v) ~= "table" or #v > 0 then
		return nil, "不是 JSON 对象"
	end
	local items: { Item } = {}
	local seen: { [string]: boolean } = {}
	local dropped = 0
	if v.items ~= nil and type(v.items) ~= "table" then
		return nil, "items 应为数组"
	end
	for _, x in v.items or {} do
		local it = item(x, now)
		if it and not seen[it.id] and #items < M.MAX_ITEMS then
			seen[it.id] = true
			table.insert(items, it)
		else
			dropped += 1
		end
	end
	local resolve: { string } = {}
	if type(v.resolve) == "table" then
		for _, id in v.resolve do
			if valid_id(id) and #resolve < M.MAX_ITEMS then
				table.insert(resolve, id)
			end
		end
	end
	local p: Payload = { replace = v.replace == true, items = items, resolve = resolve }
	return p, if dropped > 0 then `忽略了 {dropped} 个无效或超出上限的条目` else nil
end

local function same(a: Item, b: Item): boolean
	return a.title == b.title and a.detail == b.detail and a.url == b.url and a.kind == b.kind
end

-- Applies what workflow `wf`'s run `run` reported. Items whose text didn't change keep when they
-- were first reported; workflows beyond MAX_WORKFLOWS lose their oldest box, and past MAX_TOTAL
-- items the oldest reported go (other workflows' first).
function M.apply(b: Book, wf: string, p: Payload, run: string, now: number)
	local box = b.boxes[wf]
	local old: { [string]: Item } = {}
	local before: { Item } = if box then box.items else {}
	for _, it in before do
		old[it.id] = it
	end
	local list: { Item } = {}
	if not p.replace and box then
		local gone: { [string]: boolean } = {}
		for _, id in p.resolve do
			gone[id] = true
		end
		for _, it in p.items do
			gone[it.id] = true
		end
		for _, it in box.items do
			if not gone[it.id] then
				table.insert(list, it)
			end
		end
	end
	for _, it in p.items do
		local prev = old[it.id]
		if prev and same(prev, it) then
			it.at = prev.at
		end
		table.insert(list, it)
	end
	while #list > M.MAX_ITEMS do
		table.remove(list, 1)
	end
	if #list == 0 then
		b.boxes[wf] = nil
		return
	end
	b.boxes[wf] = { at = now, run = run, items = list }
	local names = util.keys(b.boxes)
	while #names > M.MAX_WORKFLOWS do
		local oldest, at = names[1], math.huge
		for _, n in names do
			if b.boxes[n].at < at then
				oldest, at = n, b.boxes[n].at
			end
		end
		b.boxes[oldest] = nil
		names = util.keys(b.boxes)
	end
	local all: { { wf: string, it: Item } } = {}
	for n, x in b.boxes do
		for _, it in x.items do
			table.insert(all, { wf = n, it = it })
		end
	end
	if #all > M.MAX_TOTAL then
		-- The oldest go, other workflows' first: one sort, then the boxes rebuilt without them.
		table.sort(all, function(a, c): boolean
			local ao, co = a.wf == wf, c.wf == wf
			if ao ~= co then
				return co
			end
			return a.it.at < c.it.at
		end)
		local drop: { [Item]: boolean } = {}
		for i = 1, #all - M.MAX_TOTAL do
			drop[all[i].it] = true
		end
		for n, x in table.clone(b.boxes) do
			local keep: { Item } = {}
			for _, it in x.items do
				if not drop[it] then
					table.insert(keep, it)
				end
			end
			if #keep == 0 then
				b.boxes[n] = nil
			else
				x.items = keep
			end
		end
	end
end

-- Drops the boxes of workflows that no longer exist (`keep`: the current ids).
function M.prune(b: Book, keep: { [string]: any }): boolean
	local changed = false
	for wf in table.clone(b.boxes) do
		if keep[wf] == nil then
			b.boxes[wf] = nil
			changed = true
		end
	end
	return changed
end

local function key(wf: string, id: string): string
	return `{wf}\0{id}`
end

local function fingerprint(it: Item): string
	return `{it.kind}\0{it.title}\0{it.detail or ""}\0{it.url or ""}`
end

-- Hides item `id` of `wf` until it changes. False when there is no such item.
function M.dismiss(b: Book, wf: string, id: string, boxes: { [string]: Box }?): boolean
	local src = boxes or b.boxes
	local box = src[wf]
	local items: { Item } = if box then box.items else {}
	for _, it in items do
		if it.id == id then
			local k = key(wf, id)
			b.dismissed[k] = fingerprint(it)
			local names = util.keys(b.dismissed)
			if #names > M.MAX_DISMISSED then
				-- No order is kept: drop arbitrary others (a dropped one only shows again).
				local extra = #names - M.MAX_DISMISSED
				for _, n in names do
					if extra == 0 then
						break
					elseif n ~= k then
						b.dismissed[n] = nil
						extra -= 1
					end
				end
			end
			return true
		end
	end
	return false
end

-- Every item not dismissed (or changed since), most pressing kind first, newest first.
function M.list(b: Book, boxes: { [string]: Box }?): { Entry }
	local out: { Entry } = {}
	for wf, box in boxes or b.boxes do
		for _, it in box.items do
			if b.dismissed[key(wf, it.id)] ~= fingerprint(it) then
				local e = table.clone(it) :: any
				e.workflow = wf
				table.insert(out, e :: Entry)
			end
		end
	end
	table.sort(out, function(x: Entry, y: Entry): boolean
		local rx, ry = RANK[x.kind] or 99, RANK[y.kind] or 99
		if rx ~= ry then
			return rx < ry
		end
		if x.at ~= y.at then
			return x.at > y.at
		end
		return x.workflow .. x.id < y.workflow .. y.id
	end)
	return out
end

local function decode_boxes(v: any): { [string]: Box }
	local boxes: { [string]: Box } = {}
	if type(v) ~= "table" then
		return boxes
	end
	local n = 0
	for wf, box in v do
		if n >= M.MAX_WORKFLOWS then
			break
		end
		if valid_workflow(wf) and type(box) == "table" and type(box.items) == "table" then
			local items: { Item } = {}
			for _, x in box.items do
				local it = item(x, if type(x) == "table" and type(x.at) == "number" then x.at else 0)
				if it and #items < M.MAX_ITEMS then
					table.insert(items, it)
				end
			end
			if #items > 0 then
				boxes[wf] = { at = if type(box.at) == "number" then box.at else 0, run = if type(box.run) == "string" then box.run else "", items = items }
				n += 1
			end
		end
	end
	return boxes
end

-- The boxes as JSON-ready data (also what the executor uploads for observers).
function M.encode_boxes(boxes: { [string]: Box }): { [string]: any }
	local out: { [string]: any } = {}
	for wf, box in boxes do
		local items = {}
		for _, it in box.items do
			table.insert(items, {
				id = it.id,
				title = it.title,
				detail = it.detail,
				url = it.url,
				kind = it.kind,
				run = it.run,
				at = it.at,
			})
		end
		out[wf] = { at = box.at, run = box.run, items = tern.json.array(items) }
	end
	return out
end

function M.decode_boxes(v: any): { [string]: Box }
	return decode_boxes(v)
end

local function read(path: string): Book?
	local ok, raw = pcall(tern.fs.read, path, MAX_STORE)
	if not ok then
		return nil
	end
	local okj, v = pcall(tern.json.decode, raw :: string)
	if not okj or type(v) ~= "table" then
		return nil
	end
	local dismissed: { [string]: string } = {}
	if type(v.dismissed) == "table" then
		for k, f in v.dismissed do
			if type(k) == "string" and type(f) == "string" and #k <= 200 then
				dismissed[k] = f
			end
		end
	end
	return { boxes = decode_boxes(v.boxes), dismissed = dismissed }
end

-- The saved book (its .bak when the file is unreadable), or an empty one.
function M.load(data: string): Book
	local path = `{data}/{M.FILE}`
	return read(path) or read(path .. ".bak") or M.empty()
end

function M.save(data: string, b: Book): string?
	local path = `{data}/{M.FILE}`
	local ok, err = pcall(function(): string?
		local text = tern.json.encode({ version = 1, boxes = M.encode_boxes(b.boxes), dismissed = b.dismissed })
		-- Only a readable file becomes the backup: a corrupt one never replaces a good .bak.
		if tern.fs.exists(path) and read(path) then
			tern.fs.write(path .. ".bak", tern.fs.read(path, MAX_STORE))
		end
		tern.fs.write(path, text)
		return nil
	end)
	return if ok then nil else tostring(err)
end

return M
