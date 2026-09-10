#!/usr/bin/env python3
"""Compile the exact benchmark P2 input and cache its trusted local LLVM AOT."""
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

runtime, source, cache = (Path(arg).resolve() for arg in sys.argv[1:])
flags = ['-C', 'cranelift-llvm-backend=true', '-C', 'cranelift-sse41']
def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

identity = dict(format=1, runtime_sha256=digest(runtime),
                input_sha256=digest(source), flags=flags)
key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
folder = cache / key
folder.mkdir(parents=True, exist_ok=True)
artifact = folder / 'app.cwasm'
manifest = folder / 'manifest.json'
with (folder / 'lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        saved = json.loads(manifest.read_text())
        valid = saved['identity'] == identity and saved['aot_sha256'] == digest(artifact)
    except (OSError, ValueError, KeyError):
        valid = False
    if valid:
        print(f'LLVM AOT cache hit: {source.name}', file=sys.stderr)
    else:
        print(f'LLVM AOT compiling: {source.name} (requires opt-19 / llc-19)', file=sys.stderr)
        log = folder / 'compile.log'
        with tempfile.TemporaryDirectory(prefix='build-', dir=folder) as work:
            candidate = Path(work) / 'app.cwasm'
            with log.open('w') as output:
                result = subprocess.run([str(runtime), 'compile', *flags,
                                         '-o', str(candidate), str(source)],
                                        stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                print(log.read_text(errors='replace')[-12000:], file=sys.stderr)
                sys.exit(f'LLVM compilation failed; log: {log}')
            candidate.replace(artifact)
        manifest.write_text(json.dumps(dict(identity=identity,
            aot_sha256=digest(artifact), source=str(source)), indent=2)+'\n')
print(artifact)
