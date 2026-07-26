//! Instalação, atualização e lançamento do cliente do jogo.
//!
//! O launcher trata a pasta do jogo como algo que ele gerencia: a versão
//! instalada fica registrada em `kambrasil.json`, ao lado do executável. Isso
//! evita ter que inferir versão a partir do binário — que mudaria de formato a
//! cada build do Delphi.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, State};
use tokio::io::AsyncWriteExt;

use crate::auth::AppState;

const EXE_NAME: &str = "KaM_Remake.exe";
const VERSION_FILE: &str = "kambrasil.json";

/// O que a API responde em `GET /client/latest`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LatestRelease {
    pub version: String,
    #[serde(rename = "gameRevision")]
    pub game_revision: String,
    #[serde(rename = "downloadUrl")]
    pub download_url: String,
    pub sha256: String,
    #[serde(rename = "sizeBytes")]
    pub size_bytes: u64,
    pub notes: String,
}

/// Gravado ao lado do executável para sabermos o que está instalado.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct InstalledInfo {
    version: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct GameStatus {
    /// Pasta onde o jogo está (ou deveria estar).
    pub path: String,
    /// O executável existe?
    pub installed: bool,
    /// Versão instalada, se o launcher souber.
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UpdateCheck {
    pub status: GameStatus,
    pub latest: Option<LatestRelease>,
    /// `true` quando falta instalar ou a versão difere da publicada.
    pub needs_update: bool,
}

/// Progresso do download, emitido como evento `download-progress`.
#[derive(Clone, Serialize)]
struct Progress {
    received: u64,
    total: u64,
}

/// Pasta do jogo: `game/` ao lado do executável do launcher.
///
/// Sobrescrevível por `KAMBRASIL_GAME_DIR`, que é o que permite apontar para o
/// repositório durante o desenvolvimento sem duplicar a instalação.
fn game_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("KAMBRASIL_GAME_DIR") {
        return PathBuf::from(dir);
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.join("game")))
        .unwrap_or_else(|| PathBuf::from("game"))
}

fn read_installed(dir: &Path) -> Option<InstalledInfo> {
    let raw = std::fs::read_to_string(dir.join(VERSION_FILE)).ok()?;
    serde_json::from_str(&raw).ok()
}

fn status_of(dir: &Path) -> GameStatus {
    GameStatus {
        path: dir.display().to_string(),
        installed: dir.join(EXE_NAME).is_file(),
        version: read_installed(dir).map(|i| i.version),
    }
}

#[tauri::command]
pub fn game_status() -> GameStatus {
    status_of(&game_dir())
}

#[tauri::command]
pub async fn check_update(state: State<'_, AppState>) -> Result<UpdateCheck, String> {
    let status = status_of(&game_dir());

    let response = reqwest::Client::new()
        .get(format!("{}/client/latest", state.api_base()))
        .send()
        .await
        .map_err(|e| format!("não foi possível consultar a versão: {e}"))?;

    // 404 = nada publicado ainda. Não é erro: o launcher só não tem o que oferecer.
    if response.status().as_u16() == 404 {
        return Ok(UpdateCheck { status, latest: None, needs_update: false });
    }
    if !response.status().is_success() {
        return Err(format!("a API respondeu {} ao consultar a versão", response.status()));
    }

    let latest: LatestRelease = response
        .json()
        .await
        .map_err(|e| format!("resposta inesperada da API: {e}"))?;

    let needs_update = !status.installed || status.version.as_deref() != Some(latest.version.as_str());

    Ok(UpdateCheck { status, latest: Some(latest), needs_update })
}

/// Baixa `url` para `dest`, conferindo o sha256 antes de dar por bom.
///
/// Livre de tipos do Tauri de propósito: é o que permite testá-la sem subir
/// janela nenhuma (ver os testes no fim do arquivo). O progresso sai por
/// callback em vez de evento pelo mesmo motivo.
async fn download_verified(
    url: &str,
    dest: &Path,
    expected_sha256: &str,
    fallback_total: u64,
    // `+ Send` porque comandos Tauri exigem future Send, e o closure e mantido
    // vivo atraves dos `.await` do laco de download.
    on_progress: &mut (dyn FnMut(u64, u64) + Send),
) -> Result<(), String> {
    let response = reqwest::Client::new()
        .get(url)
        .send()
        .await
        .map_err(|e| format!("falha ao baixar: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("o servidor respondeu {} ao baixar o cliente", response.status()));
    }

    let total = response.content_length().unwrap_or(fallback_total);

    let mut file = tokio::fs::File::create(dest)
        .await
        .map_err(|e| format!("não foi possível gravar o download: {e}"))?;

    let mut hasher = Sha256::new();
    let mut received: u64 = 0;
    let mut stream = response;

    while let Some(chunk) = stream
        .chunk()
        .await
        .map_err(|e| format!("download interrompido: {e}"))?
    {
        hasher.update(&chunk);
        received += chunk.len() as u64;
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("erro ao gravar o download: {e}"))?;
        on_progress(received, total);
    }

    file.flush().await.map_err(|e| format!("erro ao finalizar o download: {e}"))?;
    drop(file);

    let digest = format!("{:x}", hasher.finalize());
    if digest != expected_sha256.to_lowercase() {
        // Arquivo corrompido ou adulterado: descarta em vez de instalar.
        let _ = tokio::fs::remove_file(dest).await;
        return Err("o arquivo baixado não confere com a assinatura publicada".into());
    }

    Ok(())
}

/// Baixa e instala a release, emitindo `download-progress` ao longo do caminho.
#[tauri::command]
pub async fn install_update(app: AppHandle, release: LatestRelease) -> Result<GameStatus, String> {
    let dir = game_dir();
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("não foi possível criar {}: {e}", dir.display()))?;

    // Baixa para um arquivo temporário: se algo falhar no meio, a instalação
    // atual continua intacta em vez de virar um executável truncado.
    let temp_path = dir.join(format!("{EXE_NAME}.download"));

    download_verified(
        &release.download_url,
        &temp_path,
        &release.sha256,
        release.size_bytes,
        &mut |received, total| {
            let _ = app.emit("download-progress", Progress { received, total });
        },
    )
    .await?;

    let exe_path = dir.join(EXE_NAME);
    tokio::fs::rename(&temp_path, &exe_path)
        .await
        .map_err(|e| format!("não foi possível substituir o executável: {e}"))?;

    let info = InstalledInfo { version: release.version.clone() };
    tokio::fs::write(
        dir.join(VERSION_FILE),
        serde_json::to_vec_pretty(&info).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| format!("não foi possível registrar a versão instalada: {e}"))?;

    Ok(status_of(&dir))
}

/// Onde o KaM guarda configurações do jogador.
///
/// Espelha `CreateAndGetDocumentsSavePath` do Pascal:
/// `Documentos\My Games\Knights and Merchants Remake\`. **Não é** a pasta do
/// jogo — `USE_KMR_DIR_FOR_SETTINGS` só vale em builds de debug.
///
/// Usa a API de pastas conhecidas em vez de montar `%USERPROFILE%\Documents`,
/// porque Documentos pode estar redirecionado (OneDrive, por exemplo).
fn kam_settings_dir() -> Option<PathBuf> {
    dirs::document_dir().map(|d| d.join("My Games").join("Knights and Merchants Remake"))
}

/// Substitui o valor de um atributo dentro de um elemento XML.
///
/// Edição textual pontual em vez de parsear e reescrever o XML: o jogo é dono
/// desse arquivo e reescreve-o inteiro ao sair. Preservar tudo que não é nosso
/// é mais seguro que reserializar.
fn replace_xml_attr(content: &str, element: &str, attr: &str, value: &str) -> Option<String> {
    let block_start = content.find(element)?;
    let block_end = content[block_start..].find('>').map(|i| block_start + i)?;
    let needle = format!("{attr}=\"");
    let attr_start = content[block_start..block_end].find(&needle)?;

    let value_start = block_start + attr_start + needle.len();
    let value_len = content[value_start..].find('"')?;

    let mut updated = String::with_capacity(content.len());
    updated.push_str(&content[..value_start]);
    updated.push_str(value);
    updated.push_str(&content[value_start + value_len..]);
    Some(updated)
}

/// Aponta o jogo para a nossa infraestrutura antes de lançá-lo.
///
/// Duas coisas, ambas em `Documentos\My Games\...`:
///
/// - **Nickname** em `KaM Remake Settings.xml`, `Game/Multiplayer/@Name`. Faz o
///   nick da conta valer dentro do jogo sem alterar Pascal. É conveniência, não
///   autoridade — o jogador ainda pode editar o arquivo. A imposição real vem do
///   servidor, que recusa quem não tem token válido.
/// - **Master server** em `KaM Remake Server Settings.ini`. Sem isto o jogo lista
///   os servidores oficiais em vez dos nossos.
///
/// Falhas aqui não impedem de jogar: registramos e seguimos.
fn configure_game(nickname: &str, api_base: &str) -> Result<(), String> {
    let dir = kam_settings_dir().ok_or("não foi possível localizar a pasta Documentos")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("não foi possível criar {}: {e}", dir.display()))?;

    // --- nickname ---
    let xml_path = dir.join("KaM Remake Settings.xml");
    match std::fs::read_to_string(&xml_path) {
        Ok(content) => {
            if let Some(updated) = replace_xml_attr(&content, "<Multiplayer", "Name", nickname) {
                std::fs::write(&xml_path, updated)
                    .map_err(|e| format!("não foi possível gravar o nickname: {e}"))?;
            }
        }
        Err(_) => {
            // Primeira execução: o jogo ainda não criou o arquivo. Criamos o
            // mínimo; ele preenche o resto com os padrões e regrava ao sair.
            let minimal = format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Root>\n  <Game>\n    <Multiplayer Name=\"{nickname}\"/>\n  </Game>\n</Root>\n"
            );
            std::fs::write(&xml_path, minimal)
                .map_err(|e| format!("não foi possível criar as configurações do jogo: {e}"))?;
        }
    }

    // --- master server ---
    let ini_path = dir.join("KaM Remake Server Settings.ini");
    let master = format!("{}/", api_base.trim_end_matches('/'));
    let ini = match std::fs::read_to_string(&ini_path) {
        Ok(content) if content.contains("MasterServerAddressNew=") => content
            .lines()
            .map(|line| {
                if line.starts_with("MasterServerAddressNew=") {
                    format!("MasterServerAddressNew={master}")
                } else {
                    line.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\r\n"),
        Ok(content) => format!("{}\r\nMasterServerAddressNew={master}", content.trim_end()),
        Err(_) => format!("[Server]\r\nMasterServerAddressNew={master}\r\n"),
    };

    std::fs::write(&ini_path, ini).map_err(|e| format!("não foi possível apontar o master server: {e}"))?;

    Ok(())
}

#[tauri::command]
pub async fn launch_game(state: State<'_, AppState>) -> Result<(), String> {
    let dir = game_dir();
    let exe = dir.join(EXE_NAME);

    if !exe.is_file() {
        return Err(format!("{EXE_NAME} não encontrado em {}", dir.display()));
    }

    if let Some(nickname) = state.nickname() {
        // Falhar aqui não impede de jogar — só significa que o jogo abre com a
        // configuração anterior.
        if let Err(e) = configure_game(&nickname, &state.api_base()) {
            eprintln!("aviso: {e}");
        }
    }

    let mut command = std::process::Command::new(&exe);
    command.current_dir(&dir);

    // Entrega do token: arquivo temporário cujo caminho vai por variável de
    // ambiente. NÃO por argumento de linha de comando — argumentos aparecem na
    // lista de processos para qualquer usuário da máquina.
    //
    // O jogo apaga o arquivo assim que o lê (ver KM_KamBrasilAuth.pas). O que
    // sobra aqui é o caso do jogo nem abrir; por isso o nome é previsível e
    // sobrescrito a cada lançamento, em vez de acumular.
    let token_path = std::env::temp_dir().join("kambrasil-session.token");
    if let Some(token) = state.token() {
        tokio::fs::write(&token_path, token)
            .await
            .map_err(|e| format!("não foi possível preparar a sessão do jogo: {e}"))?;
        command.env("KAMBRASIL_TOKEN_FILE", &token_path);
    } else {
        // Sem sessão não há o que entregar. Deixar um arquivo velho para trás
        // faria o jogo usar um token de outro login.
        let _ = tokio::fs::remove_file(&token_path).await;
    }

    command
        .spawn()
        .map_err(|e| format!("não foi possível abrir o jogo: {e}"))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kambrasil-test-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Verifica o download contra a API real: hash correto instala, hash errado
    /// e recusado e o arquivo parcial nao fica para tras.
    ///
    ///   cd brasil/api && bun run dev
    ///   cd brasil/launcher/src-tauri && cargo test -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn download_confere_hash() {
        let latest: LatestRelease = reqwest::get("http://localhost:3000/client/latest")
            .await
            .expect("API precisa estar no ar")
            .json()
            .await
            .expect("precisa haver uma release publicada");

        let dir = temp_dir("download");

        // Caminho feliz: hash bate, arquivo fica com o tamanho anunciado.
        let good = dir.join("ok.bin");
        let mut seen: Vec<(u64, u64)> = Vec::new();
        download_verified(
            &latest.download_url,
            &good,
            &latest.sha256,
            latest.size_bytes,
            &mut |r, t| seen.push((r, t)),
        )
        .await
        .expect("download com hash correto deveria funcionar");

        let size = std::fs::metadata(&good).unwrap().len();
        assert_eq!(size, latest.size_bytes, "tamanho baixado deveria bater");
        assert!(!seen.is_empty(), "deveria ter reportado progresso");
        assert_eq!(seen.last().unwrap().0, size, "ultimo progresso deveria ser o total");

        // Hash errado: recusa E limpa o arquivo, senao um download adulterado
        // ficaria em disco esperando ser promovido a executavel.
        let bad = dir.join("ruim.bin");
        let err = download_verified(
            &latest.download_url,
            &bad,
            &"0".repeat(64),
            latest.size_bytes,
            &mut |_, _| {},
        )
        .await
        .expect_err("hash errado deveria ser recusado");

        assert!(err.contains("assinatura"), "mensagem inesperada: {err}");
        assert!(!bad.exists(), "arquivo com hash errado deveria ter sido apagado");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn troca_nickname_preservando_o_resto_do_xml() {
        let xml = r#"<Root><Game><Multiplayer Name="NoName" LastIP="127.0.0.1"/><Misc A="1"/></Game></Root>"#;
        let updated = replace_xml_attr(xml, "<Multiplayer", "Name", "Raposo").unwrap();

        assert!(updated.contains(r#"Name="Raposo""#), "nickname nao trocado: {updated}");
        assert!(updated.contains(r#"LastIP="127.0.0.1""#), "atributo vizinho deveria sobreviver");
        assert!(updated.contains(r#"<Misc A="1"/>"#), "o resto do XML deveria ficar intacto");
    }

    #[test]
    fn nao_confunde_atributo_de_outro_elemento() {
        // "Name" aparece antes, noutro elemento. A troca tem que acontecer
        // dentro do Multiplayer, senao gravariamos o nick no lugar errado.
        let xml = r#"<Root><Menu Name="algo"/><Multiplayer Name="NoName"/></Root>"#;
        let updated = replace_xml_attr(xml, "<Multiplayer", "Name", "Raposo").unwrap();

        assert!(updated.contains(r#"<Menu Name="algo"/>"#), "elemento anterior foi alterado: {updated}");
        assert!(updated.contains(r#"<Multiplayer Name="Raposo"/>"#), "nickname nao trocado: {updated}");
    }

    #[test]
    fn atributo_ausente_devolve_none() {
        // Sem o atributo nao ha o que trocar -- e isso precisa ser distinguivel
        // de sucesso, senao gravariamos o arquivo sem mudanca nenhuma.
        let xml = r#"<Root><Multiplayer LastIP="127.0.0.1"/></Root>"#;
        assert!(replace_xml_attr(xml, "<Multiplayer", "Name", "Raposo").is_none());
    }
}
