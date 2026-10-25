#!/usr/bin/env python3
"""Measure all Sources/ Swift files using the offline CI regression suites."""
import argparse
import html
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
CHECKS = (
    "ContractChecks", "AuthorizationChecks", "ModelTransportChecks --offline",
    "HostIntegrationChecks", "StructuredModelChecks", "WorkbenchChecks",
    "SharedAuthorityChecks", "WorkspaceChecks", "WorkspaceTransferChecks", "VMChecks", "RuntimeReceiveChecks",
    "PresentationChecks (validated)",
    "ExecutionBoundaryChecks", "ExecutionBoundaryChecks --final-effect-clock",
    "ExecutionBoundaryChecks --native-repairs", "ExecutionBoundaryChecks --native-response",
    "MCPGatewayChecks --transport-unit",
    "MCPGatewayChecks (loopback)", "MCPGatewayChecks (independent loopback)",
    "ExecutionBoundaryChecks --mcp (loopback)",
    "ExecutionBoundaryChecks --mcp-transaction (loopback)",
    "WorkbenchChecks --composition-mcp (loopback)",
    "MiniSandbox --diagnostics-json (validated)",
)


def check_commands(binary_dir):
    for name in CHECKS:
        if name == "PresentationChecks (validated)":
            yield [sys.executable, str(ROOT / "Tests/PresentationTests/run.py"),
                   "--binary", str(binary_dir / "PresentationChecks")]
        elif name.endswith("(validated)"):
            yield [sys.executable, str(ROOT / "Tests/DiagnosticsTests/check_diagnostics.py"),
                   "--binary", str(binary_dir / "MiniSandbox")]
        elif "loopback)" not in name:
            binary, *args = name.split()
            yield [str(binary_dir / binary), *args]
        elif name.startswith("MCPGatewayChecks"):
            yield [sys.executable, str(ROOT / "Tests/MCPIntegrationTests/test_loopback.py"),
                   "--binary", str(binary_dir / "MCPGatewayChecks"), "--scope",
                   "independent" if "independent" in name else "default"]
        elif name.startswith("ExecutionBoundaryChecks"):
            args = ["--transaction"] if "transaction" in name else []
            yield [sys.executable, str(ROOT / "Tests/ExecutionBoundaryChecks/loopback.py"),
                   "--binary", str(binary_dir / "ExecutionBoundaryChecks"), *args]
        else:
            yield [sys.executable, str(ROOT / "Tests/MCPIntegrationTests/composition_close.py"),
                   "--binary", str(binary_dir / "WorkbenchChecks")]


def source_totals(export, root, sources):
    """Filter LLVM's merged report; count uncovered source files in the denominator."""
    expected = {str(path.resolve()): path.relative_to(root).as_posix() for path in sources}
    rows = {}
    for unit in export["data"]:
        for entry in unit["files"]:
            filename = str(Path(entry["filename"]).resolve())
            if filename not in expected:
                continue
            path = expected[filename]
            if path in rows:
                raise ValueError(f"duplicate coverage entry: {path}")
            lines = entry["summary"]["lines"]
            total, covered = lines["count"], lines["covered"]
            if type(total) is not int or type(covered) is not int or not 0 <= covered <= total:
                raise ValueError(f"invalid line counts: {path}")
            rows[path] = {"path": path, "lines": total, "covered": covered}
    missing = set(expected.values()) - rows.keys()
    if missing:
        raise ValueError(f"source files missing from LLVM report: {sorted(missing)}")
    total = sum(row["lines"] for row in rows.values())
    covered = sum(row["covered"] for row in rows.values())
    if total == 0:
        raise ValueError("no executable source lines found")
    return {"lines": total, "covered": covered, "percent": round(100 * covered / total, 2),
            "files": sorted(rows.values(), key=lambda row: row["path"])}


def badge(percent):
    value = f"{percent:.1f}%"
    color = "#4c1" if percent >= 80 else "#dfb317" if percent >= 50 else "#e05d44"
    title = html.escape(f"Swift line coverage: {value}")
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="164" height="20" role="img" aria-label="{title}">
  <title>{title}</title>
  <rect width="164" height="20" rx="3" fill="#555"/>
  <path d="M106 0h55a3 3 0 0 1 3 3v14a3 3 0 0 1-3 3h-55z" fill="{color}"/>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Arial,sans-serif" font-size="11">
    <text x="53" y="14">Swift coverage</text><text x="135" y="14">{value}</text>
  </g>
</svg>
'''


def report_markdown(report):
    repo = report["repository"]
    commit = report["commit"]
    lines = ["# Swift CI line coverage", "",
             f"**{report['percent']:.1f}%** — {report['covered']:,} / {report['lines']:,} executable lines.", "",
             f"Source commit: [`{commit[:12]}`](https://github.com/{repo}/commit/{commit}).", "",
             "Scope: all Swift files under `Sources/`, including files with zero hits. "
             "Excludes `Tests/`, `Tools/`, Python, Go and generated code.", "",
             "Executed checks: " + ", ".join(f"`{name}`" for name in report["checks"]) + ". "
             "Compiling another target does not count as exercising it.", ""]
    if report["run_url"]:
        lines.extend([f"[CI run]({report['run_url']})", ""])
    lines.extend(["| Source | Covered / executable lines | Coverage |", "|---|---:|---:|"])
    for row in report["files"]:
        percent = f"{100 * row['covered'] / row['lines']:.1f}%" if row["lines"] else "n/a"
        url = f"https://github.com/{repo}/blob/{commit}/{quote(row['path'], safe='/')}"
        lines.append(f"| [{row['path']}]({url}) | {row['covered']} / {row['lines']} | {percent} |")
    return "\n".join(lines) + "\n"


def run(args):
    scratch = args.scratch_path.resolve()
    output = args.output.resolve()
    build = ["swift", "build", "--scratch-path", str(scratch), "--enable-code-coverage"]
    if not args.skip_build:
        subprocess.run(build, cwd=ROOT, check=True)
    binary_dir = Path(subprocess.check_output(build + ["--show-bin-path"], cwd=ROOT, text=True).strip())
    sources = sorted((ROOT / "Sources").rglob("*.swift"))
    # Load every product source object, including modules not linked by the checks.
    objects = [binary_dir / (source.relative_to(ROOT / "Sources").parts[0] + ".build") /
               (source.name + ".o") for source in sources]
    for obj in objects:
        if not obj.is_file():
            raise ValueError(f"missing instrumented source object: {obj}")
    # SwiftPM does not link executable dependencies into another executable.
    # Link the actual instrumented App object (its entry point is renamed by
    # SwiftPM), together with the other unchanged product objects, into a
    # separate presentation harness. No copied or rewritten product sources.
    description = json.loads((binary_dir / "description.json").read_text())
    host_arguments = next(command["otherArguments"] for command in description["swiftCommands"].values()
                          if command["moduleName"] == "SandboxHost")
    package_name = host_arguments[host_arguments.index("-package-name") + 1]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-package-name", package_name, "-profile-generate", "-profile-coverage-mapping",
                    "-I", str(binary_dir / "Modules"),
                    *map(str, sorted((ROOT / "Tests/PresentationTests").glob("*.swift"))),
                    *map(str, objects), "-o", str(binary_dir / "PresentationChecks")],
                   cwd=ROOT, check=True)
    output.mkdir(parents=True, exist_ok=True)
    # A fresh profile directory prevents old test executions from inflating coverage.
    with tempfile.TemporaryDirectory(prefix="swift-coverage-") as temp:
        profile_dir = Path(temp).resolve()
        env = dict(os.environ, LLVM_PROFILE_FILE=str(profile_dir / "%m-%p.profraw"))
        env["TMPDIR"] = str(profile_dir)
        for name, command in zip(CHECKS, check_commands(binary_dir), strict=True):
            print(f"Running {name}", flush=True)
            subprocess.run(command, cwd=ROOT, env=env, check=True, timeout=120)
        profiles = sorted(profile_dir.glob("*.profraw"))
        if not profiles:
            raise ValueError("checks produced no raw coverage profiles")
        merged = profile_dir / "merged.profdata"
        subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles),
                        "-o", str(merged)], check=True)
        command = ["xcrun", "llvm-cov", "export", f"-instr-profile={merged}", str(objects[0])]
        for obj in objects[1:]:
            command += ["-object", str(obj)]
        exported = json.loads(subprocess.check_output(command, text=True))
        (output / "llvm.json").write_text(json.dumps(exported) + "\n")
    totals = source_totals(exported, ROOT, sources)
    commit = os.environ.get("GITHUB_SHA") or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    repository = os.environ.get("GITHUB_REPOSITORY", "mingmingtsao/mini-sandbox")
    run_id = os.environ.get("GITHUB_RUN_ID")
    report = {"schema": 1, "metric": "Swift executable line coverage", "scope": "Sources/**/*.swift",
              "checks": list(CHECKS), "commit": commit, "repository": repository,
              "run_url": f"https://github.com/{repository}/actions/runs/{run_id}" if run_id else None,
              **totals}
    markdown = report_markdown(report)
    (output / "coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    (output / "coverage.svg").write_text(badge(report["percent"]))
    (output / "README.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(markdown)
    print(f"Swift line coverage: {report['percent']:.1f}% ({report['covered']}/{report['lines']}), {len(sources)} source files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build/coverage")
    parser.add_argument("--output", type=Path, default=ROOT / "coverage-report")
    parser.add_argument("--skip-build", action="store_true", help="Use an existing instrumented build")
    run(parser.parse_args())
