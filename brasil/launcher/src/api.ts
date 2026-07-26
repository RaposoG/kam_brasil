import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'

/**
 * Ponte com o Rust. Repare que não existe função para "pegar o token": ele
 * nunca chega até aqui de propósito. Todo request autenticado é feito do lado
 * Rust, que é quem guarda a sessão. Ver src-tauri/src/auth.rs.
 */

export interface Account {
  id: string
  email: string
  nickname: string
}

export interface LatestRelease {
  version: string
  gameRevision: string
  downloadUrl: string
  sha256: string
  sizeBytes: number
  notes: string
}

export interface GameStatus {
  path: string
  installed: boolean
  version: string | null
}

export interface UpdateCheck {
  status: GameStatus
  latest: LatestRelease | null
  needsUpdate: boolean
}

export interface DownloadProgress {
  received: number
  total: number
}

// --- contas ---

export function register(email: string, nickname: string, password: string): Promise<Account> {
  return invoke('register', { email, nickname, password })
}

export function login(login: string, password: string): Promise<Account> {
  return invoke('login', { login, password })
}

export function logout(): Promise<void> {
  return invoke('logout')
}

/** Reaproveita a sessão guardada no cofre do sistema. `null` = precisa logar. */
export function restoreSession(): Promise<Account | null> {
  return invoke('restore_session')
}

export function apiBase(): Promise<string> {
  return invoke('api_base')
}

// --- jogo ---

export function gameStatus(): Promise<GameStatus> {
  return invoke('game_status')
}

export function checkUpdate(): Promise<UpdateCheck> {
  return invoke('check_update')
}

export function installUpdate(release: LatestRelease): Promise<GameStatus> {
  return invoke('install_update', { release })
}

export function launchGame(): Promise<void> {
  return invoke('launch_game')
}

/** Assina o progresso do download. Devolve a função para cancelar a assinatura. */
export function onDownloadProgress(handler: (p: DownloadProgress) => void) {
  return listen<DownloadProgress>('download-progress', (event) => handler(event.payload))
}
