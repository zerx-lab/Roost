--!strict
-- Small pure helpers shared by the runtime and the views.

local M = {}

-- `s` quoted for POSIX sh.
function M.shq(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Parses `90`, `90s`, `30m`, `2h`, `1h30m`, `1d` into seconds.
function M.duration(s: string): (number?, string?)
	local t = string.lower((string.gsub(s, "%s", "")))
	if t == "" then
		return nil, "空时长"
	end
	local n = tonumber(t)
	if n and n >= 0 and n == math.floor(n) then
		return n, nil
	end
	local total, pos = 0, 1
	local units: { [string]: number } = { s = 1, m = 60, h = 3600, d = 86400 }
	while pos <= #t do
		local a, b, num, unit = string.find(t, "^(%d+)([smhd])", pos)
		if not a then
			return nil, `时长 "{s}" 无效(用 90s、30m、1h30m、1d)`
		end
		total += (tonumber(num) :: number) * units[unit :: string]
		pos = (b :: number) + 1
	end
	return total, nil
end

-- `1h30m`, `45s`, `0s`.
function M.fmt_duration(sec: number): string
	sec = math.max(0, math.floor(sec))
	if sec < 60 then
		return `{sec}s`
	end
	local out = {}
	local sizes = { 86400, 3600, 60, 1 }
	local names = { "d", "h", "m", "s" }
	for i, size in sizes do
		local n = math.floor(sec / size)
		if n > 0 then
			table.insert(out, `{n}{names[i]}`)
			sec -= n * size
		end
		if #out == 2 then
			break
		end
	end
	return table.concat(out)
end

-- "3 分钟前" style relative time from `now` (epoch seconds).
function M.ago(t: number?, now: number): string
	if t == nil then
		return "—"
	end
	local d = now - t
	if d < 0 then
		return M.until_(t, now)
	elseif d < 10 then
		return "刚刚"
	elseif d < 60 then
		return `{math.floor(d)} 秒前`
	elseif d < 3600 then
		return `{math.floor(d / 60)} 分钟前`
	elseif d < 86400 then
		return `{math.floor(d / 3600)} 小时前`
	end
	return `{math.floor(d / 86400)} 天前`
end

-- "3 分钟后" style.
function M.until_(t: number, now: number): string
	local d = t - now
	if d < 60 then
		return "1 分钟内"
	elseif d < 3600 then
		return `{math.ceil(d / 60)} 分钟后`
	elseif d < 86400 then
		return `{math.floor(d / 3600)} 小时后`
	end
	return `{math.floor(d / 86400)} 天后`
end

-- `MM-DD HH:MM` in local time.
function M.clock(t: number?): string
	if t == nil then
		return "—"
	end
	return os.date("%m-%d %H:%M", t) :: string
end

-- At most `n` characters of `s` (UTF-8 aware), with an ellipsis when cut.
function M.clip(s: string, n: number): string
	local len = utf8.len(s)
	if len == nil or len <= n then
		return s
	end
	local cut = utf8.offset(s, n + 1)
	return string.sub(s, 1, (cut or (#s + 1)) - 1) .. "…"
end

-- The first line of `s`.
function M.first_line(s: string): string
	return (string.match(s, "^[^\r\n]*") or "")
end

-- Expands a leading `~` with `home`.
function M.expand(path: string, home: string?): string
	if home and (path == "~" or string.sub(path, 1, 2) == "~/") then
		return home .. string.sub(path, 2)
	end
	return path
end

function M.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- Case-insensitive lookup of `key` in a string-keyed table.
function M.ifind<T>(t: { [string]: T }, key: string): (string?, T?)
	local v = t[key]
	if v ~= nil then
		return key, v
	end
	local low = string.lower(key)
	for k, x in t do
		if string.lower(k) == low then
			return k, x
		end
	end
	return nil, nil
end

-- Sorted keys of a string-keyed table.
function M.keys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- Deep structural equality for JSON-like values.
function M.equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not M.equal(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

return M
