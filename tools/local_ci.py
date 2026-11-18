#!/usr/bin/env python3
"""The merge gate, run on this machine: the steps of ci.yml's test,
release and coverage jobs, against emulators started for the run, and the
result posted on the commit as the `local-ci` status that main's ruleset
requires. Since 2026-11-18 ci.yml runs only by hand, to keep a private
repository inside GitHub's free minutes, so this is what a pull request
is held to.

    python3 -I tools/local_ci.py [--no-post] [--only STEP,...]
    python3 -I tools/local_ci.py --list
    python3 -I tools/local_ci.py --self-test

It tests HEAD, and refuses (exit 2) unless the working tree is clean and
HEAD is on GitHub: a status names a commit, and has to mean that commit
was tested. Before posting it checks again, and a HEAD that moved or a
tree that changed during the run posts nothing. --no-post runs the steps
on any tree and posts nothing; --only runs the steps it names, and posts
nothing either.

A line per step says how it went; each step's output is in
_tmp/local-ci/<commit>/<step>.log, and a failure prints the end of its
log. Exit codes:

  0  every step passed (and the status was posted, unless told not to)
  1  a step failed or timed out (named, and posted as a failure)
  2  refused: a dirty tree, a commit not on GitHub, HEAD moved
  5  something it needs is missing or failed (named on stderr)
  64 a usage error

What it needs, on a Mac with Homebrew: Zig, kcov, gh logged in, the Cloud
SDK's Pub/Sub and Firestore emulators with a JDK (JAVA_HOME, else
Homebrew's openjdk), and fake-gcs-server on the PATH or in ~/go/bin (CI
pins 1.56.1: `go install github.com/fsouza/fake-gcs-server@v1.56.1`).
zigvet and gnarl are fetched at the releases
.github/actions/vet-tools/action.yml pins, checked against its digests,
and put first on the PATH, as CI does.

What it cannot run: the unit tests on Linux and Windows, and the
emulators in containers. Run ci.yml by hand for those before a release.
"""

import argparse
import hashlib
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request

CONTEXT = "local-ci"
ACTION = ".github/actions/vet-tools/action.yml"
WORKFLOW = ".github/workflows/ci.yml"
STATE = os.path.join("_tmp", "local-ci")
# A release mode's own cache, emptied when it grows past this: Zig never
# collects its caches, and an optimized build's is large.
CACHE_LIMIT_KB = 4 * 1024 * 1024
KEEP_LOG_DIRS = 20


class ToolFailed(Exception):
    """Something the gate needs is missing or failed."""


class Refused(Exception):
    """The tree or the commit cannot be vouched for."""


class Step:
    """One step: commands run in order, each line of output to its log.
    `emulators` names the variables, of PUBSUB, STORAGE and FIRESTORE,
    the step gets pointed at the run's emulators, as ci.yml's env does."""

    def __init__(self, name, commands, minutes, emulators=(), cache=None):
        self.name = name
        self.commands = commands
        self.minutes = minutes
        self.emulators = emulators
        self.cache = cache


def steps():
    """ci.yml's test, release and coverage jobs, in its order. The platforms
    job's macOS leg is the unit step here; its Windows leg needs ci.yml."""
    zig_test = ["zig", "build", "test", "--summary", "all"]
    all_three = ("PUBSUB", "STORAGE", "FIRESTORE")
    out = [
        Step("format", [["zig", "build", "fmt"]], 10),
        Step("docs", [["python3", "tools/check_docs.py"]], 10),
        Step("tools", [
            ["python3", "-I", "tools/await_pr.py", "--self-test"],
            ["python3", "-I", "tools/discovery_drift.py", "--self-test"],
            ["python3", "-I", "tools/local_ci.py", "--self-test"],
        ], 5),
        Step("unit", [zig_test], 45),
        Step("core-baseline", [["zig", "build", "test", "-Dmodule=core", "-Dcpu=baseline", "--summary", "all"]], 20),
        Step("integration", [["zig", "build", "test-integration", "--summary", "all"]], 10, emulators=all_three),
        Step("firestore-differential", [["zig", "build", "test", "-Dmodule=firestore", "-Dtest-filter=emulator differential", "--summary", "all"]], 10, emulators=("FIRESTORE",)),
        Step("pubsub-differential", [["zig", "build", "test", "-Dmodule=pubsub", "-Dtest-filter=emulator differential", "--summary", "all"]], 10, emulators=("PUBSUB",)),
        Step("examples", [["bash", "tools/ci_examples.sh"]], 10, emulators=all_three),
    ]
    for mode in ("ReleaseSafe", "ReleaseFast"):
        cache = os.path.join(STATE, "cache", mode)
        out.append(Step(mode, [["zig", "build", "test-unit", f"-Doptimize={mode}", "--summary", "all", "--cache-dir", cache]], 45, cache=cache))
    out.append(Step("coverage", [["zig", "build", "coverage"], ["python3", "tools/coverage_summary.py", "zig-out/coverage"]], 30))
    return out


# Variables that point a test or an example at production, or at someone
# else's emulator. CI sets none of them but the emulators it starts.
SCRUB = re.compile(r"^(GCP_|GOOGLE_|CLOUDSDK_|PUBSUB_|STORAGE_|FIRESTORE_)|_TEST(_|$)|_EMULATOR_HOST$|_PROJECT_ID$")


def clean_env(env):
    return {k: v for k, v in env.items() if not SCRUB.search(k)}


def platform_name(system, machine):
    """The release asset's platform for this machine, as action.yml names it."""
    names = {
        ("Darwin", "arm64"): "darwin-arm64",
        ("Darwin", "x86_64"): "darwin-amd64",
        ("Linux", "x86_64"): "linux-amd64",
    }
    found = names.get((system, machine))
    if not found:
        raise ToolFailed(f"no zigvet or gnarl release for {system} {machine}")
    return found


def pinned(action_text, tool, plat):
    """(version, sha256) of the release action.yml installs for TOOL."""
    version = re.search(rf"^\s*install {tool} (v[0-9A-Za-z.\-]+)\s*$", action_text, re.M)
    digest = re.search(rf"\b{tool}-{plat}\) want=([0-9a-f]{{64}}) ;;", action_text)
    if not version or not digest:
        raise ToolFailed(f"{ACTION} pins no {tool} release for {plat}")
    return version.group(1), digest.group(1)


def describe(outcome, where, minutes=None, step=None):
    """The status's description, which GitHub cuts at 140 characters."""
    if outcome == "pending":
        text = f"running on {where}"
    elif outcome == "success":
        text = f"every step passed on {where}, in {minutes} min"
    elif outcome == "failure":
        text = f"{step} failed on {where}"
    else:
        text = f"stopped during {step} on {where}"
    return text[:140]


def free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def run(argv, **kw):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, check=False, **kw)
    except OSError as e:
        raise ToolFailed(f"{argv[0]}: {e}") from e
    if done.returncode != 0:
        raise ToolFailed(f"{' '.join(argv)}: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout.strip()


def stop(proc):
    """Stops a process started in its own session, and all it started."""
    if proc.poll() is not None:
        return
    for sig, wait in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            pass


def vet_tools(root):
    """The pinned zigvet and gnarl, downloaded once, checked every run.
    Returns the directories to put first on the PATH."""
    text = open(os.path.join(root, ACTION)).read()
    plat = platform_name(platform.system(), platform.machine())
    dirs = []
    for tool in ("zigvet", "gnarl"):
        version, want = pinned(text, tool, plat)
        where = os.path.join(root, STATE, "tools", f"{tool}-{version}")
        path = os.path.join(where, tool)
        if not os.path.exists(path) or sha256(path) != want:
            os.makedirs(where, exist_ok=True)
            url = f"https://github.com/kmoneil/{tool}/releases/download/{version}/{tool}-{plat}"
            run(["curl", "-fsSLo", path + ".part", url])
            got = sha256(path + ".part")
            if got != want:
                raise ToolFailed(f"{tool} {version} for {plat} has digest {got}, not the {want} {ACTION} pins")
            os.chmod(path + ".part", 0o755)
            os.replace(path + ".part", path)
        dirs.append(where)
    return dirs


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Emulators:
    """The Pub/Sub and Firestore emulators and fake-gcs-server, fresh for
    the run on ports nobody else holds: the examples count what they leave
    behind, so a second run against the same emulators would fail."""

    def __init__(self, env, logdir):
        self.env = env
        self.logdir = logdir
        self.procs = []
        self.hosts = {}

    def start(self):
        java = self.env.get("JAVA_HOME") or "/opt/homebrew/opt/openjdk"
        gcloud = shutil.which("gcloud", path=self.env.get("PATH"))
        if not gcloud:
            raise ToolFailed("gcloud is not on the PATH: the emulators come with the Cloud SDK")
        sdk = os.path.dirname(os.path.dirname(os.path.realpath(gcloud)))
        pubsub = os.path.join(sdk, "platform", "pubsub-emulator", "bin", "cloud-pubsub-emulator")
        firestore = os.path.join(sdk, "platform", "cloud-firestore-emulator", "cloud_firestore_emulator")
        fake_gcs = shutil.which("fake-gcs-server", path=self.env.get("PATH")) or os.path.expanduser("~/go/bin/fake-gcs-server")
        for path, how in ((pubsub, "gcloud components install pubsub-emulator"),
                          (firestore, "gcloud components install cloud-firestore-emulator"),
                          (fake_gcs, "go install github.com/fsouza/fake-gcs-server@v1.56.1"),
                          (os.path.join(java, "bin", "java"), "brew install openjdk, or set JAVA_HOME")):
            if not os.path.exists(path):
                raise ToolFailed(f"{path} is missing ({how})")
        ps, fs, gcs = free_ports(3)
        jenv = dict(self.env, JAVA_HOME=java, PATH=f"{java}/bin:{self.env['PATH']}")
        self.spawn("pubsub", [pubsub, "--host=127.0.0.1", f"--port={ps}"], jenv)
        self.spawn("firestore", [firestore, "start", "--host=127.0.0.1", f"--port={fs}"], jenv)
        # fake-gcs-server publishes a bucket's notifications to the Pub/Sub
        # emulator, and serves signed URLs' paths only for -public-host.
        self.spawn("fake-gcs", [fake_gcs, "-backend", "memory", "-scheme", "http", "-host", "127.0.0.1",
                                "-port", str(gcs), "-public-host", f"127.0.0.1:{gcs}", "-log-level", "warn"],
                   dict(self.env, PUBSUB_EMULATOR_HOST=f"127.0.0.1:{ps}"))
        self.hosts = {
            "PUBSUB": f"127.0.0.1:{ps}",
            "FIRESTORE": f"127.0.0.1:{fs}",
            "STORAGE": f"http://127.0.0.1:{gcs}",
        }
        self.ready("pubsub", f"http://127.0.0.1:{ps}/")
        self.ready("firestore", f"http://127.0.0.1:{fs}/")
        self.ready("fake-gcs", f"http://127.0.0.1:{gcs}/storage/v1/b?project=test")

    def spawn(self, name, argv, env):
        log = open(os.path.join(self.logdir, f"emulator-{name}.log"), "wb")
        proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                env=env, start_new_session=True)
        log.close()
        proc.name = name
        self.procs.append(proc)

    def ready(self, name, url, seconds=180):
        # Straight to the port, whatever proxy the environment names.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        proc = next(p for p in self.procs if p.name == name)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise ToolFailed(f"the {name} emulator exited ({proc.returncode}); see {self.logdir}/emulator-{name}.log")
            try:
                with opener.open(url, timeout=2) as answer:
                    if answer.status == 200:
                        return
            except OSError:
                pass
            time.sleep(1)
        raise ToolFailed(f"the {name} emulator did not answer {url} in {seconds} s; see {self.logdir}/emulator-{name}.log")

    def env_for(self, names):
        out = {}
        for name in names:
            out[f"{name}_EMULATOR_HOST"] = self.hosts[name]
        return out

    def stop(self):
        for proc in self.procs:
            stop(proc)
        self.procs = []


def run_step(step, env, log_path):
    """Runs a step's commands, output to its log. None when it passed, or
    what went wrong."""
    deadline = time.monotonic() + step.minutes * 60
    with open(log_path, "wb") as log:
        for argv in step.commands:
            log.write(("$ " + " ".join(argv) + "\n").encode())
            log.flush()
            proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    env=env, start_new_session=True)
            try:
                code = proc.wait(timeout=max(1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                stop(proc)
                return f"timed out after {step.minutes} min"
            except BaseException:
                stop(proc)
                raise
            if code != 0:
                return f"exit {code}"
    return None


def prune_cache(path):
    if not os.path.isdir(path):
        return False
    size = int(run(["du", "-sk", path]).split()[0])
    if size > CACHE_LIMIT_KB:
        shutil.rmtree(path)
        return True
    return False


def prune_logs(root):
    base = os.path.join(root, STATE, "runs")
    if not os.path.isdir(base):
        return
    dirs = sorted((os.path.join(base, d) for d in os.listdir(base)), key=os.path.getmtime)
    for d in dirs[:-KEEP_LOG_DIRS]:
        shutil.rmtree(d, ignore_errors=True)


def tail(path, lines=40):
    with open(path, "rb") as f:
        text = f.read().decode(errors="replace").splitlines()
    return "\n".join(text[-lines:])


def git(*argv):
    return run(["git", *argv])


def post(sha, state, description):
    run(["gh", "api", "-X", "POST", f"repos/{{owner}}/{{repo}}/statuses/{sha}",
         "-f", f"state={state}", "-f", f"context={CONTEXT}", "-f", f"description={description}"])


def on_github(sha):
    try:
        return run(["gh", "api", f"repos/{{owner}}/{{repo}}/commits/{sha}", "--jq", ".sha"]) == sha
    except ToolFailed as e:
        if "No commit found" in str(e) or "HTTP 422" in str(e) or "HTTP 404" in str(e):
            return False
        raise


def gate(args):
    root = git("rev-parse", "--show-toplevel")
    os.chdir(root)
    plan = steps()
    if args.only:
        names = [n.strip() for n in args.only.split(",") if n.strip()]
        unknown = [n for n in names if n not in {s.name for s in plan}]
        if unknown:
            raise SystemExit(f"local_ci: no step named {', '.join(unknown)}; --list names them")
        plan = [s for s in plan if s.name in names]
    posting = not (args.no_post or args.only)
    sha = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain", "--untracked-files=all")
    if posting:
        if dirty:
            raise Refused("the working tree has changes, so HEAD is not what would be tested:\n" + dirty)
        if not on_github(sha):
            raise Refused(f"{sha[:12]} is not on GitHub, so there is nothing to post on: push it first, or pass --no-post")
    where = f"{'macOS' if platform.system() == 'Darwin' else platform.system()} {platform.machine()}"
    zig = run(["zig", "version"])
    where_zig = f"{where}, Zig {zig}"
    label = sha[:12] + ("" if not dirty else "-dirty")
    logdir = os.path.join(root, STATE, "runs", label)
    shutil.rmtree(logdir, ignore_errors=True)
    os.makedirs(logdir)
    prune_logs(root)

    base_env = clean_env(os.environ)
    base_env["PATH"] = os.pathsep.join(vet_tools(root) + [base_env.get("PATH", "")])
    print(f"local-ci: {label} on {where_zig}; {'posting' if posting else 'not posting'}; logs in {os.path.relpath(logdir, root)}/", flush=True)
    if posting:
        post(sha, "pending", describe("pending", where_zig))

    started = time.monotonic()
    emulators = None
    current = "setup"
    try:
        for step in plan:
            current = step.name
            env = dict(base_env)
            if step.emulators:
                if emulators is None:
                    emulators = Emulators(base_env, logdir)
                    t = time.monotonic()
                    emulators.start()
                    print(f"[ok]   {'emulators':<24} {time.monotonic() - t:5.0f}s", flush=True)
                env.update(emulators.env_for(step.emulators))
            elif emulators is not None:
                emulators.stop()
                emulators = None
            if step.cache and prune_cache(os.path.join(root, step.cache)):
                print(f"       {step.name}: its cache passed {CACHE_LIMIT_KB // (1024 * 1024)} GB and was emptied", flush=True)
            t = time.monotonic()
            log = os.path.join(logdir, f"{step.name}.log")
            problem = run_step(step, env, log)
            took = time.monotonic() - t
            if problem:
                print(f"[FAIL] {step.name:<24} {took:5.0f}s  {problem}; log: {os.path.relpath(log, root)}", flush=True)
                print(tail(log), flush=True)
                if posting:
                    post(sha, "failure", describe("failure", where_zig, step=step.name))
                return 1
            print(f"[ok]   {step.name:<24} {took:5.0f}s", flush=True)
    except (KeyboardInterrupt, ToolFailed):
        if posting:
            try:
                post(sha, "error", describe("error", where_zig, step=current))
            except ToolFailed:
                pass
        raise
    finally:
        if emulators is not None:
            emulators.stop()

    minutes = round((time.monotonic() - started) / 60)
    if not posting:
        print(f"local-ci: every step passed in {minutes} min; nothing posted", flush=True)
        return 0
    # What was tested has to be what the status names.
    now_sha = git("rev-parse", "HEAD")
    now_dirty = git("status", "--porcelain", "--untracked-files=all")
    if now_sha != sha or now_dirty:
        post(sha, "error", describe("error", where_zig, step="the run (the tree changed under it)"))
        raise Refused(f"the tree changed during the run (HEAD {now_sha[:12]}, {'dirty' if now_dirty else 'clean'}): nothing vouched for")
    post(sha, "success", describe("success", where_zig, minutes=minutes))
    print(f"local-ci: every step passed in {minutes} min; posted success on {sha[:12]}", flush=True)
    return 0


def self_test():
    """The decisions, on canned inputs: no network, no emulators."""
    assert platform_name("Darwin", "arm64") == "darwin-arm64"
    assert platform_name("Linux", "x86_64") == "linux-amd64"
    try:
        platform_name("Windows", "AMD64")
    except ToolFailed:
        pass
    else:
        raise AssertionError("platform_name accepted Windows")

    canned = (
        "            zigvet-darwin-arm64) want=" + "a" * 64 + " ;;\n"
        "            gnarl-darwin-arm64) want=" + "b" * 64 + " ;;\n"
        "        install zigvet v0.25.1\n"
        "        install gnarl v0.7.1\n"
    )
    assert pinned(canned, "zigvet", "darwin-arm64") == ("v0.25.1", "a" * 64)
    assert pinned(canned, "gnarl", "darwin-arm64") == ("v0.7.1", "b" * 64)
    for tool, plat in (("gnarl", "linux-amd64"), ("zig", "darwin-arm64")):
        try:
            pinned(canned, tool, plat)
        except ToolFailed:
            pass
        else:
            raise AssertionError(f"pinned found {tool} for {plat}")
    # The real action pins both tools for every platform the gate runs on.
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    action = open(os.path.join(here, ACTION)).read()
    for plat in ("darwin-arm64", "darwin-amd64", "linux-amd64"):
        for tool in ("zigvet", "gnarl"):
            version, digest = pinned(action, tool, plat)
            assert version.startswith("v") and len(digest) == 64

    env = clean_env({
        "PATH": "/bin", "HOME": "/h", "JAVA_HOME": "/j", "ZIG_GLOBAL_CACHE_DIR": "/z",
        "PUBSUB_EMULATOR_HOST": "x", "STORAGE_EMULATOR_HOST": "x", "FIRESTORE_EMULATOR_HOST": "x",
        "GCP_TEST_PROJECT": "x", "GOOGLE_APPLICATION_CREDENTIALS": "x", "AUTH_TEST_CREDENTIALS": "x",
        "BIGQUERY_TEST": "x", "COMPUTE_TEST_ZONE": "x", "KMS_TEST_KEY_RING": "x", "CLOUDSDK_CONFIG": "x",
        "STORAGE_PROJECT_ID": "x", "PUBSUB_PROJECT_ID": "x", "SOME_EMULATOR_HOST": "x",
    })
    assert env == {"PATH": "/bin", "HOME": "/h", "JAVA_HOME": "/j", "ZIG_GLOBAL_CACHE_DIR": "/z"}, env

    where = "macOS arm64, Zig 0.17.1"
    assert describe("success", where, minutes=23) == "every step passed on macOS arm64, Zig 0.17.1, in 23 min"
    assert describe("failure", where, step="integration") == "integration failed on macOS arm64, Zig 0.17.1"
    assert len(describe("failure", where, step="x" * 300)) == 140

    # ci.yml's test job, step for step, less what only a container does.
    plan = steps()
    names = [s.name for s in plan]
    assert len(names) == len(set(names)), names
    assert names[:3] == ["format", "docs", "tools"], names
    assert {"unit", "integration", "examples", "ReleaseSafe", "ReleaseFast", "coverage"} <= set(names)
    # The emulators run in one stretch, so they start once and stop once.
    flags = [bool(s.emulators) for s in plan]
    first, last = flags.index(True), len(flags) - 1 - flags[::-1].index(True)
    assert all(flags[first:last + 1]), names
    # Every command the steps run is in this repository or on the PATH.
    workflow = open(os.path.join(here, WORKFLOW)).read()
    for s in plan:
        for argv in s.commands:
            for word in argv:
                if word.startswith("tools/"):
                    assert os.path.exists(os.path.join(here, word)), word
    for needle in ("tools/ci_examples.sh", "emulator differential", "-Dcpu=baseline", "test-unit", "zig build coverage"):
        assert needle in workflow, needle

    a, b, c = free_ports(3)
    assert len({a, b, c}) == 3
    print("local_ci self-test: ok")


def interrupted(_signum, _frame):
    """SIGTERM stops a run as Ctrl-C does: its steps and emulators too."""
    raise KeyboardInterrupt


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f"{self.prog}: error: {message}\n")


def main():
    parser = Parser(description="Run ci.yml's steps here and post the result on HEAD as the local-ci status.")
    parser.add_argument("--no-post", action="store_true", help="run on any tree, post nothing")
    parser.add_argument("--only", help="run only these steps, comma-separated (posts nothing)")
    parser.add_argument("--list", action="store_true", help="name the steps and exit")
    parser.add_argument("--self-test", action="store_true", help="check the decisions on canned inputs, and exit")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.list:
        for s in steps():
            print(f"{s.name:<24} up to {s.minutes} min{'  (emulators)' if s.emulators else ''}")
        return 0
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return gate(args)
    except Refused as e:
        print(f"local_ci: refused: {e}", file=sys.stderr)
        return 2
    except ToolFailed as e:
        print(f"local_ci: {e}", file=sys.stderr)
        return 5
    except KeyboardInterrupt:
        print("local_ci: stopped", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
