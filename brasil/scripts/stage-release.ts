#!/usr/bin/env bun
/**
 * Monta a árvore de uma release.
 *
 *   bun brasil/scripts/stage-release.ts <repo> <kam_remake_resources> <destino>
 *
 * Lista de inclusão, não de exclusão. Apontar a publicação para a raiz do
 * repositório mandaria `src/`, `Docs/` e o histórico do git para os jogadores —
 * enumerar o que entra é a única forma segura.
 *
 * O que deliberadamente NÃO entra: sprites, sons, músicas, `houses.dat` e
 * `unit.dat`. Vêm do Knights and Merchants original e são gerados na máquina do
 * jogador (ver launcher/src-tauri/src/assets.rs).
 */
import { cp, mkdir, rm, stat } from 'node:fs/promises'
import { join, resolve } from 'node:path'

const [repoArg, resourcesArg, outArg] = process.argv.slice(2)

if (!repoArg || !resourcesArg || !outArg) {
  console.error('uso: bun stage-release.ts <repo> <kam_remake_resources> <destino>')
  process.exit(1)
}

const repo = resolve(repoArg)
const resources = resolve(resourcesArg)
const out = resolve(outArg)

/** Arquivos soltos, na raiz. */
const FILES = [
  'KaM_Remake.exe',
  'bass.dll',
  'ogg.dll',
  'vorbis.dll',
  'vorbisfile.dll',
  'libzplay.dll',
  'LICENSE.txt',
  'Changelog.txt',
]

/** Pastas inteiras: [origem relativa ao repo, destino relativo à release]. */
const DIRS: [string, string][] = [
  ['data/text', 'data/text'],
  ['data/gfx/fonts', 'data/gfx/fonts'],
  ['data/cursors', 'data/cursors'],
  ['Maps', 'Maps'],
  ['MapsMP', 'MapsMP'],
  ['Campaigns', 'Campaigns'],
  ['Tutorials', 'Tutorials'],
  ['Docs/Readme', 'Readme'],
]

/**
 * De `data/defines` vão só os arquivos do projeto. `houses.dat` e `unit.dat`
 * são do jogo original e ficam de fora.
 */
const DEFINES = ['mapelem.dat', 'tiles.json', 'interp.dat']

/** O RXXPacker roda na máquina do jogador; vai junto, com os sprites que ele consome. */
const SPRITE_FOLDERS = ['2', '3', '4', '5', '7']

async function exists(path: string) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function copyFile(from: string, to: string) {
  if (!(await exists(from))) {
    console.warn(`  ! faltando, pulado: ${from}`)
    return 0
  }
  await mkdir(join(to, '..'), { recursive: true })
  await Bun.write(to, Bun.file(from))
  return 1
}

async function copyDir(from: string, to: string) {
  if (!(await exists(from))) {
    console.warn(`  ! faltando, pulado: ${from}`)
    return
  }
  await cp(from, to, { recursive: true })
}

console.log(`repo      : ${repo}`)
console.log(`resources : ${resources}`)
console.log(`destino   : ${out}\n`)

await rm(out, { recursive: true, force: true })
await mkdir(out, { recursive: true })

console.log('executável e bibliotecas')
for (const f of FILES) await copyFile(join(repo, f), join(out, f))

console.log('dados do projeto')
for (const [from, to] of DIRS) await copyDir(join(repo, from), join(out, to))
for (const f of DEFINES) await copyFile(join(repo, 'data/defines', f), join(out, 'data/defines', f))

console.log('RXXPacker e sprites da comunidade')
await copyFile(join(repo, 'Utils/RXXPacker/RXXPacker.exe'), join(out, 'Utils/RXXPacker/RXXPacker.exe'))
for (const folder of SPRITE_FOLDERS) {
  await copyDir(join(resources, 'SpriteResource', folder), join(out, 'SpriteResource', folder))
}

// Confere o que nao pode ter escapado. Uma lista de inclusao errada e silenciosa:
// o jogador so descobriria recebendo material que nao deveriamos distribuir.
const FORBIDDEN = ['data/Sprites', 'data/sfx', 'Music', 'data/defines/houses.dat', 'data/defines/unit.dat', 'src', 'brasil']
const leaked: string[] = []
for (const f of FORBIDDEN) if (await exists(join(out, f))) leaked.push(f)

if (leaked.length > 0) {
  console.error(`\nERRO: material que nao deve ser distribuido entrou na release: ${leaked.join(', ')}`)
  process.exit(1)
}

const proc = Bun.spawnSync(['powershell', '-NoProfile', '-Command',
  `$f = Get-ChildItem '${out}' -Recurse -File; '{0} arquivos, {1:N1} MB' -f $f.Count, (($f | Measure-Object Length -Sum).Sum/1MB)`])

console.log(`\npronto: ${proc.stdout.toString().trim()}`)
console.log(`\npublicar com:\n  curl -X POST http://localhost:3000/client/releases \\\n    -H "x-admin-token: $ADMIN_TOKEN" -H 'content-type: application/json' \\\n    -d '{"version":"1.0.0","gameRevision":"r16155","sourceDir":"${out.replace(/\\/g, '/')}"}'`)
