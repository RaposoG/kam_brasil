import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm'

/**
 * Uma versão publicada do cliente.
 *
 * Uma release **não** é um arquivo: é uma árvore. O executável, os mapas, as
 * campanhas e os textos somam centenas de MB, e um pacote único obrigaria o
 * jogador a rebaixar tudo a cada correção de bug.
 *
 * Por isso o banco guarda só os metadados e aponta para um **manifesto** em
 * disco, que lista cada arquivo com tamanho e sha256. O launcher compara o
 * manifesto com o que tem localmente e baixa apenas a diferença — instalação
 * nova e atualização passam pelo mesmo caminho de código.
 *
 * Layout em disco, dentro de RELEASES_DIR:
 *
 *   <version>/manifest.json
 *   <version>/files/...        (a árvore em si)
 *
 * O que NÃO entra aqui: sprites, sons, músicas e os `.dat` de unidades e casas.
 * Esses vêm do Knights and Merchants original e são gerados na máquina do
 * jogador, a partir da cópia dele. Nada do jogo comercial sai do nosso servidor.
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

  @Column({ type: 'int' })
  fileCount!: number

  @Column({ type: 'bigint' })
  totalBytes!: string

  /** Integridade do próprio manifesto. */
  @Column({ type: 'varchar', length: 64 })
  manifestSha256!: string

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
