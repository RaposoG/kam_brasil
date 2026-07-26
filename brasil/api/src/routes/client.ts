import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { mkdir, readdir, stat, writeFile } from 'node:fs/promises'
import { join, posix, relative, resolve, sep } from 'node:path'
import type { FastifyInstance, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { config } from '../config.ts'
import { clientReleases } from '../data-source.ts'
import type { ClientRelease } from '../entities/client-release.ts'

const publishSchema = z.object({
  version: z.string().regex(/^[0-9]+\.[0-9]+\.[0-9]+$/, 'versão deve ser no formato 1.2.3'),
  gameRevision: z.string().min(1).max(32),
  /** Pasta no servidor com a árvore pronta para publicar. */
  sourceDir: z.string().min(1),
  notes: z.string().max(4000).default(''),
  published: z.boolean().default(true),
})

interface ManifestFile {
  path: string
  size: number
  sha256: string
}

/**
 * Nunca entram numa release: ou vêm do Knights and Merchants original (e são
 * gerados na máquina do jogador), ou são lixo de build, ou são estado local
 * daquele jogador.
 */
const EXCLUDED_PREFIXES = [
  'data/sprites/', // gerado pelo RXXPacker a partir dos .rx do jogador
  'data/sfx/', // sons do jogo original
  'music/', // músicas do jogo original
  'logs/',
  'saves/',
  'savesmp/',
  'savescmp/',
  'brasil/', // a plataforma nao faz parte do jogo
  '.git/',
]

const EXCLUDED_FILES = [
  'data/defines/houses.dat', // do jogo original
  'data/defines/unit.dat', // do jogo original
  'kambrasil.json', // marcador de versao instalada, e local
]

/**
 * Só artefatos de build, que nunca são conteúdo de jogo.
 *
 * Esta lista é rede de segurança, não a regra: quem decide o que entra é o
 * `brasil/scripts/stage-release.ts`, por lista de inclusão. Toda extensão a mais
 * aqui é risco de descartar conteúdo legítimo em silêncio.
 *
 * `.map` **não** entra: é o terreno dos mapas do KaM, não o linker map do
 * Delphi. Excluí-lo publicaria centenas de mapas que não carregam.
 */
const EXCLUDED_EXTENSIONS = ['.dcu', '.o', '.ppu', '.identcache', '.drc']

function isExcluded(relPath: string): boolean {
  const lower = relPath.toLowerCase()
  if (EXCLUDED_PREFIXES.some((p) => lower.startsWith(p))) return true
  if (EXCLUDED_FILES.includes(lower)) return true
  if (EXCLUDED_EXTENSIONS.some((e) => lower.endsWith(e))) return true
  // Paletas e .dat de gfx tambem vem do original
  if (lower.startsWith('data/gfx/') && /\.(bbm|lbm|dat)$/.test(lower)) return true
  return false
}

async function sha256OfFile(path: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

/** Percorre a árvore devolvendo caminhos relativos com barra normal. */
async function walk(root: string, current = root): Promise<string[]> {
  const entries = await readdir(current, { withFileTypes: true })
  const out: string[] = []

  for (const entry of entries) {
    const full = join(current, entry.name)
    if (entry.isDirectory()) {
      out.push(...(await walk(root, full)))
    } else if (entry.isFile()) {
      out.push(relative(root, full).split(sep).join(posix.sep))
    }
  }

  return out
}

function manifestUrl(request: FastifyRequest, version: string) {
  return `${request.protocol}://${request.host}/downloads/${version}/manifest.json`
}

function toPublic(release: ClientRelease, request: FastifyRequest) {
  return {
    version: release.version,
    gameRevision: release.gameRevision,
    fileCount: release.fileCount,
    totalBytes: Number(release.totalBytes),
    manifestUrl: manifestUrl(request, release.version),
    manifestSha256: release.manifestSha256,
    baseUrl: `${request.protocol}://${request.host}/downloads/${release.version}/files`,
    notes: release.notes,
    publishedAt: release.createdAt,
  }
}

export default async function clientRoutes(app: FastifyInstance) {
  /** Versão que os jogadores devem estar rodando. */
  app.get('/client/latest', async (request, reply) => {
    const release = await clientReleases().findOne({
      where: { published: true },
      order: { createdAt: 'DESC' },
    })

    if (!release) return reply.code(404).send({ error: 'nenhuma versão publicada ainda' })

    return toPublic(release, request)
  })

  app.get('/client/releases', async (request) => {
    const releases = await clientReleases().find({
      where: { published: true },
      order: { createdAt: 'DESC' },
      take: 20,
    })
    return { releases: releases.map((r) => toPublic(r, request)) }
  })

  /**
   * Publica uma release a partir de uma árvore no servidor.
   *
   * A API percorre a pasta, calcula o sha256 de cada arquivo e escreve o
   * manifesto. Hashes vêm sempre do disco, nunca do que o publicador informou —
   * é o que garante que o manifesto descreve o que os jogadores vão baixar.
   */
  app.post('/client/releases', async (request, reply) => {
    if (!config.ADMIN_TOKEN) {
      return reply.code(503).send({ error: 'publicação desabilitada: ADMIN_TOKEN não configurado' })
    }
    if (request.headers['x-admin-token'] !== config.ADMIN_TOKEN) {
      return reply.code(401).send({ error: 'token administrativo inválido' })
    }

    const parsed = publishSchema.safeParse(request.body)
    if (!parsed.success) {
      return reply.code(400).send({ error: 'dados inválidos', issues: z.treeifyError(parsed.error) })
    }

    const { version, gameRevision, sourceDir, notes, published } = parsed.data

    const source = resolve(sourceDir)
    try {
      if (!(await stat(source)).isDirectory()) throw new Error('não é pasta')
    } catch {
      return reply.code(400).send({ error: `pasta não encontrada: ${source}` })
    }

    const releaseDir = join(resolve(config.RELEASES_DIR), version)
    const filesDir = join(releaseDir, 'files')
    await mkdir(filesDir, { recursive: true })

    const all = await walk(source)
    const included = all.filter((p) => !isExcluded(p))

    const files: ManifestFile[] = []
    let totalBytes = 0

    for (const rel of included) {
      const from = join(source, ...rel.split(posix.sep))
      const to = join(filesDir, ...rel.split(posix.sep))
      await mkdir(join(to, '..'), { recursive: true })

      // copyFile em vez de link: a pasta de origem e o repositorio de trabalho e
      // continua sendo editada. Uma release tem que ser um retrato imutavel.
      await Bun.write(to, Bun.file(from))

      const size = (await stat(to)).size
      files.push({ path: rel, size, sha256: await sha256OfFile(to) })
      totalBytes += size
    }

    const manifest = { version, gameRevision, files }
    const manifestJson = JSON.stringify(manifest, null, 2)
    await writeFile(join(releaseDir, 'manifest.json'), manifestJson)
    const manifestSha256 = createHash('sha256').update(manifestJson).digest('hex')

    try {
      const release = await clientReleases().save(
        clientReleases().create({
          version,
          gameRevision,
          fileCount: files.length,
          totalBytes: String(totalBytes),
          manifestSha256,
          notes,
          published,
        }),
      )
      return reply.code(201).send({
        ...toPublic(release, request),
        skipped: all.length - included.length,
      })
    } catch (error) {
      if ((error as { code?: string }).code === '23505') {
        return reply.code(409).send({ error: `versão ${version} já foi publicada` })
      }
      throw error
    }
  })
}
