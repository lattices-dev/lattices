#!/usr/bin/env python3
"""Emit signed-bundle build identity from the native build's actual source inputs."""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
from datetime import datetime, timezone

root, resources, plist, configuration = sys.argv[1:]
root = pathlib.Path(root).resolve()

def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()

# Hash contents and relative names, not mtime; exclude generated native build output.
inputs = []
for folder in ('native/engine', 'assets', 'themes'):
    for path in (root / folder).rglob('*'):
        if path.is_file() and not any(part in ('.build', '.swiftpm', '.DS_Store', '__pycache__') for part in path.parts):
            inputs.append(path)
digest = hashlib.sha256()
for path in sorted(inputs):
    digest.update(str(path.relative_to(root)).encode() + b'\0')
    digest.update(path.read_bytes())
    digest.update(b'\0')
with open(plist, 'rb') as file:
    bundle_info = plistlib.load(file)
    version = bundle_info['CFBundleShortVersionString']
orchestration_digest = subprocess.check_output(
    ['bun', '-e', "import { orchestrationDigest } from './packages/runtime/src/capabilities.ts'; console.log(orchestrationDigest(process.cwd()));"],
    cwd=root, text=True,
).strip()
manifest = {
    'schemaVersion': 1,
    'build': {
        'version': version,
        'bundleBuild': bundle_info['CFBundleVersion'],
        'commit': git('rev-parse', 'HEAD'),
        'sourceDigest': digest.hexdigest(),
        'orchestrationSourceDigest': orchestration_digest,
        'sourceScope': 'native/engine+assets+themes (excluding generated .build/.swiftpm)',
        'builtAt': datetime.now(timezone.utc).isoformat(),
        'dirty': bool(git('status', '--porcelain', '--', 'native/engine', 'assets', 'themes')),
        'configuration': configuration,
    },
    'features': {'privateLayer': True, 'isolationContext': True, 'persistentAgentDisplay': True},
    'routing': {
        'nativeHost': 'agent-display owns the persistent monitor; agent-layer attaches a task without display reconfiguration',
        'privateLayerWorkflow': 'Use Action MCP layer_open/snapshot/click/type/js/close with active tools/list names; browser control is MCP orchestration over CDP, not raw WebSocket',
        'rawWebSocket': 'status.methods lists only raw agent RPCs; it is not the complete CLI/MCP capability catalog',
    },
}
pathlib.Path(resources).mkdir(parents=True, exist_ok=True)
(pathlib.Path(resources) / 'build-provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
