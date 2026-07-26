//! Gera os arquivos derivados do Knights and Merchants original.
//!
//! Nada disto vem da nossa API: sprites, sons, músicas e os `.dat` de unidades e
//! casas pertencem ao jogo comercial. São produzidos aqui, na máquina do
//! jogador, a partir da cópia que ele possui — por isso o launcher exige achar a
//! instalação original antes de deixar jogar.
//!
//! São quatro operações, três triviais e uma cara:
//!
//! | Destino | Origem |
//! |---|---|
//! | `data/gfx/*.bbm`, `*.lbm`, `*.dat` | cópia direta (paletas) |
//! | `data/defines/houses.dat`, `unit.dat` | cópia direta |
//! | `data/sfx/` | cópia direta |
//! | `Music/*.mp2` | `data/sfx/songs/*.sng` renomeados |
//! | `data/Sprites/*.rxx` | **RXXPacker** sobre os `.rx` (~2 min) |
//!
//! O `.sng` do KaM é MP2 com outra extensão; renomear basta.

use std::path::{Path, PathBuf};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
struct AssetProgress {
    step: String,
    detail: String,
}

fn copy_dir(from: &Path, to: &Path) -> Result<u32, String> {
    if !from.is_dir() {
        return Ok(0);
    }
    std::fs::create_dir_all(to).map_err(|e| format!("não foi possível criar {}: {e}", to.display()))?;

    let mut count = 0;
    for entry in std::fs::read_dir(from).map_err(|e| format!("não foi possível ler {}: {e}", from.display()))? {
        let entry = entry.map_err(|e| e.to_string())?;
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            count += copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)
                .map_err(|e| format!("não foi possível copiar {}: {e}", entry.path().display()))?;
            count += 1;
        }
    }
    Ok(count)
}

fn copy_glob(from: &Path, to: &Path, extensions: &[&str]) -> Result<u32, String> {
    if !from.is_dir() {
        return Ok(0);
    }
    std::fs::create_dir_all(to).map_err(|e| format!("não foi possível criar {}: {e}", to.display()))?;

    let mut count = 0;
    for entry in std::fs::read_dir(from).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let matches = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| extensions.iter().any(|want| want.eq_ignore_ascii_case(e)))
            .unwrap_or(false);
        if matches {
            std::fs::copy(&path, to.join(entry.file_name()))
                .map_err(|e| format!("não foi possível copiar {}: {e}", path.display()))?;
            count += 1;
        }
    }
    Ok(count)
}

/// `.sng` é MP2 com outro nome. O jogo procura `.mp2` na pasta Music.
fn copy_music(original: &Path, game: &Path) -> Result<u32, String> {
    let songs = original.join("data").join("sfx").join("songs");
    if !songs.is_dir() {
        return Ok(0);
    }
    let music = game.join("Music");
    std::fs::create_dir_all(&music).map_err(|e| e.to_string())?;

    let mut count = 0;
    for entry in std::fs::read_dir(&songs).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case("sng")) != Some(true) {
            continue;
        }
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("track");
        std::fs::copy(&path, music.join(format!("{stem}.mp2")))
            .map_err(|e| format!("não foi possível copiar {}: {e}", path.display()))?;
        count += 1;
    }
    Ok(count)
}

/// Converte os `.rx` originais nos `.rxx` que o engine lê.
///
/// O engine **não** lê os `.rx` — só `.rxx` de `data/Sprites`. Sem esta etapa o
/// jogo abre numa tela preta, sem erro nenhum.
///
/// O RXXPacker é um binário Delphi distribuído junto com a release. Ele precisa
/// que os `.rx` do jogador e as pastas de sprites da comunidade estejam na mesma
/// pasta de origem, e lê as paletas de `<jogo>/data/gfx` — por isso as paletas
/// são copiadas antes.
fn run_rxx_packer(game: &Path, original: &Path) -> Result<(), String> {
    let packer = game.join("Utils").join("RXXPacker").join("RXXPacker.exe");
    if !packer.is_file() {
        return Err(format!(
            "RXXPacker não encontrado em {} — a release precisa incluí-lo",
            packer.display()
        ));
    }

    // Pasta de trabalho: sprites da comunidade (vieram da release) + os .rx do
    // jogador, lado a lado, que e o layout que o packer espera.
    let source = game.join("SpriteResource");
    std::fs::create_dir_all(&source).map_err(|e| e.to_string())?;
    copy_glob(&original.join("data").join("gfx").join("res"), &source, &["rx"])?;

    let dest = game.join("data").join("Sprites");
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;

    let output = std::process::Command::new(&packer)
        .current_dir(packer.parent().unwrap())
        .arg("srx")
        .arg(format!("{}\\", source.display()))
        .arg("d")
        .arg(format!("{}\\", dest.display()))
        .arg("all")
        .output()
        .map_err(|e| format!("não foi possível executar o RXXPacker: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "RXXPacker falhou: {}",
            String::from_utf8_lossy(&output.stdout).lines().last().unwrap_or("erro desconhecido")
        ));
    }

    // O packer relata erro no stdout sem falhar o processo, entao conferimos o
    // resultado em vez de confiar no codigo de saida.
    let produced = std::fs::read_dir(&dest)
        .map(|d| d.filter_map(Result::ok).filter(|e| e.path().extension().is_some()).count())
        .unwrap_or(0);

    if produced == 0 {
        return Err(format!(
            "o RXXPacker não produziu sprites: {}",
            String::from_utf8_lossy(&output.stdout).lines().last().unwrap_or("")
        ));
    }

    Ok(())
}

/// Roda todas as etapas locais. Bloqueante e demorado — chame de spawn_blocking.
pub fn generate(app: &AppHandle, game: &Path, original: &Path) -> Result<(), String> {
    let step = |name: &str, detail: &str| {
        let _ = app.emit(
            "asset-progress",
            AssetProgress { step: name.into(), detail: detail.into() },
        );
    };

    step("paletas", "copiando paletas de cores");
    let gfx = game.join("data").join("gfx");
    copy_glob(&original.join("data").join("gfx"), &gfx, &["bbm", "lbm", "dat"])?;

    step("defines", "copiando dados de unidades e casas");
    let defines = game.join("data").join("defines");
    std::fs::create_dir_all(&defines).map_err(|e| e.to_string())?;
    for name in ["houses.dat", "unit.dat"] {
        let from = original.join("data").join("defines").join(name);
        std::fs::copy(&from, defines.join(name))
            .map_err(|e| format!("não foi possível copiar {name}: {e}"))?;
    }

    step("sons", "copiando efeitos sonoros");
    copy_dir(&original.join("data").join("sfx"), &game.join("data").join("sfx"))?;

    step("musicas", "copiando trilha sonora");
    copy_music(original, game)?;

    step("sprites", "convertendo sprites — esta etapa demora alguns minutos");
    run_rxx_packer(game, original)?;

    step("pronto", "");
    Ok(())
}

/// Já geramos os assets nesta instalação?
pub fn assets_ready(game: &Path) -> bool {
    let sprites = game.join("data").join("Sprites");
    let required = ["GUI.rxx", "GUIMain.rxx", "Houses.rxx", "Trees.rxx", "Units.rxx", "Tileset.rxx"];
    required.iter().all(|f| sprites.join(f).is_file())
        && game.join("data").join("defines").join("unit.dat").is_file()
}

#[tauri::command]
pub fn assets_status() -> bool {
    assets_ready(&crate::install::game_dir())
}

#[tauri::command]
pub async fn generate_assets(app: AppHandle, original_path: String) -> Result<(), String> {
    let game = crate::install::game_dir();
    let original = PathBuf::from(original_path);

    tokio::task::spawn_blocking(move || generate(&app, &game, &original))
        .await
        .map_err(|e| format!("falha ao gerar os arquivos do jogo: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kambrasil-assets-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn copia_apenas_as_extensoes_pedidas() {
        let from = temp_dir("glob-origem");
        let to = temp_dir("glob-destino");
        std::fs::write(from.join("pal0.bbm"), "x").unwrap();
        std::fs::write(from.join("setup.lbm"), "x").unwrap();
        std::fs::write(from.join("leiame.txt"), "x").unwrap();

        let n = copy_glob(&from, &to, &["bbm", "lbm"]).unwrap();

        assert_eq!(n, 2);
        assert!(to.join("pal0.bbm").is_file());
        assert!(!to.join("leiame.txt").exists(), "txt nao deveria ter sido copiado");

        let _ = std::fs::remove_dir_all(&from);
        let _ = std::fs::remove_dir_all(&to);
    }

    #[test]
    fn musica_vira_mp2() {
        let original = temp_dir("musica-origem");
        let game = temp_dir("musica-destino");
        let songs = original.join("data").join("sfx").join("songs");
        std::fs::create_dir_all(&songs).unwrap();
        std::fs::write(songs.join("track_00.sng"), "x").unwrap();
        std::fs::write(songs.join("leiame.txt"), "x").unwrap();

        let n = copy_music(&original, &game).unwrap();

        assert_eq!(n, 1);
        assert!(game.join("Music").join("track_00.mp2").is_file(), "sng deveria virar mp2");

        let _ = std::fs::remove_dir_all(&original);
        let _ = std::fs::remove_dir_all(&game);
    }

    #[test]
    fn assets_incompletos_nao_contam_como_prontos() {
        // Faltando um unico rxx o jogo abre em tela preta. Meio pronto e o pior
        // estado possivel: parece instalado e nao funciona.
        let game = temp_dir("assets-parciais");
        let sprites = game.join("data").join("Sprites");
        std::fs::create_dir_all(&sprites).unwrap();
        for f in ["GUI.rxx", "GUIMain.rxx", "Houses.rxx", "Trees.rxx", "Units.rxx"] {
            std::fs::write(sprites.join(f), "x").unwrap();
        }
        assert!(!assets_ready(&game), "faltando Tileset.rxx nao pode contar como pronto");

        let _ = std::fs::remove_dir_all(&game);
    }
}
