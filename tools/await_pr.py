#!/usr/bin/env python3
"""Waits for a pull request to merge, then checks that what landed is
what CI tested: the merged commit's tree equals the tested head's, and
the base branch holds the merged commit. It merges nothing itself; auto-
merge, or a person, does that.

    python3 -I tools/await_pr.py PR [--repo OWNER/NAME] [--interval SECONDS]
                                    [--timeout MINUTES]
    python3 -I tools/await_pr.py --self-test

It prints a line when the checks move, and one at the end. Exit codes:

  0  merged; the tree is the tested head's, and the base branch holds it
  1  a check failed, was cancelled or timed out (named)
  2  closed without merging
  3  merged, but the tree differs from the tested head's, or the base
     branch does not hold the merged commit
  4  still open at the timeout
  5  gh or git failed (their message on stderr)
  64 a usage error

A rebase merge rewrites commit ids, so ids are not compared; trees are.
Every id is checked to be non-empty before it is compared, since two
failed lookups would otherwise compare equal.
"""

import argparse
import json
import subprocess
import sys
import time

FAILED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"}
FIELDS = "state,headRefOid,mergeCommit,statusCheckRollup,baseRefName,autoMergeRequest"


class ToolFailed(Exception):
    """gh or git failed; the message is theirs."""


def run(argv):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as e:
        raise ToolFailed(f"{argv[0]}: {e}") from e
    if done.returncode != 0:
        raise ToolFailed(f"{' '.join(argv)}: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout.strip()


def checks_of(pr):
    """(name, status, conclusion) for every check, a status context too."""
    out = []
    for c in pr.get("statusCheckRollup") or []:
        name = c.get("name") or c.get("context") or "?"
        status = c.get("status") or ("COMPLETED" if c.get("state") else "")
        conclusion = c.get("conclusion") or c.get("state") or ""
        out.append((name, status, conclusion))
    return out


def classify(pr):
    """What a PR's state says to do: ("merged" | "closed" | "failed" |
    "open", detail). Detail names failed checks, or what is pending."""
    state = pr.get("state")
    if state == "MERGED":
        return "merged", (pr.get("mergeCommit") or {}).get("oid") or ""
    if state == "CLOSED":
        return "closed", ""
    checks = checks_of(pr)
    failed = sorted(n for n, _, conclusion in checks if conclusion.upper() in FAILED)
    if failed:
        return "failed", ", ".join(failed)
    pending = sorted(n for n, status, conclusion in checks if status.upper() != "COMPLETED" and conclusion.upper() not in ("SUCCESS", "SKIPPED", "NEUTRAL"))
    return "open", ", ".join(pending)


def progress(pr):
    """A line on the checks, for when it changes."""
    checks = checks_of(pr)
    done = sum(1 for _, status, conclusion in checks if status.upper() == "COMPLETED" or conclusion.upper() in ("SUCCESS", "SKIPPED", "NEUTRAL"))
    _, pending = classify(pr)
    line = f"{done}/{len(checks)} checks done"
    if pending:
        line += f"; waiting on: {pending}"
    if not pr.get("autoMergeRequest") and pending == "" and checks:
        line += "; every check is green but auto-merge is not armed: someone has to merge it"
    return line


def same_tree(git, merged, head):
    """Whether two commits hold the same tree. Refuses empty ids."""
    if not merged or not head:
        raise ToolFailed(f"a commit id is empty (merged {merged!r}, tested head {head!r})")
    a = git(["rev-parse", f"{merged}^{{tree}}"])
    b = git(["rev-parse", f"{head}^{{tree}}"])
    if not a or not b:
        raise ToolFailed(f"a tree id is empty ({a!r}, {b!r})")
    return a == b, a, b


def verify(pr_number, pr, git):
    """After a merge: fetch the base branch and the PR's head, then compare.
    Returns (exit code, message)."""
    merged = (pr.get("mergeCommit") or {}).get("oid") or ""
    head = pr.get("headRefOid") or ""
    base = pr.get("baseRefName") or "main"
    git(["fetch", "--quiet", "origin", base, f"pull/{pr_number}/head"])
    equal, merged_tree, head_tree = same_tree(git, merged, head)
    if not equal:
        return 3, f"merged as {merged}, but its tree {merged_tree} is not the tested head {head}'s ({head_tree})"
    try:
        git(["merge-base", "--is-ancestor", merged, f"origin/{base}"])
    except ToolFailed:
        return 3, f"merged as {merged}, but origin/{base} does not hold it"
    return 0, f"merged as {merged} on {base}; its tree {merged_tree} is the tested head {head}'s"


def stamp():
    return time.strftime("%H:%M:%SZ", time.gmtime())


def await_pr(args, gh, git, sleep=time.sleep, clock=time.monotonic, say=None):
    say = say or (lambda line: print(f"[{stamp()}] {line}", flush=True))
    base_cmd = ["pr", "view", str(args.pr), "--json", FIELDS]
    if args.repo:
        base_cmd += ["--repo", args.repo]
    deadline = clock() + args.timeout * 60
    last = None
    while True:
        pr = json.loads(gh(base_cmd))
        verdict, detail = classify(pr)
        if verdict == "merged":
            code, message = verify(args.pr, pr, git)
            say(message)
            return code
        if verdict == "closed":
            say("closed without merging")
            return 2
        if verdict == "failed":
            say(f"failed: {detail}")
            return 1
        line = progress(pr)
        if line != last:
            say(line)
            last = line
        if clock() >= deadline:
            say(f"still open after {args.timeout} minutes: {line}")
            return 4
        sleep(args.interval)


def self_test():
    """The decisions, on canned answers: no network, no repository."""
    ok = lambda name: {"name": name, "status": "COMPLETED", "conclusion": "SUCCESS"}
    running = lambda name: {"name": name, "status": "IN_PROGRESS", "conclusion": ""}
    assert classify({"state": "MERGED", "mergeCommit": {"oid": "abc"}}) == ("merged", "abc")
    assert classify({"state": "CLOSED"}) == ("closed", "")
    assert classify({"state": "OPEN", "statusCheckRollup": [ok("test"), running("coverage")]}) == ("open", "coverage")
    assert classify({"state": "OPEN", "statusCheckRollup": [ok("test"), {"name": "fuzz", "status": "COMPLETED", "conclusion": "SKIPPED"}]}) == ("open", "")
    for bad in ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "failure"):
        assert classify({"state": "OPEN", "statusCheckRollup": [ok("a"), {"name": "z", "status": "COMPLETED", "conclusion": bad}]})[0] == "failed"
    # A status context (no check run) counts too.
    assert classify({"state": "OPEN", "statusCheckRollup": [{"context": "ci/x", "state": "FAILURE"}]}) == ("failed", "ci/x")
    assert "auto-merge is not armed" in progress({"state": "OPEN", "statusCheckRollup": [ok("test")]})
    assert "auto-merge" not in progress({"state": "OPEN", "autoMergeRequest": {"mergeMethod": "REBASE"}, "statusCheckRollup": [ok("test")]})
    assert progress({"state": "OPEN", "statusCheckRollup": [ok("test"), running("lint")]}) == "1/2 checks done; waiting on: lint"

    # The tree comparison refuses empty ids instead of calling them equal.
    trees = {"m^{tree}": "T1", "h^{tree}": "T1", "x^{tree}": "T2", "e^{tree}": ""}
    git = lambda argv: trees[argv[1]] if argv[0] == "rev-parse" else ""
    assert same_tree(git, "m", "h")[0]
    assert not same_tree(git, "m", "x")[0]
    for merged, head in [("", "h"), ("m", ""), ("e", "h")]:
        try:
            same_tree(git, merged, head)
        except ToolFailed:
            pass
        else:
            raise AssertionError(f"same_tree accepted {merged!r}, {head!r}")

    # The whole wait, scripted: two polls open, then merged and verified;
    # and the paths that end it otherwise.
    class Args:
        pr, repo, interval, timeout = 7, None, 30, 60

    def scripted(answers):
        calls = iter(answers)
        return lambda argv: json.dumps(next(calls))

    def fake_git(holds=True, tree_of_merge="T1"):
        def git(argv):
            if argv[0] == "fetch":
                return ""
            if argv[0] == "rev-parse":
                return tree_of_merge if argv[1].startswith("m") else "T1"
            if argv[0] == "merge-base":
                if not holds:
                    raise ToolFailed("not an ancestor")
                return ""
            raise AssertionError(argv)
        return git

    open_pr = {"state": "OPEN", "autoMergeRequest": {}, "statusCheckRollup": [running("test")]}
    merged_pr = {"state": "MERGED", "mergeCommit": {"oid": "m1"}, "headRefOid": "h1", "baseRefName": "main"}
    quiet = lambda _seconds: None
    said = []
    say = said.append
    assert await_pr(Args, scripted([open_pr, open_pr, merged_pr]), fake_git(), sleep=quiet, say=say) == 0
    # A line when the checks move, not one per poll.
    assert said == ["0/1 checks done; waiting on: test", "merged as m1 on main; its tree T1 is the tested head h1's"], said
    assert await_pr(Args, scripted([merged_pr]), fake_git(tree_of_merge="T9"), sleep=quiet, say=say) == 3
    assert await_pr(Args, scripted([merged_pr]), fake_git(holds=False), sleep=quiet, say=say) == 3
    assert await_pr(Args, scripted([{"state": "CLOSED"}]), fake_git(), sleep=quiet, say=say) == 2
    failed_pr = {"state": "OPEN", "statusCheckRollup": [{"name": "test", "status": "COMPLETED", "conclusion": "FAILURE"}]}
    assert await_pr(Args, scripted([open_pr, failed_pr]), fake_git(), sleep=quiet, say=say) == 1
    ticks = iter([0, 0, 61 * 60])
    assert await_pr(Args, scripted([open_pr, open_pr]), fake_git(), sleep=quiet, clock=lambda: next(ticks), say=say) == 4
    assert said[-1].startswith("still open after 60 minutes")
    print("await_pr self-test: ok")


class Parser(argparse.ArgumentParser):
    """argparse, its usage errors at 64: 2 means a closed pull request."""

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f"{self.prog}: error: {message}\n")


def main():
    parser = Parser(description="Wait for a pull request to merge, then check that what landed is what CI tested.")
    parser.add_argument("pr", nargs="?", type=int, help="the pull request's number")
    parser.add_argument("--repo", help="OWNER/NAME; the current repository's when absent")
    parser.add_argument("--interval", type=int, default=30, help="seconds between polls (default 30)")
    parser.add_argument("--timeout", type=int, default=60, help="minutes before giving up (default 60)")
    parser.add_argument("--self-test", action="store_true", help="check the decisions on canned answers, and exit")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.pr is None:
        parser.error("the pull request's number is required")
    try:
        return await_pr(args, lambda argv: run(["gh"] + argv), lambda argv: run(["git"] + argv))
    except ToolFailed as e:
        print(f"await_pr: {e}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
