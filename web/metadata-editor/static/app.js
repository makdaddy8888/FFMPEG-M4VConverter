(() => {
  const state = {
    clips: [],
    filter: "attention",
    selectedId: null,
    saving: false,
  };

  const els = {
    empty: document.getElementById("emptyState"),
    reviewBody: document.getElementById("reviewBody"),
    actionBar: document.getElementById("actionBar"),
    batchSelect: document.getElementById("batchSelect"),
    preview: document.getElementById("preview"),
    thumbStill: document.getElementById("thumbStill"),
    clipIdLabel: document.getElementById("clipIdLabel"),
    progressText: document.getElementById("progressText"),
    flagList: document.getElementById("flagList"),
    saveMsg: document.getElementById("saveMsg"),
    prevBtn: document.getElementById("prevBtn"),
    skipBtn: document.getElementById("skipBtn"),
    saveNextBtn: document.getElementById("saveNextBtn"),
    editorForm: document.getElementById("editorForm"),
    locHints: document.getElementById("locHints"),
    fields: {
      title: document.getElementById("f_title"),
      description: document.getElementById("f_description"),
      location_name: document.getElementById("f_location_name"),
      latitude: document.getElementById("f_latitude"),
      longitude: document.getElementById("f_longitude"),
      creation_time: document.getElementById("f_creation_time"),
      notes: document.getElementById("f_notes"),
    },
  };

  function filteredClips() {
    return state.clips.filter((c) => {
      if (state.filter === "all") return true;
      if (state.filter === "empty") return c.flags.includes("empty-desc");
      if (state.filter === "attention") return c.needs_attention;
      return true;
    });
  }

  function escapeHtml(s) {
    return String(s)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  }

  function selectedIndex() {
    return filteredClips().findIndex((c) => c.id === state.selectedId);
  }

  function showEmpty(isEmpty) {
    els.empty.classList.toggle("hidden", !isEmpty);
    els.reviewBody.classList.toggle("hidden", isEmpty);
    els.actionBar.classList.toggle("hidden", isEmpty);
  }

  function focusTitle() {
    // Keep viewport stable — do not scrollIntoView the whole page
    requestAnimationFrame(() => {
      els.fields.title.focus({ preventScroll: true });
      els.fields.title.select();
    });
  }

  function selectClip(id, { focus = true } = {}) {
    const clip = state.clips.find((c) => c.id === id);
    if (!clip) return;

    state.selectedId = id;
    const clips = filteredClips();
    const idx = clips.findIndex((c) => c.id === id);
    const n = clips.length;

    showEmpty(false);
    els.progressText.textContent =
      idx >= 0 ? `Clip ${idx + 1} of ${n}` : `Clip — of ${n}`;
    els.clipIdLabel.textContent = clip.file;

    els.fields.title.value = clip.title || "";
    els.fields.description.value = clip.description || "";
    els.fields.location_name.value = clip.location_name || "";
    els.fields.latitude.value = clip.latitude || "";
    els.fields.longitude.value = clip.longitude || "";
    els.fields.creation_time.value = clip.creation_time || "";
    els.fields.notes.value = clip.notes || "";

    const badges = (clip.flags || []).filter((f) => f !== "default-title");
    els.flagList.innerHTML = badges.length
      ? badges.map((f) => `<span class="badge">${escapeHtml(f)}</span>`).join("")
      : `<span class="badge">ok</span>`;

    els.saveMsg.textContent = "";
    els.saveMsg.classList.remove("error");

    els.preview.pause();
    els.preview.src = `/api/video/${encodeURIComponent(clip.id)}`;
    els.thumbStill.src = `/api/thumb/${encodeURIComponent(clip.id)}?t=${clip.mtime || Date.now()}`;

    els.prevBtn.disabled = idx <= 0;
    els.skipBtn.disabled = idx < 0 || idx >= n - 1;
    els.saveNextBtn.textContent = idx >= 0 && idx >= n - 1 ? "Save" : "Save & Next";

    if (focus) focusTitle();
  }

  function moveSelection(delta, { focus = true } = {}) {
    const clips = filteredClips();
    if (!clips.length) {
      showEmpty(true);
      return;
    }
    let idx = selectedIndex();
    if (idx < 0) idx = 0;
    else idx = Math.max(0, Math.min(clips.length - 1, idx + delta));
    selectClip(clips[idx].id, { focus });
  }

  function ensureSelection() {
    const clips = filteredClips();
    if (!clips.length) {
      state.selectedId = null;
      showEmpty(true);
      return;
    }
    if (!state.selectedId || !clips.some((c) => c.id === state.selectedId)) {
      selectClip(clips[0].id);
    } else {
      selectClip(state.selectedId, { focus: false });
    }
  }

  async function loadBatches() {
    const res = await fetch("/api/batches");
    const data = await res.json();
    els.batchSelect.innerHTML = "";
    for (const b of data.batches || []) {
      const opt = document.createElement("option");
      opt.value = b.id;
      opt.textContent = `${b.id} (${b.clips})`;
      if (b.id === data.current) opt.selected = true;
      els.batchSelect.appendChild(opt);
    }
  }

  async function loadClips() {
    const res = await fetch("/api/clips");
    const data = await res.json();
    state.clips = data.clips || [];
    rebuildLocationHints();
    ensureSelection();
  }

  function rebuildLocationHints() {
    const locs = [...new Set(state.clips.map((c) => c.location_name).filter(Boolean))].sort();
    els.locHints.innerHTML = locs
      .map((l) => `<option value="${escapeHtml(l)}"></option>`)
      .join("");
  }

  function formBody() {
    return {
      title: els.fields.title.value,
      description: els.fields.description.value,
      location_name: els.fields.location_name.value,
      latitude: els.fields.latitude.value,
      longitude: els.fields.longitude.value,
      creation_time: els.fields.creation_time.value,
      notes: els.fields.notes.value,
    };
  }

  async function saveCurrent({ goNext = false } = {}) {
    if (!state.selectedId || state.saving) return false;
    state.saving = true;
    els.saveNextBtn.disabled = true;
    els.prevBtn.disabled = true;
    els.skipBtn.disabled = true;
    els.saveMsg.textContent = "Saving…";
    els.saveMsg.classList.remove("error");

    const previousId = state.selectedId;

    try {
      const res = await fetch(`/api/clips/${encodeURIComponent(state.selectedId)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(formBody()),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Save failed");

      const updated = data.clip;
      const oldIdx = state.clips.findIndex((c) => c.id === previousId);
      state.clips = state.clips.filter((c) => c.id !== previousId && c.id !== updated.id);
      if (oldIdx >= 0) state.clips.splice(Math.min(oldIdx, state.clips.length), 0, updated);
      else state.clips.push(updated);

      state.selectedId = updated.id;
      rebuildLocationHints();

      if (goNext) {
        // After save, advance within the current filter list
        const clips = filteredClips();
        const idx = clips.findIndex((c) => c.id === updated.id);
        if (idx >= 0 && idx < clips.length - 1) {
          selectClip(clips[idx + 1].id);
          els.saveMsg.textContent = "Saved — moved to next";
        } else {
          selectClip(updated.id);
          els.saveMsg.textContent = "Saved — end of list";
        }
      } else {
        selectClip(updated.id);
        els.saveMsg.textContent = "Saved";
      }
      return true;
    } catch (err) {
      els.saveMsg.textContent = String(err.message || err);
      els.saveMsg.classList.add("error");
      // restore button states for current clip
      ensureSelection();
      return false;
    } finally {
      state.saving = false;
      els.saveNextBtn.disabled = false;
    }
  }

  document.querySelectorAll(".chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      document.querySelectorAll(".chip").forEach((c) => c.classList.remove("active"));
      chip.classList.add("active");
      state.filter = chip.dataset.filter;
      ensureSelection();
    });
  });

  els.batchSelect.addEventListener("change", async () => {
    const id = els.batchSelect.value;
    await fetch("/api/batch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id }),
    });
    state.selectedId = null;
    await loadClips();
  });

  els.editorForm.addEventListener("submit", (e) => {
    e.preventDefault();
    saveCurrent({ goNext: true });
  });

  els.saveNextBtn.addEventListener("click", () => saveCurrent({ goNext: true }));
  els.prevBtn.addEventListener("click", () => moveSelection(-1));
  els.skipBtn.addEventListener("click", () => moveSelection(1));

  document.addEventListener("keydown", (e) => {
    const tag = (e.target && e.target.tagName) || "";
    const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";

    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
      e.preventDefault();
      saveCurrent({ goNext: true });
      return;
    }

    if (typing) return;

    if (e.key === "ArrowRight" || e.key === "j") {
      e.preventDefault();
      moveSelection(1);
    }
    if (e.key === "ArrowLeft" || e.key === "k") {
      e.preventDefault();
      moveSelection(-1);
    }
  });

  (async function init() {
    await loadBatches();
    await loadClips();
  })().catch((err) => {
    els.progressText.textContent = `Failed to load: ${err}`;
  });
})();
