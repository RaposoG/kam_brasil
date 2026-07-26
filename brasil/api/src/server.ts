import Fastify from 'fastify'
import cors from '@fastify/cors'
import { config } from './config.ts'
import { dataSource } from './data-source.ts'
import authPlugin from './plugins/auth.ts'
import authRoutes from './routes/auth.ts'
import masterRoutes from './routes/master.ts'

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
await app.register(authPlugin)
await app.register(authRoutes)
await app.register(masterRoutes)

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
