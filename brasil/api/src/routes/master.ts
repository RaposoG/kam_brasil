import type { FastifyInstance, FastifyRequest } from 'fastify'
import { LessThanOrEqual, MoreThan } from 'typeorm'
import { config } from '../config.ts'
import { gameServers } from '../data-source.ts'

/**
 * Compatibilidade com o master server original (os PHPs em Utils/MasterServer/).
 *
 * O cliente monta estas URLs em KM_NetServerLocator.pas e elas são fixas no
 * Pascal — mudar qualquer nome de rota ou formato de resposta exigiria
 * recompilar o jogo. Por isso mantemos o sufixo .php e o texto puro.
 *
 * Todas respondem text/plain. O cliente ignora o corpo de serveradd e maps.
 */

/** O TTL vem do cliente; limitamos para ninguém fixar um servidor fantasma na lista. */
const MAX_TTL_SECONDS = 3600

/**
 * O parser do cliente (TKMServerList.AddFromText) faz split por vírgula e
 * exige exatamente 5 campos — uma vírgula no nome gera 6 e a linha é
 * DESCARTADA EM SILÊNCIO. `|` é quebra de linha na interface do KaM.
 */
function sanitizeServerName(raw: string): string {
  return raw.replace(/[,\r\n|]/g, ' ').trim().slice(0, 60)
}

/** `::ffff:127.0.0.1` e `::1` viram formas comparáveis com o allowlist. */
function normalizeIp(ip: string): string {
  if (ip.startsWith('::ffff:')) return ip.slice(7)
  if (ip === '::1') return '127.0.0.1'
  return ip
}

function isAnnounceAllowed(ip: string): boolean {
  // Lista vazia = qualquer origem pode anunciar. Só aceitável em desenvolvimento.
  if (config.announceAllowedIps.length === 0) return true
  return config.announceAllowedIps.includes(ip)
}

function str(request: FastifyRequest, key: string): string {
  const value = (request.query as Record<string, unknown>)[key]
  return typeof value === 'string' ? value : ''
}

function int(request: FastifyRequest, key: string, fallback = 0): number {
  const parsed = Number.parseInt(str(request, key), 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

export default async function masterRoutes(app: FastifyInstance) {
  /** Um servidor se anuncia. Chamado periodicamente (a cada MasterAnnounceInterval). */
  app.get('/serveradd.php', async (request, reply) => {
    reply.type('text/plain')

    const ip = normalizeIp(request.ip)

    if (!isAnnounceAllowed(ip)) {
      request.log.warn({ ip }, 'anuncio de servidor recusado: origem fora do allowlist')
      // Texto qualquer: o cliente descarta a resposta. Serve para o log/curl.
      return reply.code(403).send('forbidden')
    }

    const port = int(request, 'port')
    if (port < 1 || port > 65535) return reply.code(400).send('invalid port')

    const name = sanitizeServerName(str(request, 'name'))
    if (!name) return reply.code(400).send('invalid name')

    const netRevision = str(request, 'rev')
    if (!netRevision) return reply.code(400).send('invalid revision')

    const ttl = Math.min(Math.max(int(request, 'ttl', 1), 1), MAX_TTL_SECONDS)

    // O master original usava REPLACE INTO com chave (IP, Port): reanunciar
    // sobrescreve em vez de duplicar. Mantemos a mesma semântica.
    await gameServers()
      .createQueryBuilder()
      .insert()
      .values({
        name,
        ip,
        port,
        playerCount: int(request, 'playercount'),
        dedicated: int(request, 'dedicated') !== 0,
        os: str(request, 'os').slice(0, 16),
        netRevision: netRevision.slice(0, 16),
        gameRevision: str(request, 'coderev').slice(0, 32),
        expiresAt: new Date(Date.now() + ttl * 1000),
      })
      .orUpdate(
        ['name', 'playerCount', 'dedicated', 'os', 'netRevision', 'gameRevision', 'expiresAt', 'updatedAt'],
        ['ip', 'port'],
      )
      .execute()

    return reply.send('success')
  })

  /**
   * Lista de servidores. Formato exigido pelo parser do cliente:
   *   Name,IP,Port,Dedicated,OS\n
   * Linhas que não tiverem 5 campos são ignoradas pelo jogo.
   */
  app.get('/serverquery.php', async (request, reply) => {
    reply.type('text/plain')

    const netRevision = str(request, 'rev')
    if (!netRevision) return reply.code(400).send('Invalid revision')

    // Só servidores do mesmo protocolo: builds diferentes não conseguem jogar juntas.
    const servers = await gameServers().find({
      where: { netRevision, expiresAt: MoreThan(new Date()) },
      order: { playerCount: 'DESC', name: 'ASC' },
    })

    const body = servers
      .map((s) => `${s.name},${s.ip},${s.port},${s.dedicated ? 1 : 0},${s.os}`)
      .join('\n')

    // Lista vazia responde corpo vazio — o cliente lida com isso normalmente.
    return reply.send(body ? `${body}\n` : '')
  })

  /** Mensagem exibida na aba multiplayer. O cliente interpreta como UTF-8. */
  app.get('/announcements.php', async (_request, reply) => {
    reply.type('text/plain; charset=utf-8')
    return reply.send(config.MOTD)
  })

  /**
   * O cliente avisa qual mapa foi jogado. Ainda não guardamos — vira estatística
   * quando desenharmos essa parte. Respondemos ok para o cliente não logar erro.
   */
  app.get('/maps.php', async (request, reply) => {
    reply.type('text/plain')
    request.log.info(
      { map: str(request, 'map'), crc: str(request, 'mapcrc'), players: int(request, 'playercount') },
      'partida reportada',
    )
    return reply.send('success')
  })

  /** Limpeza dos anúncios vencidos. Não é crítico: a listagem já filtra por expiresAt. */
  app.post('/internal/prune-servers', async () => {
    const result = await gameServers().delete({ expiresAt: LessThanOrEqual(new Date()) })
    return { removed: result.affected ?? 0 }
  })
}
