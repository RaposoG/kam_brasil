import { Column, CreateDateColumn, Entity, Index, JoinColumn, ManyToOne, PrimaryColumn } from 'typeorm'
import { Session } from './session.ts'

/**
 * Credencial de curta duração que o launcher entrega ao jogo.
 *
 * Antes o jogo carregava o próprio token de sessão (30 dias). Isso significava
 * uma credencial longa passando por um arquivo temporário — se vazasse, valeria
 * um mês e daria acesso à conta inteira.
 *
 * O ticket resolve os dois problemas:
 *
 * - **Validade curta.** Cobre uma sessão de jogo, não um mês.
 * - **Escopo restrito.** Só serve em `GET /auth/verify`, consumido pelo servidor
 *   de jogo. Não abre `/auth/me`, não troca senha, não faz nada na conta.
 *
 * Fica preso à sessão que o originou, e não à conta: assim, sair da conta
 * invalida os tickets junto — que é a propriedade que garante que logout
 * expulsa do jogo.
 *
 * Reutilizável dentro da validade, de propósito: o cliente reenvia a credencial
 * ao reconectar depois de uma queda, e um ticket de uso único deixaria o jogador
 * fora da própria partida.
 */
@Entity('play_tickets')
export class PlayTicket {
  /** Aleatório opaco. Não é JWT: nada aqui precisa ser lido pelo portador. */
  @PrimaryColumn({ type: 'varchar', length: 64 })
  ticket!: string

  @Index()
  @Column({ type: 'uuid' })
  sessionId!: string

  @ManyToOne(() => Session, { onDelete: 'CASCADE' })
  @JoinColumn({ name: 'sessionId' })
  session!: Session

  @Index()
  @Column({ type: 'timestamptz' })
  expiresAt!: Date

  @Column({ type: 'timestamptz', nullable: true })
  lastUsedAt!: Date | null

  @CreateDateColumn({ type: 'timestamptz' })
  createdAt!: Date
}
