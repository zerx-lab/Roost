--!strict
-- Five-field Vixie cron, pure Luau (no tern.*).
--
-- Day-of-month and day-of-week: if neither field starts with `*`, a day matches when either
-- field matches; otherwise both must. Sunday is 0 and 7. Local time is os.date("*t"); UTC is
-- os.date("!*t"). next() jumps whole months, days and hours, re-reads the date table after
-- every jump, and skips a civil time that falls in a DST gap. Search stops after 5 years or
-- 200000 iterations. Expressions longer than 512 bytes are rejected.

local M = {}

export type FieldSet = { [number]: boolean }

export type Cron = {
	expr: string,
	minute: FieldSet,
	hour: FieldSet,
	dom: FieldSet,
	month: FieldSet,
	dow: FieldSet,
	dom_star: boolean,
	dow_star: boolean,
}

local MAX_EXPR = 512
local SEARCH_CAP = 200000
-- A little over five calendar years, so a Feb 29 four years out is still inside.
local HORIZON = 5 * 366 * 86400

local FIELD_NAME: { string } = { "分钟", "小时", "日", "月", "星期" }
local FIELD_LO: { number } = { 0, 0, 1, 1, 0 }
local FIELD_HI: { number } = { 59, 23, 31, 12, 7 }

local MONTH_NAMES: { [string]: number } = {
	JAN = 1,
	FEB = 2,
	MAR = 3,
	APR = 4,
	MAY = 5,
	JUN = 6,
	JUL = 7,
	AUG = 8,
	SEP = 9,
	OCT = 10,
	NOV = 11,
	DEC = 12,
}

local DOW_NAMES: { [string]: number } = {
	SUN = 0,
	MON = 1,
	TUE = 2,
	WED = 3,
	THU = 4,
	FRI = 5,
	SAT = 6,
}

local MACROS: { [string]: string } = {
	yearly = "0 0 1 1 *",
	annually = "0 0 1 1 *",
	monthly = "0 0 1 * *",
	weekly = "0 0 * * 0",
	daily = "0 0 * * *",
	midnight = "0 0 * * *",
	hourly = "0 * * * *",
}

local DIM: { number } = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local WEEK: { string } = { "日", "一", "二", "三", "四", "五", "六" }

type Civil = {
	year: number,
	month: number,
	day: number,
	hour: number,
	min: number,
	sec: number,
	dow: number,
}

local function field_label(idx: number): string
	return FIELD_NAME[idx] or "?"
end

local function ferr(idx: number, body: string): string
	return string.format("第 %d 段(%s)%s", idx, field_label(idx), body)
end

local function is_leap(y: number): boolean
	return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local function days_in_month(y: number, m: number): number
	if m == 2 and is_leap(y) then
		return 29
	end
	local n = DIM[m]
	return if n ~= nil then n else 30
end

-- Howard Hinnant, days since 1970-01-01. Valid for the proleptic Gregorian calendar.
local function days_from_civil(y: number, m: number, d: number): number
	local yy = y - if m <= 2 then 1 else 0
	local era = math.floor(yy / 400)
	local yoe = yy - era * 400
	local doy = math.floor((153 * (m + if m > 2 then -3 else 9) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function utc_epoch(y: number, m: number, d: number, h: number, minute: number): number
	return days_from_civil(y, m, d) * 86400 + h * 3600 + minute * 60
end

-- 1970-01-01 was Thursday (cron dow 4).
local function dow_of(y: number, m: number, d: number): number
	return (days_from_civil(y, m, d) + 4) % 7
end

local function read_civil(utc: boolean, epoch: number): Civil?
	local ok, result = pcall(function(): any
		return if utc then os.date("!*t", epoch) else os.date("*t", epoch)
	end)
	if not ok or type(result) ~= "table" then
		return nil
	end
	local year = result.year
	local month = result.month
	local day = result.day
	local hour = result.hour
	local minute = result.min
	local sec = result.sec
	local wday = result.wday
	if type(year) ~= "number" or type(month) ~= "number" or type(day) ~= "number" or type(hour) ~= "number" or type(minute) ~= "number" or type(sec) ~= "number" or type(wday) ~= "number" then
		return nil
	end
	return {
		year = year,
		month = month,
		day = day,
		hour = hour,
		min = minute,
		sec = sec,
		dow = wday - 1,
	}
end

local function day_matches(c: Cron, day: number, dow: number): boolean
	local dom_ok = c.dom[day] == true
	local dow_ok = c.dow[dow] == true
	if c.dom_star or c.dow_star then
		return dom_ok and dow_ok
	end
	return dom_ok or dow_ok
end

-- Local offset in seconds (local civil clock minus Unix epoch) at `epoch`.
local function offset_at(epoch: number): number?
	local t = read_civil(false, epoch)
	if t == nil then
		return nil
	end
	return utc_epoch(t.year, t.month, t.day, t.hour, t.min) + t.sec - epoch
end

-- Epoch of a local civil minute strictly after `hint`, or nil if that clock time does not
-- exist (DST gap, or the only occurrence is already past). A repeated hour is resolved by
-- taking the later fold when the earlier one is not strictly after `hint`.
local function local_resolve(y: number, m: number, d: number, h: number, minute: number, hint: number): number?
	local off = offset_at(hint)
	if off == nil then
		return nil
	end
	local want = utc_epoch(y, m, d, h, minute)
	local guess = want - off
	local seen: { [number]: boolean } = {}
	for _ = 1, 4 do
		if guess ~= guess or guess >= math.huge or guess <= -math.huge then
			return nil
		end
		guess = math.floor(guess + 0.5)
		if seen[guess] then
			return nil
		end
		seen[guess] = true
		local t = read_civil(false, guess)
		if t == nil then
			return nil
		end
		if t.year == y and t.month == m and t.day == d and t.hour == h and t.min == minute and t.sec == 0 then
			if guess > hint then
				return guess
			end
			local later = guess + 3600
			local t2 = read_civil(false, later)
			if t2 ~= nil and later > hint and t2.year == y and t2.month == m and t2.day == d and t2.hour == h and t2.min == minute and t2.sec == 0 then
				return later
			end
			return nil
		end
		local actual = utc_epoch(t.year, t.month, t.day, t.hour, t.min) + t.sec
		local delta = want - actual
		if delta == 0 then
			return nil
		end
		guess += delta
	end
	return nil
end

local function advance_to(utc: boolean, y: number, m: number, d: number, h: number, minute: number, hint: number): number
	if utc then
		local e = utc_epoch(y, m, d, h, minute)
		return if e > hint then e else hint + 60
	end
	local e = local_resolve(y, m, d, h, minute, hint)
	return if e ~= nil and e > hint then e else hint + 60
end

-- True when an hour of epoch later the local clock has not moved a full hour forward
-- (fall-back overlap, including a 30-minute fold).
local function clock_folded(epoch: number, t: Civil): boolean
	local ahead = read_civil(false, epoch + 3600)
	if ahead == nil then
		return false
	end
	local ahead_abs = utc_epoch(ahead.year, ahead.month, ahead.day, ahead.hour, ahead.min) + ahead.sec
	local now_abs = utc_epoch(t.year, t.month, t.day, t.hour, t.min) + t.sec
	return ahead_abs < now_abs + 3600
end

local function jump_month(c: Cron, utc: boolean, t: Civil, epoch: number): number
	local y = t.year
	local m = t.month
	for _ = 1, 48 do
		m += 1
		if m > 12 then
			m = 1
			y += 1
		end
		if c.month[m] then
			return advance_to(utc, y, m, 1, 0, 0, epoch)
		end
	end
	return epoch + 60
end

local function next_day_start(utc: boolean, t: Civil, epoch: number): number
	local y = t.year
	local m = t.month
	local d = t.day + 1
	if d > days_in_month(y, m) then
		d = 1
		m += 1
		if m > 12 then
			m = 1
			y += 1
		end
	end
	return advance_to(utc, y, m, d, 0, 0, epoch)
end

local function jump_day(c: Cron, utc: boolean, t: Civil, epoch: number): number
	local y = t.year
	local m = t.month
	local dim = days_in_month(y, m)
	local last = math.min(dim, t.day + 31)
	for dd = t.day + 1, last do
		if day_matches(c, dd, dow_of(y, m, dd)) then
			return advance_to(utc, y, m, dd, 0, 0, epoch)
		end
	end
	m += 1
	if m > 12 then
		m = 1
		y += 1
	end
	return advance_to(utc, y, m, 1, 0, 0, epoch)
end

local function jump_hour(c: Cron, utc: boolean, t: Civil, epoch: number): number
	for h = t.hour + 1, 23 do
		if c.hour[h] then
			return advance_to(utc, t.year, t.month, t.day, h, 0, epoch)
		end
	end
	return next_day_start(utc, t, epoch)
end

local function bump(epoch: number, nxt: number): number
	return if nxt > epoch then nxt else epoch + 60
end

-- First minute boundary strictly after `after`. Epoch minutes are 60s apart; timezone
-- offsets in use are whole minutes, so a local minute start is also epoch-aligned.
local function first_candidate(after: number): number?
	if after ~= after or after >= math.huge or after <= -math.huge then
		return nil
	end
	local e = math.floor(after / 60) * 60 + 60
	if e <= after then
		e += 60
	end
	return e
end

local function is_digit(b: number): boolean
	return b >= 48 and b <= 57
end

local function is_alpha(b: number): boolean
	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- Integer token, or nil. More than 6 digits is reported as out of range by the caller via raw.
local function read_int(s: string, i: number): (number?, number, string)
	local b = string.byte(s, i)
	if b == nil or not is_digit(b) then
		return nil, i, ""
	end
	local j = i
	local n = 0
	local digits = 0
	while j <= #s do
		local c = string.byte(s, j)
		if c == nil or not is_digit(c) then
			break
		end
		digits += 1
		if digits <= 6 then
			n = n * 10 + (c - 48)
		end
		j += 1
		if digits > 12 then
			break
		end
	end
	if digits > 6 then
		return 1000000, j, string.sub(s, i, j - 1)
	end
	return n, j, string.sub(s, i, j - 1)
end

-- Number or, when `names` is set, a 3-letter name. `bad` is set when the token is not a value.
local function read_value(s: string, i: number, names: { [string]: number }?): (number?, number, string, boolean)
	local b = string.byte(s, i)
	if b == nil then
		return nil, i, "", true
	end
	if is_digit(b) then
		local n, j, raw = read_int(s, i)
		return n, j, raw, n == nil
	end
	if names ~= nil and is_alpha(b) then
		local j = i
		while j <= #s do
			local c = string.byte(s, j)
			if c == nil or not is_alpha(c) then
				break
			end
			j += 1
			if j - i > 12 then
				break
			end
		end
		local raw = string.sub(s, i, j - 1)
		if #raw == 3 then
			local v = names[string.upper(raw)]
			if v ~= nil then
				return v, j, raw, false
			end
		end
		return nil, j, raw, true
	end
	return nil, i, string.sub(s, i, i), true
end

local function fill(set: FieldSet, start_n: number, stop_n: number, step: number, is_dow: boolean)
	local count = math.floor((stop_n - start_n) / step) + 1
	if count < 1 then
		count = 1
	elseif count > 64 then
		count = 64
	end
	for i = 0, count - 1 do
		local v = start_n + i * step
		if is_dow and v == 7 then
			v = 0
		end
		set[v] = true
	end
end

-- One comma-separated item. Returns a Chinese error body (no field prefix) or nil.
local function parse_item(item: string, set: FieldSet, lo: number, hi: number, names: { [string]: number }?, is_dow: boolean): string?
	if item == "" then
		return "有空项"
	end
	local start_n: number
	local stop_n: number
	local step: number
	local start_raw: string
	local stop_raw: string

	if string.byte(item, 1) == 42 then
		start_n = lo
		stop_n = hi
		start_raw = "*"
		stop_raw = "*"
		local i = 2
		if i <= #item then
			if string.byte(item, i) ~= 47 then
				return "无法识别: " .. item
			end
			local n, j, _raw = read_int(item, i + 1)
			if n == nil or j ~= #item + 1 then
				return "步长无效"
			end
			step = n
		else
			step = 1
		end
	else
		local n, j, raw, bad = read_value(item, 1, names)
		if bad or n == nil then
			return "无法识别: " .. item
		end
		start_n = n
		start_raw = raw
		local i = j
		local ranged = false
		if i <= #item and string.byte(item, i) == 45 then
			local n2, j2, raw2, bad2 = read_value(item, i + 1, names)
			if bad2 or n2 == nil then
				return "无法识别: " .. item
			end
			stop_n = n2
			stop_raw = raw2
			i = j2
			ranged = true
		end
		if i <= #item and string.byte(item, i) == 47 then
			local n3, j3, _raw3 = read_int(item, i + 1)
			if n3 == nil or j3 ~= #item + 1 then
				return "步长无效"
			end
			step = n3
			if not ranged then
				stop_n = hi
				stop_raw = tostring(hi)
			end
		elseif i ~= #item + 1 then
			return "无法识别: " .. item
		else
			step = 1
			if not ranged then
				stop_n = start_n
				stop_raw = start_raw
			end
		end
	end

	if step == 0 then
		return "步长不能为 0"
	end
	if start_n < lo or start_n > hi then
		return string.format("超出范围 %d-%d: %s", lo, hi, start_raw)
	end
	if stop_n < lo or stop_n > hi then
		return string.format("超出范围 %d-%d: %s", lo, hi, stop_raw)
	end
	if start_n > stop_n then
		return "范围颠倒: " .. item
	end
	fill(set, start_n, stop_n, step, is_dow)
	return nil
end

local function split_comma(s: string): ({ string }?, string?)
	local out: { string } = {}
	local start_i = 1
	local n = #s
	if n == 0 then
		return nil, "有空项"
	end
	for i = 1, n + 1 do
		if i == n + 1 or string.byte(s, i) == 44 then
			if i == start_i then
				return nil, "有空项"
			end
			table.insert(out, string.sub(s, start_i, i - 1))
			start_i = i + 1
			if #out > 64 then
				return nil, "项太多"
			end
		end
	end
	return out, nil
end

local function parse_field(field: string, idx: number): (FieldSet?, string?)
	local lo = FIELD_LO[idx]
	local hi = FIELD_HI[idx]
	if lo == nil or hi == nil then
		return nil, ferr(idx, "无法识别: " .. field)
	end
	local names: { [string]: number }? = if idx == 4 then MONTH_NAMES elseif idx == 5 then DOW_NAMES else nil
	local items, split_err = split_comma(field)
	if items == nil then
		return nil, ferr(idx, split_err or "无法识别: " .. field)
	end
	local set: FieldSet = {}
	for _, item in items do
		local body = parse_item(item, set, lo, hi, names, idx == 5)
		if body ~= nil then
			return nil, ferr(idx, body)
		end
	end
	return set, nil
end

local function split_ws(s: string): { string }
	local out: { string } = {}
	for field in string.gmatch(s, "%S+") do
		table.insert(out, field)
		if #out > 8 then
			break
		end
	end
	return out
end

local function parse_fields(expr: string, fields: { string }): (Cron?, string?)
	if #fields ~= 5 then
		return nil, string.format("需要 5 段,实际 %d 段", #fields)
	end
	local sets: { FieldSet } = {}
	for idx = 1, 5 do
		local field = fields[idx]
		if field == nil then
			return nil, string.format("需要 5 段,实际 %d 段", #fields)
		end
		local set, err = parse_field(field, idx)
		if set == nil then
			return nil, err
		end
		sets[idx] = set
	end
	local minute = sets[1]
	local hour = sets[2]
	local dom = sets[3]
	local month = sets[4]
	local dow = sets[5]
	if minute == nil or hour == nil or dom == nil or month == nil or dow == nil then
		return nil, "需要 5 段,实际 0 段"
	end
	local dom_field = fields[3] or ""
	local dow_field = fields[5] or ""
	local cron: Cron = {
		expr = expr,
		minute = minute,
		hour = hour,
		dom = dom,
		month = month,
		dow = dow,
		dom_star = string.sub(dom_field, 1, 1) == "*",
		dow_star = string.sub(dow_field, 1, 1) == "*",
	}
	return cron, nil
end

function M.parse(expr: string): (Cron?, string?)
	if type(expr) ~= "string" then
		return nil, "表达式为空"
	end
	if #expr > MAX_EXPR then
		return nil, "表达式过长"
	end
	local s = string.match(expr, "^%s*(.-)%s*$")
	if s == nil or s == "" then
		return nil, "表达式为空"
	end
	if #s > MAX_EXPR then
		return nil, "表达式过长"
	end
	if string.sub(s, 1, 1) == "@" then
		local name, extra = string.match(s, "^@(%a+)(.*)$")
		if name == nil then
			return nil, "未知的宏: " .. s
		end
		if extra ~= "" then
			return nil, "宏后面有多余内容"
		end
		local expanded = MACROS[string.lower(name)]
		if expanded == nil then
			return nil, "未知的宏: @" .. name
		end
		local cron, err = parse_fields(s, split_ws(expanded))
		return cron, err
	end
	return parse_fields(s, split_ws(s))
end

function M.matches(c: Cron, epoch: number, utc: boolean): boolean
	if epoch ~= epoch or epoch >= math.huge or epoch <= -math.huge then
		return false
	end
	local t = read_civil(utc, epoch)
	if t == nil then
		return false
	end
	if not c.minute[t.min] or not c.hour[t.hour] or not c.month[t.month] then
		return false
	end
	return day_matches(c, t.day, t.dow)
end

function M.next(c: Cron, after: number, utc: boolean): number?
	local epoch = first_candidate(after)
	if epoch == nil then
		return nil
	end
	local limit = after + HORIZON
	if limit ~= limit or limit == math.huge then
		return nil
	end
	for _ = 1, SEARCH_CAP do
		if epoch > limit then
			return nil
		end
		local t = read_civil(utc, epoch)
		if t == nil then
			return nil
		end
		if t.sec ~= 0 then
			local slip = t.sec % 60
			epoch += if slip == 0 then 60 else 60 - slip
			continue
		end
		if not c.month[t.month] then
			epoch = bump(epoch, jump_month(c, utc, t, epoch))
			continue
		end
		if not day_matches(c, t.day, t.dow) then
			epoch = bump(epoch, jump_day(c, utc, t, epoch))
			continue
		end
		local folded = not utc and clock_folded(epoch, t)
		if not c.hour[t.hour] then
			epoch = if folded then epoch + 60 else bump(epoch, jump_hour(c, utc, t, epoch))
			continue
		end
		if not c.minute[t.min] then
			local nxt_min: number? = nil
			for m = t.min + 1, 59 do
				if c.minute[m] then
					nxt_min = m
					break
				end
			end
			if nxt_min ~= nil then
				epoch += (nxt_min - t.min) * 60
			elseif folded then
				epoch += 60
			else
				epoch = bump(epoch, jump_hour(c, utc, t, epoch))
			end
			continue
		end
		if epoch > after then
			return epoch
		end
		epoch += 60
	end
	return nil
end

local function covers(set: FieldSet, lo: number, hi: number): boolean
	for n = lo, hi do
		if not set[n] then
			return false
		end
	end
	return true
end

local function sole(set: FieldSet, lo: number, hi: number): number?
	local found: number? = nil
	for n = lo, hi do
		if set[n] then
			if found ~= nil then
				return nil
			end
			found = n
		end
	end
	return found
end

local function weekdays(set: FieldSet): boolean
	for n = 0, 6 do
		local want = n >= 1 and n <= 5
		if (set[n] == true) ~= want then
			return false
		end
	end
	return true
end

-- Step from 0 with at least two hits (`*/5`), or nil.
local function minute_step(set: FieldSet): number?
	if not set[0] then
		return nil
	end
	local step: number? = nil
	for n = 1, 59 do
		if set[n] then
			step = n
			break
		end
	end
	if step == nil or step < 2 then
		return nil
	end
	for n = 0, 59 do
		local on = n % step == 0
		if (set[n] == true) ~= on then
			return nil
		end
	end
	return step
end

local function hm(hour: number, minute: number): string
	return string.format("%02d:%02d", hour, minute)
end

function M.describe(c: Cron): string
	local min_all = covers(c.minute, 0, 59)
	local hour_all = covers(c.hour, 0, 23)
	local dom_all = covers(c.dom, 1, 31)
	local mon_all = covers(c.month, 1, 12)
	local dow_all = covers(c.dow, 0, 6)
	if min_all and hour_all and dom_all and mon_all and dow_all then
		return "每分钟"
	end
	if hour_all and dom_all and mon_all and dow_all then
		local step = minute_step(c.minute)
		if step ~= nil then
			return "每 " .. tostring(step) .. " 分钟"
		end
		if sole(c.minute, 0, 59) == 0 then
			return "每小时整点"
		end
	end
	local minute = sole(c.minute, 0, 59)
	local hour = sole(c.hour, 0, 23)
	if minute ~= nil and hour ~= nil and mon_all then
		local clock = hm(hour, minute)
		if dom_all and weekdays(c.dow) then
			return "工作日 " .. clock
		end
		if dom_all then
			local d = sole(c.dow, 0, 6)
			local name = if d ~= nil then WEEK[d + 1] else nil
			if name ~= nil then
				return "每周" .. name .. " " .. clock
			end
		end
		if dom_all and dow_all then
			return "每天 " .. clock
		end
		local dom = sole(c.dom, 1, 31)
		if dom ~= nil and dow_all then
			return "每月 " .. tostring(dom) .. " 日 " .. clock
		end
	end
	return c.expr
end

return M
