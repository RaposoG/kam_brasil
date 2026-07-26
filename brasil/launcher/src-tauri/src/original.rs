//! Localiza a instalação do Knights and Merchants: The Peasants Rebellion.
//!
//! O Kam Brasil não distribui os arquivos do jogo comercial. Sprites, sons,
//! músicas e os `.dat` de unidades e casas são gerados na máquina do jogador, a
//! partir da cópia que ele possui. Por isso o launcher precisa achá-la — e, não
//! achando, dizer com todas as letras que o original é necessário.
//!
//! A detecção é uma sequência de palpites seguida de **validação**: só aceitamos
//! uma pasta se os arquivos que realmente vamos usar estiverem lá. Palpite que
//! não valida é palpite descartado.

use std::path::{Path, PathBuf};

use serde::Serialize;

/// Arquivos que o Kam Brasil precisa da instalação original. A presença de todos
/// é o que define uma pasta como válida — não o nome dela.
const REQUIRED: &[&str] = &[
    "data/gfx/res/units.rx",
    "data/gfx/res/houses.rx",
    "data/gfx/res/trees.rx",
    "data/gfx/res/gui.rx",
    "data/gfx/res/guimain.rx",
    "data/defines/unit.dat",
    "data/defines/houses.dat",
];

#[derive(Debug, Clone, Serialize)]
pub struct OriginalGame {
    pub path: String,
    /// Como foi encontrada — útil para a UI explicar ao jogador.
    pub source: String,
}

/// Uma pasta serve se contém tudo que vamos ler dela.
///
/// Comparar por nome de pasta seria frágil: instalações vêm de CD, GOG, Steam e
/// de pastas renomeadas à mão, cada uma com um nome diferente.
pub fn is_valid_install(dir: &Path) -> bool {
    REQUIRED.iter().all(|rel| dir.join(rel).is_file())
}

/// Lê o caminho de uma biblioteca Steam a partir do `libraryfolders.vdf`.
///
/// Formato simplificado: linhas `"path"  "C:\\algum\\lugar"`. Não vale trazer um
/// parser de VDF para extrair um campo.
fn steam_libraries(vdf: &str) -> Vec<PathBuf> {
    vdf.lines()
        .filter_map(|line| {
            let line = line.trim();
            let rest = line.strip_prefix("\"path\"")?;
            let start = rest.find('"')? + 1;
            let end = rest[start..].find('"')? + start;
            Some(PathBuf::from(rest[start..end].replace("\\\\", "\\")))
        })
        .collect()
}

fn candidates() -> Vec<(PathBuf, String)> {
    let mut found: Vec<(PathBuf, String)> = Vec::new();

    // Override explícito ganha de tudo: é a saída para instalações exóticas.
    if let Ok(dir) = std::env::var("KAMBRASIL_ORIGINAL_DIR") {
        found.push((PathBuf::from(dir), "variável de ambiente".into()));
    }

    let program_files: Vec<PathBuf> = ["ProgramFiles(x86)", "ProgramFiles", "ProgramW6432"]
        .iter()
        .filter_map(|var| std::env::var(var).ok())
        .map(PathBuf::from)
        .collect();

    let names = [
        "KaM - The Peasants Rebellion",
        "Knights and Merchants",
        "Knights and Merchants The Peasants Rebellion",
        "KaM The Peasants Rebellion",
        "Knights and Merchants - The Peasants Rebellion",
    ];

    for base in &program_files {
        for name in &names {
            found.push((base.join(name), "Arquivos de Programas".into()));
        }
        // GOG costuma instalar sob uma pasta GOG Galaxy\Games
        for name in &names {
            found.push((base.join("GOG Galaxy").join("Games").join(name), "GOG".into()));
        }
    }

    for base in ["C:\\GOG Games", "D:\\GOG Games"] {
        for name in &names {
            found.push((PathBuf::from(base).join(name), "GOG".into()));
        }
    }

    // Steam: percorre as bibliotecas declaradas, não só a instalação padrão.
    for base in &program_files {
        let vdf = base.join("Steam").join("steamapps").join("libraryfolders.vdf");
        let Ok(content) = std::fs::read_to_string(&vdf) else { continue };
        for lib in steam_libraries(&content) {
            for name in &names {
                found.push((lib.join("steamapps").join("common").join(name), "Steam".into()));
            }
        }
    }

    found
}

/// Procura a instalação original. `None` = precisa perguntar ao jogador.
#[tauri::command]
pub fn find_original_game() -> Option<OriginalGame> {
    candidates().into_iter().find_map(|(dir, source)| {
        if is_valid_install(&dir) {
            Some(OriginalGame { path: dir.display().to_string(), source })
        } else {
            None
        }
    })
}

/// Valida uma pasta escolhida à mão pelo jogador.
#[tauri::command]
pub fn check_original_game(path: String) -> Result<OriginalGame, String> {
    let dir = PathBuf::from(&path);

    if !dir.is_dir() {
        return Err("essa pasta não existe".into());
    }

    if !is_valid_install(&dir) {
        // Diz o que faltou em vez de um "inválido" seco: quase sempre o jogador
        // apontou para a pasta de cima ou para um atalho.
        let missing: Vec<&str> = REQUIRED.iter().copied().filter(|rel| !dir.join(rel).is_file()).collect();
        return Err(format!(
            "não parece uma instalação do Knights and Merchants — não encontrei: {}",
            missing.join(", ")
        ));
    }

    Ok(OriginalGame { path, source: "escolhida por você".into() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kambrasil-orig-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fake_install(dir: &Path, skip: &[&str]) {
        for rel in REQUIRED {
            if skip.contains(rel) {
                continue;
            }
            let path = dir.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"x").unwrap();
        }
    }

    #[test]
    fn instalacao_completa_e_valida() {
        let dir = temp_dir("completa");
        fake_install(&dir, &[]);
        assert!(is_valid_install(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn faltando_um_arquivo_nao_vale() {
        // Meia instalacao e pior que nenhuma: passaria na deteccao e quebraria
        // so na hora de gerar os sprites.
        let dir = temp_dir("incompleta");
        fake_install(&dir, &["data/gfx/res/units.rx"]);
        assert!(!is_valid_install(&dir));

        let err = check_original_game(dir.display().to_string()).unwrap_err();
        assert!(err.contains("units.rx"), "o erro deveria dizer o que faltou: {err}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pasta_inexistente_da_erro_claro() {
        let err = check_original_game("Z:\\nao\\existe".into()).unwrap_err();
        assert!(err.contains("não existe"), "mensagem inesperada: {err}");
    }

    #[test]
    fn le_bibliotecas_do_steam() {
        let vdf = r#"
"libraryfolders"
{
    "0"
    {
        "path"		"C:\\Program Files (x86)\\Steam"
    }
    "1"
    {
        "path"		"D:\\SteamLibrary"
    }
}
"#;
        let libs = steam_libraries(vdf);
        assert_eq!(libs.len(), 2, "deveria achar as duas bibliotecas");
        assert_eq!(libs[1], PathBuf::from("D:\\SteamLibrary"));
    }
}
