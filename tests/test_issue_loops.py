"""Exercise CLI adapters and the shared workflow without model or GitHub calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
BASH = shutil.which("bash")

FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args = sys.argv[1:]
cli = pathlib.Path(sys.argv[0]).name
if args == ['login', 'status']:
    sys.exit(0)
if args == ['auth', 'status']:
    print(json.dumps(dict(loggedIn=True, subscriptionType='max', apiKeySource=None)))
    sys.exit(0)
prompt = sys.stdin.read() if cli == 'codex' else args[args.index('-p') + 1]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(dict(cli=cli, args=args, prompt=prompt)) + '\n')
mode = os.environ.get('FAKE_MODE', 'success')
result = 'OK'
if 'ADOPT_BRANCH:' in prompt:
    result = 'ADOPT_BRANCH: NONE\nADOPT_SPEC: NONE'
if prompt.startswith(('/spec-from-issue', '$spec-from-issue')):
    spec = pathlib.Path(prompt.splitlines()[0].split()[2])
    spec.parent.mkdir(parents=True, exist_ok=True)
    spec.write_text('# Spec\n\n## Derived decisions\nNone\n')
    result = 'SPEC_STATUS: READY'
if prompt.startswith(('/implement-spec', '$implement-spec')):
    pathlib.Path('implemented.txt').write_text('implementation fixture\n')
fixed = pathlib.Path(os.environ['CALLS'] + '.fixed')
if prompt.startswith('The full branch review is at'):
    fixed.touch()
    pathlib.Path('fix.txt').write_text('review fix fixture\n')
if prompt.startswith(('/update-context', '$update-context')):
    pathlib.Path('context.txt').write_text('context fixture\n')
if 'BLOCKING:' in prompt:
    blocking = int(os.environ.get('FAKE_REVIEW') == 'blocked' or
                   (os.environ.get('FAKE_REVIEW') == 'fix' and not fixed.exists()))
    result = f'Review complete\nBLOCKING: {blocking}'
if 'The FIRST LINE of that file is the PR title' in prompt:
    path = re.search(r'Write it to (.+/pr.md)\.', prompt).group(1)
    pathlib.Path(path).write_text('Fixture PR\n\nFixture description\n')
if mode == 'limit':
    result = 'You have hit your usage limit'
if cli == 'claude':
    print(json.dumps(dict(result=result, is_error=mode != 'success',
                         api_error_status=429 if mode == 'limit' else None)))
else:
    output = pathlib.Path(args[args.index('--output-last-message') + 1])
    if mode != 'empty':
        output.write_text(result)
    if mode == 'malformed':
        print('invalid JSON')
    else:
        print(json.dumps(dict(type='thread.started', thread_id='fixture-thread')))
        if mode not in ('incomplete', 'timeout'):
            if mode in ('limit', 'failed'):
                print(json.dumps(dict(type='turn.failed', error=dict(message=result))))
            else:
                print(json.dumps(dict(type='turn.completed', usage=dict(input_tokens=10, output_tokens=2))))
sys.exit(124 if mode == 'timeout' else 0)
'''

FAKE_GH = r'''#!/usr/bin/env python3
import json, sys
if sys.argv[1:3] == ['issue', 'view']:
    print(json.dumps(dict(number=19, title='Add fixture', body='Fixture issue', labels=[], state='OPEN', comments=[])))
if sys.argv[1:3] == ['pr', 'view']:
    print('https://example.invalid/pr/42' if sys.argv[-1] == '.url' else '42')
'''

# Records every call; `systemctl --user show-environment` succeeds, as it does
# on a host with a user systemd instance.
FAKE_SYSTEMD = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['CALLS'] + '.systemd', 'a') as f:
    f.write(json.dumps([pathlib.Path(sys.argv[0]).name] + sys.argv[1:]) + '\n')
'''

FAKE_TMUX = r'''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ['-V']:
    print(os.environ.get('FAKE_TMUX_VERSION', 'tmux 3.2'))
    sys.exit(0)
if sys.argv[1] == 'has-session':
    sys.exit(0 if sys.argv[-1] == '=repo-21' else 1)
with open(os.environ['CALLS'] + '.tmux', 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
'''


class IssueLoopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, content in (("claude", FAKE_CLI), ("codex", FAKE_CLI), ("gh", FAKE_GH),
                              ("tmux", FAKE_TMUX)):
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALLS=str(self.root / "calls.jsonl"), MAX_ATTEMPTS="1", MIN_DISK_GB="0",
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        LOOPS_CGROUP="off")
        for key in ("PLAN_MODEL", "CODE_MODEL", "PLAN_EFFORT", "CODE_EFFORT", "LOOP_CLI",
                    "STAGE_BUDGET_USD", "TOTAL_BUDGET_USD", "FAKE_MODE", "LOOPS_SHARE",
                    "BUILD_JOBS", "SUBAGENT_CAP_OVERRIDE", "ALLOW_WORKTREES_OVERRIDE", "MB_PER_JOB",
                    "LOOPS_MEMORY_MAX", "LOOPS_MEMORY_RESERVE_MB", "LOOPS_SLICE",
                    "LOOPS_WORKTREE_PARENT", "LOOPS_WORKTREE_ROOT"):
            self.env.pop(key, None)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Loop Test")
        self.git("config", "user.email", "loop@example.invalid")
        shutil.copytree(SCRIPTS, self.repo / "scripts")
        self.git("add", "scripts")
        self.git("commit", "-qm", "fixture")

    def run_cmd(self, *args, cwd=None, **env):
        return subprocess.run(args, cwd=cwd or self.repo, env=dict(self.env, **env), text=True,
                              capture_output=True, timeout=20)

    def git(self, *args):
        result = self.run_cmd("git", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def shell(self, code, **env):
        return self.run_cmd(BASH, "-c", 'source scripts/loops-lib.sh\n' + code, **env)

    def add_remote(self):
        remote = self.root / "origin.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-qu", "origin", "main")
        return remote

    def reject_commits_of(self, name):
        hook = self.repo / ".git/hooks/pre-commit"
        hook.write_text(f'#!/bin/sh\ngit diff --cached --name-only | grep -qx {name} && exit 1\nexit 0\n')
        hook.chmod(0o755)

    def statuses(self):
        return [json.loads(p.read_text()) for p in sorted((self.repo / ".git/loops").glob("*.json"))]

    def calls(self):
        path = Path(self.env["CALLS"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def stage(self, cli="codex", **env):
        return self.shell('''
RUN_DIR="$PWD/run"; mkdir -p "$RUN_DIR"; LOG="$RUN_DIR/run.log"
BACKOFF=(0 0 0)
stage test "$PLAN_MODEL" "$PLAN_EFFORT" $'/branch-review main\n\n/clear-technical-writing' "$RUN_DIR/result.json"
rc=$?
printf 'RC=%s LIMIT=%s\n' "$rc" "$USAGE_LIMIT_HIT"
exit "$rc"
''', LOOP_CLI=cli, **env)

    def test_defaults_and_overrides(self):
        code = 'printf "%s %s %s %s" "$PLAN_MODEL" "$PLAN_EFFORT" "$CODE_MODEL" "$CODE_EFFORT"'
        for cli, model in (("claude", "claude-opus-5-5"), ("codex", "gpt-6.1-sol")):
            with self.subTest(cli=cli):
                self.assertEqual(self.shell(code, LOOP_CLI=cli).stdout, f"{model} high {model} medium")
                self.assertEqual(self.shell(code, LOOP_CLI=cli, PLAN_MODEL="plan", CODE_MODEL="code",
                                            PLAN_EFFORT="medium", CODE_EFFORT="low").stdout,
                                 "plan medium code low")

    def budget(self, mem_mb, cores, **env):
        """The derived budget for a host of the given size, as a dict."""
        out = self.shell(f'''
MEM_TOTAL_MB={mem_mb}; CORES={cores}; compute_budget
printf '%s\\n' "$LOOPS_SHARING" "$BUILD_JOBS" "$SUBAGENT_CAP" "$ALLOW_WORKTREES" "$SHARE_BELOW_ONE_JOB"
printf '%s' "$RESOURCE_NOTE"
''', **env).stdout
        sharing, jobs, cap, worktrees, below, note = out.split("\n", 5)
        return dict(sharing=int(sharing), jobs=int(jobs), cap=int(cap), worktrees=worktrees,
                    below=below, note=note)

    def test_budget_divides_the_host_between_loops(self):
        # (RAM MB, cores, loops) -> (jobs per agent, subagents, below one job)
        for (mem, cores, share), expected in {
            (3915, 2, 1): (1, 1, "no"),
            (3915, 2, 2): (1, 1, "yes"),
            (16384, 4, 1): (1, 2, "no"),   # -j4 split between the agent and 2 subagents
            (65536, 16, 1): (5, 2, "no"),  # -j16 split three ways
            (65536, 16, 2): (2, 2, "no"),
        }.items():
            with self.subTest(mem=mem, cores=cores, share=share):
                b = self.budget(mem, cores, LOOPS_SHARE=str(share))
                self.assertEqual((b["jobs"], b["cap"], b["below"]), expected)
                self.assertEqual(b["sharing"], share)
                self.assertIn(f"at {b['jobs']} job(s) per agent", b["note"])
                self.assertEqual(f"{share} issue loops share this host" in b["note"], share > 1)
                self.assertEqual("smaller than one build job" in b["note"], expected[2] == "yes")

    def test_budget_counts_only_live_running_loops(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        self.write_status("1-issue-21", issue=21, pid=sleeper.pid)
        self.write_status("2-issue-22", issue=22, pid=2**22 + 1)            # died
        self.write_status("3-issue-23", issue=23, state="done", pid=sleeper.pid)
        self.assertEqual(self.budget(16384, 4)["sharing"], 2)
        self.assertEqual(self.budget(16384, 4, LOOPS_SHARE="5")["sharing"], 5)

    def test_pinned_budget_survives_recomputation(self):
        b = self.budget(3915, 2, LOOPS_SHARE="4", BUILD_JOBS="3", SUBAGENT_CAP_OVERRIDE="2",
                        ALLOW_WORKTREES_OVERRIDE="yes")
        self.assertEqual((b["jobs"], b["cap"], b["worktrees"]), (3, 2, "yes"))

    def test_adoption_uses_small_models(self):
        for cli, model in (("claude", "claude-haiku-4-5-20251001"),
                           ("codex", "gpt-6-luna")):
            with self.subTest(cli=cli):
                result = self.run_cmd(BASH, f"scripts/{cli}-issue-loop.sh", "19", "--dry-run")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = self.calls()[-1]["args"]
                self.assertEqual(args[args.index("--model") + 1], model)
                if cli == "claude":
                    self.assertNotIn("--effort", args)
                else:
                    self.assertIn('model_reasoning_effort="medium"', args)

    def test_cli_arguments_and_result(self):
        for cli in ("claude", "codex"):
            with self.subTest(cli=cli):
                result = self.stage(cli)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                call = self.calls()[-1]
                self.assertEqual(call["cli"], cli)
                self.assertNotIn("xhigh", call["args"])
                self.assertEqual(json.loads((self.repo / "run/result.json").read_text())["result"], "OK")
                if cli == "codex":
                    self.assertIn('model_reasoning_effort="high"', call["args"])
                    self.assertIn('approval_policy="never"', call["args"])
                    self.assertIn("danger-full-access", call["args"])
                    self.assertEqual(call["prompt"].strip(), "$branch-review main\n\n$clear-technical-writing")
                else:
                    self.assertIn("--effort", call["args"])
                    self.assertTrue(call["prompt"].startswith("/branch-review"))

    def test_read_only_adoption(self):
        result = self.stage(TOOLS="Read,Glob,Grep")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("read-only", self.calls()[-1]["args"])
        self.assertNotIn("danger-full-access", self.calls()[-1]["args"])

    def test_failed_or_partial_codex_output_is_rejected(self):
        for mode in ("failed", "incomplete", "malformed", "empty", "timeout"):
            with self.subTest(mode=mode):
                result = self.stage(FAKE_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("LIMIT=0", result.stdout)

    def test_usage_limits_and_timeouts_do_not_retry(self):
        for cli in ("claude", "codex"):
            before = len(self.calls())
            result = self.stage(cli, FAKE_MODE="limit", MAX_ATTEMPTS="3")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("LIMIT=1", result.stdout)
            self.assertEqual(len(self.calls()), before + 1)
        before = len(self.calls())
        self.stage(FAKE_MODE="timeout", MAX_ATTEMPTS="3")
        self.assertEqual(len(self.calls()), before + 1)

    def test_fast_failure_retries(self):
        result = self.stage(FAKE_MODE="failed", MAX_ATTEMPTS="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 3)

    def test_codex_rejects_unsupported_cost_caps(self):
        result = self.shell("true", LOOP_CLI="codex", STAGE_BUDGET_USD="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not support", result.stderr)

    def test_help_and_dry_run(self):
        for cli, model in (("claude", "claude-opus-5-5"), ("codex", "gpt-6.1-sol")):
            script = f"scripts/{cli}-issue-loop.sh"
            result = self.run_cmd(BASH, script, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(script, result.stdout)
            result = self.run_cmd(BASH, script, "19", "--dry-run", "--no-adopt", "--from", "review")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"plan={model}/high  code={model}/medium", result.stdout)
            self.assertIn("Stages that would run: review context pr", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_full_local_workflow_uses_phase_efforts(self):
        self.add_remote()
        for cli in ("claude", "codex"):
            with self.subTest(cli=cli):
                Path(self.env["CALLS"] + ".fixed").unlink(missing_ok=True)
                before = len(self.calls())
                result = self.run_cmd(BASH, f"scripts/{cli}-issue-loop.sh", "19",
                                      "--no-adopt", "--fresh-spec",
                                      FAKE_REVIEW="fix", MAX_REVIEW_ROUNDS="1")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = self.calls()[before:]
                # Smoke code/plan, spec/review, implement, debt, review/fix/verify, context, PR.
                self.assertEqual(len(calls), 11)
                expected = ["medium", "high", "high", "high", "medium", "medium",
                            "high", "medium", "high", "medium", "medium"]
                for call, effort in zip(calls, expected):
                    if cli == "codex":
                        self.assertIn(f'model_reasoning_effort="{effort}"', call["args"])
                    else:
                        self.assertEqual(call["args"][call["args"].index("--effort") + 1], effort)
                self.assertIn("https://example.invalid/pr/42", result.stdout)
                self.assertTrue((self.repo / "implemented.txt").exists())
                self.assertEqual(self.git("status", "--porcelain"), "")
                status = self.statuses()[-1]
                self.assertEqual((status["cli"], status["state"], status["stage"], status["exit_code"]),
                                 (cli, "done", "pr", 0))
                self.assertEqual(status["pr"], "https://example.invalid/pr/42")

    def test_codex_resume_hint_after_unresolved_review(self):
        self.add_remote()
        result = self.run_cmd(BASH, "scripts/codex-issue-loop.sh", "19", "--no-push",
                              "--no-adopt", "--stages", "review", FAKE_REVIEW="blocked",
                              MAX_REVIEW_ROUNDS="1")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("./scripts/codex-issue-loop.sh 19 --from review", result.stdout)
        self.assertNotIn("./scripts/claude-issue-loop.sh 19 --from review", result.stdout)
        status = self.statuses()[-1]
        self.assertEqual((status["cli"], status["state"], status["from"]), ("codex", "needs-human", "review"))
        self.assertIn("1 blocking", status["reason"])

    def test_commit_leftovers_reports_git_failure(self):
        code = '''
RUN_DIR="$PWD/run"; mkdir -p "$RUN_DIR"; LOG="$RUN_DIR/run.log"
commit_leftovers "clean tree" || exit 10
echo kept > kept.txt
commit_leftovers "kept" || exit 11
echo rejected > rejected.txt
commit_leftovers "rejected"
'''
        self.reject_commits_of("rejected.txt")
        result = self.shell(code)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("could not commit", result.stderr)
        self.assertEqual(self.git("log", "-1", "--format=%s"), "kept")
        self.assertIn("rejected.txt", self.git("status", "--porcelain"))

    def test_rejected_leftover_commit_stops_the_run(self):
        # Each file is written by a different stage and committed by a different
        # commit_leftovers call; the run must stop at the stage that wrote it.
        self.add_remote()
        for name, stage in (("implemented.txt", "techdebt"), ("fix.txt", "review"),
                            ("context.txt", "context")):
            with self.subTest(stage=stage):
                # Start each stage from main with no branch left by the previous one.
                self.git("checkout", "-qf", "main")
                self.git("clean", "-qfd")
                self.run_cmd("git", "branch", "-qD", "v0/feature/19-add-fixture")
                self.run_cmd("git", "push", "-q", "origin", ":v0/feature/19-add-fixture")
                Path(self.env["CALLS"] + ".fixed").unlink(missing_ok=True)
                self.reject_commits_of(name)
                result = self.run_cmd(BASH, "scripts/claude-issue-loop.sh", "19",
                                      "--no-adopt", "--fresh-spec",
                                      FAKE_REVIEW="fix", MAX_REVIEW_ROUNDS="1")
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 5, output)
                self.assertIn(f"stopped at '{stage}'", output)
                self.assertIn("uncommitted", result.stdout)
                self.assertIn(f"claude-issue-loop.sh 19 --from {stage}", result.stdout)
                self.assertNotIn("complete ════", result.stdout)
                self.assertIn(name, self.git("status", "--porcelain"))
                status = self.statuses()[-1]
                self.assertEqual((status["state"], status["from"], status["exit_code"]),
                                 ("failed", stage, 5))

    def test_final_push_failure_is_not_success(self):
        remote = self.add_remote()
        hook = remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.run_cmd(BASH, "scripts/claude-issue-loop.sh", "19",
                              "--no-adopt", "--fresh-spec", "--skip", "pr")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertIn("push failed", result.stdout)
        self.assertIn("git push -u origin v0/feature/19-add-fixture", result.stdout)
        self.assertNotIn("Review came back clean", result.stdout)

    def test_dry_run_is_not_registered(self):
        self.run_cmd(BASH, "scripts/claude-issue-loop.sh", "19", "--dry-run", "--no-adopt")
        self.assertEqual(self.statuses(), [])

    def test_killed_run_records_its_stage(self):
        self.add_remote()
        sleeper = self.bin / "claude"
        sleeper.write_text(FAKE_CLI.replace("mode = os.environ", "import time\n"
                           "if prompt.startswith('/implement-spec'): time.sleep(2)\nmode = os.environ"))
        proc = subprocess.Popen([BASH, "scripts/claude-issue-loop.sh", "19", "--no-adopt", "--fresh-spec"],
                                cwd=self.repo, env=self.env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        for _ in range(100):
            if any(s["stage"] == "implement" for s in self.statuses()):
                break
            subprocess.run(["sleep", "0.1"])
        proc.terminate()
        proc.wait(timeout=20)
        status = self.statuses()[-1]
        self.assertEqual((status["state"], status["stage"], status["from"]), ("killed", "implement", "implement"))

    def test_loop_runs_in_a_worktree_beside_others(self):
        self.add_remote()
        wt = self.root / "wt-19"
        self.git("worktree", "add", "-q", "--detach", str(wt), "origin/main")
        self.git("worktree", "add", "-q", "--detach", str(self.root / "wt-other"), "origin/main")
        result = self.run_cmd(BASH, "scripts/claude-issue-loop.sh", "19", "--no-adopt",
                              "--fresh-spec", "--no-push", cwd=wt)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.run_cmd("git", "branch", "--show-current", cwd=wt).stdout.strip(),
                         "v0/feature/19-add-fixture")
        self.assertEqual(self.statuses()[-1]["worktree"], str(wt.resolve()))

    def test_nested_worktree_still_fails_preflight(self):
        self.add_remote()
        self.git("worktree", "add", "-q", "--detach", str(self.repo / "nested"), "origin/main")
        (self.repo / ".git/info/exclude").write_text(".loops\nnested\n")
        result = self.run_cmd(BASH, "scripts/claude-issue-loop.sh", "19", "--no-adopt")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("inside this checkout", result.stderr)

    def write_status(self, run_id, **fields):
        registry = self.repo / ".git/loops"
        registry.mkdir(exist_ok=True)
        status = dict(issue=19, cli="claude", state="running", stage="implement", reason="", **{"from": ""},
                      branch="", base="main", pr="", tmux="", worktree=str(self.repo),
                      log="/logs/run.log", pid=os.getpid(), started=0, updated=0, exit_code=None)
        status.update(fields)
        (registry / f"{run_id}.json").write_text(json.dumps(status))

    def test_loops_status_shows_latest_run_per_issue(self):
        self.add_remote()
        self.git("checkout", "-qb", "b19")
        self.git("commit", "-q", "--allow-empty", "-m", "one")
        self.git("commit", "-q", "--allow-empty", "-m", "two")
        self.write_status("1-issue-19", state="done", started=1)
        self.write_status("2-issue-19", cli="codex", state="limit", stage="review", branch="b19",
                          reason="account usage limit", started=2, exit_code=4, **{"from": "review"})
        self.write_status("3-issue-21", issue=21, pid=2**22 + 1, started=3, **{"from": "implement"})
        self.write_status("4-issue-24", issue=24, tmux="repo-24", started=4)
        out = self.run_cmd(BASH, "scripts/loops", "status").stdout
        rows = {line.split()[0]: line for line in out.splitlines() if line.startswith("#")}
        self.assertEqual(out.count("#19 "), 1, out)
        self.assertRegex(rows["#19"], r"codex\s+review\s+limit\s+2\s")
        self.assertIn("loops run --cli codex 19 -- --from review", rows["#19"])
        self.assertIn("account usage limit", out)
        self.assertIn("died", rows["#21"])
        self.assertIn("loops run 21 -- --from implement", rows["#21"])
        self.assertIn("running", rows["#24"])
        self.assertIn("tmux attach -t repo-24", rows["#24"])
        self.assertEqual(self.run_cmd(BASH, "scripts/loops", "status", "--all").stdout.count("#19 "), 2)

    def test_loops_run_starts_one_worktree_and_session_per_issue(self):
        self.add_remote()
        other = self.root / "repo-loops/issue-24"
        self.git("worktree", "add", "-q", "--detach", str(other), "origin/main")
        self.write_status("1-issue-24", issue=24, state="limit", worktree=str(self.repo))
        result = self.run_cmd(BASH, "scripts/loops", "run", "--cli", "codex", "19", "21", "24",
                              "--", "--no-push", PLAN_MODEL="fable")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("#21 is already running", result.stdout)
        calls = [json.loads(l) for l in Path(self.env["CALLS"] + ".tmux").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        wt = (self.root / "repo-loops/issue-19").resolve()
        self.assertEqual(self.run_cmd("git", "rev-parse", "HEAD", cwd=wt).stdout,
                         self.run_cmd("git", "rev-parse", "origin/main").stdout)
        new19, new24 = calls
        self.assertEqual(new19[:5], ["new-session", "-d", "-s", "repo-19", "-c"])
        self.assertEqual(Path(new19[5]).resolve(), wt)
        self.assertIn("PLAN_MODEL=fable", new19)
        self.assertRegex(new19[-1], r"codex-issue-loop\.sh 19 --no-push\s*$")
        self.assertEqual(Path(new24[5]).resolve(), other.resolve())
        self.assertFalse((self.root / "repo-loops/issue-21").exists())

    def fake_systemd(self):
        for name in ("systemd-run", "systemctl"):
            path = self.bin / name
            path.write_text(FAKE_SYSTEMD)
            path.chmod(0o755)

    def test_loops_run_contains_every_loop_in_one_memory_slice(self):
        self.add_remote()
        self.fake_systemd()
        for env, limit in (({}, None), ({"LOOPS_MEMORY_MAX": "6G"}, "6G")):
            with self.subTest(**env):
                for suffix in (".systemd", ".tmux"):
                    Path(self.env["CALLS"] + suffix).unlink(missing_ok=True)
                result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_CGROUP="auto", **env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                systemd = [json.loads(l) for l in Path(self.env["CALLS"] + ".systemd").read_text().splitlines()]
                prop = next(c for c in systemd if "set-property" in c)
                self.assertEqual(prop[:5], ["systemctl", "--user", "set-property", "--runtime", "loops.slice"])
                self.assertRegex(prop[5], r"^MemoryMax=\d+M$" if limit is None else f"^MemoryMax={limit}$")
                tmux = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
                self.assertRegex(tmux[-1], r"^systemd-run --user --scope --quiet --slice=loops\.slice -- "
                                           r"\S+/claude-issue-loop\.sh 19\s*$")

    def test_loops_run_without_a_user_systemd_instance(self):
        self.add_remote()
        self.fake_systemd()
        (self.bin / "systemctl").write_text("#!/bin/sh\nexit 1\n")   # no user instance to reach
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_CGROUP="on")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no systemd-run or user systemd instance", result.stderr)
        self.assertFalse((self.root / "repo-loops/issue-19").exists())
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_CGROUP="auto")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("without a shared memory ceiling", result.stdout)
        tmux = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
        self.assertNotIn("systemd-run", tmux[-1])

    def test_loops_run_when_the_memory_ceiling_cannot_be_set(self):
        self.add_remote()
        self.fake_systemd()
        (self.bin / "systemctl").write_text(          # reachable, but set-property is refused
            '#!/bin/sh\n[ "$2" = set-property ] && exit 1\nexit 0\n')
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_CGROUP="on")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("cannot set MemoryMax", result.stderr)
        self.assertFalse((self.root / "repo-loops/issue-19").exists())
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_CGROUP="auto")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cannot set MemoryMax", result.stdout)
        tmux = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
        self.assertNotIn("systemd-run", tmux[-1])

    def test_loops_run_rejects_tmux_before_creating_worktrees(self):
        for version in ("tmux 3.0", "tmux 3.1c", "unknown"):
            with self.subTest(version=version):
                result = self.run_cmd(BASH, "scripts/loops", "run", "19",
                                      FAKE_TMUX_VERSION=version)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("tmux version" if version == "unknown" else "tmux 3.2 or newer",
                              result.stderr)
                self.assertFalse((self.root / "repo-loops/issue-19").exists())
                self.assertFalse(Path(self.env["CALLS"] + ".tmux").exists())

    def test_loops_run_uses_current_checkout_only_for_matching_issue_branch(self):
        self.add_remote()
        self.git("checkout", "-qb", "v1/bugfix/19-existing")
        self.write_status("old-19", state="done", worktree=str(self.root / "elsewhere"))
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", "190")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in Path(self.env["CALLS"] + ".tmux").read_text().splitlines()]
        self.assertEqual(Path(calls[0][5]).resolve(), self.repo.resolve())
        self.assertEqual(Path(calls[1][5]).resolve(), (self.root / "repo-loops/issue-190").resolve())

    def test_loops_run_ignores_recorded_main_checkout_after_branch_changes(self):
        self.add_remote()
        self.write_status("old-19", state="done", worktree=str(self.repo))
        result = self.run_cmd(BASH, "scripts/loops", "run", "19")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
        self.assertEqual(Path(call[5]).resolve(), (self.root / "repo-loops/issue-19").resolve())


    def test_loops_run_puts_worktrees_under_the_configured_parent(self):
        self.add_remote()
        parent = self.root / "volume"
        result = self.run_cmd(BASH, "scripts/loops", "run", "19", LOOPS_WORKTREE_PARENT=str(parent))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
        self.assertEqual(Path(call[5]).resolve(), (parent / "repo-loops/issue-19").resolve())
        self.assertFalse((self.root / "repo-loops").exists())

    def test_loops_worktree_root_takes_precedence_over_the_parent(self):
        self.add_remote()
        root = self.root / "exact"
        result = self.run_cmd(BASH, "scripts/loops", "run", "19",
                              LOOPS_WORKTREE_PARENT=str(self.root / "volume"), LOOPS_WORKTREE_ROOT=str(root))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(Path(self.env["CALLS"] + ".tmux").read_text().splitlines()[-1])
        self.assertEqual(Path(call[5]).resolve(), (root / "issue-19").resolve())
        self.assertFalse((self.root / "volume").exists())


if __name__ == "__main__":
    unittest.main()
