const state = {
  size: "medium",
  difficulty: "classic",
  worldEvil: "random",
  selectedSeedIds: new Set(),
  specialSeeds: [],
};

const worldNameEl = document.getElementById("worldName");
const manualSeedEl = document.getElementById("manualSeed");
const maxPlayersEl = document.getElementById("maxPlayers");
const serverPortEl = document.getElementById("serverPort");
const extraArgsEl = document.getElementById("extraArgs");
const outputEl = document.getElementById("output");
const runStatusEl = document.getElementById("runStatus");
const resolvedSeedEl = document.getElementById("resolvedSeed");
const selectedSeedsLabelEl = document.getElementById("selectedSeedsLabel");

const seedModalEl = document.getElementById("seedModal");
const seedListEl = document.getElementById("seedList");
const seedSearchEl = document.getElementById("seedSearch");

function setStatus(mode, text) {
  runStatusEl.className = `status ${mode}`;
  runStatusEl.textContent = text;
}

function bindChoiceGroup(rootId, key) {
  const root = document.getElementById(rootId);
  for (const button of root.querySelectorAll("button")) {
    button.addEventListener("click", () => {
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
    selectedSeedsLabelEl.textContent = "No special seeds selected";
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

async function loadSeeds() {
  const response = await fetch("/api/special-seeds");
  const data = await response.json();
  state.specialSeeds = data.seeds || [];
  renderSeedCards();
  refreshSeedSummary();
}

function openModal() {
  seedModalEl.classList.remove("hidden");
}

function closeModal() {
  seedModalEl.classList.add("hidden");
}

async function createWorld() {
  const payload = {
    world_name: worldNameEl.value.trim() || "test.wld",
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

  document.getElementById("createWorld").addEventListener("click", createWorld);

  setStatus("idle", "idle");
  loadSeeds().catch((error) => {
    outputEl.textContent = `Failed to load seed library: ${error}`;
    setStatus("error", "error");
  });
}

boot();

