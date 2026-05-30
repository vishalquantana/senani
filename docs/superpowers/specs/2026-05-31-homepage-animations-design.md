# Senani — Homepage Animations: The Golden Engine (Design Spec)

**Date:** 2026-05-31
**Status:** Approved design — ready for implementation planning
**Scope:** A high-fidelity, interactive GSAP-powered visualization for the Senani landing page hero section. This "Golden Engine" replaces the static mock-up with a dynamic representation of Senani's core value proposition: private, offline agent orchestration.

---

## 1. Goals & Non-goals

### Goals
- **Explain at a glance**: Visually demonstrate how raw emails are processed by a team of local agents to produce refined results.
- **Premium Aesthetic**: Reinforce the "gold-glass" visual identity with smooth, 60fps GSAP animations.
- **Offline Representation**: Use a contained, transparent box to symbolize the secure, on-device processing environment.
- **Performance**: Ensure the animation is lightweight and handles window resizing/responsiveness gracefully.

### Non-goals
- **Live Data**: This is a choreographed visualization, not a live dashboard of real user data.
- **Interaction (Phase 1)**: The primary goal is an auto-playing loop. User-triggered interactions (like the simulator concept) are deferred.

---

## 2. Visual Architecture

### 2.1 The Engine Box (The Container)
- **Style**: Glass-morphism (blur + semi-transparent background).
- **Structure**: A 3D-feeling rounded rectangle using `perspective` and `rotateX/Y` to give depth.
- **Border**: A thin, golden stroke with subtle glowing highlights.
- **Label**: "Senani Core Engine" in Cinzel font, positioned as a small tag above the box.

### 2.2 The Agent Formation (The Internal Team)
- **Grid**: A 3x2 grid of agent icons centered inside the Engine Box.
- **Icons**: SVG representations of:
  1. **Triage** (Classifies & prioritizes)
  2. **Lead Qualifier** (Scores inbound leads)
  3. **Reply Drafter** (Drafts in user's voice)
  4. **Booking** (Calendar management)
  5. **Inbox Hygiene** (Spam/Newsletter cleanup)
  6. **Daily Digest** (Morning cock-pit view)

### 2.3 The Intake (Email Particles)
- **Visual**: Small, stylized email icons or "data bits" (golden rectangles).
- **Trajectory**: Accelerate from the left edge of the hero section towards the center of the Engine Box.

### 2.4 The Output (Result Cards)
- **Visual**: Polished "Draft Cards" with golden accents and line-placeholders.
- **Trajectory**: Emerge from the right side of the box with a "pop-out" bounce effect.

---

## 3. Animation Choreography (GSAP Loop)

The animation follows a repeating loop:

1. **Intake Phase**: 
   - An "Email Particle" scales in and accelerates toward the box (`ease: "power2.in"`).
2. **Collision & Impact**: 
   - As the particle hits the box, the Engine Box scales slightly and glows (`boxShadow`).
   - The particle disappears.
3. **Processing Phase (The Choreography)**:
   - Specific agents light up in a sequence (e.g., Triage → Lead Qualifier → Reply Drafter).
   - "Lighting up" involves increasing background opacity, brightening the border, and adding a subtle inner glow.
4. **Completion Phase**:
   - A "Result Card" pops out from the right side of the box with a slight bounce (`ease: "back.out"`).
   - The card fades out as it moves further right.
5. **Cooldown**:
   - The engine and agents return to their standby state (faint glow).

---

## 4. Implementation Details

- **Technology**: GSAP 3.x for all motion, CSS for styling and layout.
- **Placement**: Replace the `.mock` div in `landing/index.html`.
- **Responsiveness**: Use `clamp()` and relative units (vh/vw) to ensure the engine scales appropriately on mobile devices.
- **Accessibility**: Wrap all logic in `gsap.matchMedia()` to respect `prefers-reduced-motion`.

---

## 5. Success Criteria
- The animation explains the "Private Engine" concept in under 5 seconds of viewing.
- The visual style matches the existing "Senani" branding (Gold, Ink, Glass).
- No performance regressions on mobile or low-power devices.
