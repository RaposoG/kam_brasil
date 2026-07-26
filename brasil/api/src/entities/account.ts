import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm'

@Entity('accounts')
export class Account {
  @PrimaryGeneratedColumn('uuid')
  id!: string

  /** Sempre gravado em minúsculas. A unicidade real é garantida por índice em lower(email). */
  @Column({ type: 'varchar', length: 254 })
  email!: string

  /** Exibido no jogo. Unicidade case-insensitive via índice em lower(nickname). */
  @Column({ type: 'varchar', length: 16 })
  nickname!: string

  /** argon2id. Nunca sai da API — veja Account.toPublic(). */
  @Column({ type: 'text' })
  passwordHash!: string

  @Column({ type: 'timestamptz', nullable: true })
  lastLoginAt!: Date | null

  @CreateDateColumn({ type: 'timestamptz' })
  createdAt!: Date

  @UpdateDateColumn({ type: 'timestamptz' })
  updatedAt!: Date
}

/** Formato seguro para devolver ao cliente. */
export function toPublicAccount(account: Account) {
  return {
    id: account.id,
    email: account.email,
    nickname: account.nickname,
    createdAt: account.createdAt,
  }
}
