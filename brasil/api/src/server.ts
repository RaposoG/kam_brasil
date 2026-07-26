import Fastify from 'fastify'
import cors from '@fastify/cors'
import { dataSource } from './data-source.ts'

const isDev = process.env.NODE_ENV === 'development'

const app = Fastify({
  logger: isDev
    ? { transport: { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss', ignore: 'pid,hostname' } } }
    : true,
})

await app.register(cors, { origin: true })

app.get('/health', async () => {
  // Confirma que a API está de pé E que ela enxerga o banco — é o teste de fumaça
  // que a gente roda depois de qualquer mudança de infra.
  let database = 'disconnected'
  try {
    await dataSource.query('select 1')
    database = 'connected'
  } catch (error) {
    app.log.error({ error }, 'health check: banco inacessível')
  }

  return { status: 'ok', database }
})

const port = Number(process.env.API_PORT ?? 3000)
const host = process.env.API_HOST ?? '0.0.0.0'

try {
  await dataSource.initialize()
  app.log.info('TypeORM conectado')
} catch (error) {
  app.log.error({ error }, 'falha ao conectar no Postgres — a API sobe assim mesmo, /health vai acusar')
}

await app.listen({ port, host })
