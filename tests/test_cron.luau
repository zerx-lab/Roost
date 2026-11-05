--!strict
-- Vixie cron: syntax, the dom/dow OR rule, next() across calendar boundaries, describe.

local cron = require("../lib/cron")

local function eq(a: any, b: any, what: string)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2)
	end
end

local function must_parse(expr: string): any
	local c, err = cron.parse(expr)
	if c == nil then
		error("parse " .. expr .. ": " .. tostring(err), 2)
	end
	return c
end

local function must_fail(expr: string, expect: string)
	local c, err = cron.parse(expr)
	eq(c, nil, "reject " .. expr)
	eq(err, expect, "error for [" .. expr .. "]")
end

local function set_eq(set: any, lo: number, hi: number, want: { number }, what: string)
	local mark: { [number]: boolean } = {}
	for _, n in want do
		mark[n] = true
	end
	for n = lo, hi do
		local on = set[n] == true
		local expect = mark[n] == true
		if on ~= expect then
			error(string.format("%s: value %d on=%s expect=%s", what, n, tostring(on), tostring(expect)), 2)
		end
	end
end

-- Days from the Unix epoch. Independent of os.time; checked against os.date below.
local function days_from_civil(y: number, m: number, d: number): number
	local yy = y - if m <= 2 then 1 else 0
	local era = math.floor(yy / 400)
	local yoe = yy - era * 400
	local doy = math.floor((153 * (m + if m > 2 then -3 else 9) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function utc(y: number, m: number, d: number, h: number, minute: number, sec: number?): number
	return days_from_civil(y, m, d) * 86400 + h * 3600 + minute * 60 + (sec or 0)
end

local function cron_dow(y: number, m: number, d: number): number
	return (days_from_civil(y, m, d) + 4) % 7
end

do
	local e = utc(2028, 2, 29, 0, 0)
	local t = os.date("!*t", e)
	eq(t.year, 2028, "helper year")
	eq(t.month, 2, "helper month")
	eq(t.day, 29, "helper day")
	eq(t.hour, 0, "helper hour")
	eq(t.min, 0, "helper minute")
	eq(t.sec, 0, "helper second")
	eq(utc(1970, 1, 1, 0, 0), 0, "epoch")
	eq(cron_dow(1970, 1, 1), 4, "epoch Thursday")
	eq(cron_dow(2026, 1, 1), os.date("!*t", utc(2026, 1, 1, 0, 0)).wday - 1, "dow agrees with os.date")
end

-- ── syntax ──────────────────────────────────────────────────────────────────

do
	local c = must_parse("*/5 1-3,5 1,15 JAN-MAR MON-FRI")
	set_eq(c.minute, 0, 59, { 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55 }, "*/5")
	set_eq(c.hour, 0, 23, { 1, 2, 3, 5 }, "hour list and range")
	set_eq(c.dom, 1, 31, { 1, 15 }, "dom list")
	set_eq(c.month, 1, 12, { 1, 2, 3 }, "month names")
	set_eq(c.dow, 0, 6, { 1, 2, 3, 4, 5 }, "dow names")
	eq(c.dom_star, false, "dom not star")
	eq(c.dow_star, false, "dow not star")
	eq(c.expr, "*/5 1-3,5 1,15 JAN-MAR MON-FRI", "expr kept")
end

do
	local all_min = {}
	local all_hour = {}
	local all_dom = {}
	local all_mon = {}
	local all_dow = {}
	for n = 0, 59 do
		table.insert(all_min, n)
	end
	for n = 0, 23 do
		table.insert(all_hour, n)
	end
	for n = 1, 31 do
		table.insert(all_dom, n)
	end
	for n = 1, 12 do
		table.insert(all_mon, n)
	end
	for n = 0, 6 do
		table.insert(all_dow, n)
	end
	local c = must_parse("* * * * *")
	set_eq(c.minute, 0, 59, all_min, "star minute")
	set_eq(c.hour, 0, 23, all_hour, "star hour")
	set_eq(c.dom, 1, 31, all_dom, "star dom")
	set_eq(c.month, 1, 12, all_mon, "star month")
	set_eq(c.dow, 0, 6, all_dow, "star dow")
	eq(c.dom_star, true, "dom star")
	eq(c.dow_star, true, "dow star")
end

do
	local c = must_parse("5/15 0-23/6 1-10/3 5/2 0-7/2")
	set_eq(c.minute, 0, 59, { 5, 20, 35, 50 }, "a/n minutes")
	set_eq(c.hour, 0, 23, { 0, 6, 12, 18 }, "a-b/n hours")
	set_eq(c.dom, 1, 31, { 1, 4, 7, 10 }, "a-b/n dom")
	set_eq(c.month, 1, 12, { 5, 7, 9, 11 }, "a/n months")
	set_eq(c.dow, 0, 6, { 0, 2, 4, 6 }, "0 and 7 are Sunday, step")
end

do
	local sun = must_parse("0 0 * * 7")
	set_eq(sun.dow, 0, 6, { 0 }, "7 is Sunday")
	local sun0 = must_parse("0 0 * * 0")
	set_eq(sun0.dow, 0, 6, { 0 }, "0 is Sunday")
	local sun_name = must_parse("0 0 * * sun")
	set_eq(sun_name.dow, 0, 6, { 0 }, "sun")
	local sat = must_parse("0 0 * * SAT")
	set_eq(sat.dow, 0, 6, { 6 }, "SAT")
	local jul = must_parse("0 0 1 jAn,Jul *")
	set_eq(jul.month, 1, 12, { 1, 7 }, "month names ignore case")
	eq(jul.dom_star, false, "dom literal")
	eq(jul.dow_star, true, "dow star")
end

do
	local stepped = must_parse("* * */2 * 1")
	eq(stepped.dom_star, true, "*/2 starts with star")
	eq(stepped.dow_star, false, "dow literal")
	local mixed = must_parse("* * 1,*/2 * *")
	eq(mixed.dom_star, false, "star not at the start")
	eq(mixed.dow_star, true, "dow star after mixed dom")
	local odds = {}
	for n = 1, 31, 2 do
		table.insert(odds, n)
	end
	set_eq(mixed.dom, 1, 31, odds, "1 plus every odd day")
	local listed = must_parse("* * 1,* * *")
	eq(listed.dom_star, false, "star later in the list is not a star field")
	local every_day = {}
	for n = 1, 31 do
		table.insert(every_day, n)
	end
	set_eq(listed.dom, 1, 31, every_day, "1,* fills every day")
	local leading = must_parse("  *   *\t*\t*  *  ")
	eq(leading.expr, "*   *\t*\t*  *", "trimmed, internal space kept")
	eq(leading.dom_star, true, "star after spaces between fields")
end

do
	local function same(macro: string, expanded: string)
		local a = must_parse(macro)
		local b = must_parse(expanded)
		eq(a.expr, macro, macro .. " keeps its spelling")
		set_eq(a.minute, 0, 59, (function()
			local w = {}
			for n = 0, 59 do
				if b.minute[n] then
					table.insert(w, n)
				end
			end
			return w
		end)(), macro .. " minute")
		eq(a.dom_star, b.dom_star, macro .. " dom_star")
		eq(a.dow_star, b.dow_star, macro .. " dow_star")
		eq(a.hour[0] == true, b.hour[0] == true, macro .. " hour 0")
		eq(a.month[1] == true, b.month[1] == true, macro .. " january")
		eq(a.dow[0] == true, b.dow[0] == true, macro .. " sunday")
		eq(a.dom[1] == true, b.dom[1] == true, macro .. " day 1")
	end
	same("@yearly", "0 0 1 1 *")
	same("@annually", "0 0 1 1 *")
	same("@monthly", "0 0 1 * *")
	same("@weekly", "0 0 * * 0")
	same("@daily", "0 0 * * *")
	same("@midnight", "0 0 * * *")
	same("@hourly", "0 * * * *")
	local daily = must_parse("  @Daily  ")
	eq(daily.expr, "@Daily", "macro case and trim")
	eq(daily.dow_star, true, "@Daily dow star")
	eq(must_parse("@AnNuAlLy").month[1], true, "annually case")
	eq(must_parse("@weekly").dow_star, false, "@weekly restricts dow")
	eq(must_parse("@weekly").dom_star, true, "@weekly dom star")
end

do
	local mon = must_parse("0 0 * * MON/2")
	set_eq(mon.dow, 0, 6, { 0, 1, 3, 5 }, "name/step runs to the field max")
	local one = must_parse("00 09 * * *")
	set_eq(one.minute, 0, 59, { 0 }, "leading zero minute")
	set_eq(one.hour, 0, 23, { 9 }, "leading zero hour")
	local wide = must_parse("1-2/5 * * * *")
	set_eq(wide.minute, 0, 59, { 1 }, "step larger than the span keeps the start")
end

-- ── errors ──────────────────────────────────────────────────────────────────

must_fail("", "表达式为空")
must_fail("   \t  ", "表达式为空")
must_fail("* * * *", "需要 5 段,实际 4 段")
must_fail("* * * * * *", "需要 5 段,实际 6 段")
must_fail("*", "需要 5 段,实际 1 段")
must_fail(string.rep("1,", 300), "表达式过长")

must_fail("60 * * * *", "第 1 段(分钟)超出范围 0-59: 60")
must_fail("* 24 * * *", "第 2 段(小时)超出范围 0-23: 24")
must_fail("* * 0 * *", "第 3 段(日)超出范围 1-31: 0")
must_fail("* * 32 * *", "第 3 段(日)超出范围 1-31: 32")
must_fail("* * * 0 *", "第 4 段(月)超出范围 1-12: 0")
must_fail("* * * 13 *", "第 4 段(月)超出范围 1-12: 13")
must_fail("* * * * 8", "第 5 段(星期)超出范围 0-7: 8")
must_fail("* * * * -1", "第 5 段(星期)无法识别: -1")
must_fail("1,60 * * * *", "第 1 段(分钟)超出范围 0-59: 60")
must_fail("0-60 * * * *", "第 1 段(分钟)超出范围 0-59: 60")
must_fail("* 1-24 * * *", "第 2 段(小时)超出范围 0-23: 24")

must_fail("*/0 * * * *", "第 1 段(分钟)步长不能为 0")
must_fail("* 1-5/0 * * *", "第 2 段(小时)步长不能为 0")
must_fail("* * 1/0 * *", "第 3 段(日)步长不能为 0")
must_fail("* * * 1-12/0 *", "第 4 段(月)步长不能为 0")
must_fail("* * * * 0-7/0", "第 5 段(星期)步长不能为 0")
must_fail("5/0 * * * *", "第 1 段(分钟)步长不能为 0")
must_fail("*/ * * * *", "第 1 段(分钟)步长无效")
must_fail("* */x * * *", "第 2 段(小时)步长无效")
must_fail("1/MON * * * *", "第 1 段(分钟)步长无效")
must_fail("1-10/2/3 * * * *", "第 1 段(分钟)步长无效")

must_fail("10-5 * * * *", "第 1 段(分钟)范围颠倒: 10-5")
must_fail("* * * DEC-JAN *", "第 4 段(月)范围颠倒: DEC-JAN")
must_fail("* * * * FRI-MON", "第 5 段(星期)范围颠倒: FRI-MON")

must_fail("foo * * * *", "第 1 段(分钟)无法识别: foo")
must_fail("* * * * FRO", "第 5 段(星期)无法识别: FRO")
must_fail("* * * JANU *", "第 4 段(月)无法识别: JANU")
must_fail("* * * SUN *", "第 4 段(月)无法识别: SUN")
must_fail("* * * * JAN", "第 5 段(星期)无法识别: JAN")
must_fail("1.5 * * * *", "第 1 段(分钟)无法识别: 1.5")
must_fail("-1 * * * *", "第 1 段(分钟)无法识别: -1")
must_fail("* * * * ?", "第 5 段(星期)无法识别: ?")
must_fail("1- * * * *", "第 1 段(分钟)无法识别: 1-")
must_fail("** * * * *", "第 1 段(分钟)无法识别: **")
must_fail("*1 * * * *", "第 1 段(分钟)无法识别: *1")

must_fail("1, * * * *", "第 1 段(分钟)有空项")
must_fail(",1 * * * *", "第 1 段(分钟)有空项")
must_fail("1,,2 * * * *", "第 1 段(分钟)有空项")
must_fail("1, * * * *", "第 1 段(分钟)有空项")

must_fail("@reboot", "未知的宏: @reboot")
must_fail("@", "未知的宏: @")
must_fail("@123", "未知的宏: @123")
must_fail("@year", "未知的宏: @year")
must_fail("@daily extra", "宏后面有多余内容")
must_fail("@hourly\tx", "宏后面有多余内容")

-- ── matches: dom/dow OR, and the star exception ─────────────────────────────

local function at(y: number, m: number, d: number, h: number, minute: number, sec: number?): number
	return utc(y, m, d, h, minute, sec)
end

do
	-- 2026-01-01 Thursday, 2026-01-04 Sunday, 2026-01-05 Monday, 2026-02-01 Sunday.
	eq(cron_dow(2026, 1, 1), 4, "2026-01-01 Thursday")
	eq(cron_dow(2026, 1, 5), 1, "2026-01-05 Monday")
	eq(cron_dow(2026, 2, 1), 0, "2026-02-01 Sunday")

	local either = must_parse("0 0 1 * 1")
	eq(either.dom_star, false, "either dom")
	eq(either.dow_star, false, "either dow")
	eq(cron.matches(either, at(2026, 1, 1, 0, 0, 30), true), true, "the 1st matches even if not Monday")
	eq(cron.matches(either, at(2026, 1, 5, 0, 0), true), true, "Monday matches even if not the 1st")
	eq(cron.matches(either, at(2026, 1, 6, 0, 0), true), false, "Tuesday the 6th matches neither")
	eq(cron.matches(either, at(2026, 2, 1, 0, 0), true), true, "the 1st of February")
	eq(cron.matches(either, at(2026, 1, 5, 0, 1), true), false, "right minute required")

	local only_dom = must_parse("0 0 1 * *")
	eq(cron.matches(only_dom, at(2026, 1, 1, 0, 0), true), true, "star dow: the 1st")
	eq(cron.matches(only_dom, at(2026, 1, 5, 0, 0), true), false, "star dow: Monday is not enough")

	local only_dow = must_parse("0 0 * * 1")
	eq(cron.matches(only_dow, at(2026, 1, 5, 0, 0), true), true, "star dom: Monday")
	eq(cron.matches(only_dow, at(2026, 1, 1, 0, 0), true), false, "star dom: the 1st is not enough")

	-- `*/2` starts with `*`, so both fields must match: odd day AND Monday.
	local both = must_parse("0 0 */2 * 1")
	eq(cron.matches(both, at(2026, 1, 5, 0, 0), true), true, "Monday the 5th")
	eq(cron.matches(both, at(2026, 1, 12, 0, 0), true), false, "Monday the 12th is even")
	eq(cron.matches(both, at(2026, 1, 1, 0, 0), true), false, "Thursday the 1st is not Monday")

	local sun7 = must_parse("0 12 * * 7")
	local sun0 = must_parse("0 12 * * 0")
	eq(cron.matches(sun7, at(2026, 1, 4, 12, 0, 59), true), true, "7 matches Sunday")
	eq(cron.matches(sun0, at(2026, 1, 4, 12, 0), true), true, "0 matches Sunday")
	eq(cron.matches(sun7, at(2026, 1, 5, 12, 0), true), false, "7 is not Monday")

	local clock = must_parse("30 9 * * *")
	eq(cron.matches(clock, at(2026, 6, 15, 9, 30, 0), true), true, "09:30")
	eq(cron.matches(clock, at(2026, 6, 15, 9, 30, 59), true), true, "any second of that minute")
	eq(cron.matches(clock, at(2026, 6, 15, 9, 31, 0), true), false, "next minute")
	eq(cron.matches(clock, at(2026, 6, 15, 8, 30, 0), true), false, "wrong hour")
	eq(cron.matches(must_parse("0 0 1 JAN *"), at(2026, 1, 1, 0, 0), true), true, "January")
	eq(cron.matches(must_parse("0 0 1 JAN *"), at(2026, 2, 1, 0, 0), true), false, "not January")
	eq(cron.matches(must_parse("* * * * *"), math.huge, true), false, "infinite epoch")
	eq(cron.matches(must_parse("* * * * *"), 0 / 0, false), false, "nan epoch")
end

-- ── next (UTC, exact epochs from the civil helper) ─────────────────────────

local function expect_next(expr: string, after: number, want: number)
	local c = must_parse(expr)
	eq(cron.next(c, after, true), want, expr .. " after " .. tostring(after))
	assert(want > after, "strictly after")
	eq(cron.matches(c, want, true), true, expr .. " result matches")
end

expect_next("* * * * *", utc(2026, 1, 1, 0, 0), utc(2026, 1, 1, 0, 1))
expect_next("* * * * *", utc(2026, 1, 1, 0, 0, 1), utc(2026, 1, 1, 0, 1))
expect_next("* * * * *", -1, 0)
expect_next("*/15 * * * *", utc(2026, 1, 1, 0, 0), utc(2026, 1, 1, 0, 15))
expect_next("*/15 * * * *", utc(2026, 1, 1, 0, 14, 59), utc(2026, 1, 1, 0, 15))
expect_next("*/15 * * * *", utc(2026, 1, 1, 0, 15), utc(2026, 1, 1, 0, 30))
expect_next("*/15 * * * *", utc(2026, 1, 1, 23, 50), utc(2026, 1, 2, 0, 0))
expect_next("*/5 * * * *", 100.9, 300)

expect_next("0 * * * *", utc(2026, 1, 1, 10, 30), utc(2026, 1, 1, 11, 0))
expect_next("0 * * * *", utc(2026, 1, 1, 23, 30), utc(2026, 1, 2, 0, 0))
expect_next("0 9 * * *", utc(2026, 1, 1, 8, 59, 59), utc(2026, 1, 1, 9, 0))
expect_next("30 9 * * *", utc(2026, 1, 1, 9, 30), utc(2026, 1, 2, 9, 30))
expect_next("30 9 * * *", utc(2026, 1, 1, 9, 29, 59), utc(2026, 1, 1, 9, 30))
expect_next("30 9 * * *", utc(2026, 1, 1, 9, 30, 1), utc(2026, 1, 2, 9, 30))

expect_next("0 0 * * *", utc(2026, 1, 1, 0, 0), utc(2026, 1, 2, 0, 0))
expect_next("0 0 * * *", utc(2026, 1, 1, 23, 59), utc(2026, 1, 2, 0, 0))
expect_next("30 23 * * *", utc(2026, 1, 1, 23, 30), utc(2026, 1, 2, 23, 30))
expect_next("59 23 31 12 *", utc(2026, 12, 31, 23, 58), utc(2026, 12, 31, 23, 59))

expect_next("0 0 1 * *", utc(2026, 1, 2, 0, 0), utc(2026, 2, 1, 0, 0))
expect_next("0 0 1 * *", utc(2026, 1, 31, 23, 59), utc(2026, 2, 1, 0, 0))
expect_next("0 0 1 * *", utc(2026, 1, 1, 0, 0), utc(2026, 2, 1, 0, 0))
expect_next("0 0 31 * *", utc(2026, 1, 30, 0, 0), utc(2026, 1, 31, 0, 0))
expect_next("0 0 31 * *", utc(2026, 1, 31, 0, 0), utc(2026, 3, 31, 0, 0))
expect_next("0 0 31 1,3,5 *", utc(2026, 1, 31, 0, 0), utc(2026, 3, 31, 0, 0))
expect_next("0 0 1 JAN *", utc(2026, 2, 1, 0, 0), utc(2027, 1, 1, 0, 0))

expect_next("0 0 1 1 *", utc(2026, 6, 1, 0, 0), utc(2027, 1, 1, 0, 0))
expect_next("0 0 1 1 *", utc(2026, 12, 31, 23, 59), utc(2027, 1, 1, 0, 0))
expect_next("0 0 1 1 *", utc(2026, 1, 1, 0, 0), utc(2027, 1, 1, 0, 0))

expect_next("0 0 29 2 *", utc(2026, 1, 1, 0, 0), utc(2028, 2, 29, 0, 0))
expect_next("0 0 29 2 *", utc(2026, 3, 1, 0, 0), utc(2028, 2, 29, 0, 0))
expect_next("0 0 29 2 *", utc(2024, 2, 28, 12, 0), utc(2024, 2, 29, 0, 0))
expect_next("0 0 29 2 *", utc(2024, 2, 29, 0, 0), utc(2028, 2, 29, 0, 0))
expect_next("0 0 29 2 *", utc(2028, 2, 29, 0, 0), utc(2032, 2, 29, 0, 0))
eq(cron.next(must_parse("0 0 31 2 *"), utc(2026, 1, 1, 0, 0), true), nil, "Feb 31 never happens")
eq(cron.next(must_parse("0 0 30 2 *"), utc(2026, 1, 1, 0, 0), true), nil, "Feb 30 never happens")
eq(cron.next(must_parse("* * * * *"), math.huge, true), nil, "infinite after")
eq(cron.next(must_parse("* * * * *"), 0 / 0, true), nil, "nan after")

expect_next("0 9 * * 1", utc(2026, 1, 1, 0, 0), utc(2026, 1, 5, 9, 0))
expect_next("0 9 * * 1-5", utc(2026, 1, 2, 10, 0), utc(2026, 1, 5, 9, 0))
expect_next("0 9 * * 1-5", utc(2026, 1, 5, 8, 0), utc(2026, 1, 5, 9, 0))
expect_next("0 9 * * 7", utc(2026, 1, 1, 0, 0), utc(2026, 1, 4, 9, 0))
expect_next("0 0 13 * 5", utc(2026, 1, 1, 0, 0), utc(2026, 1, 2, 0, 0))
expect_next("0 0 13 * 5", utc(2026, 1, 2, 0, 0), utc(2026, 1, 9, 0, 0))
expect_next("0 0 13 * 5", utc(2026, 1, 12, 0, 0), utc(2026, 1, 13, 0, 0))
expect_next("0 0 13 * 5", utc(2026, 1, 13, 0, 0), utc(2026, 1, 16, 0, 0))

expect_next("@yearly", utc(2026, 6, 1, 0, 0), utc(2027, 1, 1, 0, 0))
expect_next("@monthly", utc(2026, 1, 15, 0, 0), utc(2026, 2, 1, 0, 0))
expect_next("@weekly", utc(2026, 1, 1, 0, 0), utc(2026, 1, 4, 0, 0))
expect_next("@daily", utc(2026, 1, 1, 12, 0), utc(2026, 1, 2, 0, 0))
expect_next("@midnight", utc(2026, 1, 1, 0, 0), utc(2026, 1, 2, 0, 0))
expect_next("@hourly", utc(2026, 1, 1, 0, 30), utc(2026, 1, 1, 1, 0))

do
	local c = must_parse("15,45 9,18 * * 1-5")
	local e = utc(2026, 1, 1, 0, 0)
	for i = 1, 12 do
		local n = cron.next(c, e, true)
		if n == nil or n <= e then
			error("walk " .. i, 2)
		end
		eq(cron.matches(c, n, true), true, "walk matches " .. i)
		local back = os.date("!*t", n)
		eq(back.sec, 0, "walk second")
		eq(back.min == 15 or back.min == 45, true, "walk minute")
		eq(back.hour == 9 or back.hour == 18, true, "walk hour")
		local dow = back.wday - 1
		eq(dow >= 1 and dow <= 5, true, "walk weekday")
		e = n
	end
end

-- ── local mode ──────────────────────────────────────────────────────────────

do
	local after = utc(2026, 1, 1, 0, 0)
	local every = must_parse("* * * * *")
	local n = cron.next(every, after, false)
	eq(n, after + 60, "local every-minute is the next epoch minute")
	if n == nil then
		error("local every", 2)
	end
	local t = os.date("*t", n)
	eq(t.sec, 0, "local every second")
	eq(cron.matches(every, n, false), true, "local every matches")

	local daily = must_parse("30 9 * * *")
	local at9 = cron.next(daily, after, false)
	if at9 == nil then
		error("local 09:30", 2)
	end
	assert(at9 > after, "local 09:30 after")
	local d = os.date("*t", at9)
	eq(d.hour, 9, "local hour")
	eq(d.min, 30, "local minute")
	eq(d.sec, 0, "local second")
	eq(cron.matches(daily, at9, false), true, "local 09:30 matches")

	local monday = must_parse("0 9 * * 1")
	local mon = cron.next(monday, after, false)
	if mon == nil then
		error("local Monday", 2)
	end
	local md = os.date("*t", mon)
	eq(md.hour, 9, "local Monday hour")
	eq(md.min, 0, "local Monday minute")
	eq(md.wday, 2, "local Monday wday")
	eq(cron.matches(monday, mon, false), true, "local Monday matches")

	local leap = cron.next(must_parse("0 0 29 2 *"), after, false)
	if leap == nil then
		error("local Feb 29", 2)
	end
	local ld = os.date("*t", leap)
	eq(ld.month, 2, "local Feb")
	eq(ld.day, 29, "local 29")
	eq(ld.hour, 0, "local midnight hour")
	eq(ld.min, 0, "local midnight minute")
	eq(ld.sec, 0, "local midnight second")
	assert(leap > after, "local Feb 29 after")

	eq(cron.next(must_parse("0 0 31 2 *"), after, false), nil, "local Feb 31 is impossible")
end

-- ── describe ────────────────────────────────────────────────────────────────

local function described(expr: string, want: string)
	eq(cron.describe(must_parse(expr)), want, "describe " .. expr)
end

described("* * * * *", "每分钟")
described("*/5 * * * *", "每 5 分钟")
described("0 * * * *", "每小时整点")
described("30 9 * * *", "每天 09:30")
described("0 9 * * 1-5", "工作日 09:00")
described("0 9 * * 1", "每周一 09:00")
described("0 0 1 * *", "每月 1 日 00:00")
described("0 9 * * 0", "每周日 09:00")
described("0 9 * * MON-FRI", "工作日 09:00")
described("@hourly", "每小时整点")
described("@daily", "每天 00:00")
described("@monthly", "每月 1 日 00:00")
described("15 9 * * 1,3", "15 9 * * 1,3")
described("1 2 3 4 5", "1 2 3 4 5")
described("@yearly", "@yearly")
eq(cron.describe(must_parse("  1 2 3 4 5  ")), "1 2 3 4 5", "describe returns the trimmed expr")

print("cron ok")
