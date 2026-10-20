'use strict';
// koffi ships its native library as one npm package per platform, and npm only installs the one
// for the machine it runs on. Packages built for other platforms/architectures need theirs too.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const version = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'node_modules', 'koffi', 'package.json'), 'utf8')).version;
const targets = process.argv.slice(2).length ? process.argv.slice(2) : ['linux-x64', 'linux-arm64', 'win32-x64', 'win32-arm64'];
const packages = targets.map((t) => `@koromix/koffi-${t}@${version}`);
console.log('installing', packages.join(' '));
execFileSync(process.platform === 'win32' ? 'npm.cmd' : 'npm',
  ['install', '--no-save', '--force', '--no-audit', '--no-fund', ...packages], { stdio: 'inherit', shell: process.platform === 'win32' });
