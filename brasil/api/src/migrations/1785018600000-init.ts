import type { MigrationInterface, QueryRunner } from 'typeorm'

export class Init1785018600000 implements MigrationInterface {
  name = 'Init1785018600000'

  public async up(queryRunner: QueryRunner): Promise<void> {
    // gen_random_uuid() e nativa desde o PG13, nao precisa de extensao.
    await queryRunner.query(`
      create table "accounts" (
        "id"           uuid primary key default gen_random_uuid(),
        "email"        varchar(254) not null,
        "nickname"     varchar(16)  not null,
        "passwordHash" text         not null,
        "lastLoginAt"  timestamptz,
        "createdAt"    timestamptz  not null default now(),
        "updatedAt"    timestamptz  not null default now()
      )
    `)

    // Unicidade case-insensitive: "Gabriel" e "gabriel" sao a mesma conta.
    // Indice em expressao em vez de constraint simples, senao daria para
    // registrar o mesmo nick variando maiusculas.
    await queryRunner.query(`create unique index "uq_accounts_email_lower" on "accounts" (lower("email"))`)
    await queryRunner.query(`create unique index "uq_accounts_nickname_lower" on "accounts" (lower("nickname"))`)

    await queryRunner.query(`
      create table "sessions" (
        "id"         uuid primary key default gen_random_uuid(),
        "accountId"  uuid not null references "accounts"("id") on delete cascade,
        "expiresAt"  timestamptz not null,
        "revokedAt"  timestamptz,
        "ip"         varchar(45),
        "userAgent"  text,
        "createdAt"  timestamptz not null default now()
      )
    `)
    await queryRunner.query(`create index "idx_sessions_accountId" on "sessions" ("accountId")`)

    await queryRunner.query(`
      create table "game_servers" (
        "id"            uuid primary key default gen_random_uuid(),
        "name"          varchar(60) not null,
        "ip"            varchar(45) not null,
        "port"          int         not null,
        "playerCount"   int         not null default 0,
        "dedicated"     boolean     not null default false,
        "os"            varchar(16) not null default '',
        "netRevision"   varchar(16) not null,
        "gameRevision"  varchar(32) not null default '',
        "expiresAt"     timestamptz not null,
        "createdAt"     timestamptz not null default now(),
        "updatedAt"     timestamptz not null default now(),
        constraint "uq_game_servers_ip_port" unique ("ip", "port")
      )
    `)
    await queryRunner.query(`create index "idx_game_servers_netRevision" on "game_servers" ("netRevision")`)
    await queryRunner.query(`create index "idx_game_servers_expiresAt" on "game_servers" ("expiresAt")`)
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`drop table "game_servers"`)
    await queryRunner.query(`drop table "sessions"`)
    await queryRunner.query(`drop table "accounts"`)
  }
}
