import type { FastifyInstance } from 'fastify'
import { hash, verify } from '@node-rs/argon2'
import { z } from 'zod'
import { config } from '../config.ts'
import { accounts, sessions } from '../data-source.ts'
import { toPublicAccount } from '../entities/account.ts'

/**
 * Charset restrito de propósito. O KaM usa `|` como quebra de linha e
 * `[$RRGGBB]` como código de cor no texto da interface — um nickname com
 * esses caracteres bagunçaria o lobby de quem estivesse jogando.
 */
const nicknameSchema = z
  .string()
  .regex(/^[A-Za-z0-9_-]{3,16}$/, 'nickname: 3 a 16 caracteres, apenas letras, números, _ e -')

const registerSchema = z.object({
  email: z.email('email inválido').max(254),
  nickname: nicknameSchema,
  password: z.string().min(8, 'a senha precisa de pelo menos 8 caracteres').max(200),
})

const loginSchema = z.object({
  /** Aceita email ou nickname — o jogador não precisa lembrar qual usou. */
  login: z.string().min(1),
  password: z.string().min(1).max(200),
})

const UNIQUE_VIOLATION = '23505'

export default async function authRoutes(app: FastifyInstance) {
  app.post('/auth/register', async (request, reply) => {
    const parsed = registerSchema.safeParse(request.body)
    if (!parsed.success) {
      return reply.code(400).send({ error: 'dados inválidos', issues: z.treeifyError(parsed.error) })
    }

    const { nickname, password } = parsed.data
    const email = parsed.data.email.toLowerCase()

    const passwordHash = await hash(password)
    const account = accounts().create({ email, nickname, passwordHash, lastLoginAt: null })

    try {
      await accounts().save(account)
    } catch (error) {
      // Checar antes de inserir teria uma janela de corrida entre o SELECT e o
      // INSERT. Deixamos o índice único decidir e traduzimos o erro aqui.
      if ((error as { code?: string }).code === UNIQUE_VIOLATION) {
        const detail = String((error as { detail?: string }).detail ?? '')
        const field = detail.includes('nickname') ? 'nickname' : 'email'
        return reply.code(409).send({ error: `${field} já está em uso` })
      }
      throw error
    }

    return reply.code(201).send({ account: toPublicAccount(account) })
  })

  app.post('/auth/login', async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body)
    if (!parsed.success) {
      return reply.code(400).send({ error: 'dados inválidos' })
    }

    const { login, password } = parsed.data

    const account = await accounts()
      .createQueryBuilder('a')
      .where('lower(a.email) = lower(:login) or lower(a.nickname) = lower(:login)', { login })
      .getOne()

    // Mesma mensagem para conta inexistente e senha errada: não entregamos de
    // graça quais emails/nicknames existem.
    const invalid = { error: 'credenciais inválidas' }

    if (!account) return reply.code(401).send(invalid)
    if (!(await verify(account.passwordHash, password))) return reply.code(401).send(invalid)

    const expiresAt = new Date(Date.now() + config.SESSION_TTL_DAYS * 24 * 60 * 60 * 1000)
    const session = await sessions().save(
      sessions().create({
        accountId: account.id,
        expiresAt,
        revokedAt: null,
        ip: request.ip,
        userAgent: request.headers['user-agent'] ?? null,
      }),
    )

    account.lastLoginAt = new Date()
    await accounts().save(account)

    const token = app.jwt.sign({ sub: account.id, jti: session.id }, { expiresIn: `${config.SESSION_TTL_DAYS}d` })

    return { token, expiresAt, account: toPublicAccount(account) }
  })

  app.get('/auth/me', { onRequest: [app.authenticate] }, async (request) => {
    return { account: toPublicAccount(request.account) }
  })

  app.post('/auth/logout', { onRequest: [app.authenticate] }, async (request) => {
    await sessions().update({ id: request.user.jti }, { revokedAt: new Date() })
    return { ok: true }
  })
}
