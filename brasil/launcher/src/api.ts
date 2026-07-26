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
  manifestUrl: string
  baseUrl: string
  totalBytes: number
  fileCount: number
  notes: string
}

export interface UpdateCheck {
  path: string
  installedVersion: string | null
  latest: LatestRelease | null
  needsUpdate: boolean
}

export interface GameStatus {
  path: string
  installed: boolean
  version: string | null
  assetsReady: boolean
}

export interface OriginalGame {
  path: string
  source: string
}

export interface InstallProgress {
  phase: 'verificando' | 'baixando' | 'assets' | 'pronto'
  current_file: string
  files_done: number
  files_total: number
  bytes_done: number
  bytes_total: number
  bytes_per_second: number
}

export interface AssetProgress {
  step: string
  detail: string
}

// --- contas ---

export const register = (email: string, nickname: string, password: string): Promise<Account> =>
  invoke('register', { email, nickname, password })

export const login = (login: string, password: string): Promise<Account> =>
  invoke('login', { login, password })

export const logout = (): Promise<void> => invoke('logout')

/** Reaproveita a sessão guardada no cofre do sistema. `null` = precisa logar. */
export const restoreSession = (): Promise<Account | null> => invoke('restore_session')

export const apiBase = (): Promise<string> => invoke('api_base')

// --- jogo original ---

/** `null` = não achamos; a UI precisa pedir a pasta ao jogador. */
export const findOriginalGame = (): Promise<OriginalGame | null> => invoke('find_original_game')

export const checkOriginalGame = (path: string): Promise<OriginalGame> =>
  invoke('check_original_game', { path })

// --- instalação ---

export const checkUpdate = (): Promise<UpdateCheck> => invoke('check_update')

export const installUpdate = (release: LatestRelease): Promise<void> =>
  invoke('install_update', { release })

export const gameStatus = (): Promise<GameStatus> => invoke('game_status')

export const assetsStatus = (): Promise<boolean> => invoke('assets_status')

export const generateAssets = (originalPath: string): Promise<void> =>
  invoke('generate_assets', { originalPath })

export const launchGame = (): Promise<void> => invoke('launch_game')

// --- eventos ---

export const onInstallProgress = (handler: (p: InstallProgress) => void) =>
  listen<InstallProgress>('install-progress', (e) => handler(e.payload))

export const onAssetProgress = (handler: (p: AssetProgress) => void) =>
  listen<AssetProgress>('asset-progress', (e) => handler(e.payload))
