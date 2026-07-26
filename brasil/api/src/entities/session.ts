import { Column, CreateDateColumn, Entity, Index, JoinColumn, ManyToOne, PrimaryGeneratedColumn } from 'typeorm'
import { Account } from './account.ts'

/**
 * Uma sessão por login. O id vai no JWT como `jti`, o que nos permite revogar
 * um token individualmente — sem isso, um token vazado valeria até expirar.
 */
@Entity('sessions')
export class Session {
  @PrimaryGeneratedColumn('uuid')
  id!: string

  @Index()
  @Column({ type: 'uuid' })
  accountId!: string

  // Unidirecional de propósito: a relação inversa em Account criaria import
  // circular, e com emitDecoratorMetadata o tipo é avaliado na carga do módulo.
  @ManyToOne(() => Account, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'accountId' })
  account!: Account

  @Column({ type: 'timestamptz' })
  expiresAt!: Date

  @Column({ type: 'timestamptz', nullable: true })
  revokedAt!: Date | null

  /** Para o usuário conseguir auditar de onde entraram na conta dele. */
  @Column({ type: 'varchar', length: 45, nullable: true })
  ip!: string | null

  @Column({ type: 'text', nullable: true })
  userAgent!: string | null

  @CreateDateColumn({ type: 'timestamptz' })
  createdAt!: Date
}
