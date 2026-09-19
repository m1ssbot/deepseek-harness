import { createRequire } from 'module'
import { readFileSync, readdirSync, statSync, existsSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { spawnSync } from 'child_process'

const repo = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const name = '@deepseek-ai/dsh-commands'
const roots = [
  join(repo, 'package.json'),
  join(repo, 'packages/interaction/commands/package.json'),
  join(repo, 'apps/cli/package.json'),
  join(repo, 'packages/bundle/web-app/package.json'),
]

for (const root of roots) {
  if (!existsSync(root)) { console.log('missing root', root); continue }
  const r = createRequire(root)
  try {
    const pkg = r.resolve(name + '/package.json')
    console.log('OK', root, '=>', pkg)
    const lib = join(dirname(pkg), 'lib')
    for (const f of readdirSync(lib)) {
      if (!f.includes('typert') && f !== 'client.js') continue
      const p = join(lib, f)
      const t = readFileSync(p, 'utf8')
      console.log(' ', f, {
        mtime: statSync(p).mtime.toISOString(),
        submitted: t.includes('submittedAttachments'),
        executeImages: t.includes('execute:images'),
      })
    }
  } catch (e) {
    console.log('FAIL', root, e.message.split('\n')[0])
  }
}

const rg = spawnSync('rg', ['-l', 'execute:images', repo, '--glob', '!node_modules'], { encoding: 'utf8' })
console.log('rg execute:images:\\n' + (rg.stdout || '(none)'))
console.log('rg err:\\n' + (rg.stderr || ''))
