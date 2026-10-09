#!/usr/bin/env python3
"""Export current sources and reject incomplete/nonportable application bundles."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

MACHO_MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
EXPECTED = {'Receiver': ('x86_64', '10.15', 4), 'Sender': ('arm64', '14.0', 1)}


def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])


def runtime_paths(commands):
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)


def validate_image(path, app, architecture, maximum_os, inherited_rpaths=()):
    archs = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
    if archs != [architecture]:
        raise ValueError(f'Unexpected architecture: {path}: {archs}')
    commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
    minimum = re.search(r'\bminos\s+(\S+)', commands) or re.search(r'LC_VERSION_MIN_MACOSX[\s\S]*?\bversion\s+(\S+)', commands)
    if minimum is None or version(minimum[1]) > version(maximum_os):
        raise ValueError(f'Incompatible minimum macOS: {path}')
    for rpath in runtime_paths(commands):
        if rpath not in ('@executable_path', '@loader_path') and not rpath.startswith(('@executable_path/', '@loader_path/', '/System/Library/', '/usr/lib/')):
            raise ValueError(f'Nonportable runtime search path: {path}: {rpath}')
    linked = subprocess.check_output(['otool', '-L', str(path)], text=True)
    for dependency in re.findall(r'^\s+(.*?) \(compatibility version', linked, re.M):
        if dependency.startswith(('/System/Library/', '/usr/lib/')):
            continue
        install_id = re.search(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset', commands)
        if install_id and dependency == install_id[1] and dependency.startswith('@rpath/'):
            continue
        if dependency.startswith('@rpath/'):
            # macOS 14 supplies the Sender's system Swift runtime.
            if dependency.startswith('@rpath/libswift') and architecture == 'arm64' and version(maximum_os) >= version('14.0'):
                continue
            search = [(value, path.parent) for value in runtime_paths(commands)] + list(inherited_rpaths)
            found = False
            for value, loader_directory in search:
                directory = value.replace('@executable_path', str(app / 'Contents/MacOS')).replace('@loader_path', str(loader_directory))
                candidate = (Path(directory) / dependency[len('@rpath/'):]).resolve()
                if candidate.is_relative_to(app.resolve()) and candidate.is_file():
                    found = True
                    break
            if found:
                continue
        elif dependency.startswith(('@loader_path/', '@executable_path/')):
            base = path.parent if dependency.startswith('@loader_path/') else app / 'Contents/MacOS'
            candidate = (base / dependency.split('/', 1)[1]).resolve()
            if candidate.is_relative_to(app.resolve()) and candidate.is_file():
                continue
        raise ValueError(f'Missing/nonportable library: {path}: {dependency}')
    return {'executable': path.relative_to(app).as_posix(), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'architectures': ' '.join(archs), 'minimumOS': minimum[1]}


def main(root, stage):
    source_root = stage / 'Sources/CurrentSource'
    source_root.mkdir(parents=True, exist_ok=True)
    paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).split(b'\0')
    sources = {}
    for raw in sorted(set(paths)):
        if not raw:
            continue
        relative = Path(raw.decode('utf-8'))
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unsafe source path')
        source = root / relative
        if not source.is_file() or source.is_symlink():
            continue
        target = source_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        sources[relative.as_posix()] = hashlib.sha256(target.read_bytes()).hexdigest()
    bundles = []
    for side, (arch, minimum_os, count) in EXPECTED.items():
        apps = sorted((stage / side).glob('*.app'))
        if len(apps) != count:
            raise ValueError(f'Incomplete {side} distribution: expected {count} apps')
        for app in apps:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if version(info['LSMinimumSystemVersion']) > version(minimum_os):
                raise ValueError(f'Incompatible bundle minimum macOS: {app}')
            executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
            main_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
            inherited_rpaths = [(value, executable.parent) for value in runtime_paths(main_commands)]
            images = []
            for path in sorted(app.rglob('*')):
                if not path.is_file() or path.is_symlink():
                    continue
                with path.open('rb') as file:
                    if file.read(4) not in MACHO_MAGIC:
                        continue
                images.append(validate_image(path, app, arch, minimum_os, inherited_rpaths))
            if not any(image['executable'] == executable.relative_to(app).as_posix() for image in images):
                raise ValueError(f'Missing main executable: {app}')
            bundles.append({'bundle': app.relative_to(stage).as_posix(), 'version': info['CFBundleShortVersionString'], 'images': images})
    manifest = {'schema': 2, 'milestone': 'current-source-preview',
        'sourceBaseCommit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        'sourceFiles': sources, 'bundles': bundles,
        'signing': 'local ad-hoc; notarization and virtual-device activation not validated'}
    (stage / 'BuildManifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Build manifest: {len(sources)} sources, {len(bundles)} apps, {sum(len(b["images"]) for b in bundles)} Mach-O images')


if __name__ == '__main__':
    main(*(Path(value).resolve() for value in sys.argv[1:3]))
