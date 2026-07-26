import fastifyJwt from '@fastify/jwt'
import fp from 'fastify-plugin'
import type { FastifyReply, FastifyRequest } from 'fastify'
import { IsNull, MoreThan } from 'typeorm'
import { config } from '../config.ts'
import { sessions } from '../data-source.ts'
import type { Account } from '../entities/account.ts'

declare module 'fastify' {
  interface FastifyInstance {
    /** Preflight handler: rejeita a requisição se não houver sessão válida. */
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>
  }
  interface FastifyRequest {
    account: Account
  }
}

declare module '@fastify/jwt' {
  interface FastifyJWT {
    payload: { sub: string; jti: string }
    user: { sub: string; jti: string }
  }
}

export default fp(async (app) => {
  await app.register(fastifyJwt, { secret: config.JWT_SECRET })

  // Declara o campo sem valor: quem preenche é o hook authenticate abaixo.
  // O Fastify 5 não aceita mais `null` aqui.
  app.decorateRequest('account')

  app.decorate('authenticate', async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      await request.jwtVerify()
    } catch {
      return reply.code(401).send({ error: 'token ausente ou inválido' })
    }

    // A assinatura do JWT prova que nós o emitimos, mas não que ele ainda vale:
    // logout e expiração vivem na tabela de sessões. Por isso conferimos sempre.
    const session = await sessions().findOne({
      where: {
        id: request.user.jti,
        revokedAt: IsNull(),
        expiresAt: MoreThan(new Date()),
      },
      relations: { account: true },
    })

    if (!session) {
      return reply.code(401).send({ error: 'sessão expirada ou revogada' })
    }

    request.account = session.account
  })
})
