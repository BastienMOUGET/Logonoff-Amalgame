// Logonoff — interface web locale (vanilla JS, pas de build).
//
// Tout passe par /api/* sur le même serveur. Les POST portent l'en-tête
// X-Logonoff: 1 (exigé par le serveur contre le CSRF). Le DOM est
// construit avec el() / textContent : aucune donnée n'est injectée en
// HTML (libellés de projets, noms de comptes…).
"use strict";

const state = { me: null, projects: [], timer: null };

// ── utilitaires ───────────────────────────────────────

function el(tag, attrs, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") n.className = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else if (k === "value") n.value = v;
    else if (k === "checked") n.checked = !!v;
    else n.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    n.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return n;
}

async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Logonoff": "1" },
    body: JSON.stringify(body),
  };
  const r = await fetch("/api/" + path, opt);
  let j = {};
  try { j = await r.json(); } catch (_) { /* corps vide */ }
  if (!r.ok) throw new Error(j.error || r.status + " " + r.statusText);
  return j;
}

function toast(msg, error) {
  const t = document.getElementById("toast");
  t.textContent = msg;
  t.className = "toast" + (error ? " error" : "");
  t.hidden = false;
  clearTimeout(toast.h);
  toast.h = setTimeout(() => { t.hidden = true; }, error ? 6000 : 2500);
}

async function act(fn, okMsg) {
  try {
    await fn();
    if (okMsg) toast(okMsg);
    return true;
  } catch (e) {
    toast(e.message, true);
    return false;
  }
}

// Durées : secondes → "7 h 05"
function dur(sec) {
  const neg = sec < 0;
  const m = Math.round(Math.abs(sec) / 60);
  const s = Math.floor(m / 60) + " h " + String(m % 60).padStart(2, "0");
  return neg ? "−" + s : s;
}

function signed(sec) {
  return (sec >= 0 ? "+" : "") + dur(sec);
}

// minutes ↔ "HH:MM" (objectifs)
const minToHm = (m) => String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
function hmToMin(s) {
  const p = /^(\d{1,2}):(\d{2})$/.exec(s || "");
  return p ? Number(p[1]) * 60 + Number(p[2]) : NaN;
}

const DAYS = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"];

function isoDate(d) {
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
}

function addDays(date, n) {
  const d = new Date(date + "T12:00:00");
  d.setDate(d.getDate() + n);
  return isoDate(d);
}

function longDate(date) {
  return new Date(date + "T12:00:00").toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
}

function projectName(id) {
  if (id === -1) return "Perso (non compté)";
  if (!id) return "Sans projet";
  const p = state.projects.find((x) => x.id === id);
  return p ? (p.code + (p.label ? " — " + p.label : "")) : "Projet #" + id;
}

async function loadProjects() {
  state.projects = await api("projects");
}

function projectSelect(selected, onchange, withPerso) {
  const s = el("select", { onchange },
    el("option", { value: "0" }, "Sans projet"),
    withPerso ? el("option", { value: "-1" }, "Perso (non compté)") : null,
    state.projects.filter((p) => p.active || p.id === selected)
      .map((p) => el("option", { value: String(p.id) }, p.code + (p.label ? " — " + p.label : ""))));
  s.value = String(selected || 0);
  return s;
}

// Barre 0–24 h des plages de présence d'une journée.
function timeline(day, nowSec) {
  const start = new Date(day.date + "T00:00:00").getTime() / 1000;
  const span = 86400;
  const bar = el("div", { class: "timeline", title: "Présence sur la journée" });
  for (const iv of day.intervals) {
    const seg = el("div", { class: "seg" + (iv.open ? " open" : ""), title: iv.startHm + " – " + (iv.open ? "en cours" : iv.endHm) });
    seg.style.left = Math.max(0, (iv.start - start) / span * 100) + "%";
    seg.style.width = Math.max(0.3, (iv.end - iv.start) / span * 100) + "%";
    bar.append(seg);
  }
  if (nowSec && nowSec >= start && nowSec < start + span) {
    const now = el("div", { class: "now", title: "Maintenant" });
    now.style.left = ((nowSec - start) / span * 100) + "%";
    bar.append(now);
  }
  const ticks = el("div", { class: "ticks" }, ["0 h", "6 h", "12 h", "18 h", "24 h"].map((t) => el("span", {}, t)));
  return el("div", {}, bar, ticks);
}

function projectTable(day) {
  if (!day.projects.length) return el("p", { class: "empty" }, "Aucun temps enregistré.");
  const total = day.projects.reduce((a, p) => a + p.seconds, 0) || 1;
  return el("table", { class: "list-proj" },
    el("tbody", {}, day.projects.map((p) => {
      const meter = el("div", { class: "meter" }, el("div", {}));
      meter.firstChild.style.width = (p.seconds / total * 100) + "%";
      return el("tr", {},
        el("td", {}, p.code ? el("strong", {}, p.code) : el("span", { class: "muted" }, "Sans projet"), p.label && p.code ? " " + p.label : ""),
        el("td", {}, meter),
        el("td", { class: "r num" }, dur(p.seconds)));
    })));
}

const ACTIVITIES = { poste: "Au poste", reunion: "Réunion", deplacement: "Déplacement", autre: "Autre travail", urgence: "Urgence / astreinte", perso: "Personnel (non compté)" };
const WORK_KINDS = ["reunion", "deplacement", "urgence", "autre"];
const BREAKS = { repas: "Repas", perso: "Absence personnelle" };

// Carte « absences à qualifier » : chaque trou est découpable en segments
// consécutifs (réunion pour tel projet jusqu'à 12:30, puis repas…).
function pendingCard(day) {
  if (!day.pending.length) return null;
  return el("div", { class: "card attention" },
    el("h2", {}, "Absences à qualifier"),
    el("p", { class: "hint" }, "Vous n'étiez pas au poste. Indiquez ce que vous faisiez : une réunion ou un déplacement compte comme du travail, un repas sert de pause déjeuner."),
    day.pending.map((g) => absenceEditor(day.date, g)));
}

function absenceEditor(date, gap) {
  const box = el("div", { class: "absence" });
  const segs = el("div", {});
  const kindSelect = (v) => {
    const k = el("select", {},
      el("optgroup", { label: "Travail" }, WORK_KINDS.map((x) => el("option", { value: x }, ACTIVITIES[x]))),
      el("optgroup", { label: "Pause" }, Object.keys(BREAKS).map((x) => el("option", { value: x }, BREAKS[x]))));
    k.value = v;
    return k;
  };
  const addSeg = (kind, until) => {
    const k = kindSelect(kind);
    const p = projectSelect(0);
    const u = el("input", { type: "time", value: until });
    const sync = () => { p.disabled = k.value in BREAKS; };
    k.addEventListener("change", sync);
    sync();
    const row = el("div", { class: "row seg-row" }, el("span", { class: "muted small seg-from" }), k, p, el("span", { class: "muted small" }, "jusqu'à"), u,
      el("button", { class: "small", title: "Retirer", onclick: () => { if (segs.children.length > 1) { row.remove(); refreshFrom(); } } }, "×"));
    row._get = () => ({ kind: k.value, projectId: Number(p.value), end: u.value });
    u.addEventListener("change", refreshFrom);
    segs.append(row);
    refreshFrom();
  };
  const refreshFrom = () => {
    let from = gap.startHm;
    for (const r of segs.children) {
      r.querySelector(".seg-from").textContent = "de " + from;
      from = r._get().end;
    }
  };
  addSeg("reunion", gap.endHm);
  box.append(
    el("div", { class: "row spread" },
      el("strong", {}, gap.startHm + " → " + gap.endHm + " (" + dur(gap.seconds) + ")"),
      el("div", { class: "row" },
        el("button", { class: "small", onclick: () => {
          // The last segment now stops halfway through what is left; the
          // new one runs to the end of the absence.
          const last = segs.lastElementChild;
          let from = gap.startHm;
          for (const r of segs.children) { if (r !== last) from = r._get().end || from; }
          const a = hmToMin(from), b = hmToMin(gap.endHm);
          if (!isNaN(a) && !isNaN(b) && b - a >= 10) {
            last.querySelector("input").value = minToHm(Math.round((a + (b - a) / 2) / 5) * 5);
          }
          addSeg("repas", gap.endHm);
        } }, "+ Découper"),
        el("button", { class: "small primary", onclick: () => {
          let from = gap.startHm;
          const segments = [];
          for (const r of segs.children) {
            const v = r._get();
            if (!v.end) { toast("Indiquez l'heure de fin de chaque segment", true); return; }
            segments.push({ start: from, end: v.end, kind: v.kind, projectId: v.projectId });
            from = v.end;
          }
          if (from !== gap.endHm && !confirm("Les segments s'arrêtent à " + from + " au lieu de " + gap.endHm + ". Le reste restera à qualifier. Continuer ?")) return;
          act(() => api("qualify", { date, segments }), "Absence qualifiée").then(() => render());
        } }, "Valider"))),
    segs);
  return box;
}

// Répartition de la journée entre imputations, modifiable. Une fois
// enregistrée, elle remplace le calcul automatique (rapport, export).
function allocationEditor(day) {
  const rows = el("tbody", {});
  const totalCell = el("td", { class: "r num" });
  const durInput = (sec) => el("input", { type: "text", class: "num dur", value: minToHm(Math.round(sec / 60)), placeholder: "h:mm", inputmode: "numeric" });
  const parse = (v) => {
    const t = (v || "").trim().replace(",", ".");
    if (/^\d+:\d{1,2}$/.test(t)) { const [h, m] = t.split(":").map(Number); return m < 60 ? h * 60 + m : NaN; }
    if (/^\d+(\.\d+)?$/.test(t)) return Math.round(Number(t) * 60);   // heures décimales : 7,5
    return t === "" ? 0 : NaN;
  };
  const autoOf = (pid) => (day.autoProjects.find((x) => x.projectId === pid) || { seconds: 0 }).seconds;
  const refresh = () => {
    let total = 0, bad = false;
    for (const r of rows.children) { const m = parse(r._dur.value); if (isNaN(m)) bad = true; else total += m; }
    totalCell.textContent = bad ? "?" : dur(total * 60);
    totalCell.className = "r num " + (bad ? "neg" : (Math.abs(total * 60 - day.worked) <= 60 ? "pos" : "warn"));
  };
  const addRow = (pid, sec, after) => {
    const sel = projectSelect(pid);
    const d = durInput(sec);
    d.addEventListener("input", refresh);
    const tr = el("tr", {}, el("td", {}, sel),
      el("td", { class: "r num muted" }, dur(autoOf(pid))),
      el("td", { class: "r" }, d),
      el("td", { class: "r" },
        el("button", { class: "small", title: "Scinder : la moitié du temps passe sur une nouvelle ligne", onclick: () => {
          const m = parse(d.value);
          if (isNaN(m) || m < 2) return;
          d.value = minToHm(m - Math.floor(m / 2));
          addRow(0, Math.floor(m / 2) * 60, tr);
          refresh();
        } }, "Découper"),
        " ",
        el("button", { class: "small", title: "Supprimer la ligne", onclick: () => { tr.remove(); refresh(); } }, "×")));
    tr._sel = sel;
    tr._dur = d;
    sel.addEventListener("change", () => { tr.children[1].textContent = dur(autoOf(Number(sel.value))); });
    if (after) after.after(tr); else rows.append(tr);
  };
  for (const p of day.projects) addRow(p.projectId, p.seconds);
  if (!day.projects.length) addRow(0, 0);
  refresh();

  const save = () => {
    const items = [];
    for (const r of rows.children) {
      const m = parse(r._dur.value);
      if (isNaN(m)) { toast("Durée invalide (format 7:30 ou 7,5)", true); return; }
      items.push({ projectId: Number(r._sel.value), minutes: m });
    }
    act(() => api("allocations", { date: day.date, items }), "Répartition enregistrée").then(() => render());
  };
  return el("div", { class: "card scroll" },
    el("div", { class: "row spread" },
      el("h2", {}, "Imputations de la journée"),
      day.overridden ? el("span", { class: "badge on" }, "saisie manuelle") : el("span", { class: "badge" }, "calcul automatique")),
    el("table", {},
      el("thead", {}, el("tr", {}, el("th", {}, "Imputation"), el("th", { class: "r" }, "Calculé"), el("th", { class: "r" }, "Imputé"), el("th", {}))),
      rows,
      el("tfoot", {}, el("tr", {},
        el("td", {}, el("button", { class: "small", onclick: () => addRow(0, 0) }, "+ Ligne")),
        el("td", { class: "r num muted" }, dur(day.worked)),
        totalCell, el("td", {})))),
    el("div", { class: "row" },
      el("button", { class: "primary", onclick: save }, "Enregistrer la répartition"),
      day.overridden ? el("button", { onclick: () => act(() => api("allocations", { date: day.date, items: [] }), "Retour au calcul automatique").then(() => render()) }, "Revenir au calcul automatique") : null),
    el("p", { class: "hint" }, "« Calculé » vient de la présence et des changements de projet (pause déduite non incluse). Une répartition enregistrée remplace ce calcul dans le rapport et l'export ; le total temps travaillé de la journée, lui, ne change pas."));
}

// ── vues ──────────────────────────────────────────────

const views = {};

views.today = async (root) => {
  await loadProjects();
  const [me, week, day] = await Promise.all([api("me"), api("week"), api("day")]);
  state.me = me;
  const remaining = week.remainingToday;
  const status = el("div", { class: "card" },
    el("div", { class: "row spread" },
      el("span", { class: "badge" + (me.present ? " on" : "") }, !me.present ? "Absent" : (me.projectId === -1 ? "Perso" : "Présent")),
      el("span", { class: "muted small" }, longDate(me.today))),
    el("div", { class: "grid" },
      el("div", {},
        el("div", { class: "muted small" }, "Aujourd'hui"),
        el("div", { class: "big" }, dur(day.worked)),
        el("div", { class: "muted small" }, "objectif " + dur(day.target) +
          (day.deduction ? " · pause déduite " + dur(day.deduction) : "") +
          (day.personal >= 60 ? " · perso " + dur(day.personal) + " non compté" : ""))),
      el("div", {},
        el("div", { class: "muted small" }, "Semaine"),
        el("div", { class: "big " + (week.balance >= 0 ? "pos" : "neg") }, signed(week.balance)),
        el("div", { class: "muted small" }, dur(week.workedToDate) + " sur " + dur(week.targetToDate) + " à date")),
      el("div", {},
        el("div", { class: "muted small" }, remaining > 0 ? "Reste à faire" : "Objectif atteint"),
        el("div", { class: "big" }, remaining > 0 ? dur(remaining) : "✓"),
        el("div", { class: "muted small" }, remaining > 0
          ? (week.endHm && me.projectId !== -1 ? "fin estimée à " + week.endHm + (week.lunchAhead >= 60 ? " (repas ~" + Math.round(week.lunchAhead / 60) + " min inclus)" : "") : (me.projectId === -1 ? "décompte en pause (perso)" : "hors présence"))
          : signed(-remaining) + " d'avance"))),
    timeline(day, me.now));

  const pick = el("div", { class: "projects-pick" },
    [{ id: 0, code: "Aucun projet", label: "" }, ...state.projects.filter((p) => p.active),
     { id: -1, code: "Perso", label: "Usage personnel : le temps n'est pas compté" }].map((p) =>
      el("button", {
        class: (p.id === me.projectId ? "current" : "") + (p.id === -1 ? " perso" : ""),
        title: p.label || "",
        onclick: () => act(() => api("switch", { projectId: p.id })).then(() => render()),
      }, p.code)));
  const projCard = el("div", { class: "card" + (me.projectId === -1 ? " perso-on" : "") },
    el("div", { class: "row spread" },
      el("h2", {}, "Je travaille sur…"),
      el("span", { class: "muted small" }, "En cours : " + projectName(me.projectId))),
    me.projectId === -1 ? el("p", { class: "hint" }, "Mode perso : votre présence n'est pas comptée. Cliquez sur un projet (ou « Aucun projet ») pour reprendre le travail.") : null,
    state.projects.length ? pick : el("p", { class: "empty" }, "Ajoutez vos numéros d'imputation dans l'onglet ",
      el("a", { href: "#projects" }, "Projets"), "."));

  const perProj = el("div", { class: "card" }, el("h2", {}, "Temps par projet aujourd'hui"), projectTable(day));
  root.append(...[el("h1", {}, "Bonjour " + me.display), status, pendingCard(day), projCard, perProj].filter(Boolean));
};

views.week = async (root, arg) => {
  const date = arg || (state.me ? state.me.today : isoDate(new Date()));
  const week = await api("week?date=" + date);
  const today = state.me ? state.me.today : isoDate(new Date());
  const rows = week.days.map((d) => el("tr", {
    class: "click" + (d.date === today ? " today" : ""),
    onclick: () => { location.hash = "#day/" + d.date; },
  },
    el("td", {}, DAYS[d.weekday - 1] + " " + d.date.slice(8) + "/" + d.date.slice(5, 7),
      d.pending ? el("span", { class: "dot", title: d.pending + " absence(s) à qualifier" }, " ●") : null),
    el("td", { class: "num" }, d.firstHm || "—"),
    el("td", { class: "num" }, d.lastHm || "—"),
    el("td", { class: "r num" }, d.worked ? dur(d.worked) : "—"),
    el("td", { class: "r num muted" }, d.target ? dur(d.target) : "—"),
    el("td", { class: "r num " + (d.worked - d.target >= 0 ? "pos" : "neg") },
      (d.worked || d.target) && d.date <= today ? signed(d.worked - d.target) : "")));
  root.append(
    el("div", { class: "row spread" },
      el("h1", {}, "Semaine du " + new Date(week.monday + "T12:00:00").toLocaleDateString("fr-FR", { day: "numeric", month: "long" })),
      el("div", { class: "row" },
        el("button", { onclick: () => { location.hash = "#week/" + addDays(week.monday, -7); } }, "← Précédente"),
        el("button", { onclick: () => { location.hash = "#week/" + today; } }, "Cette semaine"),
        el("button", { onclick: () => { location.hash = "#week/" + addDays(week.monday, 7); } }, "Suivante →"))),
    el("div", { class: "card scroll" },
      el("table", {},
        el("thead", {}, el("tr", {}, ["Jour", "Arrivée", "Départ"].map((h) => el("th", {}, h)),
          ["Travaillé", "Objectif", "Écart"].map((h) => el("th", { class: "r" }, h)))),
        el("tbody", {}, rows),
        el("tfoot", {}, el("tr", {},
          el("td", { colspan: "3" }, "Total"),
          el("td", { class: "r num" }, dur(week.worked)),
          el("td", { class: "r num muted" }, dur(week.target)),
          el("td", { class: "r num " + (week.balance >= 0 ? "pos" : "neg") }, signed(week.balance))))),
      el("p", { class: "hint" }, "L'écart total compare le temps travaillé aux objectifs des jours écoulés (aujourd'hui compris). Cliquez sur un jour pour le détail et les corrections.")));
};

views.day = async (root, arg) => {
  await loadProjects();
  const date = arg || (state.me ? state.me.today : isoDate(new Date()));
  const [day, switches, events] = await Promise.all([
    api("day?date=" + date), api("switches?date=" + date), api("events?date=" + date)]);
  const nav = el("div", { class: "row spread" },
    el("h1", {}, longDate(date)),
    el("div", { class: "row" },
      el("button", { onclick: () => { location.hash = "#day/" + addDays(date, -1); } }, "←"),
      el("input", { type: "date", value: date, onchange: (e) => { if (e.target.value) location.hash = "#day/" + e.target.value; } }),
      el("button", { onclick: () => { location.hash = "#day/" + addDays(date, 1); } }, "→")));

  const summary = el("div", { class: "card" },
    el("div", { class: "row spread" },
      el("div", {}, el("span", { class: "big" }, dur(day.worked)), el("span", { class: "muted" }, "  / " + dur(day.target))),
      el("div", { class: "muted small" },
        day.firstHm ? "de " + day.firstHm + " à " + day.lastHm : "aucune présence",
        day.deduction ? " · pause déduite " + dur(day.deduction) : "",
        day.lunchDeclared ? " · repas " + dur(day.lunchDeclared) : (day.longestBreak ? " · pause la plus longue " + dur(day.longestBreak) : ""),
        day.personal ? " · perso " + dur(day.personal) + " (non compté)" : "")),
    timeline(day, state.me && state.me.today === date ? state.me.now : 0));

  // Plages de présence (modifiables). Les cases à cocher servent à
  // rassembler plusieurs plages en une seule.
  const selected = new Set();
  const mergeBtn = el("button", { class: "small", disabled: true, title: "Une seule plage, du début de la première à la fin de la dernière : les trous entre elles sont comptés comme travaillés" });
  const refreshMerge = () => {
    mergeBtn.disabled = selected.size < 2;
    mergeBtn.textContent = selected.size >= 2 ? "Rassembler les " + selected.size + " plages" : "Rassembler (cochez 2 plages ou plus)";
  };
  mergeBtn.addEventListener("click", () => {
    const sel = day.intervals.filter((iv) => selected.has(iv.id));
    const first = Math.min(...sel.map((iv) => iv.start));
    const last = Math.max(...sel.map((iv) => iv.end));
    const covered = sel.reduce((t, iv) => t + (iv.end - iv.start), 0);
    const startHm = sel.find((iv) => iv.start === first).startHm;
    const endIv = sel.find((iv) => iv.end === last);
    const msg = "Rassembler " + sel.length + " plages en une seule, de " + startHm + " à " + (endIv.open ? "maintenant" : endIv.endHm) +
      " ?\n\nLes trous entre elles (" + dur(Math.max(0, last - first - covered)) + ") seront comptés comme travaillés.";
    if (confirm(msg)) act(() => api("intervals/merge", { date, ids: [...selected] }), "Plages rassemblées").then(() => render());
  });
  refreshMerge();
  const ivRows = day.intervals.map((iv) => {
    const pick = el("input", { type: "checkbox", title: "Sélectionner pour rassembler", onchange: (ev) => {
      if (ev.target.checked) selected.add(iv.id); else selected.delete(iv.id);
      refreshMerge();
    } });
    const s = el("input", { type: "time", value: iv.startHm });
    const e = el("input", { type: "time", value: iv.open ? "" : iv.endHm, disabled: iv.open, title: iv.open ? "Plage en cours" : "" });
    const a = el("select", {}, Object.keys(ACTIVITIES).map((x) => el("option", { value: x }, ACTIVITIES[x])));
    a.value = iv.activity || "poste";
    const p = projectSelect(iv.projectId);
    p.title = "« Sans projet » = selon les changements de projet";
    const n = el("input", { class: "note", value: iv.note || "", maxlength: "500", placeholder: "Note (justification, ticket…)" });
    return el("tr", { class: iv.activity === "perso" ? "row-perso" : "" },
      el("td", {}, el("div", { class: "row" }, pick, s)), el("td", {}, e),
      el("td", { class: "small" },
        el("div", { class: "row" }, a, p),
        el("div", { class: "row" }, n),
        el("div", { class: "muted" }, iv.manual ? "saisie manuelle" : (iv.startReason + " → " + (iv.open ? "en cours" : iv.endReason)))),
      el("td", { class: "r" },
        el("button", { class: "small", onclick: () => act(() => api("intervals/" + iv.id, { date, start: s.value, end: iv.open ? "" : e.value, activity: a.value, projectId: Number(p.value), note: n.value }), "Plage modifiée").then(() => render()) }, "Enregistrer"),
        " ",
        el("button", { class: "small", title: "Couper la plage en deux à une heure donnée", onclick: () => {
          const at = prompt("Découper la plage " + iv.startHm + " – " + (iv.open ? "maintenant" : iv.endHm) + " à quelle heure ? (HH:MM)");
          if (at) act(() => api("intervals/" + iv.id + "/split", { date, at: at.trim() }), "Plage découpée").then(() => render());
        } }, "Découper"),
        " ",
        el("button", { class: "small danger", onclick: () => { if (confirm("Supprimer cette plage ?")) act(() => api("intervals/" + iv.id + "/delete", {}), "Plage supprimée").then(() => render()); } }, "Supprimer")));
  });
  const ns = el("input", { type: "time" });
  const ne = el("input", { type: "time" });
  const na = el("select", {}, Object.keys(ACTIVITIES).map((x) => el("option", { value: x }, ACTIVITIES[x])));
  const nap = projectSelect(0);
  const intervals = el("div", { class: "card scroll" },
    el("div", { class: "row spread" }, el("h2", {}, "Plages de présence"), mergeBtn),
    el("table", {},
      el("thead", {}, el("tr", {}, el("th", {}, "Début"), el("th", {}, "Fin"), el("th", {}, "Activité · imputation"), el("th", {}))),
      el("tbody", {}, ivRows.length ? ivRows : el("tr", {}, el("td", { colspan: "4", class: "empty" }, "Aucune plage."))),
      el("tfoot", {}, el("tr", {},
        el("td", {}, ns), el("td", {}, ne), el("td", {}, el("div", { class: "row" }, na, nap)),
        el("td", { class: "r" }, el("button", { class: "small primary", onclick: () => act(() => api("intervals", { date, start: ns.value, end: ne.value, activity: na.value, projectId: Number(nap.value) }), "Plage ajoutée").then(() => render()) }, "Ajouter"))))),
    el("p", { class: "hint" }, "Fin avant début = le lendemain. Projet « Sans projet » = selon les changements de projet ci-dessous. Pour compter un passage sur un autre poste, cochez les plages qui l'encadrent puis « Rassembler » (elles doivent être sur le même projet)."));

  const breaks = day.breaks.length ? el("div", { class: "card" },
    el("h2", {}, "Pauses déclarées"),
    el("table", {}, el("tbody", {}, day.breaks.map((b) => el("tr", {},
      el("td", { class: "num" }, b.startHm + " – " + b.endHm),
      el("td", {}, BREAKS[b.kind] || b.kind),
      el("td", { class: "r num" }, dur(b.seconds)),
      el("td", { class: "r" }, el("button", { class: "small danger", onclick: () => act(() => api("breaks/" + b.id + "/delete", {}), "Pause supprimée").then(() => render()) }, "Supprimer"))))))) : null;

  // Changements de projet
  const swRows = switches.map((sw) => {
    const sel = projectSelect(sw.projectId, undefined, true);
    const t = el("input", { type: "time", value: sw.hm });
    const before = sw.date !== date;
    return el("tr", {},
      el("td", {}, before ? el("span", { class: "muted small" }, "depuis le " + sw.date + " ") : null, before ? null : t),
      el("td", {}, sel),
      el("td", { class: "r" }, before ? null : [
        el("button", { class: "small", onclick: () => act(() => api("switches/" + sw.id, { projectId: Number(sel.value), date, time: t.value }), "Changement modifié").then(() => render()) }, "Enregistrer"),
        " ",
        el("button", { class: "small danger", onclick: () => act(() => api("switches/" + sw.id + "/delete", {}), "Changement supprimé").then(() => render()) }, "Supprimer")]));
  });
  const nt = el("input", { type: "time" });
  const np = projectSelect(0, undefined, true);
  const sws = el("div", { class: "card scroll" },
    el("h2", {}, "Changements de projet"),
    el("table", {},
      el("thead", {}, el("tr", {}, el("th", {}, "À partir de"), el("th", {}, "Projet"), el("th", {}))),
      el("tbody", {}, swRows.length ? swRows : el("tr", {}, el("td", { colspan: "3", class: "empty" }, "Aucun changement : tout est « sans projet »."))),
      el("tfoot", {}, el("tr", {},
        el("td", {}, nt), el("td", {}, np),
        el("td", { class: "r" }, el("button", { class: "small primary", onclick: () => act(() => api("switches", { projectId: Number(np.value), date, time: nt.value }), "Changement ajouté").then(() => render()) }, "Ajouter"))))),
    el("p", { class: "hint" }, "Le temps de présence est réparti entre les projets selon ces changements."));

  const per = allocationEditor(day);

  const evs = el("details", { class: "card" },
    el("summary", {}, "Journal brut des événements (" + events.length + ")"),
    events.length ? el("table", {}, el("tbody", {}, events.map((ev) =>
      el("tr", {}, el("td", { class: "num" }, ev.hm), el("td", {}, ev.kind),
        el("td", { class: "muted small" }, ev.session >= 0 ? "session " + ev.session : ""),
        el("td", { class: "muted small" }, ev.location))))) : el("p", { class: "empty" }, "Aucun événement."));

  root.append(...[nav, summary, pendingCard(day), intervals, breaks, sws, per, evs].filter(Boolean));
};

views.projects = async (root) => {
  await loadProjects();
  const code = el("input", { class: "code", placeholder: "N° imputation", maxlength: "64" });
  const label = el("input", { class: "wide", placeholder: "Description", maxlength: "200" });
  const add = el("form", {
    class: "row",
    onsubmit: (e) => {
      e.preventDefault();
      act(() => api("projects", { code: code.value, label: label.value }), "Projet ajouté").then((ok) => { if (ok) render(); });
    },
  }, code, el("div", { class: "row", style: null }, label), el("button", { class: "primary", type: "submit" }, "Ajouter"));
  add.children[1].style.flex = "1";

  const rows = state.projects.map((p) => {
    const c = el("input", { class: "code", value: p.code, maxlength: "64" });
    const l = el("input", { class: "wide", value: p.label, maxlength: "200" });
    const a = el("input", { type: "checkbox", checked: p.active });
    return el("tr", {},
      el("td", {}, c), el("td", {}, l),
      el("td", {}, el("label", { class: "row" }, a, "actif")),
      el("td", { class: "r" }, el("button", { class: "small", onclick: () => act(() => api("projects/" + p.id, { code: c.value, label: l.value, active: a.checked }), "Projet enregistré").then(() => render()) }, "Enregistrer")));
  });
  root.append(
    el("h1", {}, "Projets"),
    el("div", { class: "card" }, el("h2", {}, "Nouveau projet"), add),
    el("div", { class: "card scroll" },
      el("table", {},
        el("thead", {}, el("tr", {}, el("th", {}, "Imputation"), el("th", {}, "Description"), el("th", {}, "État"), el("th", {}))),
        el("tbody", {}, rows.length ? rows : el("tr", {}, el("td", { colspan: "4", class: "empty" }, "Aucun projet pour l'instant.")))),
      el("p", { class: "hint" }, "Un projet inactif n'apparaît plus dans le sélecteur mais garde son historique.")));
};

views.report = async (root, arg) => {
  const today = state.me ? state.me.today : isoDate(new Date());
  const [qFrom, qTo] = (arg || "").split("_");
  const from = qFrom || today.slice(0, 8) + "01";
  const to = qTo || today;
  const rep = await api("report?from=" + from + "&to=" + to);
  const f = el("input", { type: "date", value: from });
  const t = el("input", { type: "date", value: to });
  const totals = new Map();
  for (const r of rep.rows) {
    const k = r.projectId;
    const cur = totals.get(k) || { code: r.code, label: r.label, seconds: 0, days: new Set() };
    cur.seconds += r.seconds;
    cur.days.add(r.date);
    totals.set(k, cur);
  }
  const all = [...totals.values()].sort((a, b) => b.seconds - a.seconds);
  const sum = all.reduce((a, x) => a + x.seconds, 0);
  root.append(
    el("h1", {}, "Rapport par imputation"),
    el("div", { class: "card row" },
      el("label", { class: "field" }, el("span", {}, "Du"), f),
      el("label", { class: "field" }, el("span", {}, "Au"), t),
      el("button", { class: "primary", onclick: () => { location.hash = "#report/" + f.value + "_" + t.value; } }, "Afficher"),
      el("a", { class: "btn primary-link", href: "/api/report.xlsx?from=" + from + "&to=" + to }, "Exporter Excel"),
      el("a", { class: "btn", href: "/api/report.csv?from=" + from + "&to=" + to }, "CSV"),
      el("a", { class: "btn", href: "/api/export?from=" + from + "&to=" + to, title: "Format réglable dans Paramètres → Export" }, "Export Espace Temps")),
    el("div", { class: "card scroll" },
      el("table", {},
        el("thead", {}, el("tr", {}, el("th", {}, "Imputation"), el("th", {}, "Description"), el("th", { class: "r" }, "Jours"), el("th", { class: "r" }, "Heures"), el("th", { class: "r" }, "Part"))),
        el("tbody", {}, all.length ? all.map((x) => el("tr", {},
          el("td", {}, x.code ? el("strong", {}, x.code) : el("span", { class: "muted" }, "—")),
          el("td", {}, x.label),
          el("td", { class: "r num" }, x.days.size),
          el("td", { class: "r num" }, dur(x.seconds)),
          el("td", { class: "r num muted" }, Math.round(x.seconds / (sum || 1) * 100) + " %"))) :
          el("tr", {}, el("td", { colspan: "5", class: "empty" }, "Rien sur cette période."))),
        el("tfoot", {}, el("tr", {}, el("td", { colspan: "3" }, "Total"), el("td", { class: "r num" }, dur(sum)), el("td", {}))))));
};

views.settings = async (root) => {
  const [s, net, mach] = await Promise.all([api("settings"), api("network"), api("machine")]);
  const display = el("input", { value: s.display, maxlength: "100" });
  const targets = s.targets.map((m) => el("input", { type: "time", value: minToHm(m), step: "300" }));
  const lunchMin = el("input", { type: "number", min: "0", max: "240", value: s.lunchMin });
  const lunchAfter = el("input", { type: "time", value: minToHm(s.lunchAfter) });
  const lunchFrom = el("input", { type: "time", value: minToHm(s.lunchFrom) });
  const lunchTo = el("input", { type: "time", value: minToHm(s.lunchTo) });
  const lunchAvg = el("input", { type: "number", min: "1", max: "60", value: s.lunchAvgDays });
  const mode = el("select", {}, el("option", { value: "week" }, "Objectif de la semaine (à date)"), el("option", { value: "day" }, "Objectif du jour"), el("option", { value: "off" }, "Désactivées"));
  mode.value = s.notifyMode;
  const how = el("select", {}, el("option", { value: "toast" }, "Notification Windows"), el("option", { value: "message" }, "Boîte de message"));
  how.value = s.notifyHow;
  const ahead = el("input", { type: "number", min: "0", max: "240", value: s.notifyAhead });
  const absMin = el("input", { type: "number", min: "1", max: "480", value: s.absenceMin });
  const outside = el("select", {}, el("option", { value: "count" }, "Compté normalement"), el("option", { value: "perso" }, "Considéré comme personnel"));
  outside.value = s.outsideMode;
  const workFrom = el("input", { type: "time", value: minToHm(s.workFrom) });
  const workTo = el("input", { type: "time", value: minToHm(s.workTo) });
  const ask = el("input", { type: "checkbox", checked: s.askOnReturn });

  const save = () => act(async () => {
    const t = targets.map((i) => hmToMin(i.value || "00:00"));
    if (t.some(isNaN)) throw new Error("objectif journalier invalide");
    await api("settings", {
      display: display.value, targets: t,
      lunchMin: Number(lunchMin.value), lunchAfter: hmToMin(lunchAfter.value),
      lunchFrom: hmToMin(lunchFrom.value), lunchTo: hmToMin(lunchTo.value), lunchAvgDays: Number(lunchAvg.value),
      notifyMode: mode.value, notifyHow: how.value, notifyAhead: Number(ahead.value),
      absenceMin: Number(absMin.value), askOnReturn: ask.checked,
      outsideMode: outside.value, workFrom: hmToMin(workFrom.value), workTo: hmToMin(workTo.value),
    });
  }, "Paramètres enregistrés");

  const field = (label, input) => el("label", { class: "field" }, el("span", {}, label), input);
  const personal = el("div", { class: "card" },
    el("h2", {}, "Mes paramètres"),
    el("div", { class: "form-grid" }, field("Nom affiché", display)),
    el("h2", {}, "Objectifs journaliers"),
    el("div", { class: "form-grid" }, targets.map((i, k) => field(DAYS[k], i))),
    el("h2", {}, "Pause déjeuner"),
    el("div", { class: "form-grid" },
      field("Durée minimale (min, 0 = aucune)", lunchMin),
      field("Si plus de … travaillées", lunchAfter),
      field("Pause commençant après", lunchFrom),
      field("et avant", lunchTo),
      field("Fin estimée : moyenne des N derniers repas", lunchAvg)),
    el("p", { class: "hint" }, "Si la plus longue pause commencée dans cette plage est plus courte que la durée minimale, la différence est déduite du temps de la journée. Tant que le repas n'est pas pris, l'heure de fin estimée inclut la durée moyenne de vos derniers repas (au moins la durée minimale)."),
    el("h2", {}, "Usage personnel"),
    el("div", { class: "form-grid" },
      field("Hors horaires, le temps au poste est", outside),
      field("Horaires de travail : de", workFrom),
      field("à", workTo)),
    el("p", { class: "hint" }, "Avec « personnel » : le temps au poste en dehors de ces horaires (et les jours sans objectif) n'est pas compté, sauf s'il est marqué « Urgence / astreinte », réunion, etc. À tout moment, le bouton « Perso » de l'accueil met en pause le décompte."),
    el("h2", {}, "Absences"),
    el("div", { class: "form-grid" },
      field("À qualifier au-delà de (min)", absMin),
      el("label", { class: "row small" }, ask, "Me demander ce que je faisais quand je reviens")),
    el("h2", {}, "Fin de journée"),
    el("div", { class: "form-grid" },
      field("Prévenir quand est atteint", mode),
      field("Type", how),
      field("Préavis (min, 0 = aucun)", ahead)),
    el("div", { class: "row" },
      el("button", { class: "primary", onclick: save }, "Enregistrer"),
      el("button", { onclick: () => act(() => api("test-notify", {}), "Notification envoyée") }, "Tester la notification")));

  const exHeader = el("input", { class: "wide", value: s.exportHeader, maxlength: "500" });
  const exLine = el("input", { class: "wide", value: s.exportLine, maxlength: "500" });
  const exEnc = el("select", {}, el("option", { value: "utf8" }, "UTF-8"), el("option", { value: "ansi" }, "Windows-1252 (ANSI)"));
  exEnc.value = s.exportEncoding;
  const exSkip = el("input", { type: "checkbox", checked: s.exportSkipNone });
  const exportCard = el("div", { class: "card" },
    el("h2", {}, "Export (Espace Temps)"),
    el("p", { class: "hint" }, "Une ligne par jour et par projet. Jetons : {date} (JJ/MM/AAAA), {date_iso}, {jour}, {code}, {libelle}, {heures} (7,50), {heures_point} (7.50), {hhmm} (07:30), {minutes}, {compte}, {nom}."),
    el("div", { class: "form-grid one" },
      field("Ligne d'en-tête (vide = aucune)", exHeader),
      field("Modèle de ligne", exLine)),
    el("div", { class: "form-grid" },
      field("Encodage", exEnc),
      el("label", { class: "row small" }, exSkip, "Ignorer le temps sans projet")),
    el("button", { class: "primary", onclick: () => act(() => api("settings", { exportHeader: exHeader.value, exportLine: exLine.value, exportEncoding: exEnc.value, exportSkipNone: exSkip.checked }), "Format d'export enregistré") }, "Enregistrer"));

  const label = el("input", { value: net.label, placeholder: "ex. Bureau, Télétravail", maxlength: "64" });
  const network = el("div", { class: "card" },
    el("h2", {}, "Lieux"),
    net.key ? el("div", {},
      el("p", { class: "small muted" }, "Réseau actuel : passerelle " + net.ip + (net.mac ? " (" + net.mac + ")" : "")),
      el("div", { class: "row" }, label,
        el("button", { onclick: () => act(() => api("network", { key: net.key, label: label.value }), "Lieu enregistré").then(() => render()) }, "Nommer ce réseau")))
      : el("p", { class: "empty" }, "Pas de réseau détecté."),
    net.known.length ? el("table", {}, el("tbody", {}, net.known.map((k) => el("tr", {},
      el("td", {}, k.label), el("td", { class: "muted small num" }, k.key),
      el("td", { class: "r" }, el("button", { class: "small danger", onclick: () => act(() => api("network", { key: k.key, label: "" }), "Lieu oublié").then(() => render()) }, "Oublier")))))) : null);

  const port = el("input", { type: "number", min: "1024", max: "65535", value: mach.port, disabled: !mach.admin });
  const hb = el("input", { type: "number", min: "10", max: "600", value: mach.heartbeatSec, disabled: !mach.admin });
  const machine = el("div", { class: "card" },
    el("h2", {}, "Poste (administrateurs)"),
    el("div", { class: "form-grid" }, field("Port de l'interface", port), field("Battement (s)", hb)),
    mach.admin ? el("button", { onclick: () => act(() => api("machine", { port: Number(port.value), heartbeatSec: Number(hb.value) }), "Enregistré — le port change au redémarrage du service") }, "Enregistrer")
      : el("p", { class: "hint" }, "Réservé aux membres du groupe Administrateurs de ce PC."),
    el("p", { class: "hint" }, "Utilisateurs suivis sur ce poste : " + mach.users.map((u) => u.display || u.account).join(", ")));

  const install = el("div", { class: "card" },
    el("h2", {}, "Application"),
    el("p", { class: "small" }, "Pour l'ouvrir comme une application : menu du navigateur (Edge ou Chrome) → « Installer Logonoff ». Elle apparaît alors dans le menu Démarrer et la barre des tâches."));

  root.append(el("h1", {}, "Paramètres"), personal, exportCard, network, machine, install);
};

// ── routeur ───────────────────────────────────────────

async function render() {
  const [name, arg] = (location.hash.slice(1) || "today").split("/");
  const view = views[name] ? name : "today";
  document.querySelectorAll("#tabs a").forEach((a) => a.classList.toggle("active", a.dataset.view === view));
  const root = document.getElementById("view");
  const next = el("div", {});
  try {
    if (!state.me) state.me = await api("me");
    document.getElementById("who").textContent = state.me.display + (state.me.dev ? " · dev" : "");
    await views[view](next, arg);
  } catch (e) {
    next.replaceChildren(el("div", { class: "card" }, el("h2", {}, "Erreur"), el("p", {}, e.message)));
  }
  root.replaceChildren(...next.childNodes);
  clearInterval(state.timer);
  if (view === "today") state.timer = setInterval(() => { if (!document.hidden) render(); }, 30000);
}

window.addEventListener("hashchange", render);
document.addEventListener("visibilitychange", () => { if (!document.hidden && (location.hash || "#today").startsWith("#today")) render(); });
render();

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => { /* PWA optionnelle */ });
}
