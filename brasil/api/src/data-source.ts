import 'reflect-metadata'
import { DataSource } from 'typeorm'
import { config } from './config.ts'
import { Account } from './entities/account.ts'
import { Session } from './entities/session.ts'
import { GameServer } from './entities/game-server.ts'
import { Init1785018600000 } from './migrations/1785018600000-init.ts'

export const dataSource = new DataSource({
  type: 'postgres',
  url: config.DATABASE_URL,
  entities: [Account, Session, GameServer],
  // Nunca true: o schema é versionado por migration, inclusive em desenvolvimento.
  synchronize: false,
  migrations: [Init1785018600000],
  logging: config.isDev ? ['error', 'warn'] : ['error'],
})

export const accounts = () => dataSource.getRepository(Account)
export const sessions = () => dataSource.getRepository(Session)
export const gameServers = () => dataSource.getRepository(GameServer)
