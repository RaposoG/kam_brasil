import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, Unique, UpdateDateColumn } from 'typeorm'

/**
 * Um servidor de jogo anunciado via `serveradd.php`.
 *
 * O master server original usava `REPLACE INTO Servers (IP, Port, ...)`, ou seja,
 * a identidade de um servidor é o par (ip, port) — reanunciar sobrescreve. Mantemos
 * a mesma semântica com upsert sobre a constraint única abaixo.
 *
 * Registros expirados não são apagados no anúncio: são filtrados na listagem por
 * `expiresAt`. Um job de limpeza pode remover depois, sem pressa.
 */
@Entity('game_servers')
@Unique('uq_game_servers_ip_port', ['ip', 'port'])
export class GameServer {
  @PrimaryGeneratedColumn('uuid')
  id!: string

  @Column({ type: 'varchar', length: 60 })
  name!: string

  @Column({ type: 'varchar', length: 45 })
  ip!: string

  @Column({ type: 'int' })
  port!: number

  @Column({ type: 'int', default: 0 })
  playerCount!: number

  @Column({ type: 'boolean', default: false })
  dedicated!: boolean

  @Column({ type: 'varchar', length: 16, default: '' })
  os!: string

  /** NET_PROTOCOL_REVISON do cliente. A listagem filtra por ele — protocolos diferentes não se enxergam. */
  @Index()
  @Column({ type: 'varchar', length: 16 })
  netRevision!: string

  /** GAME_REVISION (`coderev`), só informativo. */
  @Column({ type: 'varchar', length: 32, default: '' })
  gameRevision!: string

  @Index()
  @Column({ type: 'timestamptz' })
  expiresAt!: Date

  @CreateDateColumn({ type: 'timestamptz' })
  createdAt!: Date

  @UpdateDateColumn({ type: 'timestamptz' })
  updatedAt!: Date
}
