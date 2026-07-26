//! Instalação e atualização do jogo a partir do manifesto da API.
//!
//! Uma release é uma árvore, não um arquivo. O launcher busca o manifesto,
//! compara com o que existe em disco e baixa apenas a diferença — instalação
//! nova e atualização passam pelo mesmo caminho. Como os mapas são a maior parte
//! do payload e quase nunca mudam, uma correção no executável vira poucos MB em
//! vez de meio giga.
//!
//! O que a API **não** entrega são os arquivos derivados do Knights and
//! Merchants original. Esses são produzidos aqui, a partir da cópia do próprio
//! jogador (ver `assets.rs`).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, State};
use tokio::io::AsyncWriteExt;

use crate::auth::AppState;

pub const VERSION_FILE: &str = "kambrasil.json";

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ManifestFile {
    pub path: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    pub version: String,
    #[serde(rename = "gameRevision")]
    pub game_revision: String,
    pub files: Vec<ManifestFile>,
}

/// `GET /client/latest`
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LatestRelease {
    pub version: String,
    #[serde(rename = "gameRevision")]
    pub game_revision: String,
    #[serde(rename = "manifestUrl")]
    pub manifest_url: String,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    #[serde(rename = "totalBytes")]
    pub total_bytes: u64,
    #[serde(rename = "fileCount")]
    pub file_count: u32,
    pub notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct InstalledInfo {
    pub version: String,
}

/// Progresso emitido como evento `install-progress`.
#[derive(Clone, Serialize)]
pub struct Progress {
    /// `verificando` | `baixando` | `assets` | `pronto`
    pub phase: String,
    pub current_file: String,
    pub files_done: u32,
    pub files_total: u32,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub bytes_per_second: u64,
}

/// Onde o jogo é instalado: `%LOCALAPPDATA%\KamBrasil\game`.
///
/// Não é Arquivos de Programas de propósito. Escrever lá exige elevação, e um
/// launcher que precisa de UAC a cada atualização não atualiza sozinho.
pub fn game_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("KAMBRASIL_GAME_DIR") {
        return PathBuf::from(dir);
    }
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("KamBrasil")
        .join("game")
}

pub fn read_installed(dir: &Path) -> Option<InstalledInfo> {
    let raw = std::fs::read_to_string(dir.join(VERSION_FILE)).ok()?;
    serde_json::from_str(&raw).ok()
}

fn sha256_of(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    Some(format!("{:x}", Sha256::digest(&bytes)))
}

/// Decide o que precisa ser baixado.
///
/// Tamanho diferente já reprova sem ler o arquivo inteiro — é o caso comum e
/// evita hashear centenas de MB à toa. Só quando o tamanho bate é que o sha256
/// decide, porque tamanho igual com conteúdo diferente existe.
pub fn files_to_download(dir: &Path, manifest: &Manifest) -> Vec<ManifestFile> {
    manifest
        .files
        .iter()
        .filter(|f| {
            let local = dir.join(f.path.replace('/', std::path::MAIN_SEPARATOR_STR));
            match std::fs::metadata(&local) {
                Ok(meta) if meta.len() == f.size => sha256_of(&local).as_deref() != Some(&f.sha256),
                _ => true,
            }
        })
        .cloned()
        .collect()
}

async fn fetch_manifest(url: &str) -> Result<Manifest, String> {
    let response = reqwest::Client::new()
        .get(url)
        .send()
        .await
        .map_err(|e| format!("não foi possível buscar o manifesto: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("a API respondeu {} ao buscar o manifesto", response.status()));
    }

    response
        .json()
        .await
        .map_err(|e| format!("manifesto inesperado: {e}"))
}

#[tauri::command]
pub async fn check_update(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let dir = game_dir();
    let installed = read_installed(&dir).map(|i| i.version);

    let response = reqwest::Client::new()
        .get(format!("{}/client/latest", state.api_base()))
        .send()
        .await
        .map_err(|e| format!("não foi possível consultar a versão: {e}"))?;

    if response.status().as_u16() == 404 {
        return Ok(serde_json::json!({
            "path": dir.display().to_string(),
            "installedVersion": installed,
            "latest": null,
            "needsUpdate": false,
        }));
    }
    if !response.status().is_success() {
        return Err(format!("a API respondeu {} ao consultar a versão", response.status()));
    }

    let latest: LatestRelease = response
        .json()
        .await
        .map_err(|e| format!("resposta inesperada da API: {e}"))?;

    let needs_update = installed.as_deref() != Some(latest.version.as_str());

    Ok(serde_json::json!({
        "path": dir.display().to_string(),
        "installedVersion": installed,
        "latest": latest,
        "needsUpdate": needs_update,
    }))
}

/// Baixa tudo que falta e grava a versão instalada.
#[tauri::command]
pub async fn install_update(app: AppHandle, release: LatestRelease) -> Result<(), String> {
    let dir = game_dir();
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("não foi possível criar {}: {e}", dir.display()))?;

    let emit = |p: Progress| {
        let _ = app.emit("install-progress", p);
    };

    emit(Progress {
        phase: "verificando".into(),
        current_file: String::new(),
        files_done: 0,
        files_total: release.file_count,
        bytes_done: 0,
        bytes_total: release.total_bytes,
        bytes_per_second: 0,
    });

    let manifest = fetch_manifest(&release.manifest_url).await?;

    // Comparar é I/O pesado; sai da thread do runtime para não travar a janela.
    let pending = {
        let dir = dir.clone();
        let manifest = manifest.clone();
        tokio::task::spawn_blocking(move || files_to_download(&dir, &manifest))
            .await
            .map_err(|e| format!("falha ao comparar arquivos: {e}"))?
    };

    let bytes_total: u64 = pending.iter().map(|f| f.size).sum();
    let files_total = pending.len() as u32;
    let client = reqwest::Client::new();
    let started = std::time::Instant::now();
    let mut bytes_done: u64 = 0;

    for (index, file) in pending.iter().enumerate() {
        let dest = dir.join(file.path.replace('/', std::path::MAIN_SEPARATOR_STR));
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| format!("não foi possível criar {}: {e}", parent.display()))?;
        }

        let url = format!("{}/{}", release.base_url.trim_end_matches('/'), file.path);
        let response = client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("falha ao baixar {}: {e}", file.path))?;

        if !response.status().is_success() {
            return Err(format!("servidor respondeu {} ao baixar {}", response.status(), file.path));
        }

        // Grava em .part e só então renomeia: uma queda no meio não deixa um
        // arquivo truncado passando por bom na próxima verificação.
        let temp = dest.with_extension("kbpart");
        let mut out = tokio::fs::File::create(&temp)
            .await
            .map_err(|e| format!("não foi possível gravar {}: {e}", file.path))?;

        let mut hasher = Sha256::new();
        let mut stream = response;

        while let Some(chunk) = stream
            .chunk()
            .await
            .map_err(|e| format!("download de {} interrompido: {e}", file.path))?
        {
            hasher.update(&chunk);
            bytes_done += chunk.len() as u64;
            out.write_all(&chunk)
                .await
                .map_err(|e| format!("erro ao gravar {}: {e}", file.path))?;

            let secs = started.elapsed().as_secs_f64().max(0.001);
            emit(Progress {
                phase: "baixando".into(),
                current_file: file.path.clone(),
                files_done: index as u32,
                files_total,
                bytes_done,
                bytes_total,
                bytes_per_second: (bytes_done as f64 / secs) as u64,
            });
        }

        out.flush().await.map_err(|e| format!("erro ao finalizar {}: {e}", file.path))?;
        drop(out);

        if format!("{:x}", hasher.finalize()) != file.sha256.to_lowercase() {
            let _ = tokio::fs::remove_file(&temp).await;
            return Err(format!("{} não confere com o manifesto", file.path));
        }

        tokio::fs::rename(&temp, &dest)
            .await
            .map_err(|e| format!("não foi possível instalar {}: {e}", file.path))?;
    }

    let info = InstalledInfo { version: manifest.version.clone() };
    tokio::fs::write(
        dir.join(VERSION_FILE),
        serde_json::to_vec_pretty(&info).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| format!("não foi possível registrar a versão instalada: {e}"))?;

    emit(Progress {
        phase: "pronto".into(),
        current_file: String::new(),
        files_done: files_total,
        files_total,
        bytes_done,
        bytes_total,
        bytes_per_second: 0,
    });

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kambrasil-inst-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn manifest_of(files: &[(&str, &str)]) -> Manifest {
        Manifest {
            version: "1.0.0".into(),
            game_revision: "r16155".into(),
            files: files
                .iter()
                .map(|(path, content)| ManifestFile {
                    path: (*path).into(),
                    size: content.len() as u64,
                    sha256: format!("{:x}", Sha256::digest(content.as_bytes())),
                })
                .collect(),
        }
    }

    #[test]
    fn baixa_tudo_quando_nada_existe() {
        let dir = temp_dir("vazio");
        let m = manifest_of(&[("a.txt", "aaa"), ("sub/b.txt", "bbb")]);
        assert_eq!(files_to_download(&dir, &m).len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ignora_arquivo_identico() {
        let dir = temp_dir("identico");
        std::fs::write(dir.join("a.txt"), "aaa").unwrap();
        let m = manifest_of(&[("a.txt", "aaa")]);
        assert!(files_to_download(&dir, &m).is_empty(), "arquivo igual nao deveria ser rebaixado");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rebaixa_conteudo_diferente_de_mesmo_tamanho() {
        // O caso que uma comparacao so por tamanho deixaria passar -- e que
        // deixaria o jogador com um arquivo corrompido para sempre.
        let dir = temp_dir("mesmo-tamanho");
        std::fs::write(dir.join("a.txt"), "xxx").unwrap();
        let m = manifest_of(&[("a.txt", "aaa")]);
        assert_eq!(files_to_download(&dir, &m).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rebaixa_arquivo_truncado() {
        let dir = temp_dir("truncado");
        std::fs::write(dir.join("a.txt"), "aa").unwrap();
        let m = manifest_of(&[("a.txt", "aaa")]);
        assert_eq!(files_to_download(&dir, &m).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
