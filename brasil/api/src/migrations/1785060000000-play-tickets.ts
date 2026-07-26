import type { MigrationInterface, QueryRunner } from 'typeorm'

export class PlayTickets1785060000000 implements MigrationInterface {
  name = 'PlayTickets1785060000000'

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      create table "play_tickets" (
        "ticket"     varchar(64) primary key,
        "sessionId"  uuid        not null references "sessions"("id") on delete cascade,
        "expiresAt"  timestamptz not null,
        "lastUsedAt" timestamptz,
        "createdAt"  timestamptz not null default now()
      )
    `)
    await queryRunner.query(`create index "idx_play_tickets_sessionId" on "play_tickets" ("sessionId")`)
    await queryRunner.query(`create index "idx_play_tickets_expiresAt" on "play_tickets" ("expiresAt")`)
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`drop table "play_tickets"`)
  }
}
