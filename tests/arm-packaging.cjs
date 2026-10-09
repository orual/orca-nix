const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs')
const { tmpdir } = require('node:os')
const { join, resolve } = require('node:path')
const { test } = require('node:test')

const source = resolve(process.argv[2])
const { prunePackagedRuntimeNodeModules } = require(join(source, 'config/packaged-runtime-node-modules.cjs'))
const { collectNativeBinaries, findArchViolation } = require(join(source, 'config/scripts/verify-linux-glibc-floor.cjs'))

function writeElf(path, machine) {
  mkdirSync(resolve(path, '..'), { recursive: true })
  const header = Buffer.alloc(20)
  header.write('\x7fELF', 0, 'latin1')
  header[5] = 1
  header.writeUInt16LE(machine, 18)
  writeFileSync(path, header)
}

test('ARM pruning removes the host watcher and keeps the target watcher', () => {
  const directory = mkdtempSync(join(tmpdir(), 'orca-packaging-'))
  try {
    const root = join(directory, 'dist/linux-arm64-unpacked')
    const resources = join(root, 'resources')
    const hostWatcher = join(resources, 'node_modules/@parcel/watcher-linux-x64-glibc/watcher.node')
    const targetWatcher = join(resources, 'node_modules/@parcel/watcher-linux-arm64-glibc/watcher.node')
    writeElf(hostWatcher, 0x3e)
    writeElf(targetWatcher, 0xb7)
    assert.equal(findArchViolation(hostWatcher, 'arm64').actual, 'x64')
    prunePackagedRuntimeNodeModules(resources, 'linux', 3)
    assert.equal(existsSync(hostWatcher), false)
    assert.equal(existsSync(targetWatcher), true)
    assert.equal(collectNativeBinaries(root).length, 1)
    assert.equal(findArchViolation(targetWatcher, 'arm64'), null)

    const pty = join(resources, 'node_modules/node-pty/build/Release/pty.node')
    writeElf(pty, 0x3e)
    prunePackagedRuntimeNodeModules(resources, 'linux', 3)
    assert.equal(findArchViolation(pty, 'arm64').actual, 'x64')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('the packaging patch runs the Linux check once, after pruning', () => {
  const directory = mkdtempSync(join(tmpdir(), 'orca-config-'))
  try {
    mkdirSync(join(directory, 'config'))
    copyFileSync(join(source, 'config/electron-builder.config.cjs'), join(directory, 'config/electron-builder.config.cjs'))
    execFileSync('patch', ['-p1', '-d', directory, '-i', resolve(__dirname, '../patches/verify-linux-after-pruning.patch')])
    const config = readFileSync(join(directory, 'config/electron-builder.config.cjs'), 'utf8')
    assert.equal(config.match(/verifyLinuxGlibcFloor\(context\.appOutDir/g).length, 1)
    assert.ok(config.indexOf('prunePackagedRuntimeNodeModules(resourcesDir,') < config.indexOf('verifyLinuxGlibcFloor(context.appOutDir'))
    assert.ok(config.includes("targetArch: { 1: 'x64', 3: 'arm64' }[context.arch]"))
    execFileSync(process.execPath, ['--check', join(directory, 'config/electron-builder.config.cjs')])
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
