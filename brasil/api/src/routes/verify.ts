import { randomBytes } from 'node:crypto'
import type { FastifyInstance } from 'fastify'
import { LessThan, MoreThan } from 'typeorm'
import { config } from '../config.ts'
import { playTickets } from '../data-source.ts'

/**
 * Tickets de partida e a verificação feita pelo servidor de jogo.
 *
 * O jogo nunca carrega o token de sessão. O launcher troca a sessão por um
 * ticket curto (ver entities/play-ticket.ts) e entrega só o ticket. Assim a
 * credencial que passa por arquivo temporário vale minutos e não abre nada
 * além de entrar no servidor.
 */
export default async function verifyRoutes(app: FastifyInstance) {
  /**
   * Troca a sessão por um ticket de partida. Chamado pelo launcher logo antes
   * de abrir o jogo.
   */
  app.post('/auth/ticket', { onRequest: [app.authenticate] }, async (request) => {
    const expiresAt = new Date(Date.now() + config.PLAY_TICKET_TTL_MINUTES * 60 * 1000)

    const ticket = await playTickets().save(
      playTickets().create({
        ticket: randomBytes(32).toString('hex'),
        sessionId: request.user.jti,
        expiresAt,
        lastUsedAt: null,
      }),
    )

    // Limpeza oportunista: tickets vencidos não servem para nada e a tabela
    // cresceria para sempre sem isto.
    await playTickets().delete({ expiresAt: LessThan(new Date()) })

    return { ticket: ticket.ticket, expiresAt }
  })

  /**
   * Verificação de ticket para o servidor de jogo.
   *
   * Quem chama aqui é o `KaM_DedicatedServer`, um binário Pascal cujo cliente
   * HTTP (`KM_HTTPClient`) só faz **GET, sem TLS e sem headers customizados**.
   * Por isso é GET com o ticket na query, e a resposta é texto puro de uma
   * linha — o Pascal não tem parser de JSON.
   *
   * Duas consequências que o deploy precisa respeitar:
   *
   * 1. O servidor de jogo tem que rodar **na mesma máquina que a API** e chamar
   *    via `localhost`. O ticket trafega em claro; fora do loopback seria
   *    inaceitável.
   * 2. A rota **não loga a query string** — credencial em log é credencial
   *    vazada.
   */
  app.get(
    '/auth/verify',
    { logLevel: 'silent', config: { disableRequestLogging: true } },
    async (request, reply) => {
      reply.type('text/plain')

      const remoteIp = request.ip.replace(/^::ffff:/, '').replace(/^::1$/, '127.0.0.1')
      if (!config.verifyAllowedIps.includes(remoteIp)) {
        request.log.warn({ remoteIp }, 'verificação recusada: origem fora do allowlist')
        return reply.code(403).send('forbidden')
      }

      const token = (request.query as Record<string, unknown>)['token']
      if (typeof token !== 'string' || token.length === 0) {
        return reply.code(400).send('missing token')
      }

      const found = await playTickets().findOne({
        where: { ticket: token, expiresAt: MoreThan(new Date()) },
        relations: { session: { account: true } },
      })

      // Ticket válido não basta: a sessão que o gerou precisa continuar viva.
      // É isto que faz o logout expulsar de dentro do jogo.
      if (
        !found ||
        found.session.revokedAt !== null ||
        found.session.expiresAt <= new Date()
      ) {
        return reply.code(401).send('invalid')
      }

      // Registrado para auditoria; não invalida, porque reconectar depois de uma
      // queda reenvia o mesmo ticket.
      await playTickets().update({ ticket: token }, { lastUsedAt: new Date() })

      return reply.send(`ok ${found.session.account.nickname}`)
    },
  )
}
