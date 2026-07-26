import type { MigrationInterface, QueryRunner } from 'typeorm'

export class ClientReleases1785040800000 implements MigrationInterface {
  name = 'ClientReleases1785040800000'

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      create table "client_releases" (
        "id"           uuid primary key default gen_random_uuid(),
        "version"      varchar(32)  not null,
        "gameRevision" varchar(32)  not null,
        "fileName"     varchar(128) not null,
        "sha256"       varchar(64)  not null,
        "sizeBytes"    bigint       not null,
        "notes"        text         not null default '',
        "published"    boolean      not null default true,
        "createdAt"    timestamptz  not null default now()
      )
    `)

    // Versão é a identidade da release: republicar a mesma versão com binário
    // diferente invalidaria o sha256 que os clientes já baixaram.
    await queryRunner.query(`create unique index "uq_client_releases_version" on "client_releases" ("version")`)
    await queryRunner.query(`create index "idx_client_releases_published" on "client_releases" ("published")`)
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`drop table "client_releases"`)
  }
}
