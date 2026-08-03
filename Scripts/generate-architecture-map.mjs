#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = path.join(root, "docs", "architecture.json");
const outputPath = path.join(root, "docs", "architecture.html");
const data = JSON.parse(fs.readFileSync(sourcePath, "utf8"));

const escapeHTML = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

const slug = (value) =>
  String(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

const list = (items, className = "") =>
  `<ul class="${className}">${items.map((item) => `<li>${escapeHTML(item)}</li>`).join("")}</ul>`;

const pill = (text, tone = "") =>
  `<span class="pill ${tone}">${escapeHTML(text)}</span>`;

const iconForLayer = {
  presentation: "􀫊",
  core: "􀤆",
  inference: "􀇳"
};

const components = data.components
  .filter((component) => component.layer !== "inference" || component.id !== "permissions")
  .map((component) => {
    const paths = component.paths ?? (component.path ? [component.path] : []);
    const responsibilities = component.responsibilities ?? component.items?.map((item) =>
      typeof item === "string" ? item : `${item.name}: ${item.required_for}`
    ) ?? [];
    const searchable = [
      component.name,
      component.kind,
      component.layer,
      ...paths,
      ...responsibilities
    ].join(" ").toLowerCase();
    const dependencies = component.depends_on?.length
      ? `        <div class="depends"><span>Depends on</span>${component.depends_on.map((item) => pill(item)).join("")}</div>`
      : "";
    return `
      <article class="component-card" data-search="${escapeHTML(searchable)}" data-layer="${escapeHTML(component.layer)}">
        <div class="component-topline">
          ${pill(component.layer, component.layer)}
          <span class="component-kind">${escapeHTML(component.kind)}</span>
        </div>
        <h3>${escapeHTML(component.name)}</h3>
        ${paths.map((item) => `<code>${escapeHTML(item)}</code>`).join("")}
        ${responsibilities.length ? list(responsibilities) : ""}
${dependencies}
      </article>`;
  }).join("");

const flow = data.runtime_flows.find((item) => item.id === "dictation");
const flowSteps = flow.steps.map((step, index) => `
  <div class="flow-step">
    <span class="flow-index">${String(index + 1).padStart(2, "0")}</span>
    <span>${escapeHTML(step)}</span>
  </div>
`).join("");

const layerCards = data.architecture.layers.map((layer) => `
  <article class="layer-card ${escapeHTML(layer.id)}">
    <div class="layer-icon">${iconForLayer[layer.id] ?? "•"}</div>
    <div>
      <span class="eyebrow">${escapeHTML(layer.root)}</span>
      <h3>${escapeHTML(layer.name)}</h3>
      <p>${escapeHTML(layer.owns.slice(0, 3).join(" · "))}</p>
    </div>
  </article>
`).join('<div class="layer-arrow">↓</div>');

const modelRows = data.model_policy.experiences.map((experience) => `
  <tr>
    <td><strong>${escapeHTML(experience.product_name)}</strong>${experience.first_run_default ? pill("First-run default", "good") : ""}</td>
    <td><code>${escapeHTML(experience.mode)}</code></td>
    <td>${experience.models.map((model) => pill(model, model)).join("")}</td>
    <td>${experience.live_preview ? "Live" : "On release"}</td>
    <td>${escapeHTML(experience.final_authority)}</td>
    <td>${escapeHTML(experience.exposure ?? experience.fallback ?? "Product mode")}</td>
  </tr>
`).join("");

const concurrency = data.concurrency.domains.map((domain) => `
  <article class="lane">
    <div>
      <span class="lane-dot"></span>
      <h3>${escapeHTML(domain.name)}</h3>
      <p>${escapeHTML(domain.type ?? "Actor-isolated")}</p>
    </div>
    ${list(domain.owns)}
  </article>
`).join("");

const invariantCards = data.invariants.map((item) => `
  <article class="invariant">
    <span class="check">✓</span>
    <div>
      <h3>${escapeHTML(item.rule)}</h3>
      <p>${escapeHTML(item.why)}</p>
      <code>${escapeHTML(item.id)}</code>
    </div>
  </article>
`).join("");

const agentRoutes = data.agent_routing.map((route) => `
  <details class="route">
    <summary>
      <span>${escapeHTML(route.change)}</span>
      <span class="chevron">›</span>
    </summary>
    <div class="route-body">
      <div>
        <span class="eyebrow">Start here</span>
        ${route.start_at.map((item) => `<code>${escapeHTML(item)}</code>`).join("")}
      </div>
      <div>
        <span class="eyebrow">Prove it here</span>
        ${route.tests.map((item) => `<code>${escapeHTML(item)}</code>`).join("")}
      </div>
      ${route.warning ? `<p class="warning">${escapeHTML(route.warning)}</p>` : ""}
    </div>
  </details>
`).join("");

const boundaries = data.external_boundaries.map((boundary) => {
  const disabled = boundary.enabled === false;
  return `
    <article class="boundary ${disabled ? "disabled" : ""}">
      <div class="boundary-status">${disabled ? "OFF" : boundary.enabled === true ? "ON" : "GATED"}</div>
      <h3>${escapeHTML(boundary.name)}</h3>
      <p>${escapeHTML(boundary.direction)} · ${escapeHTML(boundary.when)}</p>
      <small>${escapeHTML(boundary.reason ?? boundary.payload ?? boundary.enabled)}</small>
    </article>`;
}).join("");

const testCards = data.tests.map((test) => `
  <article class="test-card">
    <span class="eyebrow">${escapeHTML(test.kind)}</span>
    <h3>${escapeHTML(test.target)}</h3>
    ${list(test.covers)}
  </article>
`).join("");

const fileRows = data.file_index.map((item) => `
  <tr>
    <td><code>${escapeHTML(item.path)}</code></td>
    <td>${escapeHTML(item.role)}</td>
  </tr>
`).join("");

const embeddedJSON = JSON.stringify(data).replaceAll("<", "\\u003c");
const navItems = [
  ["overview", "Overview"],
  ["flow", "Runtime flow"],
  ["models", "Model policy"],
  ["concurrency", "Concurrency"],
  ["components", "Components"],
  ["invariants", "Guardrails"],
  ["agents", "Agent routing"],
  ["boundaries", "Trust boundaries"],
  ["tests", "Tests"],
  ["files", "File map"]
];

const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <title>${escapeHTML(data.document.title)}</title>
  <style>
    :root {
      --bg: #090b0f;
      --panel: rgba(21, 24, 31, .82);
      --panel-solid: #15181f;
      --raised: #1b1f28;
      --line: rgba(255, 255, 255, .09);
      --line-strong: rgba(255, 255, 255, .16);
      --text: #f5f7fb;
      --muted: #969eae;
      --faint: #606979;
      --blue: #0a84ff;
      --cyan: #59d6ff;
      --green: #32d583;
      --purple: #a78bfa;
      --orange: #ffb454;
      --red: #ff6467;
      --radius: 18px;
      --mono: ui-monospace, "SFMono-Regular", Menlo, Monaco, Consolas, monospace;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      color: var(--text);
      background:
        radial-gradient(circle at 78% -10%, rgba(10,132,255,.20), transparent 31rem),
        radial-gradient(circle at 5% 30%, rgba(89,214,255,.08), transparent 30rem),
        var(--bg);
      font-family: var(--sans);
      line-height: 1.45;
    }
    a { color: inherit; text-decoration: none; }
    code {
      display: block;
      width: fit-content;
      max-width: 100%;
      overflow-wrap: anywhere;
      color: #c8d1df;
      font: 11px/1.55 var(--mono);
      background: rgba(255,255,255,.055);
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 3px 7px;
      margin: 4px 0;
    }
    .shell { display: grid; grid-template-columns: 220px minmax(0, 1fr); min-height: 100vh; }
    aside {
      position: sticky;
      top: 0;
      height: 100vh;
      padding: 28px 18px;
      border-right: 1px solid var(--line);
      background: rgba(9,11,15,.72);
      backdrop-filter: blur(30px) saturate(1.25);
      z-index: 5;
    }
    .brand { display: flex; align-items: center; gap: 10px; padding: 0 10px 24px; }
    .brand-mark {
      display: grid; place-items: center; width: 34px; height: 34px;
      border-radius: 10px; background: var(--blue);
      box-shadow: 0 10px 28px rgba(10,132,255,.3);
      font-size: 17px; font-weight: 800;
    }
    .brand strong { display: block; font-size: 14px; }
    .brand span { display: block; color: var(--muted); font-size: 11px; }
    nav a {
      display: flex; align-items: center; gap: 9px;
      padding: 8px 10px; margin: 2px 0; border-radius: 8px;
      color: var(--muted); font-size: 12px; transition: .16s ease;
    }
    nav a::before { content: ""; width: 4px; height: 4px; border-radius: 50%; background: var(--faint); }
    nav a:hover, nav a.active { color: var(--text); background: rgba(255,255,255,.06); }
    nav a.active::before { background: var(--blue); box-shadow: 0 0 0 4px rgba(10,132,255,.15); }
    .aside-meta {
      position: absolute; bottom: 24px; left: 28px; right: 28px;
      padding-top: 14px; border-top: 1px solid var(--line);
      color: var(--faint); font: 10px/1.6 var(--mono);
    }
    main { min-width: 0; }
    .hero {
      min-height: 560px; display: flex; align-items: flex-end;
      padding: 90px clamp(32px, 6vw, 88px) 68px;
      border-bottom: 1px solid var(--line);
    }
    .hero-inner { max-width: 1020px; }
    .hero h1 {
      margin: 12px 0 20px; max-width: 900px;
      font-size: clamp(46px, 7vw, 88px); line-height: .97;
      letter-spacing: -.055em;
    }
    .hero h1 span {
      background: linear-gradient(100deg, #fff 15%, #93d8ff 72%, #0a84ff);
      -webkit-background-clip: text; color: transparent;
    }
    .hero p { max-width: 690px; margin: 0; color: var(--muted); font-size: 18px; }
    .eyebrow {
      display: block; color: var(--blue); text-transform: uppercase;
      font: 700 10px/1.5 var(--mono); letter-spacing: .13em;
    }
    .hero-meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 28px; }
    .pill {
      display: inline-flex; align-items: center; width: fit-content;
      padding: 4px 8px; margin: 2px 4px 2px 0; border-radius: 999px;
      color: var(--muted); background: rgba(255,255,255,.055);
      border: 1px solid var(--line); font: 600 9px/1 var(--mono);
      text-transform: uppercase; letter-spacing: .04em;
    }
    .pill.presentation { color: var(--cyan); border-color: rgba(89,214,255,.22); }
    .pill.core { color: var(--purple); border-color: rgba(167,139,250,.24); }
    .pill.inference { color: var(--orange); border-color: rgba(255,180,84,.24); }
    .pill.good { color: var(--green); border-color: rgba(50,213,131,.25); }
    .pill.nemotron { color: var(--cyan); }
    .pill.parakeet { color: var(--purple); }
    section { padding: 78px clamp(32px, 6vw, 88px); border-bottom: 1px solid var(--line); }
    .section-head {
      display: grid; grid-template-columns: minmax(0, 1fr) minmax(260px, 440px);
      gap: 40px; align-items: end; margin-bottom: 34px;
    }
    h2 { margin: 8px 0 0; font-size: clamp(30px, 4vw, 48px); letter-spacing: -.035em; line-height: 1.05; }
    .section-head p { color: var(--muted); margin: 0; font-size: 14px; }
    .stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin: 32px 0 44px; }
    .stat {
      padding: 18px; border: 1px solid var(--line); border-radius: 14px;
      background: linear-gradient(150deg, rgba(255,255,255,.065), rgba(255,255,255,.025));
    }
    .stat strong { display: block; font-size: 26px; letter-spacing: -.03em; }
    .stat span { color: var(--muted); font-size: 11px; }
    .layers { max-width: 880px; margin: 0 auto; }
    .layer-card {
      display: grid; grid-template-columns: 54px 1fr; gap: 16px; align-items: start;
      padding: 22px; border: 1px solid var(--line); border-radius: var(--radius);
      background: var(--panel);
      box-shadow: 0 24px 70px rgba(0,0,0,.16);
    }
    .layer-card.presentation { border-color: rgba(89,214,255,.20); }
    .layer-card.core { border-color: rgba(167,139,250,.22); }
    .layer-card.inference { border-color: rgba(255,180,84,.22); }
    .layer-icon {
      display: grid; place-items: center; width: 46px; height: 46px;
      border-radius: 13px; background: rgba(255,255,255,.06); color: var(--blue); font-size: 20px;
    }
    .layer-card h3 { margin: 3px 0 7px; font-size: 18px; }
    .layer-card p { margin: 0; color: var(--muted); font-size: 12px; }
    .layer-arrow { color: var(--faint); text-align: center; font-size: 20px; height: 38px; line-height: 38px; }
    .flow {
      display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 1px; overflow: hidden; border: 1px solid var(--line);
      border-radius: var(--radius); background: var(--line);
    }
    .flow-step {
      min-height: 86px; display: grid; grid-template-columns: 34px 1fr;
      gap: 12px; align-items: start; padding: 18px; background: var(--panel-solid);
      color: #d9deea; font-size: 12px;
    }
    .flow-index { color: var(--blue); font: 700 10px/1.5 var(--mono); }
    .callout {
      margin-top: 16px; padding: 16px 18px; border-left: 2px solid var(--blue);
      color: var(--muted); background: rgba(10,132,255,.07); font-size: 12px;
    }
    .callout strong { color: var(--text); }
    .table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: var(--radius); }
    table { width: 100%; border-collapse: collapse; background: var(--panel); font-size: 12px; }
    th, td { text-align: left; padding: 15px 16px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font: 700 9px/1 var(--mono); text-transform: uppercase; letter-spacing: .08em; }
    tr:last-child td { border-bottom: 0; }
    td code { margin: 0; }
    .memory-note {
      display: grid; grid-template-columns: auto 1fr; gap: 14px; margin-top: 18px;
      padding: 18px; border: 1px solid rgba(50,213,131,.19); border-radius: 14px;
      background: rgba(50,213,131,.055);
    }
    .memory-note b { font-size: 20px; color: var(--green); }
    .memory-note p { margin: 0; color: var(--muted); font-size: 12px; }
    .lanes { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    .lane { padding: 18px; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); }
    .lane > div { display: grid; grid-template-columns: 8px 1fr; column-gap: 10px; }
    .lane-dot { grid-row: 1 / 3; margin-top: 5px; width: 7px; height: 7px; border-radius: 50%; background: var(--blue); box-shadow: 0 0 0 5px rgba(10,132,255,.12); }
    .lane h3 { margin: 0; font-size: 14px; }
    .lane p { margin: 2px 0 0; color: var(--muted); font-size: 10px; }
    ul { padding-left: 18px; margin: 12px 0 0; color: var(--muted); font-size: 11px; }
    li { margin: 5px 0; }
    .component-tools { display: flex; gap: 8px; margin-bottom: 18px; }
    .search {
      width: min(440px, 100%); border: 1px solid var(--line); border-radius: 10px;
      background: rgba(255,255,255,.05); color: var(--text); outline: none;
      padding: 10px 12px; font: 12px var(--sans);
    }
    .search:focus { border-color: rgba(10,132,255,.6); box-shadow: 0 0 0 3px rgba(10,132,255,.13); }
    .component-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
    .component-card {
      min-width: 0; padding: 17px; border: 1px solid var(--line); border-radius: 14px;
      background: var(--panel); transition: border-color .18s, transform .18s;
    }
    .component-card:hover { transform: translateY(-2px); border-color: var(--line-strong); }
    .component-card[hidden] { display: none; }
    .component-topline { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
    .component-kind { color: var(--faint); font: 9px var(--mono); text-align: right; }
    .component-card h3 { margin: 12px 0 9px; font-size: 15px; }
    .depends { border-top: 1px solid var(--line); margin-top: 14px; padding-top: 10px; }
    .depends > span:first-child { display: block; color: var(--faint); font: 9px var(--mono); margin-bottom: 4px; }
    .guardrails { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
    .invariant {
      display: grid; grid-template-columns: 28px 1fr; gap: 10px; padding: 16px;
      border: 1px solid var(--line); border-radius: 12px; background: var(--panel);
    }
    .check { display: grid; place-items: center; width: 24px; height: 24px; color: var(--green); background: rgba(50,213,131,.1); border-radius: 50%; font-size: 12px; }
    .invariant h3 { margin: 1px 0 5px; font-size: 12px; line-height: 1.4; }
    .invariant p { margin: 0 0 9px; color: var(--muted); font-size: 10px; }
    .route { border-bottom: 1px solid var(--line); }
    .route summary {
      display: flex; justify-content: space-between; align-items: center;
      padding: 17px 3px; cursor: pointer; list-style: none; font-weight: 600; font-size: 13px;
    }
    .route summary::-webkit-details-marker { display: none; }
    .chevron { color: var(--faint); font-size: 22px; transition: transform .2s; }
    .route[open] .chevron { transform: rotate(90deg); }
    .route-body {
      display: grid; grid-template-columns: 1fr 1fr; gap: 18px;
      padding: 4px 18px 20px; color: var(--muted);
    }
    .warning { grid-column: 1 / -1; color: var(--orange); font-size: 11px; }
    .boundary-grid, .test-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
    .boundary, .test-card { padding: 18px; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); }
    .boundary.disabled { opacity: .68; }
    .boundary-status { color: var(--green); font: 800 9px var(--mono); }
    .boundary.disabled .boundary-status { color: var(--red); }
    .boundary h3, .test-card h3 { margin: 12px 0 7px; font-size: 14px; }
    .boundary p, .boundary small { color: var(--muted); font-size: 10px; }
    .boundary small { display: block; margin-top: 12px; }
    .test-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    footer { padding: 36px clamp(32px, 6vw, 88px); color: var(--faint); font: 10px/1.7 var(--mono); }
    .noscript { color: var(--orange); }
    @media (max-width: 1050px) {
      .component-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .boundary-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
    @media (max-width: 760px) {
      .shell { display: block; }
      aside { position: relative; width: 100%; height: auto; border-right: 0; border-bottom: 1px solid var(--line); }
      nav { display: flex; overflow-x: auto; padding-bottom: 4px; }
      nav a { white-space: nowrap; }
      .aside-meta { display: none; }
      .brand { padding-bottom: 12px; }
      .hero { min-height: 460px; padding-top: 70px; }
      .section-head { grid-template-columns: 1fr; gap: 14px; }
      .stats, .component-grid, .guardrails, .lanes, .boundary-grid, .test-grid { grid-template-columns: 1fr; }
      .flow { grid-template-columns: 1fr; }
      .route-body { grid-template-columns: 1fr; }
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f4f6f9; --panel: rgba(255,255,255,.82); --panel-solid: #fff;
        --raised: #fff; --line: rgba(20,30,45,.10); --line-strong: rgba(20,30,45,.18);
        --text: #121722; --muted: #606a79; --faint: #929aa7;
      }
      body { background: radial-gradient(circle at 80% 0, rgba(10,132,255,.12), transparent 30rem), var(--bg); }
      aside { background: rgba(247,249,252,.78); }
      code { color: #394557; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <aside>
      <div class="brand"><div class="brand-mark">S</div><div><strong>Saymark</strong><span>Architecture map</span></div></div>
      <nav>${navItems.map(([id, label]) => `<a href="#${id}">${escapeHTML(label)}</a>`).join("")}</nav>
      <div class="aside-meta">Schema v${escapeHTML(data.schema_version)}<br>Based on ${escapeHTML(data.document.based_on_revision)}<br>${escapeHTML(data.document.generated_on)}</div>
    </aside>
    <main>
      <header class="hero" id="overview">
        <div class="hero-inner">
          <span class="eyebrow">Native macOS · Local-first · Apple silicon</span>
          <h1>The codebase, <span>explained.</span></h1>
          <p>${escapeHTML(data.project.summary)}</p>
          <div class="hero-meta">
            ${pill("Swift")}
            ${pill("SwiftUI + AppKit")}
            ${pill("MLX")}
            ${pill("macOS 15+")}
            ${pill("arm64")}
            ${pill("JSON source", "good")}
          </div>
        </div>
      </header>

      <section>
        <div class="section-head">
          <div><span class="eyebrow">System shape</span><h2>Three layers. One direction.</h2></div>
          <p>${escapeHTML(data.architecture.dependency_rule)}</p>
        </div>
        <div class="stats">
          <div class="stat"><strong>${data.components.length}</strong><span>mapped components</span></div>
          <div class="stat"><strong>${data.runtime_flows.length}</strong><span>runtime flows</span></div>
          <div class="stat"><strong>${data.invariants.length}</strong><span>non-negotiable invariants</span></div>
          <div class="stat"><strong>${data.tests.length}</strong><span>verification surfaces</span></div>
        </div>
        <div class="layers">${layerCards}</div>
      </section>

      <section id="flow">
        <div class="section-head">
          <div><span class="eyebrow">Critical path</span><h2>Hotkey to final text.</h2></div>
          <p>The UI responds first. Audio and inference stay serialized. Final decoding leaves the main actor, then one single-shot paste attempts delivery with bounded acknowledgement.</p>
        </div>
        <div class="flow">${flowSteps}</div>
        <div class="callout"><strong>Final authority:</strong> ${escapeHTML(flow.authoritative_output)}</div>
      </section>

      <section id="models">
        <div class="section-head">
          <div><span class="eyebrow">Product policy</span><h2>Experiences, not model soup.</h2></div>
          <p>Users choose a supported experience. The core owns which models load, which text is provisional, and which output wins.</p>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Experience</th><th>Mode</th><th>Models</th><th>Feedback</th><th>Final authority</th><th>Notes</th></tr></thead>
            <tbody>${modelRows}</tbody>
          </table>
        </div>
        <div class="memory-note">
          <b>18 GiB</b>
          <p><strong>MLX safety ceiling.</strong> Model residency is process-lifetime and expected. Per-utterance capture, audio buffers, sessions, subscriptions, timers, and HUD content are not—they must be torn down after every dictation.</p>
        </div>
      </section>

      <section id="concurrency">
        <div class="section-head">
          <div><span class="eyebrow">Ownership</span><h2>Concurrency has lanes.</h2></div>
          <p>No shared inference free-for-all: UI, capture, MLX/VAD, logging, resource sampling, and finalization each have an explicit execution domain.</p>
        </div>
        <div class="lanes">${concurrency}</div>
      </section>

      <section id="components">
        <div class="section-head">
          <div><span class="eyebrow">Component catalog</span><h2>Find the owner before editing.</h2></div>
          <p>Search by type, path, responsibility, or dependency. Every card states what the component owns.</p>
        </div>
        <div class="component-tools"><input class="search" id="component-search" type="search" placeholder="Search components, files, responsibilities…" autocomplete="off"></div>
        <div class="component-grid" id="component-grid">${components}</div>
      </section>

      <section id="invariants">
        <div class="section-head">
          <div><span class="eyebrow">Regression firewall</span><h2>Rules the code must keep.</h2></div>
          <p>These are architecture decisions born from latency, accuracy, memory, trust, and privacy failures. Changing one requires evidence.</p>
        </div>
        <div class="guardrails">${invariantCards}</div>
      </section>

      <section id="agents">
        <div class="section-head">
          <div><span class="eyebrow">Agent handoff</span><h2>Start here. Prove it there.</h2></div>
          <p>A task-to-code routing table for the next contributor or coding agent. Each route pairs likely owners with the tests that should move.</p>
        </div>
        <div>${agentRoutes}</div>
      </section>

      <section id="boundaries">
        <div class="section-head">
          <div><span class="eyebrow">Privacy and platform</span><h2>Every external edge is named.</h2></div>
          <p>Model downloads are networked. Dictation is local. Automatic insertion is gated by macOS trust. Remote analytics is dormant.</p>
        </div>
        <div class="boundary-grid">${boundaries}</div>
      </section>

      <section id="tests">
        <div class="section-head">
          <div><span class="eyebrow">Verification</span><h2>Five ways to catch a regression.</h2></div>
          <p>Pure policy tests, core unit/model-acceptance tests, hosted AppKit tests, XCUITest flows, and real-model benchmarks cover different failure classes.</p>
        </div>
        <div class="test-grid">${testCards}</div>
      </section>

      <section id="files">
        <div class="section-head">
          <div><span class="eyebrow">Repository map</span><h2>Where the work lives.</h2></div>
          <p>This is the coarse file index. Use the component catalog and agent routing above for task-specific entry points.</p>
        </div>
        <div class="table-wrap"><table><thead><tr><th>Path</th><th>Role</th></tr></thead><tbody>${fileRows}</tbody></table></div>
      </section>

      <footer>
        Generated from <strong>docs/architecture.json</strong> by <strong>Scripts/generate-architecture-map.mjs</strong>.<br>
        Run <strong>node Scripts/generate-architecture-map.mjs --check</strong> to detect drift.
        <noscript><p class="noscript">JavaScript is only used for component search and active navigation; all architecture content is already in this file.</p></noscript>
      </footer>
    </main>
  </div>
  <script type="application/json" id="saymark-architecture">${embeddedJSON}</script>
  <script>
    const search = document.querySelector("#component-search");
    const cards = [...document.querySelectorAll(".component-card")];
    search?.addEventListener("input", () => {
      const query = search.value.trim().toLowerCase();
      cards.forEach((card) => { card.hidden = query && !card.dataset.search.includes(query); });
    });

    const links = [...document.querySelectorAll("nav a")];
    const sections = links.map((link) => document.querySelector(link.getAttribute("href"))).filter(Boolean);
    const observer = new IntersectionObserver((entries) => {
      const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (!visible) return;
      links.forEach((link) => link.classList.toggle("active", link.getAttribute("href") === "#" + visible.target.id));
    }, { rootMargin: "-20% 0px -65% 0px", threshold: [0, .2, .6] });
    sections.forEach((section) => observer.observe(section));
  </script>
</body>
</html>
`;

if (process.argv.includes("--check")) {
  if (!fs.existsSync(outputPath) || fs.readFileSync(outputPath, "utf8") !== html) {
    console.error("architecture-map: FAIL — docs/architecture.html is stale");
    console.error("Run: node Scripts/generate-architecture-map.mjs");
    process.exit(1);
  }
  console.log("architecture-map: PASS");
} else {
  fs.writeFileSync(outputPath, html);
  console.log(`architecture-map: wrote ${path.relative(root, outputPath)}`);
}
