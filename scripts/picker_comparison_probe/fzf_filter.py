"""Explicit bounded CLI comparison; fixture matches probe.ml, no files generated."""
import json
import os
import subprocess
import time

env = dict(os.environ, FZF_DEFAULT_OPTS="", FZF_DEFAULT_COMMAND="", GOMAXPROCS="2")
print(json.dumps({"version": subprocess.check_output(["fzf", "--version"], env=env).decode().strip(),
                  "GOMAXPROCS": 2, "samples_per_query": 1}))
for n in (10_000, 50_000):
    start = time.perf_counter_ns()
    paths = [f"{('src', 'test', 'lib', 'docs', 'vendor')[i % 5]}/package_{i // 25:04d}/component_{i % 25:02d}/{('model.ml', 'file_picker.ml', 'controller.ml', 'README.md', 'test_search.ml')[i // 5 % 5]}".encode()
             for i in range(n)]
    payload = b"\0".join(paths) + b"\0"
    print(json.dumps({"n": n, "serialize_ms": (time.perf_counter_ns()-start)/1e6,
                      "input_bytes": len(payload)}))
    # Same literal query progression; each --filter is a fresh process, no cache reuse.
    for query in ("", "m", "mo", "model", "mode", "mod", "model", "", "src mod", "zzzzzz"):
        start = time.perf_counter_ns()
        result = subprocess.run(["fzf", "--read0", "--print0", "--extended", "-i",
                                 "--tiebreak=index", "--filter=" + query], input=payload,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=10)
        child_ms = (time.perf_counter_ns() - start)/1e6
        assert result.returncode in (0, 1), result.stderr
        start = time.perf_counter_ns()
        output = result.stdout.split(b"\0")[:-1]
        parse_ms = (time.perf_counter_ns()-start)/1e6
        print(json.dumps({"n": n, "query": query, "spawn_io_filter_exit_ms": child_ms,
                          "split_output_ms": parse_ms, "output_bytes": len(result.stdout),
                          "matches": len(output)}))
