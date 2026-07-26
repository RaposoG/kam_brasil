import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { config } from '../config.ts'
import { clientReleases } from '../data-source.ts'
import type { ClientRelease } from '../entities/client-release.ts'

const publishSchema = z.object({
  version: z.string().min(1).max(32),
  gameRevision: z.string().min(1).max(32),
  /** Arquivo que já foi colocado na pasta de releases. */
  fileName: z.string().min(1).max(128),
  notes: z.string().max(4000).default(''),
  published: z.boolean().default(true),
})

/** Nome de arquivo simples: barra ou `..` viraria leitura fora da pasta. */
const SAFE_FILENAME = /^[A-Za-z0-9._-]+$/

async function sha256OfFile(path: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

function toPublic(release: ClientRelease, baseUrl: string) {
  return {
    version: release.version,
    gameRevision: release.gameRevision,
    downloadUrl: `${baseUrl}/downloads/${release.fileName}`,
    sha256: release.sha256,
    sizeBytes: Number(release.sizeBytes),
    notes: release.notes,
    publishedAt: release.createdAt,
  }
}

export default async function clientRoutes(app: FastifyInstance) {
  /**
   * Última versão que os jogadores devem estar rodando. O launcher compara com
   * o que tem instalado e decide se baixa.
   */
  app.get('/client/latest', async (request, reply) => {
    const release = await clientReleases().findOne({
      where: { published: true },
      order: { createdAt: 'DESC' },
    })

    if (!release) {
      return reply.code(404).send({ error: 'nenhuma versão publicada ainda' })
    }

    const baseUrl = `${request.protocol}://${request.host}`
    return toPublic(release, baseUrl)
  })

  /**
   * Publica uma release. O binário precisa já estar na pasta de releases; a API
   * calcula o sha256 e o tamanho a partir do arquivo em disco, em vez de
   * confiar no que foi enviado — assim o hash sempre corresponde ao que os
   * clientes vão de fato baixar.
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

    const { version, gameRevision, fileName, notes, published } = parsed.data

    if (!SAFE_FILENAME.test(fileName)) {
      return reply.code(400).send({ error: 'fileName inválido' })
    }

    const filePath = join(config.RELEASES_DIR, fileName)
    let sizeBytes: number
    try {
      const info = await stat(filePath)
      if (!info.isFile()) throw new Error('não é arquivo')
      sizeBytes = info.size
    } catch {
      return reply.code(400).send({ error: `arquivo não encontrado em ${config.RELEASES_DIR}: ${fileName}` })
    }

    const sha256 = await sha256OfFile(filePath)

    try {
      const release = await clientReleases().save(
        clientReleases().create({
          version,
          gameRevision,
          fileName,
          sha256,
          sizeBytes: String(sizeBytes),
          notes,
          published,
        }),
      )
      const baseUrl = `${request.protocol}://${request.host}`
      return reply.code(201).send(toPublic(release, baseUrl))
    } catch (error) {
      if ((error as { code?: string }).code === '23505') {
        return reply.code(409).send({ error: `versão ${version} já foi publicada` })
      }
      throw error
    }
  })

  /** Histórico, para o launcher mostrar o que mudou. */
  app.get('/client/releases', async (request) => {
    const releases = await clientReleases().find({
      where: { published: true },
      order: { createdAt: 'DESC' },
      take: 20,
    })
    const baseUrl = `${request.protocol}://${request.host}`
    return { releases: releases.map((r) => toPublic(r, baseUrl)) }
  })
}
