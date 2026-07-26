import 'reflect-metadata'
import { DataSource } from 'typeorm'

const databaseUrl = process.env.DATABASE_URL

if (!databaseUrl) {
  throw new Error('DATABASE_URL não definida. Copie brasil/.env.example para brasil/.env')
}

export const dataSource = new DataSource({
  type: 'postgres',
  url: databaseUrl,
  // Entidades entram aqui conforme forem criadas (Account, Session, Server...)
  entities: [],
  // Nunca true: o schema é versionado por migration, inclusive em desenvolvimento.
  synchronize: false,
  migrations: ['src/migrations/*.ts'],
  logging: process.env.NODE_ENV === 'development' ? ['error', 'warn'] : ['error'],
})
