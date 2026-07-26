<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { open } from "@tauri-apps/plugin-dialog";
import {
  type AssetProgress,
  type InstallProgress,
  type OriginalGame,
  type UpdateCheck,
  assetsStatus,
  checkOriginalGame,
  checkUpdate,
  findOriginalGame,
  generateAssets,
  installUpdate,
  launchGame,
  onAssetProgress,
  onInstallProgress,
} from "./api";

/**
 * Fluxo de instalação. A ordem importa e é sempre a mesma:
 *
 *   1. achar o Knights and Merchants original (sem ele não há jogo)
 *   2. baixar da API o que é nosso e da comunidade
 *   3. gerar localmente os arquivos derivados do original
 *   4. jogar
 *
 * Cada etapa só aparece quando a anterior está resolvida, para a tela nunca
 * mostrar um botão que ainda não funciona.
 */

const busy = ref(false);
const error = ref("");
const check = ref<UpdateCheck | null>(null);
const original = ref<OriginalGame | null>(null);
const assetsOk = ref(false);
const download = ref<InstallProgress | null>(null);
const assetStep = ref<AssetProgress | null>(null);

const mb = (bytes: number) => (bytes / 1024 / 1024).toFixed(0);

const percent = computed(() => {
  const p = download.value;
  if (!p || p.bytes_total === 0) return 0;
  return Math.min(100, Math.round((p.bytes_done / p.bytes_total) * 100));
});

const speed = computed(() => {
  const bps = download.value?.bytes_per_second ?? 0;
  return bps > 1024 * 1024 ? `${(bps / 1024 / 1024).toFixed(1)} MB/s` : `${Math.round(bps / 1024)} KB/s`;
});

const eta = computed(() => {
  const p = download.value;
  if (!p || !p.bytes_per_second) return "";
  const secs = Math.round((p.bytes_total - p.bytes_done) / p.bytes_per_second);
  if (secs < 60) return `${secs}s restantes`;
  return `${Math.floor(secs / 60)}min restantes`;
});

async function refresh() {
  error.value = "";
  try {
    check.value = await checkUpdate();
    assetsOk.value = await assetsStatus();
    if (!original.value) original.value = await findOriginalGame();
  } catch (e) {
    error.value = String(e);
  }
}

async function pickOriginal() {
  const picked = await open({ directory: true, title: "Onde está o Knights and Merchants?" });
  if (typeof picked !== "string") return;
  error.value = "";
  try {
    original.value = await checkOriginalGame(picked);
  } catch (e) {
    error.value = String(e);
  }
}

async function onInstall() {
  const release = check.value?.latest;
  if (!release) return;
  busy.value = true;
  error.value = "";
  try {
    await installUpdate(release);
    await refresh();
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
    download.value = null;
  }
}

async function onGenerate() {
  if (!original.value) return;
  busy.value = true;
  error.value = "";
  try {
    await generateAssets(original.value.path);
    assetsOk.value = await assetsStatus();
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
    assetStep.value = null;
  }
}

async function onPlay() {
  error.value = "";
  try {
    await launchGame();
  } catch (e) {
    error.value = String(e);
  }
}

onMounted(async () => {
  onInstallProgress((p) => (download.value = p));
  onAssetProgress((p) => (assetStep.value = p));
  await refresh();
});
</script>

<template>
  <div class="play">
    <!-- 1. jogo original -->
    <section v-if="!original" class="step warn">
      <strong>Você precisa do jogo original</strong>
      <p class="small">
        O Kam Brasil usa os gráficos e sons do <em>Knights and Merchants: The Peasants Rebellion</em>.
        Não encontramos ele instalado nesta máquina.
      </p>
      <button class="ghost" @click="pickOriginal">Escolher a pasta manualmente</button>
    </section>

    <section v-else class="step ok">
      <span class="small">Jogo original encontrado ({{ original.source }})</span>
      <code class="small path">{{ original.path }}</code>
    </section>

    <!-- 2. download -->
    <template v-if="original">
      <section v-if="busy && download" class="step">
        <div class="bar"><div class="fill" :style="{ width: percent + '%' }" /></div>
        <div class="row small">
          <span>{{ percent }}% · {{ mb(download.bytes_done) }} / {{ mb(download.bytes_total) }} MB</span>
          <span>{{ speed }}</span>
        </div>
        <div class="row small muted">
          <span class="file">{{ download.current_file }}</span>
          <span>{{ eta }}</span>
        </div>
      </section>

      <section v-else-if="busy && assetStep" class="step">
        <strong>{{ assetStep.step }}</strong>
        <p class="small muted">{{ assetStep.detail }}</p>
        <div class="bar indeterminate"><div class="fill" /></div>
      </section>

      <template v-else>
        <section v-if="check && check.needsUpdate && check.latest" class="step">
          <button class="primary" :disabled="busy" @click="onInstall">
            {{ check.installedVersion ? `Atualizar para ${check.latest.version}` : "Instalar o jogo" }}
          </button>
          <p class="small muted center">
            {{ mb(check.latest.totalBytes) }} MB · {{ check.latest.fileCount }} arquivos
          </p>
          <p v-if="check.latest.notes" class="small muted center">{{ check.latest.notes }}</p>
        </section>

        <section v-else-if="check && !check.latest" class="step">
          <p class="small muted center">Nenhuma versão publicada na API ainda.</p>
        </section>

        <section v-else-if="!assetsOk" class="step">
          <button class="primary" :disabled="busy" @click="onGenerate">Preparar arquivos do jogo</button>
          <p class="small muted center">
            Converte os gráficos e sons a partir da sua cópia original. Leva alguns minutos, e só
            acontece uma vez.
          </p>
        </section>

        <section v-else class="step">
          <button class="primary" @click="onPlay">Jogar</button>
          <p class="small muted center">Versão {{ check?.installedVersion }}</p>
        </section>
      </template>
    </template>

    <p v-if="error" class="error small">{{ error }}</p>
  </div>
</template>

<style scoped>
.play {
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
}
.step {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.step.warn {
  padding: 0.8rem;
  border: 1px solid rgba(224, 108, 108, 0.5);
  border-radius: 8px;
}
.step.ok {
  gap: 0.15rem;
}
.path {
  opacity: 0.55;
  word-break: break-all;
}
.row {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
}
.file {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 60%;
}
.bar {
  height: 8px;
  border-radius: 4px;
  overflow: hidden;
  background: rgba(128, 128, 128, 0.25);
}
.fill {
  height: 100%;
  background: #2f6fed;
  transition: width 0.2s linear;
}
.bar.indeterminate .fill {
  width: 35%;
  animation: slide 1.2s ease-in-out infinite;
}
@keyframes slide {
  0% { margin-left: -35%; }
  100% { margin-left: 100%; }
}
button.primary {
  padding: 0.6rem;
  border: none;
  border-radius: 6px;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
  background: #2f6fed;
  color: #fff;
  box-shadow: none;
}
button.primary:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}
button.ghost {
  padding: 0.5rem;
  border: 1px solid rgba(128, 128, 128, 0.4);
  border-radius: 6px;
  background: transparent;
  color: inherit;
  font: inherit;
  cursor: pointer;
  box-shadow: none;
}
.small { font-size: 0.78rem; }
.muted { opacity: 0.6; }
.center { text-align: center; }
.error { color: #e06c6c; margin: 0; }
p { margin: 0; }
</style>
