import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import Fastify from 'fastify'
import cors from '@fastify/cors'
import fastifyStatic from '@fastify/static'
import { config } from './config.ts'
import { dataSource } from './data-source.ts'
import authPlugin from './plugins/auth.ts'
import authRoutes from './routes/auth.ts'
import masterRoutes from './routes/master.ts'
import clientRoutes from './routes/client.ts'
import verifyRoutes from './routes/verify.ts'

const app = Fastify({
  trustProxy: config.TRUST_PROXY,
  logger: config.isDev
    ? { transport: { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss', ignore: 'pid,hostname' } } }
    : true,
})

// Sem isto, um POST sem corpo (ex.: /auth/logout) responde 415 por não ter
// Content-Type. O parser de JSON continua tendo precedência sobre este curinga.
app.addContentTypeParser('*', { parseAs: 'buffer' }, (_request, body, done) => {
  if (body.length === 0) return done(null, {})
  done(new Error('Content-Type não suportado — use application/json'))
})

await app.register(cors, { origin: true })

// Binários das releases. Em produção o ideal é deixar o nginx servir isso
// direto — mas ter a API servindo mantém o ambiente local autossuficiente.
const releasesDir = resolve(config.RELEASES_DIR)
await mkdir(releasesDir, { recursive: true })
await app.register(fastifyStatic, { root: releasesDir, prefix: '/downloads/' })

await app.register(authPlugin)
await app.register(authRoutes)
await app.register(masterRoutes)
await app.register(clientRoutes)
await app.register(verifyRoutes)

app.get('/health', async () => {
  // Confirma que a API está de pé E que ela enxerga o banco — teste de fumaça
  // depois de qualquer mudança de infra.
  let database = 'disconnected'
  try {
    await dataSource.query('select 1')
    database = 'connected'
  } catch (error) {
    app.log.error({ error }, 'health check: banco inacessível')
  }

  return { status: 'ok', database }
})

await dataSource.initialize()
app.log.info('TypeORM conectado')

// Migrations rodam no boot: um deploy nunca sobe com schema defasado.
const executed = await dataSource.runMigrations()
if (executed.length > 0) {
  app.log.info({ migrations: executed.map((m) => m.name) }, 'migrations aplicadas')
}

if (config.announceAllowedIps.length === 0) {
  app.log.warn('ANNOUNCE_ALLOWED_IPS vazio: qualquer origem pode anunciar servidor. Não use assim em produção.')
}

await app.listen({ port: config.API_PORT, host: config.API_HOST })
