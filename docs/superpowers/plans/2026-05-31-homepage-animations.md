# Homepage Animations: The Golden Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a high-fidelity, interactive GSAP-powered "Golden Engine" visualization in the hero section of the Senani landing page.

**Architecture:** Replace the static `.mock` container with a new `.engine-hero` structure. Use CSS Grid for agent formation and GSAP timelines for the choreographed intake/processing/output loop.

**Tech Stack:** HTML5, CSS3 (Vanilla), GSAP 3.12.5.

---

### Task 1: Setup HTML Structure & CSS Foundations

**Files:**
- Modify: `landing/index.html`

- [ ] **Step 1: Replace the existing `.mock` div with the new `.engine-hero` structure.**

Replace (around line 250):
```html
    <div class="mock fade d6">
      <div class="mock-card">
        <div class="mock-top"><i class="tl"></i><i class="tl"></i><i class="tl"></i><span class="mock-title">Senani · 06:58 — handled overnight</span></div>
        <div class="row"><span class="chip c-lead">Lead</span><div><div class="who">Acme Corp — pricing enquiry</div><div class="sub">Reply drafted in your voice · lead scored 87</div></div><div class="act"><i class="pulse"></i>Drafted</div></div>
        <div class="row"><span class="chip c-book">Booking</span><div><div class="who">Priya Nair — “can we meet next week?”</div><div class="sub">3 slots proposed from your calendar</div></div><div class="act"><i class="pulse"></i>Proposed</div></div>
        <div class="row"><span class="chip c-prop">Proposal</span><div><div class="who">Northwind retainer — no reply (5d)</div><div class="sub">Follow-up nudge ready to send</div></div><div class="act"><i class="pulse"></i>Queued</div></div>
      </div>
    </div>
```

With:
```html
    <div class="engine-hero fade d6">
      <div class="engine-stage">
        <!-- Intake Particle -->
        <div class="particle-intake" id="intake-p">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/><rect width="20" height="14" x="2" y="5" rx="2"/></svg>
        </div>

        <!-- The Engine -->
        <div class="engine-box">
          <div class="engine-label">Senani Core Engine</div>
          <div class="agent-formation">
            <!-- Triage -->
            <div class="agent-icon" id="agent-triage" title="Triage">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/></svg>
            </div>
            <!-- Drafter -->
            <div class="agent-icon" id="agent-drafter" title="Reply Drafter">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>
            </div>
            <!-- Booking -->
            <div class="agent-icon" id="agent-booking" title="Booking">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M3 9h18M8 2v4M16 2v4"/><path d="m9 15 2 2 4-4"/></svg>
            </div>
            <!-- Hygiene -->
            <div class="agent-icon" id="agent-hygiene" title="Inbox Hygiene">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 20 4-9 6 6-9 4z"/><path d="m14 11 6-6M16 3h5v5"/></svg>
            </div>
            <!-- Lead -->
            <div class="agent-icon" id="agent-lead" title="Lead Qualifier">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.4" fill="currentColor"/></svg>
            </div>
            <!-- Digest -->
            <div class="agent-icon" id="agent-digest" title="Daily Digest">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg>
            </div>
          </div>
        </div>

        <!-- Output Card -->
        <div class="output-card" id="output-c">
          <div class="card-line"></div>
          <div class="card-line gold"></div>
          <div class="card-line short"></div>
        </div>
      </div>
    </div>
```

- [ ] **Step 2: Add CSS styles for the Engine components.**

Add to the `<style>` block (around line 200):
```css
  /* Engine Hero */
  .engine-hero { margin: 64px auto 0; max-width: 800px; position: relative; }
  .engine-stage { 
    height: 400px; display: flex; align-items: center; justify-content: center; 
    position: relative; perspective: 1200px; 
  }
  
  .engine-box {
    width: 440px; height: 320px; background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(212, 175, 55, 0.25); border-radius: 28px;
    backdrop-filter: blur(25px); transform-style: preserve-3d;
    transform: rotateX(8deg) rotateY(-4deg);
    display: flex; align-items: center; justify-content: center;
    box-shadow: 0 60px 120px -30px rgba(0,0,0,0.9), inset 0 1px 1px rgba(255,255,255,0.08);
  }

  .engine-label {
    position: absolute; top: -35px; left: 0; font-family: var(--wordmark);
    color: var(--gold); font-size: 11px; letter-spacing: 3px; text-transform: uppercase;
  }

  .agent-formation { display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; }
  
  .agent-icon {
    width: 64px; height: 64px; background: rgba(212, 175, 55, 0.03);
    border: 1px solid rgba(212, 175, 55, 0.15); border-radius: 14px;
    display: flex; align-items: center; justify-content: center; color: var(--gold);
    transition: all 0.4s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .agent-icon svg { width: 28px; height: 28px; }

  .particle-intake {
    width: 44px; height: 28px; background: rgba(255,255,255,0.04);
    border: 1px solid var(--line); border-radius: 6px;
    position: absolute; left: 0; opacity: 0;
    display: flex; align-items: center; justify-content: center;
  }
  .particle-intake svg { width: 16px; height: 16px; color: var(--gold); }

  .output-card {
    width: 220px; height: 90px; border: 1px solid var(--gold); border-radius: 14px;
    position: absolute; right: 0; opacity: 0; padding: 16px;
    background: linear-gradient(180deg, rgba(255,255,255,0.08), rgba(255,255,255,0.02));
    backdrop-filter: blur(10px); box-shadow: 0 30px 60px rgba(0,0,0,0.6);
  }
  .card-line { height: 7px; background: rgba(255,255,255,0.1); border-radius: 4px; margin-bottom: 10px; }
  .card-line.short { width: 55%; }
  .card-line.gold { background: var(--gold-grad); width: 45%; }
```

- [ ] **Step 3: Verify the static layout looks correct.**

Expected: The engine box should appear in the hero section, though no animation is running yet.

- [ ] **Step 4: Commit.**

```bash
git add landing/index.html
git commit -m "feat: add Golden Engine HTML/CSS structure"
```

---

### Task 2: Implement GSAP Animation Loop

**Files:**
- Modify: `landing/index.html`

- [ ] **Step 1: Add the `initEngine()` function to the `<script>` block.**

Add to the end of the existing `<script>` block:
```javascript
  function initEngine() {
    if (!window.gsap) return;
    
    const tl = gsap.timeline({ repeat: -1 });

    // 1. Intake
    tl.fromTo("#intake-p", 
      { x: -100, opacity: 0, scale: 0.5 }, 
      { x: 220, opacity: 1, scale: 1, duration: 1.1, ease: "power2.in" }
    )
    
    // 2. Processing (Impact & Flash)
    .to(".engine-box", { 
      scale: 1.04, 
      boxShadow: "0 0 70px rgba(212, 175, 55, 0.45)", 
      borderColor: "#f4dd95",
      duration: 0.25 
    })
    .to("#agent-triage", { background: "rgba(212, 175, 55, 0.35)", borderColor: "#f4dd95", duration: 0.3 }, "<")
    .to("#agent-lead", { background: "rgba(212, 175, 55, 0.35)", borderColor: "#f4dd95", duration: 0.3 }, "+=0.1")
    .to("#agent-drafter", { background: "rgba(212, 175, 55, 0.35)", borderColor: "#f4dd95", duration: 0.3 }, "+=0.1")
    .to("#intake-p", { opacity: 0, scale: 0, duration: 0.15 }, "<")

    // 3. Output
    .fromTo("#output-c", 
      { x: -50, opacity: 0, scale: 0.8 }, 
      { x: 80, opacity: 1, scale: 1, duration: 0.7, ease: "back.out(1.5)" }
    )
    
    // 4. Cooldown
    .to(".engine-box", { 
      scale: 1, 
      boxShadow: "0 60px 120px -30px rgba(0,0,0,0.9)", 
      borderColor: "rgba(212, 175, 55, 0.25)", 
      duration: 1.2 
    })
    .to(".agent-icon", { background: "rgba(212, 175, 55, 0.03)", borderColor: "rgba(212, 175, 55, 0.15)", duration: 1 }, "<")
    .to("#output-c", { opacity: 0, x: 150, duration: 0.6 }, "-=0.6");
  }
```

- [ ] **Step 2: Call `initEngine()` inside the `matchMedia` callback.**

Modify the `gsap.matchMedia()` block:
```javascript
    mm.add('(prefers-reduced-motion: no-preference)', ()=>{
      // ... existing scroll animations ...
      initEngine(); // Start the engine loop
    });
```

- [ ] **Step 3: Verify the animation loop.**

Expected: An email particle enters the box, specific agents glow (Triage -> Lead -> Drafter), and a draft card emerges.

- [ ] **Step 4: Commit.**

```bash
git add landing/index.html
git commit -m "feat: implement GSAP Golden Engine animation loop"
```

---

### Task 3: Mobile Responsiveness & Polish

**Files:**
- Modify: `landing/index.html`

- [ ] **Step 1: Adjust the engine scale for mobile screens.**

Add to the `@media(max-width:860px)` block:
```css
  .engine-hero { transform: scale(0.8); margin-top: 40px; }
  .engine-box { width: 340px; height: 260px; }
  .agent-icon { width: 48px; height: 48px; }
  .agent-icon svg { width: 20px; height: 20px; }
```

- [ ] **Step 2: Verify on small screen sizes.**

- [ ] **Step 3: Final check for `prefers-reduced-motion`.**

Ensure the static state is acceptable when motion is disabled.

- [ ] **Step 4: Commit.**

```bash
git add landing/index.html
git commit -m "style: adjust engine animations for mobile responsiveness"
```
