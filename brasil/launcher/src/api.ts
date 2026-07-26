import { invoke } from '@tauri-apps/api/core'

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
