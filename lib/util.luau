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

-- An RFC 3339 timestamp (the agent's, UTC or with an offset) as epoch seconds.
function M.rfc3339(s: any): number?
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = string.match(s, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local Y, Mo, D = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	-- Days from civil (proleptic Gregorian), UTC.
	local yy = if Mo <= 2 then Y - 1 else Y
	local era = math.floor(yy / 400)
	local yoe = yy - era * 400
	local mp = (Mo + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + D - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	local days = era * 146097 + doe - 719468
	local t = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(se) :: number)
	local sign, oh, om = string.match(s, "([%+%-])(%d%d):?(%d%d)$")
	if sign and oh and om then
		local off = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		t = if sign == "+" then t - off else t + off
	end
	return t
end

-- `1.2 MiB` style size of `bytes`.
function M.fmt_bytes(bytes: number): string
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local v, i = math.max(0, bytes), 1
	while v >= 1024 and i < #units do
		v /= 1024
		i += 1
	end
	return if i == 1 then `{math.floor(v)} B` else string.format("%.1f %s", v, units[i])
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

-- East Asian wide and fullwidth ranges (CJK, Hangul, fullwidth forms, emoji): two cells each.
local function wide(cp: number): boolean
	return (cp >= 0x1100 and cp <= 0x115F)
		or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
		or (cp >= 0xAC00 and cp <= 0xD7A3)
		or (cp >= 0xF900 and cp <= 0xFAFF)
		or (cp >= 0xFE30 and cp <= 0xFE4F)
		or (cp >= 0xFF00 and cp <= 0xFF60)
		or (cp >= 0xFFE0 and cp <= 0xFFE6)
		or (cp >= 0x1F300 and cp <= 0x1F64F)
		or (cp >= 0x1F900 and cp <= 0x1F9FF)
		or (cp >= 0x20000 and cp <= 0x3FFFD)
end

-- Terminal cells one output line takes: escape sequences take none, `\r` returns to the first
-- column (the widest pass counts), a tab moves to the next multiple of 8, `\b` steps back, wide
-- characters take two. Bytes that are not UTF-8 are skipped.
function M.cells(line: string): number
	local s = string.gsub(line, "\27%][^\7\27]*\7", "")
	s = string.gsub(s, "\27%][^\7\27]*\27\\", "")
	s = string.gsub(s, "\27%[[0-?]*[ -/]*[@-~]", "")
	s = string.gsub(s, "\27.", "")
	local col, best = 0, 0
	for ch in string.gmatch(s, utf8.charpattern) do
		local b = string.byte(ch)
		local n = #ch
		if n == 1 then
			if b == 13 then
				col = 0
			elseif b == 9 then
				col += 8 - col % 8
			elseif b == 8 then
				col = math.max(0, col - 1)
			elseif b >= 32 and b ~= 127 then
				col += 1
			end
		else
			local cp = 0
			if n == 2 then
				cp = (b % 32) * 64 + string.byte(ch, 2) % 64
			elseif n == 3 then
				cp = (b % 16) * 4096 + (string.byte(ch, 2) % 64) * 64 + string.byte(ch, 3) % 64
			elseif n == 4 then
				cp = (b % 8) * 262144 + (string.byte(ch, 2) % 64) * 4096 + (string.byte(ch, 3) % 64) * 64 + string.byte(ch, 4) % 64
			end
			col += if wide(cp) then 2 else 1
		end
		best = math.max(best, col)
	end
	return best
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
