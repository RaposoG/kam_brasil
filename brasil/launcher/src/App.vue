<script setup lang="ts">
import { onMounted, ref } from "vue";
import {
  type Account,
  type UpdateCheck,
  apiBase,
  checkUpdate,
  installUpdate,
  launchGame,
  login,
  logout,
  onDownloadProgress,
  register,
  restoreSession,
} from "./api";

type Mode = "login" | "register";

const account = ref<Account | null>(null);
const mode = ref<Mode>("login");
const busy = ref(false);
const booting = ref(true);
const error = ref("");
const notice = ref("");
const base = ref("");

const form = ref({ login: "", email: "", nickname: "", password: "" });

// --- estado do jogo ---
const check = ref<UpdateCheck | null>(null);
const checking = ref(false);
const downloading = ref(false);
const progress = ref({ received: 0, total: 0 });

function mb(bytes: number) {
  return (bytes / 1024 / 1024).toFixed(1);
}

async function refreshGame() {
  checking.value = true;
  error.value = "";
  try {
    check.value = await checkUpdate();
  } catch (e) {
    error.value = String(e);
  } finally {
    checking.value = false;
  }
}

async function onInstall() {
  const release = check.value?.latest;
  if (!release) return;
  downloading.value = true;
  error.value = "";
  progress.value = { received: 0, total: release.sizeBytes };
  try {
    await installUpdate(release);
    notice.value = `Versão ${release.version} instalada.`;
    await refreshGame();
  } catch (e) {
    error.value = String(e);
  } finally {
    downloading.value = false;
  }
}

async function onPlay() {
  error.value = "";
  try {
    await launchGame();
    notice.value = "Bom jogo!";
  } catch (e) {
    error.value = String(e);
  }
}

onMounted(async () => {
  base.value = await apiBase();
  onDownloadProgress((p) => (progress.value = p));
  try {
    account.value = await restoreSession();
    if (account.value) await refreshGame();
  } catch (e) {
    // API fora do ar na abertura nao deve travar o launcher numa tela de erro:
    // cai para o formulario e o usuario tenta quando quiser.
    error.value = String(e);
  } finally {
    booting.value = false;
  }
});

function switchMode(to: Mode) {
  mode.value = to;
  error.value = "";
  notice.value = "";
}

async function onSubmit() {
  error.value = "";
  notice.value = "";
  busy.value = true;
  try {
    if (mode.value === "login") {
      account.value = await login(form.value.login, form.value.password);
      await refreshGame();
    } else {
      await register(form.value.email, form.value.nickname, form.value.password);
      notice.value = "Conta criada! Agora e so entrar.";
      form.value.login = form.value.nickname;
      mode.value = "login";
    }
    form.value.password = "";
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
  }
}

async function onLogout() {
  busy.value = true;
  try {
    await logout();
    account.value = null;
    check.value = null;
    form.value = { login: "", email: "", nickname: "", password: "" };
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <main class="app">
    <header class="brand">
      <h1>Kam Brasil</h1>
      <p v-if="base.includes('localhost')" class="dev">API local · {{ base }}</p>
    </header>

    <section v-if="booting" class="card center">
      <p class="muted">Restaurando sessão…</p>
    </section>

    <section v-else-if="account" class="card">
      <p class="welcome">Bem-vindo, <strong>{{ account.nickname }}</strong></p>
      <p class="muted small">{{ account.email }}</p>

      <p v-if="checking" class="muted small">Verificando versão…</p>

      <template v-else-if="downloading">
        <progress
          class="bar"
          :value="progress.received"
          :max="progress.total || 1"
        />
        <p class="muted small center">
          Baixando… {{ mb(progress.received) }} / {{ mb(progress.total) }} MB
        </p>
      </template>

      <template v-else-if="check">
        <!-- Nada publicado ainda: não faz sentido oferecer download -->
        <template v-if="!check.latest">
          <button class="primary" :disabled="!check.status.installed" @click="onPlay">Jogar</button>
          <p class="muted small center">Nenhuma versão publicada na API ainda.</p>
        </template>

        <template v-else-if="check.needsUpdate">
          <button class="primary" @click="onInstall">
            {{ check.status.installed ? `Atualizar para ${check.latest.version}` : `Instalar ${check.latest.version}` }}
          </button>
          <p v-if="check.latest.notes" class="muted small center">{{ check.latest.notes }}</p>
        </template>

        <template v-else>
          <button class="primary" @click="onPlay">Jogar</button>
          <p class="muted small center">
            Versão {{ check.status.version }} · KaM {{ check.latest.gameRevision }}
          </p>
        </template>
      </template>

      <button class="link" :disabled="busy || downloading" @click="onLogout">Sair da conta</button>
    </section>

    <section v-else class="card">
      <nav class="tabs">
        <button :class="{ active: mode === 'login' }" @click="switchMode('login')">Entrar</button>
        <button :class="{ active: mode === 'register' }" @click="switchMode('register')">Criar conta</button>
      </nav>

      <form @submit.prevent="onSubmit">
        <label v-if="mode === 'login'">
          Email ou nickname
          <input v-model="form.login" required autocomplete="username" />
        </label>

        <template v-else>
          <label>
            Email
            <input v-model="form.email" type="email" required autocomplete="email" />
          </label>
          <label>
            Nickname
            <input
              v-model="form.nickname"
              required
              minlength="3"
              maxlength="16"
              pattern="[A-Za-z0-9_\-]+"
              title="3 a 16 caracteres: letras, números, _ e -"
              autocomplete="nickname"
            />
          </label>
        </template>

        <label>
          Senha
          <input
            v-model="form.password"
            type="password"
            required
            minlength="8"
            :autocomplete="mode === 'login' ? 'current-password' : 'new-password'"
          />
        </label>

        <p v-if="error" class="error">{{ error }}</p>
        <p v-if="notice" class="notice">{{ notice }}</p>

        <button class="primary" type="submit" :disabled="busy">
          {{ busy ? "Aguarde…" : mode === "login" ? "Entrar" : "Criar conta" }}
        </button>
      </form>
    </section>
  </main>
</template>

<style scoped>
.app {
  /* box-sizing global (abaixo) evita que o padding some ao 100vh e crie rolagem */
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1.5rem;
  padding: 2rem;
}

.brand {
  text-align: center;
}
.brand h1 {
  margin: 0;
  font-size: 2.2rem;
  letter-spacing: 0.02em;
}
.dev {
  margin: 0.35rem 0 0;
  font-size: 0.75rem;
  opacity: 0.55;
}

.card {
  width: 100%;
  max-width: 360px;
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
  padding: 1.5rem;
  border: 1px solid rgba(128, 128, 128, 0.25);
  border-radius: 10px;
}
.card.center {
  align-items: center;
}

.tabs {
  display: flex;
  gap: 0.5rem;
}
.tabs button {
  flex: 1;
  padding: 0.5rem;
  background: transparent;
  border: 1px solid rgba(128, 128, 128, 0.3);
  border-radius: 6px;
  cursor: pointer;
  font: inherit;
  color: inherit;
  opacity: 0.6;
  box-shadow: none;
}
.tabs button.active {
  opacity: 1;
  border-color: currentColor;
}

form {
  display: flex;
  flex-direction: column;
  gap: 0.8rem;
}
label {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  font-size: 0.85rem;
}
input {
  padding: 0.55rem 0.7rem;
  border: 1px solid rgba(128, 128, 128, 0.35);
  border-radius: 6px;
  font: inherit;
  color: inherit;
  background: transparent;
  box-shadow: none;
}
input:focus {
  outline: 2px solid rgba(120, 160, 255, 0.5);
  outline-offset: 1px;
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

button.link {
  background: none;
  border: none;
  font: inherit;
  color: inherit;
  opacity: 0.6;
  cursor: pointer;
  text-decoration: underline;
  box-shadow: none;
}

.bar {
  width: 100%;
  height: 8px;
  appearance: none;
  border: none;
  border-radius: 4px;
  overflow: hidden;
  background: rgba(128, 128, 128, 0.25);
}
.bar::-webkit-progress-bar {
  background: rgba(128, 128, 128, 0.25);
}
.bar::-webkit-progress-value {
  background: #2f6fed;
}

.welcome {
  margin: 0;
  font-size: 1.1rem;
}
.muted {
  opacity: 0.6;
  margin: 0;
}
.small {
  font-size: 0.78rem;
}
.center {
  text-align: center;
}
.error {
  margin: 0;
  color: #e06c6c;
  font-size: 0.85rem;
}
.notice {
  margin: 0;
  color: #57b877;
  font-size: 0.85rem;
}
</style>

<style>
:root {
  font-family: Inter, Avenir, Helvetica, Arial, sans-serif;
  font-size: 16px;
  line-height: 24px;
  font-weight: 400;

  color: #0f0f0f;
  background-color: #f6f6f6;

  font-synthesis: none;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

*,
*::before,
*::after {
  box-sizing: border-box;
}

body {
  margin: 0;
  overflow: hidden;
}

@media (prefers-color-scheme: dark) {
  :root {
    color: #f6f6f6;
    background-color: #232323;
  }
}
</style>
