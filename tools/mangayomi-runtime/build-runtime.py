import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--dart', default=os.environ.get('DART', 'dart'))
parser.add_argument('--resolve', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
repo = root.parent.parent
provenance = json.loads((root / 'provenance.json').read_text())
version = subprocess.run([args.dart, '--version'], check=True, capture_output=True, text=True).stdout
if f"Dart SDK version: {provenance['dartSDK']} " not in version:
    raise SystemExit('The runtime requires the pinned Dart SDK version ' + provenance['dartSDK'])
pub = [args.dart, 'pub', 'get', '--enforce-lockfile']
if not args.resolve:
    pub.append('--offline')
subprocess.run(pub, check=True, cwd=root)
with tempfile.TemporaryDirectory(prefix='mangayomi-dart-runtime-') as temp:
    output = Path(temp) / 'runtime.js'
    subprocess.run([args.dart, 'compile', 'js', '--csp', '-O2', 'bin/main.dart', '-o', str(output)], check=True, cwd=root)
    target = repo / 'Eclipse/JSLoader/Resources/MangayomiDartRuntime.js'
    shutil.copyfile(output, target)
    shutil.copyfile(root / 'THIRD-PARTY-LICENSES.txt', target.with_suffix('.LICENSE.txt'))
    provenance['outputSHA256'] = hashlib.sha256(target.read_bytes()).hexdigest()
    (root / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print('Built ' + str(target) + ' sha256=' + provenance['outputSHA256'])
