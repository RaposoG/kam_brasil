import type { MigrationInterface, QueryRunner } from 'typeorm'

/**
 * Release deixa de ser um arquivo e passa a ser uma árvore descrita por
 * manifesto. As colunas antigas (fileName, sha256, sizeBytes) não têm
 * equivalente, então a tabela é recriada em vez de alterada.
 *
 * Descartar as linhas existentes é aceitável aqui: nenhuma release chegou a
 * jogador nenhum ainda.
 */
export class ReleaseManifest1785070000000 implements MigrationInterface {
  name = 'ReleaseManifest1785070000000'

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`drop table if exists "client_releases"`)
    await queryRunner.query(`
      create table "client_releases" (
        "id"             uuid primary key default gen_random_uuid(),
        "version"        varchar(32) not null,
        "gameRevision"   varchar(32) not null,
        "fileCount"      int         not null,
        "totalBytes"     bigint      not null,
        "manifestSha256" varchar(64) not null,
        "notes"          text        not null default '',
        "published"      boolean     not null default true,
        "createdAt"      timestamptz not null default now()
      )
    `)
    await queryRunner.query(`create unique index "uq_client_releases_version" on "client_releases" ("version")`)
    await queryRunner.query(`create index "idx_client_releases_published" on "client_releases" ("published")`)
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`drop table "client_releases"`)
  }
}
