//! Autenticação contra a API do Kam Brasil.
//!
//! Todo o tráfego HTTP acontece aqui, no Rust, e não na webview. O motivo é o
//! token de sessão: se ele chegasse ao JavaScript teríamos que guardá-lo em
//! `localStorage` ou similar, onde qualquer script carregado na página o
//! alcançaria. Deste lado ele fica na memória do processo e é persistido no
//! cofre de credenciais do sistema.
//!
//! A webview conversa só por comandos Tauri e nunca vê o token.
//!
//! `ApiClient` é deliberadamente livre de tipos do Tauri: é o que permite
//! testá-lo contra a API real sem subir uma janela (ver os testes no fim).

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::State;

/// Sobrescrevível em tempo de compilação: `KAMBRASIL_API=https://... cargo build`
const DEFAULT_API_BASE: &str = "http://localhost:3000";

const KEYRING_SERVICE: &str = "br.com.kambrasil.launcher";
const KEYRING_USER: &str = "session-token";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub email: String,
    pub nickname: String,
}

#[derive(Deserialize)]
struct LoginResponse {
    token: String,
    account: Account,
}

#[derive(Deserialize)]
struct AccountEnvelope {
    account: Account,
}

/// Corpo de erro da API: `{ "error": "..." }`
#[derive(Deserialize)]
struct ApiError {
    error: String,
}

/// Sessão recém-criada: o token e a conta a que ele pertence.
pub struct Session {
    pub token: String,
    pub account: Account,
}

pub struct ApiClient {
    client: reqwest::Client,
    base: String,
}

impl ApiClient {
    pub fn new(base: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            base: base.into().trim_end_matches('/').to_string(),
        }
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base, path)
    }

    /// Traduz uma resposta de erro da API para a mensagem que o usuário vê.
    async fn error_message(response: reqwest::Response) -> String {
        let status = response.status();
        match response.json::<ApiError>().await {
            Ok(body) => body.error,
            Err(_) => format!("erro inesperado do servidor ({status})"),
        }
    }

    pub async fn register(
        &self,
        email: &str,
        nickname: &str,
        password: &str,
    ) -> Result<Account, String> {
        let response = self
            .client
            .post(self.url("/auth/register"))
            .json(&serde_json::json!({
                "email": email, "nickname": nickname, "password": password
            }))
            .send()
            .await
            .map_err(|e| format!("não foi possível falar com o servidor: {e}"))?;

        if !response.status().is_success() {
            return Err(Self::error_message(response).await);
        }

        response
            .json::<AccountEnvelope>()
            .await
            .map(|r| r.account)
            .map_err(|e| format!("resposta inesperada do servidor: {e}"))
    }

    pub async fn login(&self, login: &str, password: &str) -> Result<Session, String> {
        let response = self
            .client
            .post(self.url("/auth/login"))
            .json(&serde_json::json!({ "login": login, "password": password }))
            .send()
            .await
            .map_err(|e| format!("não foi possível falar com o servidor: {e}"))?;

        if !response.status().is_success() {
            return Err(Self::error_message(response).await);
        }

        let body: LoginResponse = response
            .json()
            .await
            .map_err(|e| format!("resposta inesperada do servidor: {e}"))?;

        Ok(Session {
            token: body.token,
            account: body.account,
        })
    }

    /// `Ok(None)` = token recusado (expirado ou revogado), não é erro de rede.
    pub async fn me(&self, token: &str) -> Result<Option<Account>, String> {
        let response = self
            .client
            .get(self.url("/auth/me"))
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| format!("não foi possível falar com o servidor: {e}"))?;

        if !response.status().is_success() {
            return Ok(None);
        }

        response
            .json::<AccountEnvelope>()
            .await
            .map(|r| Some(r.account))
            .map_err(|e| format!("resposta inesperada do servidor: {e}"))
    }

    pub async fn logout(&self, token: &str) -> Result<(), String> {
        self.client
            .post(self.url("/auth/logout"))
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| format!("não foi possível falar com o servidor: {e}"))?;
        Ok(())
    }
}

pub struct AppState {
    token: Mutex<Option<String>>,
    api: ApiClient,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            token: Mutex::new(None),
            api: ApiClient::new(option_env!("KAMBRASIL_API").unwrap_or(DEFAULT_API_BASE)),
        }
    }
}

impl AppState {
    fn set_token(&self, token: Option<String>) {
        *self.token.lock().expect("token mutex envenenado") = token;
    }

    fn token(&self) -> Option<String> {
        self.token.lock().expect("token mutex envenenado").clone()
    }
}

fn keyring_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)
        .map_err(|e| format!("não foi possível acessar o cofre de credenciais: {e}"))
}

fn save_token(token: &str) -> Result<(), String> {
    keyring_entry()?
        .set_password(token)
        .map_err(|e| format!("não foi possível salvar a sessão: {e}"))
}

fn clear_stored_token() {
    // Falha aqui não é fatal: o token já foi revogado no servidor.
    if let Ok(entry) = keyring_entry() {
        let _ = entry.delete_credential();
    }
}

fn read_stored_token() -> Option<String> {
    keyring_entry().ok()?.get_password().ok()
}

#[tauri::command]
pub async fn register(
    state: State<'_, AppState>,
    email: String,
    nickname: String,
    password: String,
) -> Result<Account, String> {
    state.api.register(&email, &nickname, &password).await
}

#[tauri::command]
pub async fn login(
    state: State<'_, AppState>,
    login: String,
    password: String,
) -> Result<Account, String> {
    let session = state.api.login(&login, &password).await?;

    state.set_token(Some(session.token.clone()));
    // Se o cofre falhar, o login continua valendo nesta execução — só não
    // sobrevive ao fechar o launcher. Não vale abortar por isso.
    let _ = save_token(&session.token);

    Ok(session.account)
}

/// Tenta reaproveitar a sessão guardada. `None` = precisa logar.
#[tauri::command]
pub async fn restore_session(state: State<'_, AppState>) -> Result<Option<Account>, String> {
    let Some(token) = read_stored_token() else {
        return Ok(None);
    };

    match state.api.me(&token).await? {
        Some(account) => {
            state.set_token(Some(token));
            Ok(Some(account))
        }
        None => {
            // Expirado ou revogado: descarta em vez de insistir a cada abertura.
            clear_stored_token();
            Ok(None)
        }
    }
}

#[tauri::command]
pub async fn logout(state: State<'_, AppState>) -> Result<(), String> {
    if let Some(token) = state.token() {
        // Revogar no servidor é o que realmente invalida o token; apagar só
        // localmente deixaria a sessão viva até expirar.
        let _ = state.api.logout(&token).await;
    }

    state.set_token(None);
    clear_stored_token();
    Ok(())
}

/// Onde a API está apontada. Útil para a UI mostrar quando não é produção.
#[tauri::command]
pub fn api_base(state: State<'_, AppState>) -> String {
    state.api.base().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exercita o fluxo completo contra a API rodando em localhost:3000.
    ///
    /// Marcado como `ignore` porque depende de serviço externo — não deve
    /// quebrar um `cargo test` de quem não subiu o ambiente. Para rodar:
    ///
    ///   cd brasil/api && bun run dev
    ///   cd brasil/launcher/src-tauri && cargo test -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn fluxo_completo_contra_api_real() {
        let api = ApiClient::new("http://localhost:3000");

        // Nickname distinto a cada execução, senão a segunda rodada bate em 409.
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            % 100_000;
        let nickname = format!("rust{suffix}");
        let email = format!("{nickname}@kambrasil.test");
        let password = "senha-de-teste-integracao";

        let created = api
            .register(&email, &nickname, password)
            .await
            .expect("registro deveria funcionar");
        assert_eq!(created.nickname, nickname);

        let duplicate = api.register(&email, &nickname, password).await;
        assert!(duplicate.is_err(), "email repetido deveria ser recusado");

        let wrong = api.login(&nickname, "senha-errada").await;
        assert!(wrong.is_err(), "senha errada deveria ser recusada");

        // Login por nickname em caixa alta: a API é case-insensitive.
        let session = api
            .login(&nickname.to_uppercase(), password)
            .await
            .expect("login deveria funcionar");
        assert_eq!(session.account.email, email);

        let me = api.me(&session.token).await.expect("me deveria responder");
        assert_eq!(me.as_ref().map(|a| a.nickname.as_str()), Some(nickname.as_str()));

        api.logout(&session.token).await.expect("logout deveria funcionar");

        let after = api.me(&session.token).await.expect("me deveria responder");
        assert!(after.is_none(), "token deveria estar revogado apos o logout");
    }
}
