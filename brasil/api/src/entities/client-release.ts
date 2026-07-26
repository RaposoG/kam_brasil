import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm'

/**
 * Uma versão publicada do cliente do jogo.
 *
 * A API guarda o *registro* da release, não o binário: `fileName` aponta para um
 * arquivo servido em `/downloads/`. Assim dá para trocar a hospedagem depois
 * (S3, CDN, release do GitHub) mexendo só em como a URL é montada.
 *
 * Releases são imutáveis: para corrigir algo, publique uma versão nova. É o que
 * garante que o sha256 que um cliente baixou hoje continue valendo amanhã.
 */
@Entity('client_releases')
export class ClientRelease {
  @PrimaryGeneratedColumn('uuid')
  id!: string

  /** Versão do Kam Brasil, ex. "1.0.0". Única. */
  @Column({ type: 'varchar', length: 32 })
  version!: string

  /** GAME_REVISION do KaM Remake que originou este build, ex. "r16155". */
  @Column({ type: 'varchar', length: 32 })
  gameRevision!: string

  /** Nome do arquivo dentro da pasta de releases. */
  @Column({ type: 'varchar', length: 128 })
  fileName!: string

  /** Hex minúsculo. O launcher recusa o download se não bater. */
  @Column({ type: 'varchar', length: 64 })
  sha256!: string

  @Column({ type: 'bigint' })
  sizeBytes!: string

  @Column({ type: 'text', default: '' })
  notes!: string

  /**
   * Releases mais novas que a última que os jogadores devem usar podem ficar
   * despublicadas enquanto são testadas.
   */
  @Index()
  @Column({ type: 'boolean', default: true })
  published!: boolean

  @CreateDateColumn({ type: 'timestamptz' })
  createdAt!: Date
}
