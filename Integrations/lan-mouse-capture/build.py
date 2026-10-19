#!/usr/bin/env python3
"""GPL-3.0-or-later. Build an isolated Lan Mouse backport; never deploy or run it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASE = '0d2190e787db9e482e17d4c16fb7c00ef4841bcb'
FIX = 'c194df791dc11c79d266ada4d413179d4da3525b'
LOCK_SHA = '3fe10057d4303e3a8444077b179e2bf8f9bac0e6077b9bede19c9c764db51424'
SOURCE_SHA = 'f4ff23ab3481fa03a6850d67aa5f57a2f0216b4c57f313931a706f3a0ff57fbc'
PATCH = Path(__file__).with_name('capture-read-once.patch')
PATCH_SHA = 'a835b1d2634086c207be9873fed6a19cbf2c2f44d38859746964d91f6b70b173'
FEATURES = 'layer_shell_capture,libei_capture,libei_emulation,rdp_emulation'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()

def validate_patch(data):
    if hashlib.sha256(data).hexdigest() != PATCH_SHA:
        raise ValueError('The attributed upstream two-hunk patch changed')

def verify_source(source):
    if git(source, 'rev-parse', 'HEAD') != BASE:
        raise ValueError('Expected exact release base')
    if git(source, 'status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('Expected an unmodified isolated source checkout')
    if sha(source / 'Cargo.lock') != LOCK_SHA:
        raise ValueError('Pinned upstream lockfile mismatch')
    if sha(source / 'input-capture/src/layer_shell.rs') != SOURCE_SHA:
        raise ValueError('Release capture source mismatch')

def cargo_commands(cargo):
    common = ['--release', '--locked', '--offline', '--no-default-features']
    return [
        [cargo, 'build', *common, '--features', FEATURES],
        [cargo, 'test', *common, '--features', FEATURES, '--bin', 'lan-mouse'],
        [cargo, 'test', *common, '-p', 'input-capture', '--features', 'layer_shell,libei', '--lib'],
    ]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Disposable, pristine release checkout')
    parser.add_argument('--cargo', default='cargo')
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('jobs must be positive')
    source = args.source.resolve(strict=True)
    validate_patch(PATCH.read_bytes())
    verify_source(source)
    subprocess.run(['git', '-C', str(source), 'apply', '--check', str(PATCH.resolve())], check=True)
    subprocess.run(['git', '-C', str(source), 'apply', str(PATCH.resolve())], check=True)
    if git(source, 'diff', '--name-only') != 'input-capture/src/layer_shell.rs':
        raise ValueError('Unexpected patched source files')
    env = dict(os.environ, CARGO_BUILD_JOBS=str(args.jobs))
    for command in cargo_commands(args.cargo):
        print(json.dumps({'command': command}), flush=True)
        subprocess.run(command, cwd=source, env=env, check=True)
    if sha(source / 'Cargo.lock') != LOCK_SHA:
        raise ValueError('Lockfile changed during build')
    print(json.dumps({'base': BASE, 'upstreamFix': FIX, 'patchSHA256': PATCH_SHA,
                      'lockSHA256': LOCK_SHA, 'sourceSHA256': sha(source / 'input-capture/src/layer_shell.rs'),
                      'binarySHA256': sha(source / 'target/release/lan-mouse'),
                      'features': FEATURES, 'physicalQualityVerified': False}), flush=True)

if __name__ == '__main__':
    main()
