const state = {
  size: "medium",
  difficulty: "classic",
  worldEvil: "random",
  selectedSeedIds: new Set(),
  specialSeeds: [],
  worldMode: "create",
  existingWorlds: [],
  selectedExistingWorld: null,
};

const worldNameEl = document.getElementById("worldName");
const manualSeedEl = document.getElementById("manualSeed");
const maxPlayersEl = document.getElementById("maxPlayers");
const serverPortEl = document.getElementById("serverPort");
const extraArgsEl = document.getElementById("extraArgs");
const namespaceEl = document.getElementById("namespace");
const deploymentEl = document.getElementById("deployment");
const pvcNameEl = document.getElementById("pvcName");

const outputEl = document.getElementById("output");
const runStatusEl = document.getElementById("runStatus");
const resolvedSeedEl = document.getElementById("resolvedSeed");
const selectedSeedsLabelEl = document.getElementById("selectedSeedsLabel");
const selectedWorldHintEl = document.getElementById("selectedWorldHint");
const worldListEl = document.getElementById("worldList");

const modeCreateEl = document.getElementById("modeCreate");
const modeExistingEl = document.getElementById("modeExisting");
const refreshWorldsEl = document.getElementById("refreshWorlds");

const seedModalEl = document.getElementById("seedModal");
const seedListEl = document.getElementById("seedList");
const seedSearchEl = document.getElementById("seedSearch");

function setStatus(mode, text) {
  runStatusEl.className = `status ${mode}`;
  runStatusEl.textContent = text;
}

function fmtBytes(bytes) {
  const n = Number(bytes || 0);
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MB`;
}

function fmtTimestamp(epoch) {
  const n = Number(epoch || 0);
  if (!n) return "unknown";
  const d = new Date(n * 1000);
  return d.toLocaleString();
}

function getClusterScope() {
  return {
    namespace: namespaceEl.value.trim() || "terraria",
    deployment: deploymentEl.value.trim() || "terraria-server",
    pvc_name: pvcNameEl.value.trim() || "terraria-config",
  };
}

function bindChoiceGroup(rootId, key) {
  const root = document.getElementById(rootId);
  for (const button of root.querySelectorAll("button")) {
    button.addEventListener("click", () => {
      if (button.disabled) return;
      for (const b of root.querySelectorAll("button")) {
        b.classList.remove("active");
      }
      button.classList.add("active");
      state[key] = button.dataset.value;
    });
  }
}

function resolveSeedPreview() {
  const manual = manualSeedEl.value.trim();
  if (manual.length > 0) {
    return { seed: manual, mode: "custom" };
  }

  const selected = state.specialSeeds.filter((seed) => state.selectedSeedIds.has(seed.id));
  if (selected.length === 0) {
    return { seed: "", mode: "random" };
  }

  const hasZenith = selected.some((seed) => seed.id === "zenith");
  if (selected.length > 1 || hasZenith) {
    return { seed: "get fixed boi", mode: "multi-special->zenith" };
  }

  return { seed: selected[0].seed, mode: `special:${selected[0].id}` };
}

function refreshSeedSummary() {
  const selected = state.specialSeeds.filter((seed) => state.selectedSeedIds.has(seed.id));
  if (selected.length === 0) {
    selectedSeedsLabelEl.textContent = "Nenhuma seed especial selecionada";
  } else {
    selectedSeedsLabelEl.textContent = selected.map((seed) => seed.label).join(", ");
  }

  const resolved = resolveSeedPreview();
  resolvedSeedEl.textContent = resolved.seed || "(random)";
}

function renderSeedCards(filterText = "") {
  const q = filterText.trim().toLowerCase();
  seedListEl.innerHTML = "";

  for (const seed of state.specialSeeds) {
    const hay = `${seed.label} ${seed.seed} ${seed.description}`.toLowerCase();
    if (q && !hay.includes(q)) {
      continue;
    }

    const card = document.createElement("label");
    card.className = "seed-card";
    const checked = state.selectedSeedIds.has(seed.id) ? "checked" : "";

    card.innerHTML = `
      <div>
        <input type="checkbox" data-seed-id="${seed.id}" ${checked}>
        <span class="seed-name">${seed.label}</span>
      </div>
      <div class="seed-desc">${seed.description}</div>
      <div class="seed-desc">seed: ${seed.seed}</div>
    `;

    seedListEl.appendChild(card);
  }

  for (const checkbox of seedListEl.querySelectorAll("input[type='checkbox']")) {
    checkbox.addEventListener("change", () => {
      const id = checkbox.dataset.seedId;
      if (checkbox.checked) {
        state.selectedSeedIds.add(id);
      } else {
        state.selectedSeedIds.delete(id);
      }
    });
  }
}

function renderWorldList() {
  worldListEl.innerHTML = "";

  if (!state.existingWorlds.length) {
    const empty = document.createElement("div");
    empty.className = "world-item empty";
    empty.textContent = "Nenhum .wld encontrado no PVC.";
    worldListEl.appendChild(empty);
    return;
  }

  for (const world of state.existingWorlds) {
    const row = document.createElement("label");
    row.className = `world-item ${state.selectedExistingWorld === world.name ? "active" : ""}`;
    row.innerHTML = `
      <input type="radio" name="existingWorld" data-name="${world.name}" ${state.selectedExistingWorld === world.name ? "checked" : ""}>
      <div>
        <strong>${world.name}</strong>
        <div class="meta">${fmtBytes(world.size_bytes)} • ${fmtTimestamp(world.modified_epoch)}</div>
      </div>
      <span class="meta">.wld</span>
    `;
    worldListEl.appendChild(row);
  }

  for (const radio of worldListEl.querySelectorAll("input[type='radio']")) {
    radio.addEventListener("change", () => {
      state.selectedExistingWorld = radio.dataset.name;
      worldNameEl.value = state.selectedExistingWorld;
      renderWorldList();
      refreshWorldModeUI();
    });
  }
}

function refreshWorldModeUI() {
  const usingExisting = state.worldMode === "existing";
  modeCreateEl.classList.toggle("active", !usingExisting);
  modeExistingEl.classList.toggle("active", usingExisting);

  const creationControls = [
    manualSeedEl,
    maxPlayersEl,
    serverPortEl,
    extraArgsEl,
    document.getElementById("openSeedModal"),
    document.getElementById("clearSeeds"),
    ...document.querySelectorAll("#sizeChoices button"),
    ...document.querySelectorAll("#difficultyChoices button"),
    ...document.querySelectorAll("#evilChoices button"),
  ];

  for (const control of creationControls) {
    control.disabled = usingExisting;
  }

  if (usingExisting) {
    if (state.selectedExistingWorld) {
      worldNameEl.value = state.selectedExistingWorld;
      selectedWorldHintEl.textContent = `Modo atual: usar mundo existente '${state.selectedExistingWorld}'`;
    } else {
      selectedWorldHintEl.textContent = "Modo atual: usar mundo existente (selecione um da lista)";
    }
  } else {
    selectedWorldHintEl.textContent = "Modo atual: criar um novo mundo";
  }
}

function setWorldMode(mode) {
  state.worldMode = mode;
  if (mode === "existing" && !state.selectedExistingWorld && state.existingWorlds.length > 0) {
    state.selectedExistingWorld = state.existingWorlds[0].name;
    worldNameEl.value = state.selectedExistingWorld;
  }
  refreshWorldModeUI();
  renderWorldList();
}

async function loadSeeds() {
  const response = await fetch("/api/special-seeds");
  const data = await response.json();
  state.specialSeeds = data.seeds || [];
  renderSeedCards();
  refreshSeedSummary();
}

async function loadWorlds() {
  worldListEl.innerHTML = '<div class="world-item empty">Buscando mundos no PVC...</div>';
  const scope = getClusterScope();
  const params = new URLSearchParams({
    namespace: scope.namespace,
    pvc_name: scope.pvc_name,
  });

  try {
    const response = await fetch(`/api/worlds?${params.toString()}`);
    const result = await response.json();
    if (!response.ok || !result.ok) {
      throw new Error(result.error || `HTTP ${response.status}`);
    }

    state.existingWorlds = result.worlds || [];

    if (state.selectedExistingWorld && !state.existingWorlds.some((w) => w.name === state.selectedExistingWorld)) {
      state.selectedExistingWorld = null;
    }

    if (state.worldMode === "existing" && !state.selectedExistingWorld && state.existingWorlds.length > 0) {
      state.selectedExistingWorld = state.existingWorlds[0].name;
      worldNameEl.value = state.selectedExistingWorld;
    }

    renderWorldList();
    refreshWorldModeUI();
  } catch (error) {
    worldListEl.innerHTML = `<div class="world-item empty">Erro ao listar mundos: ${error}</div>`;
  }
}

function openModal() {
  seedModalEl.classList.remove("hidden");
}

function closeModal() {
  seedModalEl.classList.add("hidden");
}

async function createWorld() {
  const scope = getClusterScope();

  let worldName = worldNameEl.value.trim() || "test.wld";
  if (state.worldMode === "existing") {
    if (!state.selectedExistingWorld) {
      outputEl.textContent = "Selecione um mundo existente para aplicar.";
      setStatus("error", "error");
      return;
    }
    worldName = state.selectedExistingWorld;
  }

  const payload = {
    ...scope,
    world_name: worldName,
    seed: manualSeedEl.value.trim(),
    special_seed_ids: Array.from(state.selectedSeedIds),
    world_size: state.size,
    difficulty: state.difficulty,
    world_evil: state.worldEvil,
    max_players: Number(maxPlayersEl.value || 8),
    server_port: Number(serverPortEl.value || 7777),
    extra_create_args: extraArgsEl.value.trim(),
  };

  setStatus("running", "running");
  outputEl.textContent = "Running upload-world script...";

  const createButton = document.getElementById("createWorld");
  createButton.disabled = true;

  try {
    const response = await fetch("/api/create-world", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const result = await response.json();

    const header = [
      `ok: ${result.ok}`,
      `namespace: ${result.namespace}`,
      `deployment: ${result.deployment}`,
      `pvc: ${result.pvc_name}`,
      `exit_code: ${result.exit_code}`,
      `seed_mode: ${result.seed_mode}`,
      `resolved_seed: ${result.resolved_seed || "(random)"}`,
      `duration_seconds: ${result.duration_seconds}`,
      "",
      "command:",
      ...(result.command || []),
      "",
      "output:",
    ].join("\n");

    outputEl.textContent = `${header}\n${result.output || "(no output)"}`;
    setStatus(result.ok ? "success" : "error", result.ok ? "success" : "error");

    await loadWorlds();
  } catch (error) {
    outputEl.textContent = `Request failed: ${error}`;
    setStatus("error", "error");
  } finally {
    createButton.disabled = false;
  }
}

function boot() {
  bindChoiceGroup("sizeChoices", "size");
  bindChoiceGroup("difficultyChoices", "difficulty");
  bindChoiceGroup("evilChoices", "worldEvil");

  manualSeedEl.addEventListener("input", refreshSeedSummary);

  document.getElementById("openSeedModal").addEventListener("click", openModal);
  document.getElementById("closeSeedModal").addEventListener("click", closeModal);
  document.getElementById("applySeeds").addEventListener("click", () => {
    refreshSeedSummary();
    closeModal();
  });

  document.getElementById("clearSeeds").addEventListener("click", () => {
    state.selectedSeedIds.clear();
    renderSeedCards(seedSearchEl.value);
    refreshSeedSummary();
  });

  seedSearchEl.addEventListener("input", () => renderSeedCards(seedSearchEl.value));

  seedModalEl.addEventListener("click", (event) => {
    if (event.target === seedModalEl) {
      closeModal();
    }
  });

  modeCreateEl.addEventListener("click", () => setWorldMode("create"));
  modeExistingEl.addEventListener("click", () => setWorldMode("existing"));
  refreshWorldsEl.addEventListener("click", loadWorlds);

  document.getElementById("createWorld").addEventListener("click", createWorld);

  setStatus("idle", "idle");
  refreshSeedSummary();
  refreshWorldModeUI();

  loadSeeds().catch((error) => {
    outputEl.textContent = `Failed to load seed library: ${error}`;
    setStatus("error", "error");
  });

  loadWorlds();
}

boot();
