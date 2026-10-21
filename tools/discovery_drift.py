#!/usr/bin/env python3
"""Compares two Google API discovery documents as parsed JSON and prints
what changed in what a client reads: the methods (verb, path, parameters,
request and response types, scopes), the schemas (fields, types, formats,
enums, read-only), the OAuth scopes and the document's own addresses. Key
order and whitespace never count. A spec's research fetches a service's
discovery document and keeps it; this says what moved since.

    python3 -I tools/discovery_drift.py OLD.json NEW.json [--descriptions]
                                        [--only PREFIX ...]
    python3 -I tools/discovery_drift.py --self-test

Each change is one line, grouped and sorted:

    + method run.projects.locations.jobs.run
    - schema GoogleCloudRunV2Foo
    ~ method run.projects.locations.jobs.list: parameter pageSize: type "integer" -> "string"
    ~ schema GoogleCloudRunV2Condition.executionReason: enum + DELAYED_START_PENDING

A field inside a schema is named by its path: `items` as `[]`, a map's
values as `{}`, an inline object's fields with `.`. Descriptions change
often and mean little to a client, so by default they are only counted,
on a `#` line; `--descriptions` prints them as changes. `--only` keeps
the methods and schemas whose id or name starts with a prefix given.

Exit codes:

  0  no change (a different revision alone is not one)
  1  changes printed
  2  a file could not be read, or is not a discovery document
  64 a usage error
"""

import argparse
import json
import sys

# What a client reads of a method, a parameter and a schema field. The
# rest (icons, documentation links, `id` itself) is not compared.
METHOD_KEYS = ("httpMethod", "path", "flatPath", "parameterOrder", "supportsMediaUpload", "supportsMediaDownload", "useMediaDownloadService", "deprecated")
FIELD_KEYS = ("type", "format", "$ref", "location", "required", "repeated", "readOnly", "pattern", "default", "minimum", "maximum", "deprecated", "enumDeprecated", "annotations")
DOCUMENT_KEYS = ("version", "rootUrl", "servicePath", "basePath", "baseUrl", "batchPath", "mtlsRootUrl")
DESCRIPTIVE = ("description", "enumDescriptions")


class NotDiscovery(Exception):
    pass


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise NotDiscovery(f"{path}: {e}") from None
    if not isinstance(doc, dict) or doc.get("kind") != "discovery#restDescription":
        raise NotDiscovery(f'{path}: not a discovery document (no "kind": "discovery#restDescription")')
    return doc


def methods(doc):
    """Every method by its id, from the top level and every resource."""
    found = {}

    def walk(node, trail):
        for name, method in (node.get("methods") or {}).items():
            found[method.get("id") or ".".join(trail + [name])] = method
        for name, resource in (node.get("resources") or {}).items():
            walk(resource, trail + [name])

    walk(doc, [doc.get("name", "")])
    return found


def fields(schema):
    """A schema flattened to path -> its own attributes; "" is the schema."""
    out = {}

    def walk(node, path):
        if not isinstance(node, dict):
            return
        out[path] = {k: node[k] for k in FIELD_KEYS + DESCRIPTIVE if k in node}
        if "enum" in node:
            out[path]["enum"] = node["enum"]
        if "items" in node:
            walk(node["items"], path + "[]")
        if isinstance(node.get("additionalProperties"), dict):
            walk(node["additionalProperties"], path + "{}")
        for name, sub in (node.get("properties") or {}).items():
            walk(sub, f"{path}.{name}" if path else name)

    walk(schema, "")
    return out


def within(path, parent):
    """Whether `path` is a field inside the field `parent`."""
    return bool(parent) and len(path) > len(parent) and path.startswith(parent) and path[len(parent)] in ".[{"


def show(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


class Report:
    def __init__(self, descriptions, only):
        self.descriptions = descriptions
        self.only = only
        self.lines = []
        self.hidden = 0

    def wanted(self, subject):
        return not self.only or any(subject.startswith(p) for p in self.only)

    def add(self, line):
        self.lines.append(line)

    def attributes(self, where, old, new):
        """The changes between two attribute dicts, as lines under `where`."""
        for key in sorted(set(old) | set(new)):
            a, b = old.get(key), new.get(key)
            if a == b:
                continue
            if key in DESCRIPTIVE:
                if self.descriptions:
                    self.add(f"~ {where}: {key} {show(a)} -> {show(b)}")
                else:
                    self.hidden += 1
            elif key == "enum" and isinstance(a, list) and isinstance(b, list):
                gone = [v for v in a if v not in b]
                came = [v for v in b if v not in a]
                parts = [f"+ {v}" for v in came] + [f"- {v}" for v in gone]
                if not parts:
                    parts = ["reordered"]
                self.add(f"~ {where}: enum {', '.join(parts)}")
            else:
                self.add(f"~ {where}: {key} {show(a)} -> {show(b)}")


def scopes_of(doc):
    return set(((doc.get("auth") or {}).get("oauth2") or {}).get("scopes") or {})


def compare(old, new, descriptions=False, only=()):
    """The report's lines, the number of description changes left out,
    and the two revisions."""
    r = Report(descriptions, only)

    if not only:
        keys = DOCUMENT_KEYS + ("description",)
        r.attributes("document", {k: old[k] for k in keys if k in old}, {k: new[k] for k in keys if k in new})
        for scope in sorted(scopes_of(new) - scopes_of(old)):
            r.add(f"+ scope {scope}")
        for scope in sorted(scopes_of(old) - scopes_of(new)):
            r.add(f"- scope {scope}")
        old_params, new_params = old.get("parameters") or {}, new.get("parameters") or {}
        for name in sorted(set(old_params) | set(new_params)):
            where = f"parameter (every method) {name}"
            if name not in old_params:
                r.add(f"+ {where}")
            elif name not in new_params:
                r.add(f"- {where}")
            else:
                r.attributes(where, fields(old_params[name])[""], fields(new_params[name])[""])

    old_methods, new_methods = methods(old), methods(new)
    for mid in sorted(set(old_methods) | set(new_methods)):
        if not r.wanted(mid):
            continue
        if mid not in old_methods:
            r.add(f"+ method {mid}")
            continue
        if mid not in new_methods:
            r.add(f"- method {mid}")
            continue
        a, b = old_methods[mid], new_methods[mid]
        where = f"method {mid}"
        shape = lambda m: dict({k: m[k] for k in METHOD_KEYS + ("description",) if k in m}, request=(m.get("request") or {}).get("$ref"), response=(m.get("response") or {}).get("$ref"))
        r.attributes(where, shape(a), shape(b))
        for scope in sorted(set(b.get("scopes") or []) - set(a.get("scopes") or [])):
            r.add(f"~ {where}: scope + {scope}")
        for scope in sorted(set(a.get("scopes") or []) - set(b.get("scopes") or [])):
            r.add(f"~ {where}: scope - {scope}")
        pa, pb = a.get("parameters") or {}, b.get("parameters") or {}
        for name in sorted(set(pa) | set(pb)):
            if name not in pa:
                r.add(f"+ {where}: parameter {name}")
            elif name not in pb:
                r.add(f"- {where}: parameter {name}")
            else:
                r.attributes(f"{where}: parameter {name}", fields(pa[name])[""], fields(pb[name])[""])

    old_schemas, new_schemas = old.get("schemas") or {}, new.get("schemas") or {}
    for name in sorted(set(old_schemas) | set(new_schemas)):
        if not r.wanted(name):
            continue
        if name not in old_schemas:
            r.add(f"+ schema {name}")
            continue
        if name not in new_schemas:
            r.add(f"- schema {name}")
            continue
        fa, fb = fields(old_schemas[name]), fields(new_schemas[name])
        for path in sorted(set(fa) | set(fb), key=lambda p: (p != "", p)):
            where = f"schema {name}" + (f".{path}" if path and not path.startswith(("[", "{")) else path)
            # A field added or removed is named once; its own fields are not.
            if path not in fa:
                if not any(within(path, p) and p not in fa for p in fb):
                    r.add(f"+ {where}")
            elif path not in fb:
                if not any(within(path, p) and p not in fb for p in fa):
                    r.add(f"- {where}")
            else:
                r.attributes(where, fa[path], fb[path])

    return r.lines, r.hidden, old.get("revision", "?"), new.get("revision", "?")


def run(argv, out):
    parser = Parser(description="Print what changed between two Google API discovery documents.")
    parser.add_argument("old", nargs="?", help="the older document, a JSON file")
    parser.add_argument("new", nargs="?", help="the newer document, a JSON file")
    parser.add_argument("--descriptions", action="store_true", help="print description changes too, rather than only counting them")
    parser.add_argument("--only", action="append", default=[], metavar="PREFIX", help="keep the methods and schemas whose id or name starts with PREFIX (repeatable)")
    parser.add_argument("--self-test", action="store_true", help="check the comparison on canned documents, and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        out("discovery_drift self-test: ok")
        return 0
    if args.old is None or args.new is None:
        parser.error("two documents are required: OLD.json NEW.json")
    try:
        old, new = load(args.old), load(args.new)
    except NotDiscovery as e:
        print(f"discovery_drift: {e}", file=sys.stderr)
        return 2
    lines, hidden, rev_old, rev_new = compare(old, new, args.descriptions, args.only)
    out(f"# revision {rev_old} -> {rev_new}" if rev_old != rev_new else f"# revision {rev_old}, both")
    for line in lines:
        out(line)
    if hidden:
        out(f"# {hidden} description change{'s' if hidden != 1 else ''} not shown (--descriptions shows them)")
    if not lines:
        out("# no change")
    return 1 if lines else 0


class Parser(argparse.ArgumentParser):
    """argparse, its usage errors at 64: 2 means an unreadable document."""

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f"{self.prog}: error: {message}\n")


def self_test():
    """The comparison, on canned documents: no files, no network."""
    base = {
        "kind": "discovery#restDescription",
        "name": "run",
        "version": "v2",
        "revision": "20261009",
        "rootUrl": "https://run.googleapis.com/",
        "auth": {"oauth2": {"scopes": {"https://www.googleapis.com/auth/run": {}, "https://www.googleapis.com/auth/run.readonly": {}}}},
        "parameters": {"alt": {"type": "string", "location": "query"}},
        "resources": {"projects": {"resources": {"jobs": {"methods": {
            "list": {"id": "run.projects.jobs.list", "httpMethod": "GET", "path": "v2/{+parent}/jobs",
                     "parameters": {"pageSize": {"type": "integer", "format": "int32", "location": "query"},
                                    "parent": {"type": "string", "location": "path", "required": True}},
                     "response": {"$ref": "ListJobs"}, "scopes": ["https://www.googleapis.com/auth/run"],
                     "description": "Lists Jobs."},
            "run": {"id": "run.projects.jobs.run", "httpMethod": "POST", "path": "v2/{+name}:run",
                    "request": {"$ref": "RunJob"}, "response": {"$ref": "Operation"}},
        }}}}},
        "schemas": {
            "Job": {"id": "Job", "type": "object", "properties": {
                "name": {"type": "string"},
                "labels": {"type": "object", "additionalProperties": {"type": "string"}},
                "conditions": {"type": "array", "items": {"$ref": "Condition"}, "readOnly": True},
                "state": {"type": "string", "enum": ["A", "B"], "enumDescriptions": ["a", "b"]},
                "template": {"type": "object", "properties": {"timeout": {"type": "string", "format": "google-duration"}}},
            }},
            "Gone": {"id": "Gone", "type": "object", "properties": {"x": {"type": "string"}}},
        },
    }

    def same(lines_hidden_revs, lines, hidden=0):
        got, got_hidden, _, _ = lines_hidden_revs
        assert got == lines, "\n".join(["got:"] + got + ["want:"] + lines)
        assert got_hidden == hidden, (got_hidden, hidden)

    # Key order and whitespace never count; a new revision alone is no change.
    shuffled = json.loads(json.dumps(base, sort_keys=True))
    shuffled["revision"] = "20261020"
    same(compare(base, shuffled), [])
    assert compare(base, shuffled)[2:] == ("20261009", "20261020")

    new = json.loads(json.dumps(base))
    new["rootUrl"] = "https://run.example.com/"
    del new["auth"]["oauth2"]["scopes"]["https://www.googleapis.com/auth/run.readonly"]
    new["auth"]["oauth2"]["scopes"]["https://www.googleapis.com/auth/cloud-platform"] = {}
    new["parameters"]["fields"] = {"type": "string", "location": "query"}
    jobs = new["resources"]["projects"]["resources"]["jobs"]["methods"]
    jobs["list"]["parameters"]["pageSize"]["type"] = "string"
    jobs["list"]["parameters"]["showDeleted"] = {"type": "boolean", "location": "query"}
    del jobs["list"]["parameters"]["parent"]["required"]
    jobs["list"]["scopes"] = ["https://www.googleapis.com/auth/run.readonly"]
    jobs["list"]["description"] = "Lists Jobs, newest first."
    del jobs["run"]
    jobs["get"] = {"id": "run.projects.jobs.get", "httpMethod": "GET", "path": "v2/{+name}"}
    job = new["schemas"]["Job"]["properties"]
    job["state"]["enum"] = ["A", "C"]
    job["state"]["enumDescriptions"] = ["a", "c"]
    job["labels"]["additionalProperties"]["type"] = "integer"
    job["conditions"]["items"]["$ref"] = "ConditionV2"
    del job["conditions"]["readOnly"]
    job["template"]["properties"]["timeout"]["format"] = "int64"
    job["template"]["properties"]["retries"] = {"type": "integer", "properties": {"inner": {"type": "string"}}}
    job["etag"] = {"type": "string"}
    job["nameSuffix"] = {"type": "string"}
    del new["schemas"]["Gone"]
    new["schemas"]["Execution"] = {"id": "Execution", "type": "object"}

    want = [
        '~ document: rootUrl "https://run.googleapis.com/" -> "https://run.example.com/"',
        "+ scope https://www.googleapis.com/auth/cloud-platform",
        "- scope https://www.googleapis.com/auth/run.readonly",
        "+ parameter (every method) fields",
        "+ method run.projects.jobs.get",
        "~ method run.projects.jobs.list: scope + https://www.googleapis.com/auth/run.readonly",
        "~ method run.projects.jobs.list: scope - https://www.googleapis.com/auth/run",
        '~ method run.projects.jobs.list: parameter pageSize: type "integer" -> "string"',
        "~ method run.projects.jobs.list: parameter parent: required true -> null",
        "+ method run.projects.jobs.list: parameter showDeleted",
        "- method run.projects.jobs.run",
        "+ schema Execution",
        "- schema Gone",
        '~ schema Job.conditions: readOnly true -> null',
        '~ schema Job.conditions[]: $ref "Condition" -> "ConditionV2"',
        "+ schema Job.etag",
        '~ schema Job.labels{}: type "string" -> "integer"',
        "+ schema Job.nameSuffix",
        "~ schema Job.state: enum + C, - B",
        "+ schema Job.template.retries",
        '~ schema Job.template.timeout: format "google-duration" -> "int64"',
    ]
    same(compare(base, new), want, hidden=2)

    # --descriptions prints what was only counted.
    lines = compare(base, new, descriptions=True)[0]
    assert '~ method run.projects.jobs.list: description "Lists Jobs." -> "Lists Jobs, newest first."' in lines, lines
    assert '~ schema Job.state: enumDescriptions ["a", "b"] -> ["a", "c"]' in lines, lines
    assert compare(base, new, descriptions=True)[1] == 0

    # --only keeps matching methods and schemas, and drops the document's lines.
    same(compare(base, new, only=["run.projects.jobs.run", "Gone"]), ["- method run.projects.jobs.run", "- schema Gone"])
    same(compare(base, new, only=["Nothing"]), [])

    # An enum reordered, nothing added or removed.
    reordered = json.loads(json.dumps(base))
    reordered["schemas"]["Job"]["properties"]["state"]["enum"] = ["B", "A"]
    reordered["schemas"]["Job"]["properties"]["state"]["enumDescriptions"] = ["b", "a"]
    same(compare(base, reordered), ["~ schema Job.state: enum reordered"], hidden=1)

    # A method with no id is named by its resource path.
    anonymous = json.loads(json.dumps(base))
    anonymous["methods"] = {"ping": {"httpMethod": "GET", "path": "ping"}}
    same(compare(base, anonymous), ["+ method run.ping"])

    # The whole run: exit codes and what is printed.
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        paths = {}
        for label, doc in (("base", base), ("new", new), ("shuffled", shuffled)):
            paths[label] = os.path.join(tmp, f"{label}.json")
            with open(paths[label], "w", encoding="utf-8") as f:
                json.dump(doc, f)
        paths["junk"] = os.path.join(tmp, "junk.json")
        with open(paths["junk"], "w", encoding="utf-8") as f:
            f.write('{"kind": "storage#object"}')
        paths["broken"] = os.path.join(tmp, "broken.json")
        with open(paths["broken"], "w", encoding="utf-8") as f:
            f.write("{")
        printed = []
        assert run([paths["base"], paths["shuffled"]], printed.append) == 0
        assert printed == ["# revision 20261009 -> 20261020", "# no change"], printed
        printed.clear()
        assert run([paths["base"], paths["new"]], printed.append) == 1
        assert printed[0] == "# revision 20261009, both" and printed[1:-1] == want, printed
        assert printed[-1] == "# 2 description changes not shown (--descriptions shows them)", printed
        quiet = open(os.devnull, "w")
        stderr, sys.stderr = sys.stderr, quiet
        try:
            assert run([paths["base"], paths["junk"]], printed.append) == 2
            assert run([paths["broken"], paths["base"]], printed.append) == 2
            assert run([paths["base"], os.path.join(tmp, "missing.json")], printed.append) == 2
            try:
                run([paths["base"]], printed.append)
            except SystemExit as e:
                assert e.code == 64, e.code
            else:
                raise AssertionError("one document was accepted")
        finally:
            sys.stderr = stderr
            quiet.close()


def main():
    return run(sys.argv[1:], print)


if __name__ == "__main__":
    sys.exit(main())
