--!strict
-- Pure modules: trigger matching, prompt templates, config validation and subscriptions.

local F = require("./fake_tern")
local harness = require("./harness")
harness.fresh(F.new())

local match = require("../lib/match")
local template = require("../lib/template")
local model = require("../lib/model")
local util = require("../lib/util")

local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "eq"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

local function trig(event: string, extra: { [string]: any }?): match.GithubTrigger
	local t: any = {
		event = event,
		actions = {},
		labels = {},
		branches = {},
		senders = {},
		workflows = {},
		conclusions = {},
	}
	local more: { [string]: any } = extra or {}
	for k, v in more do
		t[k] = v
	end
	return t
end

do -- user-content events default to trusted authors; "*" opens them up
	local t = trig("issue_comment", { comment = "/roost" })
	local member = { event = "issue_comment", comment = "  /roost go", association = "MEMBER" }
	local outsider = { event = "issue_comment", comment = "/roost go", association = "NONE" }
	eq(match.mismatch(t, member), nil, "member passes")
	assert(string.find(match.mismatch(t, outsider) or "", "NONE", 1, true), "outsider blocked")
	t.associations = { "*" }
	eq(match.mismatch(t, outsider), nil, "* allows anyone")
	assert(match.mismatch(t, { event = "issue_comment", comment = "hello", association = "OWNER" }), "prefix required")
	-- push has no author association: no default gate.
	eq(match.mismatch(trig("push"), { event = "push" }), nil, "push not gated")
end

do -- CI events: fork code or unknown origin is refused unless the trigger sets forks = true
	local t = trig("workflow_run", { conclusions = { "failure" } })
	local own = { event = "workflow_run", conclusion = "failure", head_repo = "acme/web", from_fork = false }
	local fork = { event = "workflow_run", conclusion = "failure", head_repo = "evil/web", from_fork = true }
	local unknown = { event = "workflow_run", conclusion = "failure" }
	eq(match.mismatch(t, own), nil, "same-repo CI passes")
	assert(string.find(match.mismatch(t, fork) or "", "fork", 1, true), "fork refused")
	assert(match.mismatch(t, unknown), "unknown origin refused")
	t.forks = true
	eq(match.mismatch(t, fork), nil, "forks = true opts in")
end

do -- labeled actions look at the changed label only; branches glob
	local t = trig("issues", { labels = { "bug" } })
	local ev = { event = "issues", action = "labeled", label = "roost", labels = { "bug", "roost" }, association = "OWNER" }
	assert(match.mismatch(t, ev), "existing label ignored on labeled")
	t.labels = { "roost" }
	eq(match.mismatch(t, ev), nil)
	local p = trig("push", { branches = { "release/*" } })
	eq(match.mismatch(p, { event = "push", branch = "release/1.2" }), nil)
	assert(match.mismatch(p, { event = "push", branch = "main" }), "branch filtered")
	assert(match.glob("a*b*c", "a-b-c") and not match.glob("a*c", "ab") and match.glob("*", ""), "glob")
end

do -- templates: variables, inputs, payload paths with 0-based indexes, bounded output
	local t = template.parse("#{{ number }} {{title}} {{payload.issue.labels.0.name}}/{{input.x}}{{missing}}") :: template.Template
	eq(
		template.render(t, { number = 7, title = "Bug", input = { x = "X" }, payload = { issue = { labels = { { name = "roost" } } } } }),
		"#7 Bug roost/X"
	)
	assert(template.check(t, { x = true }), "unknown variable rejected")
	eq(template.check(template.parse("{{repo}} {{input.x}}") :: template.Template, { x = true }), nil)
	assert(template.check(template.parse("{{input.y}}") :: template.Template, { x = true }), "undeclared input rejected")
	assert(select(2, template.parse("{{open")), "unclosed rejected")
	local big = template.render(template.parse("{{body}}") :: template.Template, { body = string.rep("x", template.MAX_RENDERED + 10) })
	assert(#big <= template.MAX_RENDERED + 20, "rendered output bounded")
end

do -- workflows validation reports every problem with its line
	local text = table.concat({
		'[repos."acme/web"]',
		'path = "~/w"',
		"",
		"[[workflow]]",
		'id = "Bad Id"',
		'repos = ["nope/nope"]',
		"",
		"[[workflow.trigger]]",
		'cron = "61 * * * *"',
		"",
		"[[workflow.trigger]]",
		'github = "issues"',
		'tz = "UTC"',
		"",
		"[[workflow.step]]",
		'omp = "{{nosuch}}"',
		'bogus = 1',
	}, "\n")
	local w, issues = model.parse_workflows(text)
	eq(w, nil, "invalid file rejected")
	local function find(pat: string): model.Issue?
		for _, i in issues do
			if string.find(i.message, pat, 1, true) then
				return i
			end
		end
		return nil
	end
	eq((find("无效") :: model.Issue).line, 5, "bad id line")
	eq((find("未在 [repos]") :: model.Issue).line, 6, "unknown repo line")
	assert(find("超出范围"), "cron range error")
	eq((find("只用于 cron") :: model.Issue).line, 13, "tz on github trigger")
	eq((find("未知变量") :: model.Issue).line, 16, "template variable")
	eq((find("未知字段 bogus") :: model.Issue).line, 17, "unknown key")
end

do -- subscriptions: per repo, enabled workflows only, sorted events; manual TOML text
	local w = model.parse_workflows(table.concat({
		'[repos."a/one"]',
		'[repos."a/two"]',
		"hook = false",
		"[[workflow]]",
		'id = "x"',
		'repos = ["a/one"]',
		"[[workflow.trigger]]",
		'github = "push"',
		"[[workflow.trigger]]",
		'github = "issues"',
		"[[workflow.step]]",
		'run = "true"',
		"[[workflow]]",
		'id = "y"',
		"enabled = false",
		"[[workflow.trigger]]",
		'github = "release"',
		"[[workflow.step]]",
		'run = "true"',
	}, "\n")) :: model.Workflows
	local subs = model.subscriptions(w)
	eq(table.concat(subs["a/one"].events, ","), "issues,push")
	eq(#subs["a/two"].events, 0, "disabled workflow contributes nothing")
	eq(subs["a/two"].hook, false)
	local text = model.subscriptions_toml(subs)
	assert(string.find(text, '[repos."a/one"]\nevents = ["issues", "push"]\nhook = true', 1, true), text)
end

do -- roost.toml: relay URL trimmed and checked, runner bounds enforced, Roost-managed omp flags refused
	local cfg = model.parse_config('[relay]\nurl = "https://r.dev/"\ntoken = "t"\n[runner]\nmax_concurrent = 3\n') :: model.Config
	eq(cfg.relay.url, "https://r.dev")
	eq(cfg.runner.max_concurrent, 3)
	local bad, issues = model.parse_config('[relay]\nurl = "ftp://x"\n[runner]\nmax_concurrent = 0\n')
	eq(bad, nil)
	eq(#issues, 2)
	local managed, why = model.parse_config('[runner]\nomp_args = ["-p", "--session-dir=/tmp/x", "--thinking", "high"]\nsession = ""\n')
	eq(managed, nil)
	eq(#why, 3, "-p, --session-dir=… and the empty session name")
	local _, step_issues = model.parse_workflows('[[workflow]]\nid = "w"\n[[workflow.step]]\nomp = "hi"\nargs = ["--resume", "abc"]\n')
	eq(#step_issues, 1, "step args can't resume a session either")
	eq(step_issues[1].path, "workflow.w.step[1].args")
end

do -- agent command lines survive spaces and quotes; roost:// links round-trip
	local agent = require("../lib/agent")
	local dir = "/Users/me/Library/Application Support/Tern/plugin-data/roost/runs/ab12/s1.session"
	eq(agent.command("omp", dir, { "--model", "it's" }), `omp --session-dir '{dir}' --model 'it'\\''s'`)
	eq(agent.quote(""), "''", "an empty argument stays an argument")
	local r = agent.parse_url(agent.session_url("ab12", 3)) :: any
	eq(r.kind, "session")
	eq(r.run, "ab12")
	eq(r.step, 3)
	eq(agent.parse_url("roost://session/../../x/1"), nil, "only hex run ids")
	eq((agent.parse_url(agent.SIDEBAR_URL) :: any).kind, "sidebar")
end

do -- util
	eq(util.duration("1h30m"), 5400)
	eq(util.duration("90"), 90)
	eq((util.duration("5x")), nil)
	eq(util.fmt_duration(5400), "1h30m")
	eq(util.clip("你好世界", 2), "你好…")
	eq(util.shq("it's"), "'it'\\''s'")
end

print("ok")
