# Landing + Pricing Page (Phase 4): The Gold-Glass Pricing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This is a STATIC WEB plan (HTML/CSS/vanilla JS).** The Swift app-layer contracts in `2026-05-31-APP-PLANS-RECONCILIATION.md` do **not** apply here — only its §4 *tone/brand consistency* discipline does (gold on obsidian, "you approve" trust model, accurate agent names, no vaporware). Swift unit-test steps do not apply; every task instead has concrete browser/CLI verification with exact commands and expected output.

---

## Goal

Ship a dedicated, standalone **pricing page** (`landing/pricing.html`) for Senani's Phase-4 go-to-market, built entirely from the existing gold-glass design language in `landing/index.html`. It must:

- Reuse `index.html`'s CSS variables, nav, footer, buttons, and glass components **verbatim** (one shared visual system; the existing hero in `index.html` is NOT touched).
- Present the **two tiers** — **$99 Core** and **$199 Pro** — as one-time purchases, with a feature-comparison table mapped to the actual ROADMAP phases (Phase 2 ships Core; Phase 3 ships Pro).
- Carry the brand value props: **one-time purchase / offline / on-device / no-accounts / open-source (AGPL-3.0)**.
- Include an interactive **billing/compare toggle** (a "Compare all features" expander OR a "Core ↔ Pro highlight" toggle — see Architecture) that works with vanilla JS and degrades gracefully without JS.
- Include a **short agents section** listing the *real built* agents — Triage, Reply Drafter, Booking, Daily Digest, Inbox Hygiene (Core) and Lead Qualifier, Proposal Tracker, Follow-up, Outreach, Invoice/Finance (Pro) — accurate to the agent plans, never vaporware.
- Include a **system-requirements** block (Apple Silicon M1+, macOS 14+, RAM tiers 8/16/32 GB mapped to the MLX model picker) and a **pricing FAQ**.
- Provide **download / buy CTAs** as documented stubs (link targets recorded in a comment block; currently point to the GitHub repo "coming soon" the same way `index.html` does).
- Be **responsive** (single-column under 860px) and **accessible** (semantic landmarks, alt/labels, AA contrast, `prefers-reduced-motion` respected — consistent with `2026-05-31-homepage-animations.md`).
- Add a `Pricing` nav link on `index.html` that points to `pricing.html` (the only edit to `index.html`).

**Non-goals:** No build tooling, no framework, no bundler, no backend, no real payment integration (CTAs are stubs), no edit to the existing hero/engine animation. The page is one self-contained HTML file plus a one-line nav edit on `index.html`.

---

## Architecture

**One file, self-contained.** `landing/pricing.html` mirrors `index.html`'s structure: same `<head>` (fonts, favicon, meta), same inlined `:root` token block + component CSS (copied so the page works standalone — Senani's landing has no shared `.css` file by design), same fixed background layers (`.bg/.aurora/.grain/.moon`), same `nav` and `footer`, same GSAP CDN + `matchMedia` reveal pattern.

**Page section order (top → bottom):**

1. `nav` (shared) — with `Pricing` marked current via `aria-current="page"`.
2. **Pricing hero** — compact: eyebrow + `h1` "One payment. Yours forever." + lead. NO canvas constellation and NO Golden Engine (those live only on `index.html`'s hero — we do not duplicate the homepage-animations plan). A lightweight static glass "value strip" instead.
3. **Tier cards** (`.prices`) — the two `.price` cards (Core $99, Pro Featured $199), reusing the exact existing `.price/.price.feat/.amt/.badge` CSS.
4. **Compare toggle + feature matrix** — a `<table>` of features × {Core, Pro} mapped to ROADMAP phases, with a vanilla-JS **"Show shared features"** toggle that collapses/expands the rows both tiers share (the interactive element under test). Without JS, all rows show (progressive enhancement).
5. **Agents section** (`.agents`) — the 10 real agents with Core/Pro tier chips (reused from `index.html`).
6. **System requirements** — Apple Silicon, macOS 14+, RAM→model tiers (3 glass cards).
7. **Pricing FAQ** (`<details>`) — pay-once, refunds, open-source, upgrade Core→Pro, supported Macs.
8. **Final CTA** + `footer` (shared).

**The interactive toggle (the JS under test):** a single `<button id="compare-toggle" aria-expanded="false" aria-controls="shared-rows">` that toggles a `hidden` attribute on the `<tbody id="shared-rows">` of shared features, flipping `aria-expanded` and its label text. Pure DOM, no dependency on GSAP. Default state = collapsed **only when JS runs** (JS sets `hidden` on load); with JS disabled the rows stay visible → no information is hidden from no-JS / crawler / screen-reader-without-JS users.

**Reduced motion:** identical guard to `index.html` — `@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}...}` and the GSAP `mm.add('(prefers-reduced-motion: reduce)', …)` branch that sets reveals visible immediately.

**Link-target stubs (documented):** every CTA `href` is collected in an HTML comment block `<!-- CTA TARGETS … -->` near the top of `<body>`. Until checkout exists, all buy CTAs point to `https://github.com/vishalquantana/senani` (matching `index.html`'s "Coming soon — follow on GitHub" pattern). The comment documents the future swap (e.g. `https://buy.senani.app/core`).

---

## Tech Stack

- **HTML5** (semantic landmarks: `header`, `nav`, `main`, `section`, `footer`).
- **CSS3** — vanilla, inlined, copied token set from `landing/index.html` (`--gold`, `--gold-grad`, `--glass`, `--line`, fonts `Cinzel`/`Fraunces`/`Hanken Grotesk`).
- **Vanilla JS** — year stamp, the compare toggle, GSAP reveal (loaded from the same `gsap@3.12.5` jsDelivr CDN as `index.html`).
- **GSAP 3.12.5** (CDN) + ScrollTrigger — reveal-on-scroll only, mirroring `index.html`.

**Verification tooling (all via `npx -y`, no install):**

- `html-validate` — markup validity.
- `linkinator` — link/anchor checking (local file).
- `puppeteer` (via a tiny throwaway `node` script, `--no-install` acceptable since puppeteer ships Chromium) — headless render: assert the toggle works, assert reduced-motion path, assert responsive breakpoint DOM/CSS.
- `@lhci/cli` (Lighthouse CI) — a11y + perf budget assertion.
- Manual visual checklist with exact expected DOM/CSS assertions.

---

## File Structure

```
landing/
  index.html         (existing — ONLY change: add "Pricing" nav link → pricing.html)
  pricing.html        (NEW — the entire deliverable)
```

No other files are created or modified. (Verification scripts are written to `/tmp` and deleted; they never land in the repo.)

---

### Task 1: Scaffold pricing.html — head, shared layers, nav, footer, reduced-motion

**Files:**
- Create: `landing/pricing.html`

- [ ] **Step 1: Create `landing/pricing.html` with the shared shell.** Copy the head/token/nav/footer system from `index.html` verbatim so the page is standalone and pixel-consistent. Write the COMPLETE file below (sections 3–7 are stubbed with empty `<section>`s here and filled in later tasks).

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Pricing — Senani · pay once, own it forever. Offline AI email for macOS.</title>
<meta name="description" content="Senani pricing: a one-time purchase, no subscription ever. $99 Core (Triage, Reply Drafter, Booking, Digest, Hygiene) or $199 Pro (the full sales suite). 100% on-device AI, offline, no accounts, open source." />
<meta property="og:title" content="Senani Pricing — pay once, own it forever" />
<meta property="og:description" content="One-time license. $99 Core or $199 Pro sales suite. On-device AI, offline, no accounts. macOS, Apple Silicon." />
<meta property="og:type" content="website" />
<link rel="canonical" href="https://senani.app/pricing.html" />
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Cg fill='none' stroke='%23d4af37' stroke-width='6' stroke-linejoin='round'%3E%3Crect x='18' y='30' width='64' height='42' rx='5'/%3E%3Cpath d='M18 34 50 56 82 34'/%3E%3C/g%3E%3Ccircle cx='50' cy='56' r='7' fill='%23f4dd95'/%3E%3C/svg%3E" />
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Cinzel:wght@500;600&family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,500;0,9..144,600;1,9..144,500&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root{
    --bg:#08080b; --bg-2:#0c0b11;
    --gold:#d4af37; --gold-bright:#f4dd95; --gold-deep:#9c7a2e; --champagne:#e8c97a;
    --ink:#ece7dc; --muted:#9b948a; --faint:#6a655e;
    --glass:rgba(255,255,255,.045); --glass-2:rgba(255,255,255,.028);
    --line:rgba(212,175,55,.16); --line-soft:rgba(255,255,255,.07);
    --display:'Fraunces',Georgia,serif; --wordmark:'Cinzel',serif; --body:'Hanken Grotesk',system-ui,sans-serif;
    --maxw:1180px; --gold-grad:linear-gradient(135deg,#f4dd95 0%,#d4af37 45%,#9c7a2e 100%);
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html{scroll-behavior:smooth}
  body{font-family:var(--body);color:var(--ink);background:var(--bg);line-height:1.6;-webkit-font-smoothing:antialiased;overflow-x:hidden;font-size:17px}
  .bg{position:fixed;inset:0;z-index:-3;background:
    radial-gradient(1200px 700px at 75% -10%, rgba(212,175,55,.16), transparent 60%),
    radial-gradient(900px 600px at 12% 8%, rgba(120,98,200,.10), transparent 55%),
    radial-gradient(1000px 800px at 50% 120%, rgba(212,175,55,.07), transparent 60%),
    linear-gradient(180deg,#08080b 0%, #0a0910 40%, #08080b 100%)}
  .aurora{position:fixed;inset:-20% -20% auto -20%;height:80vh;z-index:-3;pointer-events:none;opacity:.5;
    background:radial-gradient(60% 60% at 30% 30%,rgba(212,175,55,.10),transparent 70%),radial-gradient(50% 50% at 70% 40%,rgba(140,110,220,.08),transparent 70%);
    filter:blur(30px);animation:drift 18s ease-in-out infinite alternate}
  @keyframes drift{from{transform:translate(-3%, -2%) scale(1)}to{transform:translate(4%, 3%) scale(1.08)}}
  .grain{position:fixed;inset:0;z-index:-1;pointer-events:none;opacity:.05;
    background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='3'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
  .moon{position:fixed;top:9%;right:8%;width:120px;height:120px;border-radius:50%;z-index:-2;
    background:radial-gradient(circle at 35% 35%, #fff7e6, #e8d9b0 45%, #b9a16a 80%);
    box-shadow:0 0 80px 20px rgba(244,221,149,.18), inset -16px -10px 30px rgba(60,50,20,.35);opacity:.65;will-change:transform}

  .wrap{max-width:var(--maxw);margin:0 auto;padding:0 28px}
  a{color:inherit;text-decoration:none}
  .eyebrow{font-family:var(--wordmark);text-transform:uppercase;letter-spacing:.28em;font-size:.72rem;color:var(--gold);font-weight:500}
  h1,h2,h3{font-family:var(--display);font-weight:500;line-height:1.05;letter-spacing:-.01em}
  .gold-text{background:var(--gold-grad);-webkit-background-clip:text;background-clip:text;color:transparent}
  .defs{position:absolute;width:0;height:0}

  .mark{display:block}

  .progress{position:fixed;top:0;left:0;height:2px;width:100%;transform:scaleX(0);transform-origin:left center;background:var(--gold-grad);z-index:60}
  nav{position:sticky;top:0;z-index:50;backdrop-filter:blur(14px) saturate(140%);background:rgba(8,8,11,.55);border-bottom:1px solid var(--line-soft)}
  nav .wrap{display:flex;align-items:center;justify-content:space-between;height:68px}
  .brand{display:flex;align-items:center;gap:11px;font-family:var(--wordmark);font-weight:600;letter-spacing:.18em;font-size:1.05rem;text-transform:uppercase}
  .brand .mark{width:30px;height:30px}
  .navlinks{display:flex;gap:30px;align-items:center}
  .navlinks a{color:var(--muted);font-size:.93rem;font-weight:500;transition:color .2s;position:relative}
  .navlinks a::after{content:"";position:absolute;left:0;bottom:-4px;width:0;height:1px;background:var(--gold);transition:width .3s}
  .navlinks a:hover{color:var(--ink)}.navlinks a:hover::after{width:100%}
  .navlinks a[aria-current="page"]{color:var(--gold-bright)}.navlinks a[aria-current="page"]::after{width:100%}
  .btn{display:inline-flex;align-items:center;gap:8px;font-family:var(--body);font-weight:600;font-size:.92rem;padding:11px 20px;border-radius:11px;cursor:pointer;transition:all .25s;border:1px solid transparent}
  .btn-gold{background:var(--gold-grad);color:#1a1408;position:relative;overflow:hidden;box-shadow:0 6px 24px rgba(212,175,55,.22)}
  .btn-gold:hover{transform:translateY(-2px);box-shadow:0 10px 32px rgba(212,175,55,.34)}
  .btn-gold::after{content:"";position:absolute;top:0;left:-120%;width:60%;height:100%;background:linear-gradient(120deg,transparent,rgba(255,255,255,.55),transparent);transform:skewX(-20deg);animation:sweep 4.5s ease-in-out infinite}
  @keyframes sweep{0%,55%{left:-120%}80%,100%{left:140%}}
  .btn-ghost{border:1px solid var(--line);color:var(--ink);background:var(--glass)}
  .btn-ghost:hover{border-color:var(--gold);background:rgba(212,175,55,.08)}
  .btn-lg{padding:15px 28px;font-size:1rem;border-radius:13px}

  section{padding:clamp(70px,9vw,120px) 0;position:relative}
  .sec-head{text-align:center;max-width:680px;margin:0 auto 56px}
  .sec-head h2{font-size:clamp(2rem,4vw,3.1rem);margin:16px 0 0}
  .sec-head p{color:var(--muted);margin-top:18px;font-size:1.08rem}

  /* pricing hero (compact, no canvas/engine) */
  .phero{padding:clamp(60px,8vw,104px) 0 0;text-align:center;position:relative}
  .phero .hero-logo{width:74px;height:74px;margin:0 auto 22px}
  .phero h1{font-size:clamp(2.4rem,5.5vw,4.2rem);margin:18px 0 0}
  .phero h1 em{font-style:italic;font-weight:500;background:var(--gold-grad);-webkit-background-clip:text;background-clip:text;color:transparent}
  .phero .lead{font-size:clamp(1.05rem,1.7vw,1.24rem);color:var(--muted);max-width:600px;margin:24px auto 0}
  .phero .lead strong{color:var(--ink);font-weight:600}
  .valuestrip{display:flex;gap:10px 22px;justify-content:center;flex-wrap:wrap;margin:30px auto 0;color:var(--faint);font-size:.84rem}
  .valuestrip span{display:inline-flex;align-items:center;gap:7px}
  .dot{width:5px;height:5px;border-radius:50%;background:var(--gold);box-shadow:0 0 8px var(--gold)}

  /* tier cards (reused verbatim from index.html) */
  .prices{display:grid;grid-template-columns:repeat(2,1fr);gap:22px;max-width:780px;margin:0 auto}
  .price{padding:38px 32px;border-radius:20px;border:1px solid var(--line-soft);background:var(--glass-2);position:relative;transition:transform .35s,box-shadow .35s}
  .price:hover{transform:translateY(-6px)}
  .price.feat{border-color:var(--gold);background:linear-gradient(180deg,rgba(212,175,55,.08),var(--glass-2));box-shadow:0 30px 70px -34px rgba(212,175,55,.4)}
  .price .ptier{font-family:var(--wordmark);letter-spacing:.16em;text-transform:uppercase;font-size:.78rem;color:var(--gold)}
  .price .amt{font-family:var(--display);font-size:3.4rem;margin:14px 0 2px;line-height:1}
  .price .amt small{font-size:1rem;color:var(--muted);font-family:var(--body)}
  .price .once{color:var(--faint);font-size:.84rem;margin-bottom:24px}
  .price ul{list-style:none;display:flex;flex-direction:column;gap:12px;margin-bottom:28px}
  .price li{display:flex;gap:11px;align-items:flex-start;font-size:.93rem}
  .price li svg{width:18px;height:18px;color:var(--gold);flex-shrink:0;margin-top:3px}
  .price .btn{width:100%;justify-content:center}
  .badge{position:absolute;top:-12px;right:24px;background:var(--gold-grad);color:#1a1408;font-size:.68rem;font-weight:700;padding:5px 13px;border-radius:20px;letter-spacing:.04em}

  /* compare matrix */
  .compare-bar{display:flex;justify-content:center;margin:0 auto 22px}
  #compare-toggle{font-family:var(--body)}
  .matrix-wrap{max-width:880px;margin:0 auto;overflow-x:auto}
  table{width:100%;border-collapse:collapse;margin-top:10px;font-size:.95rem}
  th,td{padding:15px 14px;text-align:center;border-bottom:1px solid var(--line-soft)}
  th:first-child,td:first-child{text-align:left;color:var(--ink);font-weight:500}
  thead th{font-family:var(--body);font-weight:700;font-size:.95rem}
  tbody th{font-family:var(--wordmark);letter-spacing:.12em;text-transform:uppercase;color:var(--gold);font-size:.72rem;text-align:left;background:rgba(212,175,55,.04)}
  .col-pro{background:linear-gradient(180deg,rgba(212,175,55,.09),transparent);border-left:1px solid var(--line);border-right:1px solid var(--line)}
  .phase{font-family:var(--wordmark);font-size:.6rem;letter-spacing:.12em;color:var(--faint);text-transform:uppercase;display:block;margin-top:3px}
  .yes{color:var(--gold-bright);font-weight:700}.no{color:#5a5650}
  [hidden]{display:none!important}

  /* agents grid (reused from index.html) */
  .agents{display:grid;grid-template-columns:repeat(auto-fill,minmax(248px,1fr));gap:16px}
  .agent{padding:24px;border-radius:15px;border:1px solid var(--line-soft);background:var(--glass-2);transition:all .35s;position:relative}
  .agent:hover{border-color:var(--line);transform:translateY(-6px);box-shadow:0 18px 40px -24px rgba(212,175,55,.35)}
  .agent .ico{width:30px;height:30px;color:var(--gold);margin-bottom:14px;transition:transform .35s}
  .agent:hover .ico{transform:scale(1.12) rotate(-4deg)}
  .agent h3{font-size:1.05rem;font-family:var(--body);font-weight:700;display:flex;align-items:center;gap:9px}
  .agent p{color:var(--muted);font-size:.88rem;margin-top:8px}
  .tier{font-family:var(--wordmark);font-size:.6rem;letter-spacing:.16em;padding:3px 8px;border-radius:6px;text-transform:uppercase;font-weight:600}
  .t-core{background:rgba(255,255,255,.06);color:var(--muted);border:1px solid var(--line-soft)}
  .t-pro{background:rgba(212,175,55,.14);color:var(--gold-bright);border:1px solid var(--line)}

  /* system requirements */
  .reqs{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;max-width:980px;margin:0 auto}
  .req{padding:28px 24px;border-radius:16px;border:1px solid var(--line-soft);background:var(--glass-2)}
  .req .ico{width:32px;height:32px;color:var(--gold);margin-bottom:14px}
  .req h3{font-size:1.1rem;font-family:var(--body);font-weight:700}
  .req p{color:var(--muted);font-size:.9rem;margin-top:9px}
  .req ul{list-style:none;margin-top:12px;display:flex;flex-direction:column;gap:8px;font-size:.86rem;color:var(--muted)}
  .req li{display:flex;gap:9px}
  .req li b{color:var(--ink);font-weight:600;min-width:64px;display:inline-block}

  /* faq */
  .faq{max-width:760px;margin:0 auto}
  details{border-bottom:1px solid var(--line-soft);padding:6px 0}
  summary{cursor:pointer;list-style:none;padding:18px 0;font-weight:600;font-size:1.06rem;display:flex;justify-content:space-between;align-items:center;gap:16px}
  summary::-webkit-details-marker{display:none}
  summary::after{content:"+";color:var(--gold);font-size:1.5rem;font-family:var(--display);transition:transform .3s}
  details[open] summary::after{transform:rotate(45deg)}
  details p{color:var(--muted);padding:0 0 20px;font-size:.97rem}

  .final{text-align:center}
  .final h2{font-size:clamp(2.4rem,5vw,4rem)}
  .final .btn{margin-top:34px}

  footer{border-top:1px solid var(--line-soft);padding:46px 0;color:var(--faint);font-size:.86rem}
  footer .wrap{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:18px}
  footer a{color:var(--muted)}footer a:hover{color:var(--gold)}
  .foot-links{display:flex;gap:24px}

  html.js .reveal{opacity:0;transform:translateY(34px)}
  @media(max-width:860px){
    .navlinks{display:none}
    .prices{grid-template-columns:1fr}
    .reqs{grid-template-columns:1fr}
    .moon{width:80px;height:80px;top:5%}
  }
  @media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}html.js .reveal{opacity:1!important;transform:none!important}}
</style>
<script>document.documentElement.classList.add('js')</script>
</head>
<body>
<!--
  CTA TARGETS (stubs — Phase 4 go-to-market):
    Core buy  → future: https://buy.senani.app/core   | now: GitHub repo "coming soon"
    Pro buy   → future: https://buy.senani.app/pro     | now: GitHub repo "coming soon"
    Download  → future: https://senani.app/download    | now: GitHub repo "coming soon"
  All CTAs currently route to https://github.com/vishalquantana/senani per index.html's
  "Coming soon — follow on GitHub" pattern. Swap the hrefs when checkout/notarized build exist.
-->
<div class="progress"></div>
<div class="bg"></div><div class="aurora"></div><div class="grain"></div><div class="moon"></div>

<svg class="defs"><defs>
  <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f4dd95"/><stop offset=".5" stop-color="#d4af37"/><stop offset="1" stop-color="#9c7a2e"/></linearGradient>
</defs></svg>

<nav>
  <div class="wrap">
    <a class="brand" href="index.html">
      <svg class="mark" viewBox="0 0 100 100" role="img" aria-label="Senani logo"><g fill="none" stroke="url(#gold)" stroke-width="6" stroke-linejoin="round" stroke-linecap="round"><rect x="18" y="30" width="64" height="42" rx="5"/><path d="M18 34 50 56 82 34"/></g><circle cx="50" cy="56" r="6.5" fill="url(#gold)"/></svg>
      Senani
    </a>
    <div class="navlinks">
      <a href="index.html#privacy">Privacy</a><a href="index.html#agents">Agents</a><a href="index.html#how">How it works</a><a href="pricing.html" aria-current="page">Pricing</a>
      <a href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">GitHub ↗</a>
    </div>
    <a class="btn btn-gold" href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">★ Star on GitHub</a>
  </div>
</nav>

<main>
  <header class="phero" id="top">
    <div class="wrap">
      <svg class="hero-logo mark" viewBox="0 0 100 100" role="img" aria-label="Senani logo">
        <g fill="none" stroke="url(#gold)" stroke-width="4.5" stroke-linejoin="round" stroke-linecap="round"><rect x="18" y="30" width="64" height="42" rx="5"/><path d="M18 34 50 56 82 34"/></g>
        <g fill="url(#gold)"><circle cx="18" cy="30" r="3.6"/><circle cx="82" cy="30" r="3.6"/><circle cx="18" cy="72" r="3.6"/><circle cx="82" cy="72" r="3.6"/><circle cx="50" cy="56" r="5"/></g>
      </svg>
      <p class="eyebrow">Own it · Pay once</p>
      <h1>One payment.<br>Yours <em>forever</em>.</h1>
      <p class="lead">Senani is a one-time purchase — <strong>no subscription, ever.</strong> The code is open source under AGPL-3.0; the license buys the signed, notarized, auto-updating build and funds development.</p>
      <div class="valuestrip">
        <span><i class="dot"></i> 100% on-device AI</span><span><i class="dot"></i> Works offline</span>
        <span><i class="dot"></i> No accounts, no telemetry</span><span><i class="dot"></i> AGPL-3.0</span>
      </div>
    </div>
  </header>

  <section id="tiers" aria-label="Pricing tiers"><div class="wrap"><!-- Task 2 --></div></section>
  <section id="compare" aria-label="Feature comparison"><div class="wrap"><!-- Task 3 --></div></section>
  <section id="agents" aria-label="The agents"><div class="wrap"><!-- Task 4 --></div></section>
  <section id="requirements" aria-label="System requirements"><div class="wrap"><!-- Task 5 --></div></section>
  <section id="faq" aria-label="Pricing FAQ"><div class="wrap"><!-- Task 6 --></div></section>

  <section class="final">
    <div class="wrap">
      <p class="eyebrow">Command your inbox</p>
      <h2>Own your AI.<br>Pay <span class="gold-text">once</span>.</h2>
      <a class="btn btn-gold btn-lg" href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">★ Star Senani on GitHub</a>
    </div>
  </section>
</main>

<footer>
  <div class="wrap">
    <a class="brand" href="index.html" style="font-size:.95rem"><svg class="mark" style="width:24px;height:24px" viewBox="0 0 100 100" role="img" aria-label="Senani logo"><g fill="none" stroke="url(#gold)" stroke-width="6" stroke-linejoin="round"><rect x="18" y="30" width="64" height="42" rx="5"/><path d="M18 34 50 56 82 34"/></g><circle cx="50" cy="56" r="6.5" fill="url(#gold)"/></svg> Senani</a>
    <div class="foot-links">
      <a href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">GitHub</a>
      <a href="https://github.com/vishalquantana/senani/blob/main/docs/ARCHITECTURE.md" target="_blank" rel="noopener">Architecture</a>
      <a href="https://github.com/vishalquantana/senani/blob/main/docs/ROADMAP.md" target="_blank" rel="noopener">Roadmap</a>
      <a href="https://github.com/vishalquantana/senani/blob/main/LICENSE" target="_blank" rel="noopener">AGPL-3.0</a>
    </div>
    <div>© <span id="yr"></span> Quantana · Built offline, by design.</div>
  </div>
</footer>

<script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/gsap.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/ScrollTrigger.min.js"></script>
<script>
  document.getElementById('yr').textContent = new Date().getFullYear();

  // GSAP reveal — mirrors index.html (reveal-on-scroll only; no canvas, no engine)
  if(window.gsap){
    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();
    mm.add('(prefers-reduced-motion: reduce)', ()=>{ gsap.set('.reveal',{autoAlpha:1,y:0}); });
    mm.add('(prefers-reduced-motion: no-preference)', ()=>{
      gsap.to('.progress',{scaleX:1,ease:'none',scrollTrigger:{start:0,end:'max',scrub:.3}});
      ScrollTrigger.batch('.reveal',{start:'top 90%',onEnter:b=>gsap.to(b,{autoAlpha:1,y:0,duration:.9,ease:'power3.out',stagger:.1,overwrite:true})});
      gsap.to('.moon',{yPercent:120,scale:.8,ease:'none',scrollTrigger:{start:0,end:'max',scrub:1}});
    });
    addEventListener('load',()=>ScrollTrigger.refresh());
  } else {
    document.documentElement.classList.remove('js');
  }
</script>
</body>
</html>
```

- [ ] **Step 2: Validate the scaffold markup.**

```bash
npx -y html-validate /Users/vishalkumar/Downloads/qmail/landing/pricing.html
```

Expected output: ends with a line like `pricing.html ... ` and overall `✔` / exit code `0` (no errors). If `html-validate` flags the inline `<style>`/`<script>` or void elements, fix only genuine errors (unclosed tags, duplicate ids, missing alt). The page MUST have exactly **one** `<h1>`, one `<main>`, one `<nav>`, one `<footer>`.

- [ ] **Step 3: Confirm it opens and the shell renders (headless smoke test).** Write `/tmp/smoke.mjs`:

```js
import puppeteer from 'puppeteer';
const url = 'file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html';
const b = await puppeteer.launch();
const p = await b.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e)));
await p.goto(url, { waitUntil: 'networkidle0' });
const h1 = await p.$eval('h1', el => el.textContent.replace(/\s+/g,' ').trim());
const navCurrent = await p.$eval('.navlinks a[aria-current="page"]', el => el.textContent.trim());
const year = await p.$eval('#yr', el => el.textContent);
console.log(JSON.stringify({ h1, navCurrent, year, pageErrors: errs }, null, 2));
await b.close();
```

```bash
cd /tmp && npx -y puppeteer@latest --version >/dev/null 2>&1; npm_config_yes=true npx -y -p puppeteer node /tmp/smoke.mjs
```

Expected JSON: `"h1": "One payment. Yours forever."`, `"navCurrent": "Pricing"`, `"year"` is the current 4-digit year, `"pageErrors": []`.

- [ ] **Step 4: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): scaffold gold-glass pricing page shell

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Tier cards ($99 Core, $199 Pro)

**Files:**
- Modify: `landing/pricing.html`

- [ ] **Step 1: Fill the `#tiers` section.** Replace `<section id="tiers" aria-label="Pricing tiers"><div class="wrap"><!-- Task 2 --></div></section>` with:

```html
  <section id="tiers" aria-label="Pricing tiers">
    <div class="wrap">
      <div class="sec-head reveal"><p class="eyebrow">Two builds</p><h2>Pick your formation.</h2><p>Core handles your everyday inbox. Pro adds the full sales suite — a pipeline of agents that qualify, track, follow up, and chase invoices.</p></div>
      <div class="prices">
        <div class="price reveal">
          <div class="ptier">Core</div><div class="amt">$99<small> once</small></div><div class="once">No subscription, ever</div>
          <ul>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Triage, Reply Drafter &amp; Booking</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Daily Digest &amp; Inbox Hygiene</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> On-device Gemma + in-app model picker</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Signed, notarized build + free updates</li>
          </ul>
          <a class="btn btn-ghost" href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">Coming soon — follow on GitHub</a>
        </div>
        <div class="price feat reveal">
          <div class="badge">Full arsenal</div><div class="ptier">Pro</div><div class="amt">$199<small> once</small></div><div class="once">Everything in Core, plus the sales suite</div>
          <ul>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Lead Qualifier &amp; Proposal Tracker</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Follow-up &amp; Outreach agents</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Invoice / Finance + pipeline / CRM view</li>
            <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="m5 13 4 4L19 7"/></svg> Priority updates &amp; support</li>
          </ul>
          <a class="btn btn-gold" href="https://github.com/vishalquantana/senani" target="_blank" rel="noopener">Coming soon — star to get notified</a>
        </div>
      </div>
    </div>
  </section>
```

- [ ] **Step 2: Validate + headless-assert the prices.** Re-run `npx -y html-validate …` (expect PASS). Then extend the smoke check — add to `/tmp/smoke.mjs` before `await b.close()`:

```js
const prices = await p.$$eval('.price .amt', els => els.map(e => e.textContent.replace(/\s+/g,' ').trim()));
const feat = await p.$eval('.price.feat .badge', el => el.textContent.trim());
console.log('PRICES', JSON.stringify(prices), 'BADGE', feat);
```

Re-run the smoke command. Expected: `PRICES ["$99 once","$199 once"] BADGE Full arsenal`.

- [ ] **Step 3: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): pricing tier cards (\$99 Core, \$199 Pro)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Feature comparison matrix + interactive compare toggle

**Files:**
- Modify: `landing/pricing.html`

The matrix maps to ROADMAP phases: Phase 1 (Triage, Reply Drafter) + Phase 2 (Booking, Digest, Hygiene) = **Core**; Phase 3 (Lead Qualifier, Proposal Tracker, Follow-up, Outreach, Invoice/Finance, pipeline view) = **Pro**. Phase 0 platform features (on-device Gemma, model picker, local store, offline, no-accounts, open source, signed build) are shared by both tiers.

- [ ] **Step 1: Fill the `#compare` section.** Replace `<section id="compare" aria-label="Feature comparison"><div class="wrap"><!-- Task 3 --></div></section>` with:

```html
  <section id="compare" aria-label="Feature comparison">
    <div class="wrap">
      <div class="sec-head reveal"><p class="eyebrow">The fine print, in full</p><h2>What's in each build.</h2><p>Every feature, mapped to the build you get. Both tiers share the same private, on-device foundation.</p></div>
      <div class="compare-bar reveal">
        <button class="btn btn-ghost" id="compare-toggle" type="button" aria-expanded="false" aria-controls="shared-rows">Show shared foundation</button>
      </div>
      <div class="matrix-wrap reveal">
        <table>
          <caption class="eyebrow" style="margin-bottom:14px;display:block;text-align:left">Feature comparison: Core vs Pro</caption>
          <thead>
            <tr><th scope="col">Feature</th><th scope="col">Core <span class="phase">$99</span></th><th scope="col" class="col-pro">Pro <span class="phase">$199</span></th></tr>
          </thead>
          <tbody>
            <tr><th colspan="3" scope="colgroup">Everyday inbox <span class="phase">Phase 1–2 · Core</span></th></tr>
            <tr><td>Triage — classify, prioritize &amp; label</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Reply Drafter — drafts in your voice</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Booking — calendar-aware scheduling</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Daily Digest — your morning cockpit</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Inbox Hygiene — unsubscribe &amp; declutter</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
          </tbody>
          <tbody>
            <tr><th colspan="3" scope="colgroup">Pro sales suite <span class="phase">Phase 3 · Pro only</span></th></tr>
            <tr><td>Lead Qualifier — score leads, extract intent</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Proposal Tracker — track quotes, nudge stale</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Follow-up — timed nudges on quiet threads</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Outreach — warm-outreach drafts</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Invoice / Finance — extract amounts, flag overdue</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Pipeline / CRM view</td><td class="no">—</td><td class="col-pro yes">✓</td></tr>
          </tbody>
          <tbody id="shared-rows">
            <tr><th colspan="3" scope="colgroup">Private, on-device foundation <span class="phase">Phase 0 · both tiers</span></th></tr>
            <tr><td>100% on-device AI (Gemma via Apple MLX)</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>In-app model picker (by RAM tier)</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Local SQLite store + semantic search</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Works offline (only network hop: your Gmail)</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>No accounts, no telemetry</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Per-agent autonomy dial + audit log</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>Open source (AGPL-3.0)</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
            <tr><td>One-time purchase — no subscription</td><td class="yes">✓</td><td class="col-pro yes">✓</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </section>
```

- [ ] **Step 2: Wire the toggle JS.** In the bottom `<script>`, add immediately after the `document.getElementById('yr')…` line:

```js
  // Compare toggle — progressive enhancement: shared rows visible without JS,
  // collapsed by default once JS runs, and toggled by the button.
  (function(){
    const btn = document.getElementById('compare-toggle');
    const rows = document.getElementById('shared-rows');
    if(!btn || !rows) return;
    function set(expanded){
      btn.setAttribute('aria-expanded', String(expanded));
      rows.hidden = !expanded;
      btn.textContent = expanded ? 'Hide shared foundation' : 'Show shared foundation';
    }
    set(false);                       // JS-on default: collapsed
    btn.addEventListener('click', () => set(btn.getAttribute('aria-expanded') !== 'true'));
  })();
```

- [ ] **Step 3: Validate markup.**

```bash
npx -y html-validate /Users/vishalkumar/Downloads/qmail/landing/pricing.html
```

Expected: PASS (exit 0). Note `colspan` on `<th scope="colgroup">` is valid; `<caption>` must be the first child of `<table>`.

- [ ] **Step 4: Headless-assert the toggle works.** Write `/tmp/toggle.mjs`:

```js
import puppeteer from 'puppeteer';
const url = 'file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html';
const b = await puppeteer.launch();
const p = await b.newPage();
await p.goto(url, { waitUntil: 'networkidle0' });
const sel = '#shared-rows';
const collapsed = await p.$eval(sel, el => el.hidden);                       // expect true (JS collapsed it)
const labelBefore = await p.$eval('#compare-toggle', el => el.textContent.trim());
const ariaBefore = await p.$eval('#compare-toggle', el => el.getAttribute('aria-expanded'));
await p.click('#compare-toggle');
const expanded = await p.$eval(sel, el => el.hidden);                        // expect false
const labelAfter = await p.$eval('#compare-toggle', el => el.textContent.trim());
const ariaAfter = await p.$eval('#compare-toggle', el => el.getAttribute('aria-expanded'));
await p.click('#compare-toggle');
const recollapsed = await p.$eval(sel, el => el.hidden);                     // expect true again
console.log(JSON.stringify({ collapsed, labelBefore, ariaBefore, expanded, labelAfter, ariaAfter, recollapsed }, null, 2));
await b.close();
```

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node /tmp/toggle.mjs
```

Expected JSON exactly:
```
{ "collapsed": true, "labelBefore": "Show shared foundation", "ariaBefore": "false",
  "expanded": false, "labelAfter": "Hide shared foundation", "ariaAfter": "true",
  "recollapsed": true }
```

- [ ] **Step 5: Confirm no-JS graceful degradation.** Write `/tmp/nojs.mjs`:

```js
import puppeteer from 'puppeteer';
const url = 'file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html';
const b = await puppeteer.launch();
const p = await b.newPage();
await p.setJavaScriptEnabled(false);
await p.goto(url, { waitUntil: 'load' });
const sharedVisible = await p.$eval('#shared-rows', el => !el.hidden);       // expect true: rows shown w/o JS
const rowCount = await p.$$eval('#shared-rows tr', els => els.length);
console.log(JSON.stringify({ sharedVisible, rowCount }, null, 2));
await b.close();
```

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node /tmp/nojs.mjs
```

Expected: `"sharedVisible": true`, `"rowCount": 9` (1 group header + 8 feature rows). This proves no information is hidden from no-JS/crawlers/SR.

- [ ] **Step 6: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): feature matrix + accessible compare toggle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Agents section (the 10 real agents)

**Files:**
- Modify: `landing/pricing.html`

Agent names, copy, icons, and Core/Pro chips are copied verbatim from `index.html`'s `#agents` grid (the source of truth) so the two pages never disagree. Order/tiers match the ROADMAP: 5 Core, 5 Pro.

- [ ] **Step 1: Fill the `#agents` section.** Replace `<section id="agents" aria-label="The agents"><div class="wrap"><!-- Task 4 --></div></section>` with:

```html
  <section id="agents" aria-label="The agents">
    <div class="wrap">
      <div class="sec-head reveal"><p class="eyebrow">What you're buying</p><h2>Ten agents. One orchestrator.</h2><p>Each agent does one job well. Core ships five; Pro adds the five-agent sales suite. They propose — you approve.</p></div>
      <div class="agents">
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/></svg><h3>Triage <span class="tier t-core">Core</span></h3><p>Classifies &amp; prioritizes every mail; applies Gmail labels.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg><h3>Reply Drafter <span class="tier t-core">Core</span></h3><p>Drafts replies in your voice → saved as a Gmail draft.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M3 9h18M8 2v4M16 2v4"/><path d="m9 15 2 2 4-4"/></svg><h3>Booking <span class="tier t-core">Core</span></h3><p>Reads your calendar, proposes &amp; confirms meeting times.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2"/></svg><h3>Daily Digest <span class="tier t-core">Core</span></h3><p>Your morning cockpit: what came in, what needs you.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m4 20 4-9 6 6-9 4z"/><path d="m14 11 6-6M16 3h5v5"/></svg><h3>Inbox Hygiene <span class="tier t-core">Core</span></h3><p>Spots newsletters &amp; cold spam; suggests bulk unsubscribes.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.4" fill="currentColor"/></svg><h3>Lead Qualifier <span class="tier t-pro">Pro</span></h3><p>Scores inbound leads; extracts intent &amp; budget; drafts a first reply.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="M6 2h9l5 5v15H6z"/><path d="M14 2v6h6M9 13h6M9 17h6"/></svg><h3>Proposal Tracker <span class="tier t-pro">Pro</span></h3><p>Tracks quotes &amp; their status; nudges the stale ones.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/></svg><h3>Follow-up <span class="tier t-pro">Pro</span></h3><p>Watches quiet threads awaiting their reply; suggests timed nudges.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="m3 11 15-6v14L3 13z"/><path d="M18 8a3 3 0 0 1 0 8"/><path d="M7 13v4a2 2 0 0 0 4 0"/></svg><h3>Outreach <span class="tier t-pro">Pro</span></h3><p>Proactive warm-outreach drafts from your own contacts &amp; history.</p></div>
        <div class="agent reveal"><svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><path d="M5 2v20l2-1.5L9 22l2-1.5L13 22l2-1.5L17 22l2-1.5V2l-2 1.5L15 2l-2 1.5L11 2 9 3.5 7 2z"/><path d="M9 8h6M9 12h6"/></svg><h3>Invoice / Finance <span class="tier t-pro">Pro</span></h3><p>Spots invoices &amp; payment asks; extracts amounts; flags overdue.</p></div>
      </div>
    </div>
  </section>
```

- [ ] **Step 2: Validate + assert counts.** Run `npx -y html-validate …` (PASS). Then verify the agent count and tier split with a one-off node assertion (append to `/tmp/smoke.mjs` or run inline):

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node -e "import('puppeteer').then(async ({default:pp})=>{const b=await pp.launch();const p=await b.newPage();await p.goto('file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html',{waitUntil:'load'});const total=await p.\$\$eval('.agent',e=>e.length);const core=await p.\$\$eval('.agent .t-core',e=>e.length);const pro=await p.\$\$eval('.agent .t-pro',e=>e.length);console.log(JSON.stringify({total,core,pro}));await b.close();})"
```

Expected: `{"total":10,"core":5,"pro":5}`.

- [ ] **Step 3: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): agents section (5 Core + 5 Pro, accurate to plans)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: System-requirements section

**Files:**
- Modify: `landing/pricing.html`

RAM tiers map to the MLX model picker (ARCHITECTURE.md: 8 / 16 / 32 GB+; default small Gemma on 8 GB, larger variants unlocked by RAM). macOS 14+ on Apple Silicon (M1 or newer).

- [ ] **Step 1: Fill the `#requirements` section.** Replace `<section id="requirements" aria-label="System requirements"><div class="wrap"><!-- Task 5 --></div></section>` with:

```html
  <section id="requirements" aria-label="System requirements">
    <div class="wrap">
      <div class="sec-head reveal"><p class="eyebrow">Before you buy</p><h2>What you need to run it.</h2><p>Senani runs Gemma in-process via Apple's MLX, so it needs Apple Silicon. More RAM unlocks larger, sharper models in the in-app picker.</p></div>
      <div class="reqs">
        <div class="req reveal">
          <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v2M15 2v2M9 20v2M15 20v2M2 9h2M2 15h2M20 9h2M20 15h2"/></svg>
          <h3>Apple Silicon</h3>
          <p>M1 or newer (M1/M2/M3/M4, including Pro/Max/Ultra). Intel Macs are not supported — on-device MLX inference requires Apple Silicon.</p>
        </div>
        <div class="req reveal">
          <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="14" rx="2"/><path d="M8 21h8M12 18v3M7 9h10M7 13h6"/></svg>
          <h3>macOS 14+</h3>
          <p>macOS 14 Sonoma or later. Native SwiftUI — no Python, no server, no extra install. The signed, notarized build runs without Xcode.</p>
        </div>
        <div class="req reveal">
          <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="8" width="18" height="9" rx="2"/><path d="M7 8V5M11 8V5M15 8V5M5 21h14"/></svg>
          <h3>Memory (RAM)</h3>
          <p>The model picker offers larger Gemma variants by RAM tier:</p>
          <ul>
            <li><b>8 GB</b> Default small Gemma (4-bit) — runs everything.</li>
            <li><b>16 GB</b> Mid-size models for sharper drafts.</li>
            <li><b>32 GB+</b> The largest variants in the catalog.</li>
          </ul>
        </div>
      </div>
    </div>
  </section>
```

- [ ] **Step 2: Validate.**

```bash
npx -y html-validate /Users/vishalkumar/Downloads/qmail/landing/pricing.html
```

Expected: PASS (exit 0).

- [ ] **Step 3: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): system requirements (Apple Silicon, macOS 14+, RAM tiers)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Pricing FAQ

**Files:**
- Modify: `landing/pricing.html`

FAQ is pricing-focused (the homepage FAQ stays general). Answers must match ARCHITECTURE/ROADMAP exactly.

- [ ] **Step 1: Fill the `#faq` section.** Replace `<section id="faq" aria-label="Pricing FAQ"><div class="wrap"><!-- Task 6 --></div></section>` with:

```html
  <section id="faq" aria-label="Pricing FAQ">
    <div class="wrap">
      <div class="sec-head reveal"><p class="eyebrow">Questions</p><h2>The honest answers</h2></div>
      <div class="faq reveal">
        <details><summary>Is it really pay-once, no subscription?</summary><p>Yes. One payment, yours forever. The price buys the signed, notarized, auto-updating build and a perpetual license. No recurring charge, ever — the same model as SQLite, Plausible, and Immich.</p></details>
        <details><summary>Why pay if the code is open source?</summary><p>The source is free under AGPL-3.0 — build it yourself anytime. The one-time license buys the signed, notarized, auto-updating build (no Xcode required), support, and it funds full-time development.</p></details>
        <details><summary>What's the difference between Core and Pro?</summary><p>Core ($99) is the everyday inbox team: Triage, Reply Drafter, Booking, Daily Digest, and Inbox Hygiene. Pro ($199) adds the sales suite — Lead Qualifier, Proposal Tracker, Follow-up, Outreach, Invoice/Finance, and a lightweight pipeline/CRM view.</p></details>
        <details><summary>Can I upgrade from Core to Pro later?</summary><p>Yes — you'll be able to upgrade for the difference in price. Your Core license carries over; you only pay the gap to Pro.</p></details>
        <details><summary>Which Macs are supported?</summary><p>macOS 14 (Sonoma) or later on Apple Silicon (M1 or newer). 8 GB runs the default small Gemma; 16 GB and 32 GB+ unlock larger models in the in-app picker. Intel Macs are not supported.</p></details>
        <details><summary>Do I need an account?</summary><p>No. Senani has no accounts and no telemetry. Your Gmail OAuth token lives in the macOS Keychain; your mail lives in a local SQLite file on your Mac. Nothing else leaves the device.</p></details>
      </div>
    </div>
  </section>
```

- [ ] **Step 2: Validate + assert `<details>` are keyboard-operable.** Run `npx -y html-validate …` (PASS). Then confirm a `<details>` opens (native, no JS needed):

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node -e "import('puppeteer').then(async ({default:pp})=>{const b=await pp.launch();const p=await b.newPage();await p.goto('file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html',{waitUntil:'load'});const n=await p.\$\$eval('#faq details',e=>e.length);await p.\$eval('#faq details:first-of-type summary',s=>s.click());const open=await p.\$eval('#faq details:first-of-type',d=>d.open);console.log(JSON.stringify({faqCount:n,firstOpens:open}));await b.close();})"
```

Expected: `{"faqCount":6,"firstOpens":true}`.

- [ ] **Step 3: Commit.**

```bash
git add landing/pricing.html && git commit -m "feat(landing): pricing FAQ

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Cross-link from index.html nav

**Files:**
- Modify: `landing/index.html`

The only edit to the existing landing page: point the nav `Pricing` link to the new page. Do NOT touch the hero, the engine animation, or any other section.

- [ ] **Step 1: Repoint the Pricing nav link.** In `landing/index.html`, find the nav link block (currently around line 221):

```html
      <a href="#privacy">Privacy</a><a href="#agents">Agents</a><a href="#how">How it works</a><a href="#pricing">Pricing</a>
```

Replace **only** the Pricing anchor's `href`, leaving the rest untouched:

```html
      <a href="#privacy">Privacy</a><a href="#agents">Agents</a><a href="#how">How it works</a><a href="pricing.html">Pricing</a>
```

> Rationale: `index.html` keeps its inline `#pricing` section (the in-page summary), but the nav now drives users to the dedicated page. The in-hero CTA "Get the build — $99 · soon" (which links `#pricing`) is left as-is, so the in-page section still has an anchor target.

- [ ] **Step 2: Validate both files still pass.**

```bash
npx -y html-validate /Users/vishalkumar/Downloads/qmail/landing/index.html /Users/vishalkumar/Downloads/qmail/landing/pricing.html
```

Expected: PASS for both (exit 0).

- [ ] **Step 3: Commit.**

```bash
git add landing/index.html && git commit -m "feat(landing): link nav Pricing to dedicated pricing page

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Link check (no broken links/anchors)

**Files:**
- (No source changes — verification only.)

- [ ] **Step 1: Run linkinator over both local files.** External links (GitHub, fonts CDN, GSAP CDN) are allowed; we mainly assert local cross-links resolve. Skip flaky external hosts to keep the check deterministic.

```bash
cd /Users/vishalkumar/Downloads/qmail/landing && npm_config_yes=true npx -y linkinator ./pricing.html ./index.html --skip "fonts.g(oogleapis|static).com" --skip "cdn.jsdelivr.net" --verbosity error
```

Expected: terminates with `0 broken` (or no `[BROKEN]` lines) and exit code `0`. Critically, `pricing.html → index.html`, `index.html → pricing.html`, and all `index.html#anchor` links must resolve. If GitHub raw/repo URLs rate-limit (403/429), add `--skip "github.com"` and re-run — those are known-good stubs.

- [ ] **Step 2: Manually confirm the documented CTA stubs.** Grep the page to confirm every buy/download CTA currently points to the documented stub target and the comment block exists:

Use the Grep tool: pattern `github.com/vishalquantana/senani` in `landing/pricing.html` → expect ≥ 4 matches (Star nav, 2 tier CTAs, final CTA). Pattern `CTA TARGETS` → expect 1 match (the documentation comment).

- [ ] **Step 3: Commit (verification log only — no file change).** No commit needed unless a broken link required a fix; if a fix was made, commit it with message `fix(landing): repair broken link in pricing page`.

---

### Task 9: Responsive breakpoint render check

**Files:**
- (No source changes — verification only; fix CSS if an assertion fails.)

- [ ] **Step 1: Headless-assert layout at desktop + mobile widths.** Write `/tmp/responsive.mjs`:

```js
import puppeteer from 'puppeteer';
const url = 'file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html';
const b = await puppeteer.launch();
const out = {};
for (const [name, w] of [['desktop',1280],['mobile',390]]) {
  const p = await b.newPage();
  await p.setViewport({ width: w, height: 900, deviceScaleFactor: 1 });
  await p.goto(url, { waitUntil: 'networkidle0' });
  const pricesCols = await p.$eval('.prices', el => getComputedStyle(el).gridTemplateColumns);
  const reqsCols = await p.$eval('.reqs', el => getComputedStyle(el).gridTemplateColumns);
  const navlinksDisplay = await p.$eval('.navlinks', el => getComputedStyle(el).display);
  // count distinct column widths to infer column count
  const priceColCount = pricesCols.trim().split(/\s+/).length;
  const reqColCount = reqsCols.trim().split(/\s+/).length;
  out[name] = { priceColCount, reqColCount, navlinksDisplay };
  await p.close();
}
console.log(JSON.stringify(out, null, 2));
await b.close();
```

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node /tmp/responsive.mjs
```

Expected:
```
{
  "desktop": { "priceColCount": 2, "reqColCount": 3, "navlinksDisplay": "flex" },
  "mobile":  { "priceColCount": 1, "reqColCount": 1, "navlinksDisplay": "none" }
}
```

This asserts the `@media(max-width:860px)` rules collapse `.prices` and `.reqs` to single-column and hide `.navlinks`, matching `index.html`'s behavior. If any value is wrong, fix the matching `@media` rule and re-run.

- [ ] **Step 2: Headless-assert reduced-motion is respected.** Write `/tmp/reduced.mjs`:

```js
import puppeteer from 'puppeteer';
const url = 'file:///Users/vishalkumar/Downloads/qmail/landing/pricing.html';
const b = await puppeteer.launch();
const p = await b.newPage();
await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
await p.goto(url, { waitUntil: 'networkidle0' });
// reveals must be visible (not stuck at opacity 0) under reduced motion
const revealOpacity = await p.$eval('.reveal', el => getComputedStyle(el).opacity);
const auroraAnim = await p.$eval('.aurora', el => getComputedStyle(el).animationName); // expect 'none'
console.log(JSON.stringify({ revealOpacity, auroraAnim }, null, 2));
await b.close();
```

```bash
cd /tmp && npm_config_yes=true npx -y -p puppeteer node /tmp/reduced.mjs
```

Expected: `"revealOpacity": "1"` and `"auroraAnim": "none"` — confirming the reduced-motion guard works (consistent with the homepage-animations plan's reduced-motion contract).

- [ ] **Step 3: Commit any CSS fix** (only if a step changed source): `git add landing/pricing.html && git commit -m "fix(landing): correct responsive/reduced-motion behavior on pricing page"`.

---

### Task 10: Lighthouse a11y + perf budget

**Files:**
- (No source changes unless a budget fails; then fix and re-run.)

- [ ] **Step 1: Run Lighthouse against the local file via lhci.** Lighthouse needs an HTTP URL, so serve the folder first, then run lhci against the served URL.

```bash
# serve the landing folder on a fixed port in the background
cd /Users/vishalkumar/Downloads/qmail/landing && npm_config_yes=true npx -y http-server -p 8099 -c-1 >/tmp/httpd.log 2>&1 &
sleep 2
npm_config_yes=true npx -y @lhci/cli@latest collect --url=http://127.0.0.1:8099/pricing.html --numberOfRuns=1
npm_config_yes=true npx -y @lhci/cli@latest assert \
  --assertions.categories:accessibility=0.95 \
  --assertions.categories:best-practices=0.90 \
  --assertions.categories:seo=0.90
# stop the server
kill %1 2>/dev/null || true
```

Expected: `assert` passes with **accessibility ≥ 0.95**, **best-practices ≥ 0.90**, **seo ≥ 0.90**. (Perf is not asserted as a hard gate because Lighthouse against a 3rd-party-CDN page on localhost is noisy; instead record the perf score from the `collect` output and confirm it is ≥ 0.85 manually. If perf < 0.85, the likely cause is render-blocking fonts/GSAP — acceptable for a static marketing page, note it.)

> If `lhci` reports the run differently, the equivalent is `npx -y lighthouse http://127.0.0.1:8099/pricing.html --only-categories=accessibility,best-practices,seo,performance --chrome-flags="--headless" --output=json --output-path=/tmp/lh.json` then read the `categories.*.score` values from `/tmp/lh.json` — accessibility must be ≥ 0.95.

- [ ] **Step 2: Fix any a11y failures and re-run** until accessibility ≥ 0.95. Common fixes: contrast on `--faint`/`--muted` text (already AA on the obsidian bg per `index.html`), `aria-label` on icon-only links, `alt`/`role="img"` on inline SVG logos (already added), unique `id`s.

- [ ] **Step 3: Commit any fix** (only if source changed): `git add landing/pricing.html && git commit -m "fix(landing): raise pricing page Lighthouse a11y to target"`.

---

### Task 11: Manual visual checklist + cleanup

**Files:**
- (No source changes — final human-style visual pass + temp cleanup.)

- [ ] **Step 1: Open the page in a real browser and walk the checklist.**

```bash
open /Users/vishalkumar/Downloads/qmail/landing/pricing.html
```

Visual checklist (each must be TRUE):
- [ ] Background matches `index.html`: obsidian gradient, gold/purple aurora, faint grain, gold moon top-right.
- [ ] Nav identical to homepage; **Pricing** link is highlighted (`--gold-bright`, underline) via `aria-current="page"`.
- [ ] Hero: centered logo mark, eyebrow "Own it · Pay once", `h1` "One payment. Yours forever." with italic gold "forever", lead text, value strip of 4 gold-dot items. No canvas particles, no engine box.
- [ ] Tier cards: two side-by-side; Pro card has gold border, gold "Full arsenal" badge, gold button; Core card has ghost button. Amounts read `$99 once` / `$199 once`.
- [ ] Compare toggle button reads "Show shared foundation"; clicking it reveals the 8-row shared-foundation `<tbody>` and the label flips to "Hide shared foundation". The matrix shows ✓ for Core+Pro everyday rows, "—" for Core on the Pro-only sales rows, ✓ for Pro.
- [ ] Agents grid: 10 cards, 5 with grey "Core" chips, 5 with gold "Pro" chips, names exactly Triage / Reply Drafter / Booking / Daily Digest / Inbox Hygiene / Lead Qualifier / Proposal Tracker / Follow-up / Outreach / Invoice / Finance.
- [ ] System requirements: 3 glass cards (Apple Silicon, macOS 14+, Memory with 8/16/32 GB list).
- [ ] FAQ: 6 `<details>`; clicking a summary expands it; the `+` rotates to `×`.
- [ ] Final CTA + footer match the homepage; footer year is current; footer brand links back to `index.html`.
- [ ] Hover states: tier cards lift, agent cards lift, gold buttons get the shimmer sweep.

- [ ] **Step 2: Resize the window narrow (< 860px)** and confirm: nav links hide, tier cards stack to one column, requirement cards stack to one column, matrix scrolls horizontally rather than overflowing, no horizontal page scroll.

- [ ] **Step 3: Toggle macOS "Reduce motion"** (System Settings → Accessibility → Display) or use the browser emulation, reload, and confirm: no aurora drift, no button shimmer, reveal content is fully visible (nothing stuck invisible), toggle/`<details>` still work.

- [ ] **Step 4: Delete the throwaway verification scripts.**

```bash
rm -f /tmp/smoke.mjs /tmp/toggle.mjs /tmp/nojs.mjs /tmp/responsive.mjs /tmp/reduced.mjs /tmp/lh.json /tmp/httpd.log
```

Confirm with `git status` that only `landing/pricing.html` and `landing/index.html` are tracked changes — no stray files in the repo.

- [ ] **Step 5: Final commit (if the checklist surfaced any polish fix).** Otherwise nothing to commit.

```bash
git add -A landing/ && git commit -m "polish(landing): final visual pass on pricing page

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" || echo "nothing to commit — checklist passed clean"
```

---

## Self-Review (against the Goal)

Confirm each goal item is met before declaring done:

- [ ] **Reuses the gold-glass system, hero untouched.** `pricing.html` copies `index.html`'s `:root` tokens, nav, footer, `.btn*`, `.price*`, `.agents`, `.faq`, `.sec-head`, and reduced-motion guards verbatim; the only `index.html` edit is the one nav `href` (Task 7). The existing hero/engine animation (`2026-05-31-homepage-animations.md`) is NOT duplicated or restyled — the pricing hero is a distinct compact, static header. ✔ when Tasks 1 & 7 verify PASS.
- [ ] **Two tiers, $99 / $199, one-time.** Tier cards + matrix both state "once" / "no subscription". ✔ when Task 2 smoke prints `["$99 once","$199 once"]`.
- [ ] **Feature comparison mapped to ROADMAP phases.** Matrix groups: Phase 1–2 = Core, Phase 3 = Pro, Phase 0 = shared. ✔ when Task 3 validates and the no-JS check shows 9 shared rows.
- [ ] **Value props present.** on-device / offline / no-accounts / no-telemetry / pay-once / AGPL-3.0 appear in hero value strip, matrix shared rows, and FAQ. ✔ Task 1/3/6.
- [ ] **Accurate agents, no vaporware.** Exactly the 10 agents from the ROADMAP/agent plans (5 Core + 5 Pro), copy lifted from `index.html`. ✔ when Task 4 prints `{total:10,core:5,pro:5}`.
- [ ] **System requirements.** Apple Silicon M1+, macOS 14+, RAM tiers 8/16/32 GB tied to the model picker. ✔ Task 5.
- [ ] **FAQ.** 6 pricing-focused entries, answers match ARCHITECTURE/ROADMAP. ✔ when Task 6 prints `{faqCount:6,firstOpens:true}`.
- [ ] **Interactive toggle works + degrades.** ✔ when Task 3 toggle test prints the exact expected JSON AND the no-JS test shows shared rows visible.
- [ ] **Responsive.** ✔ when Task 9 prints desktop `{2,3,flex}` and mobile `{1,1,none}`.
- [ ] **Accessible.** Semantic `main`/`nav`/`section`/`header`/`footer`, `aria-current`, `aria-expanded`/`aria-controls`, icon SVGs `aria-hidden`, logo SVGs `role="img" aria-label`, AA contrast. ✔ when Task 10 Lighthouse accessibility ≥ 0.95.
- [ ] **Reduced motion respected.** ✔ when Task 9 reduced-motion test prints `{revealOpacity:"1", auroraAnim:"none"}`.
- [ ] **Documented CTA stubs.** The `<!-- CTA TARGETS -->` comment documents future targets; all CTAs currently point to the GitHub repo. ✔ Task 8 grep.
- [ ] **Link check clean.** ✔ when Task 8 linkinator reports `0 broken`.
- [ ] **Clean repo.** Only `landing/pricing.html` (new) + the one-line `landing/index.html` nav edit are committed; no temp files. ✔ Task 11 `git status`.

If every box is checked with the stated command output observed (evidence before assertion — per superpowers:verification-before-completion), the Phase-4 landing + pricing page is complete.
