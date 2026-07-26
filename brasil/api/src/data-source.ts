import 'reflect-metadata'
import { DataSource } from 'typeorm'
import { config } from './config.ts'
import { Account } from './entities/account.ts'
import { Session } from './entities/session.ts'
import { GameServer } from './entities/game-server.ts'
import { ClientRelease } from './entities/client-release.ts'
import { Init1785018600000 } from './migrations/1785018600000-init.ts'
import { ClientReleases1785040800000 } from './migrations/1785040800000-client-releases.ts'

export const dataSource = new DataSource({
  type: 'postgres',
  url: config.DATABASE_URL,
  entities: [Account, Session, GameServer, ClientRelease],
  // Nunca true: o schema é versionado por migration, inclusive em desenvolvimento.
  synchronize: false,
  migrations: [Init1785018600000, ClientReleases1785040800000],
  logging: config.isDev ? ['error', 'warn'] : ['error'],
})

export const accounts = () => dataSource.getRepository(Account)
export const sessions = () => dataSource.getRepository(Session)
export const gameServers = () => dataSource.getRepository(GameServer)
export const clientReleases = () => dataSource.getRepository(ClientRelease)
