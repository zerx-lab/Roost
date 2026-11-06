--!strict
-- Workflow groups on the workflows page: named, ordered, foldable groups and which workflow sits
-- in which. Layout only (nothing runs differently), so it lives in its own file, groups.json, not
-- in workflows.toml: the editor, export/import and evolvers never see it.
--
-- groups.json: {"groups": [{"id": "g1", "name": "…", "collapsed": false}, …], "of": {"<workflow id>": "g1"}}
-- Saved like events.json: `.bak` first, then the file; load falls back to the backup. A file that
-- exists but neither copy decodes makes `load` report an error, and core then refuses to save
-- over it (the user's groups would be lost).
--
-- Every mutation works on the table it is given; core passes a copy and keeps it only once saved.

local M = {}

export type Group = { id: string, name: string, collapsed: boolean }
export type Groups = {
	list: { Group }, -- display order
	of: { [string]: string }, -- workflow id -> group id
}

M.MAX = 50
M.NAME_MAX = 40
local MAX_BYTES = 256 * 1024

function M.empty(): Groups
	return { list = {}, of = {} }
end

local function valid_gid(v: any): boolean
	return type(v) == "string" and string.match(v, "^g%d+$") ~= nil and #v <= 12
end

-- Rebuilds `v` field by field (no decoded, metatable-tagged table stays); drops what is malformed.
function M.decode(v: any): Groups
	local g = M.empty()
	if type(v) ~= "table" then
		return g
	end
	local seen: { [string]: boolean } = {}
	if type(v.groups) == "table" then
		for _, x in v.groups do
			if #g.list >= M.MAX then
				break
			end
			if type(x) == "table" and valid_gid(x.id) and not seen[x.id] and type(x.name) == "string" and x.name ~= "" then
				seen[x.id] = true
				table.insert(g.list, { id = x.id, name = x.name, collapsed = x.collapsed == true })
			end
		end
	end
	if type(v.of) == "table" then
		for wf, gid in v.of do
			if type(wf) == "string" and type(gid) == "string" and seen[gid] then
				g.of[wf] = gid
			end
		end
	end
	return g
end

function M.clone(g: Groups): Groups
	local out = M.empty()
	for _, x in g.list do
		table.insert(out.list, { id = x.id, name = x.name, collapsed = x.collapsed })
	end
	for wf, gid in g.of do
		out.of[wf] = gid
	end
	return out
end

function M.find(g: Groups, id: string): (Group?, number?)
	for i, x in g.list do
		if x.id == id then
			return x, i
		end
	end
	return nil, nil
end

-- Why `name` can't name a group (nil when it can); `except`: the group being renamed.
function M.check_name(g: Groups, name: string, except: string?): string?
	if name == "" then
		return "请填写分组名"
	end
	local len = utf8.len(name)
	if len == nil then
		return "分组名不是有效的 UTF-8"
	elseif len > M.NAME_MAX then
		return `分组名最多 {M.NAME_MAX} 个字符`
	elseif string.find(name, "[%c]") then
		return "分组名不能含控制字符"
	end
	for _, x in g.list do
		if x.name == name and x.id ~= except then
			return `已有分组「{name}」`
		end
	end
	return nil
end

-- Adds a group at the end; returns its id.
function M.create(g: Groups, name: string): (string?, string?)
	if #g.list >= M.MAX then
		return nil, `最多 {M.MAX} 个分组`
	end
	local err = M.check_name(g, name, nil)
	if err then
		return nil, err
	end
	local n = 0
	for _, x in g.list do
		n = math.max(n, tonumber(string.sub(x.id, 2)) or 0)
	end
	local id = `g{n + 1}`
	table.insert(g.list, { id = id, name = name, collapsed = false })
	return id, nil
end

function M.rename(g: Groups, id: string, name: string): string?
	local x = M.find(g, id)
	if x == nil then
		return "分组不存在"
	end
	local err = M.check_name(g, name, id)
	if err then
		return err
	end
	x.name = name
	return nil
end

-- Drops the group; its workflows become ungrouped.
function M.remove(g: Groups, id: string): string?
	local _, i = M.find(g, id)
	if i == nil then
		return "分组不存在"
	end
	table.remove(g.list, i)
	for wf, gid in g.of do
		if gid == id then
			g.of[wf] = nil
		end
	end
	return nil
end

-- Moves the group `delta` places along the order; false when it can't move that way.
function M.move(g: Groups, id: string, delta: number): boolean
	local _, i = M.find(g, id)
	if i == nil then
		return false
	end
	local j = i + delta
	if j < 1 or j > #g.list then
		return false
	end
	local x = table.remove(g.list, i) :: Group
	table.insert(g.list, j, x)
	return true
end

function M.toggle(g: Groups, id: string): string?
	local x = M.find(g, id)
	if x == nil then
		return "分组不存在"
	end
	x.collapsed = not x.collapsed
	return nil
end

-- Puts workflow `wf` in group `gid` (nil: ungrouped).
function M.assign(g: Groups, wf: string, gid: string?): string?
	if gid ~= nil and M.find(g, gid) == nil then
		return "分组不存在"
	end
	if gid == nil then
		g.of[wf] = nil
	else
		g.of[wf] = gid
	end
	return nil
end

-- The group workflow `wf` is in (nil: ungrouped, or its group is gone).
function M.group_of(g: Groups, wf: string): string?
	local gid = g.of[wf]
	return if gid and M.find(g, gid) then gid else nil
end

export type Section<W> = { group: Group?, items: { W } }

-- The page's sections: every group in order (empty ones too), then the ungrouped workflows when
-- there are any. Workflows keep their workflows.toml order inside a section.
function M.sections<W>(g: Groups, list: { W }, id_of: (W) -> string): { Section<W> }
	local out: { Section<W> } = {}
	local at: { [string]: Section<W> } = {}
	for _, x in g.list do
		local s: Section<W> = { group = x, items = {} }
		table.insert(out, s)
		at[x.id] = s
	end
	local rest: Section<W> = { group = nil, items = {} }
	for _, wf in list do
		local gid = g.of[id_of(wf)]
		local s = if gid then at[gid] else nil
		table.insert((s or rest).items, wf)
	end
	if #rest.items > 0 then
		table.insert(out, rest)
	end
	return out
end

function M.encode(g: Groups): string
	local list = {}
	for _, x in g.list do
		table.insert(list, { id = x.id, name = x.name, collapsed = x.collapsed })
	end
	local of: { [string]: string } = {}
	for wf, gid in g.of do
		if M.find(g, gid) then
			of[wf] = gid
		end
	end
	-- json.array tags its argument in place: the list is a fresh copy.
	return tern.json.encode({ groups = tern.json.array(list), of = of })
end

local function decode_file(path: string): (Groups?, boolean)
	if not tern.fs.exists(path) then
		return nil, false
	end
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	if not ok then
		return nil, true
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	if not ok2 or type(v) ~= "table" then
		return nil, true
	end
	return M.decode(v), true
end

-- The saved groups; an error when the file exists and neither it nor its backup decodes.
function M.load(path: string): (Groups, string?)
	local g, there = decode_file(path)
	if g then
		return g, nil
	end
	local b, bthere = decode_file(path .. ".bak")
	if b then
		return b, nil
	end
	if there or bthere then
		return M.empty(), `{path} 无法读取或不是有效的 JSON:修好或删除后重载插件`
	end
	return M.empty(), nil
end

function M.save(path: string, g: Groups): string?
	local text = M.encode(g)
	local ok, err = pcall(function(): string?
		tern.fs.write(path .. ".bak", text)
		tern.fs.write(path, text)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot save groups", err)
		return tostring(err)
	end
	return nil
end

return M
