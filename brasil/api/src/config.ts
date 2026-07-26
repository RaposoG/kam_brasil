import { z } from 'zod'

const schema = z.object({
  DATABASE_URL: z.string().min(1, 'DATABASE_URL não definida — copie brasil/.env.example para brasil/.env'),

  // 32 chars é o piso para um segredo HS256 não ser o elo fraco.
  JWT_SECRET: z.string().min(32, 'JWT_SECRET precisa de pelo menos 32 caracteres (openssl rand -hex 32)'),

  API_PORT: z.coerce.number().int().positive().default(3000),
  API_HOST: z.string().default('0.0.0.0'),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),

  SESSION_TTL_DAYS: z.coerce.number().int().positive().default(30),

  /**
   * IPs autorizados a anunciar servidor, separados por vírgula.
   *
   * O jogo não manda credencial nenhuma no serveradd.php — os parâmetros são fixos
   * no Pascal (KM_NetServerLocator.AnnounceServer). Então a única forma de garantir
   * "só o nosso servidor aparece" sem mexer no cliente é filtrar pela origem.
   *
   * Vazio = aceita qualquer origem. Use assim só em desenvolvimento.
   */
  ANNOUNCE_ALLOWED_IPS: z.string().default(''),

  /** Mensagem exibida na aba multiplayer (announcements.php). */
  MOTD: z.string().default('Bem-vindo ao Kam Brasil!'),

  /**
   * Ligue em produção quando a API estiver atrás de nginx/Cloudflare.
   * Sem isso, request.ip devolve o IP do proxy — e o ANNOUNCE_ALLOWED_IPS
   * passaria a comparar sempre contra o mesmo endereço, virando inútil.
   */
  TRUST_PROXY: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
})

const parsed = schema.safeParse(process.env)

if (!parsed.success) {
  const issues = parsed.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`).join('\n')
  throw new Error(`Configuração inválida:\n${issues}`)
}

export const config = {
  ...parsed.data,
  isDev: parsed.data.NODE_ENV === 'development',
  announceAllowedIps: parsed.data.ANNOUNCE_ALLOWED_IPS.split(',')
    .map((ip) => ip.trim())
    .filter(Boolean),
}
