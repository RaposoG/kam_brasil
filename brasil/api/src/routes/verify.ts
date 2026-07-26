import type { FastifyInstance } from 'fastify'
import { IsNull, MoreThan } from 'typeorm'
import { config } from '../config.ts'
import { sessions } from '../data-source.ts'

/**
 * Verificação de token para o servidor de jogo.
 *
 * Quem chama aqui é o `KaM_DedicatedServer`, um binário Pascal cujo cliente HTTP
 * (`KM_HTTPClient`) só faz **GET, sem TLS e sem headers customizados**. Por isso
 * esta rota é GET com o token na query, e não um POST com Authorization como
 * seria natural.
 *
 * Duas consequências que precisam ser respeitadas no deploy:
 *
 * 1. O servidor de jogo tem que rodar **na mesma máquina que a API** e chamar
 *    via `localhost`. O token trafega em claro; fora do loopback isso seria
 *    inaceitável.
 * 2. A rota **não loga a query string** — token em log é token vazado. O
 *    `disableRequestLogging` abaixo cuida disso.
 *
 * Quando o cliente Pascal ganhar POST+TLS, esta rota vira um POST comum.
 */
export default async function verifyRoutes(app: FastifyInstance) {
  app.get(
    '/auth/verify',
    {
      // Sem isto, o Fastify logaria a URL completa — com o token dentro.
      logLevel: 'silent',
      config: { disableRequestLogging: true },
    },
    async (request, reply) => {
      reply.type('text/plain')

      const remoteIp = request.ip.replace(/^::ffff:/, '').replace(/^::1$/, '127.0.0.1')
      if (!config.verifyAllowedIps.includes(remoteIp)) {
        request.log.warn({ remoteIp }, 'verificação de token recusada: origem fora do allowlist')
        return reply.code(403).send('forbidden')
      }

      const token = (request.query as Record<string, unknown>)['token']
      if (typeof token !== 'string' || token.length === 0) {
        return reply.code(400).send('missing token')
      }

      let payload: { jti?: unknown }
      try {
        payload = app.jwt.verify(token)
      } catch {
        return reply.code(401).send('invalid')
      }

      if (typeof payload.jti !== 'string') {
        return reply.code(401).send('invalid')
      }

      // Assinatura válida não basta: logout e expiração vivem na tabela.
      const session = await sessions().findOne({
        where: { id: payload.jti, revokedAt: IsNull(), expiresAt: MoreThan(new Date()) },
        relations: { account: true },
      })

      if (!session) {
        return reply.code(401).send('invalid')
      }

      // Resposta em texto puro e de uma linha só: o Pascal lê a resposta inteira
      // como string, sem parser de JSON. Formato: "ok <nickname>".
      return reply.send(`ok ${session.account.nickname}`)
    },
  )
}
