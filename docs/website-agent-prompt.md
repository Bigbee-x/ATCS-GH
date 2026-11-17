# TrafIQ website implementation handoff

Prepared 17 November 2026. Read this as my task instructions, then inspect the
current project; the simulation and its documentation may have changed since
this handoff was written.

## 1. Your task

Act as the product designer, frontend engineer and technical visualisation
engineer for **TrafIQ**, a traffic-intelligence project by **Valiborn
Technologies**, founded by **Osborn Dogbe** in Accra, Ghana.

Revamp the existing TrafIQ website into a polished, useful product experience
with current project information, fresh imagery from the actual simulator and
working interactive 3D hardware models. Implement and test it. Do not stop at a
mood board, architecture proposal, static mockup or placeholder model viewer.

The site should help a transport stakeholder understand the problem and product,
a technical visitor inspect how the system works, and a prospective collaborator
find a credible next step. It should feel precise and grounded in Accra, with
strong visual storytelling and clear engineering evidence.

The local project is:

`/Users/osborn/Developer/ATCS-GH`

A website/pitch page exists at:

`/Users/osborn/Developer/ATCS-GH/docs/pitch/index.html`

Treat that as a starting point to inspect, not proof that it is the current
production website. Look for the actual website repository, framework, domain,
deployment configuration and existing routes. If the public website lives
elsewhere, locate it from available project context or ask me for its URL/repo.
Continue the content and asset audit while that information is pending. Do not
silently replace an unrelated website, migration target or marketing stack.

Preserve the dirty worktree and other agents' work. Read applicable AGENTS.md
instructions. Do not reset/clean the repository, overwrite simulation code,
retrain agents or replace checkpoints. Website work must not alter controller
behaviour. Keep website assets and any model-export utilities separate from the
live simulation runtime.

## 2. Read the actual product state first

Inspect these files under `/Users/osborn/Developer/ATCS-GH/`:

- `CLAUDE.md` and `README.md`, including their distinction between current and
  historical findings.
- `docs/corridor-interface.md` — current in-simulation UI and its data semantics.
- `docs/traffic-observation-contract.md` — separation of traffic intelligence
  from visual appearance.
- `docs/corridor-handoff-review-20261116.md`.
- `docs/corridor-deployment-validation.md` and
  `docs/corridor-deployment-results.json` — measured evidence and known limits.
- `docs/tsh1-sensor-interface.md` — sensor concept, hardware proposal, schema,
  emulator results and physical-sensing limitations. Later corridor sections
  supersede older single-junction/open-item passages.
- `docs/streetscape.md` and `visualizer/README.md` — current visual assets,
  capture tools, geometry and attribution context.
- `docs/corridor-next-session-prompt.md` — planned intelligence work, which is
  not automatically an implemented capability.
- The actual site source and its existing analytics, forms, links and metadata.

Prepare a concise content/claims audit before writing marketing copy. For each
substantial claim, record its source, date, applicable scenario/version and
status: implemented, simulation-tested, hardware concept, or planned. Keep this
in maintainable project documentation; do not expose internal file paths on the
public page.

Important facts to preserve:

- **The N6 three-junction corridor is the sole active simulation product.**
  J0 is Achimota, J1 is Asylum Down, and J2 is Nima/Tesano. Four scenery districts
  do not mean four traffic-control agents. The single-junction experience is
  retired from the launcher and remains historical reference only.
- Current control uses trained policies plus a supervisor. Rich neighbour
  communication, new cooperative training and optional Ollama analysis are
  engineering workstreams; check their implementation status before advertising
  them. Do not describe existing limited state sharing as proven network-wide
  coordination. Ollama is not the signal controller.
- Godot renders the scene; SUMO and the Python runtime supply authoritative
  traffic/control data. The policy focuses on road topology/capacity, vehicles,
  pedestrians, signals and qualified sensor measurements. Cosmetic buildings,
  textures, camera motion and weather graphics are not policy inputs.
- Current TSH-1 heads and their displayed coverage are sensor-design visualisations.
  Frame reconstruction tests are software-equivalence evidence, not proof of
  physical detection accuracy, all-weather performance or field certification.
- TSH-1 is a proposed multisensor roadside head, with radar, wide and tele
  cameras, thermal sensing and edge compute. Proposed specifications and
  component choices must be labelled as design targets unless build/test
  evidence establishes more. Do not treat IP ratings, power budgets, range or
  component prices in concept notes as certified specifications or sales prices.
- The old pitch includes broad “40–98% lower wait” claims, single-junction
  results, “coordinated by default”, and claims about surveyed geometry/training
  time. Audit rather than copying them into the new hero, SEO metadata or schema.
  Current corridor audits include unresolved failures and regressions. Do not
  imply field deployment, universally superior control, commercial availability,
  named partnerships or deployment approval without evidence.

Explain maturity clearly and briefly. Keep historical results accessible with
context where useful; do not let old impressive numbers stand in for current
corridor evidence. Do not invent customers, testimonials, live counters, partner
logos, hardware stock, launch dates, impact statistics or certification badges.

## 3. Brand and visual direction

My company colours are **monochrome with an orange accent**. This overrides the
old pitch's CSS comment describing a locked red palette and the former green
simulator styling.

Use the current interface as a reference:

- Charcoal/near-black: `#111111`.
- Neutral surfaces around `#191919` / `#202020`.
- White/off-white: `#EEEEEE`.
- Secondary grey around `#A4A4A4`.
- Orange accent: `#F59A50`.

A clean light editorial surface is also acceptable where it improves reading.
Use an accessible darker orange or dark text for buttons/links on light surfaces;
do not assume the light-orange token has enough text contrast on white.

Give the website its own considered layout; it should not be a stretched copy
of the simulation HUD. Use confident typography, generous spacing, a clear grid,
precise diagrams, strong image composition and restrained borders. Let orange
identify actions, selection and a few important details. Avoid neon green,
colourful dashboard clutter, gratuitous glows, excessive glass effects, constant
motion, stock robot imagery and generic “AI brain” graphics. Real signal lamps
may retain their red/amber/green aspects for technical clarity.

Preserve the TrafIQ name and Valiborn Technologies attribution. The current
company motto is “Valiborn Tech. Build Beyond.” Do not revive retired slogans.

## 4. Site structure and visitor journey

Adapt to the existing site architecture. A focused product homepage with deeper
hardware/evidence views is preferable to many empty pages. Include:

1. **Hero:** a direct explanation of TrafIQ's corridor traffic-intelligence
   purpose, an excellent current simulator visual, and a clear primary action
   such as “Explore the corridor”. A secondary “Explore TSH-1” action can lead to
   the hardware explorer. Do not start with an unsupported percentage claim.
2. **The traffic problem:** concise, local context about changing demand,
   downstream queues, pedestrians and trotro boarding. Verify any external
   statistics before using them; qualitative explanation is sufficient.
3. **How TrafIQ works:** a legible sensing → semantic observations → local
   control/supervision → signal operation → measured outcomes flow. Clearly
   distinguish the simulator implementation from the proposed physical path.
4. **The corridor:** J0/J1/J2, their relationship, real simulator screenshots,
   short explanations of queues, crossings, boarding and downstream capacity.
   An interactive schematic may select junctions and explain their role.
5. **Hardware explorer:** the working TSH-1 and mounted signal/cabinet models
   described below, with verified annotations and maturity labels.
6. **Simulation and operator tools:** the new monochrome/orange HUD, measured
   traffic information, inspection tools and visual testing environment. Explain
   that changing scenery does not retrain or change the controller.
7. **Evidence and development status:** dated, scoped results and a simple
   implemented/in-progress/planned distinction. Explain what a displayed metric
   measures; avoid comparing incompatible wait/delay measures.
8. **About/contact:** TrafIQ, Valiborn Technologies and a genuine next step for
   demonstrations, technical collaboration or pilot discussions. Check the
   existing contact details; do not invent an email/domain or claim to submit
   a form if no receiving service exists.

Remove pitch-deck-only content that no longer serves a general website, such as
an application addressed to one specific organisation, unless I confirm that
this is still the site's purpose. Preserve useful information in an archive
rather than rewriting history.

## 5. Fresh images and media

Produce a coherent asset set, not just a new colour scheme around old images.
Use the latest actual simulator wherever possible. Capture/review at least:

- A strong wide corridor hero showing the three-junction environment.
- A closer streetscape/crossing view with vehicles and pedestrians.
- A useful day/night pair or short optional comparison.
- A clean view of the new HUD, plus a focused Traffic/Controls detail.
- A studio-style TSH-1 product render with readable lenses, radome, housing,
  cooling details and mounting assembly.
- A contextual view of TSH-1 mounted on a signal arm with its cable route.

Useful existing references, which must be inspected for currency:

- `logs/corridor-hud-20261116/preview-overview.png`
- `logs/corridor-hud-20261116/preview-traffic.png`
- `logs/corridor-hud-20261116/hud-traffic.png`
- `logs/corridor-hud-20261116/hud-controls.png`
- `logs/corridor-handoff-review-20261116-172818/views/aerial.png`
- `logs/corridor-handoff-review-20261116-172818/views/apron.png`
- `visualizer/tools/preview_views.gd`
- `visualizer/tools/preview_corridor_hud.gd`
- `visualizer/tools/validate_live_traffic.gd` and its optional `--hud` captures.

These log directories are local and gitignored. Copy selected, optimised assets
into the website's deployable public/assets directory; the published page must
not depend on `/Users/...`, `/private/tmp`, gitignored logs or a local server.

Captions must distinguish simulator screenshots, recorded snapshots, hardware
concept renders and real photographs. A recorded simulation view is not live
traffic in Accra. Do not remove a truthful replay/concept label to make an image
seem more impressive. Do not paint fictional telemetry over a screenshot.

Use image generation when useful for supporting concept imagery or backgrounds,
following the available image-generation skill. Keep the hardware design faithful
to its source and label generated concepts appropriately. Generated raster images
are not a substitute for the required interactive models. Use licensed or owned
photographs; maintain source/credit/licence records. Review bundled model/texture
licences rather than assuming anything present in the repository is cleared for
all web distribution.

Export responsive AVIF/WebP where supported, with sensible fallbacks, dimensions,
alt text and crops. Preserve high-resolution masters separately. If you add a
short simulation clip, supply a poster and playback controls, respect reduced
motion/data preferences and avoid autoplay audio.

## 6. Interactive 3D — required deliverables

Implement at least **two functioning 3D experiences**. A screenshot, rotating
video, static CSS illustration or empty canvas does not satisfy this requirement.

### A. TSH-1 sensor-head explorer — highest priority

Show the actual proposed industrial design, with appropriate body proportions,
radome, optical/thermal windows, sun shield, rear cooling features, cable
connector and mounting yoke/clamp. Starting source:

- `visualizer/scripts/SensorBuilder.gd`
- `visualizer/scripts/PropGeometry.gd`
- `docs/tsh1-sensor-interface.md`

The existing source describes a nominal 220 × 120 × 160 mm body; verify against
current geometry/specification before showing dimensions. Do not present the
mount or shield's total bounds as body dimensions.

Provide:

- Pointer/touch orbit and zoom, sensible camera limits, reset view, and useful
  named front/rear/mounted views.
- Accessible, labelled hotspots for radar, wide camera, tele camera, thermal
  sensing, housing/cooling, mount and power/data connection where supported.
- A linked HTML parts list so every annotation remains usable without dragging
  a 3D canvas. Hotspots must stay attached to the correct part during rotation.
- Component isolation or an exploded presentation where the source geometry
  supports it. Mark schematic internal arrangements as illustrative; do not
  invent an engineered PCB/interior or imply manufacturing readiness.
- An optional coverage toggle labelled “Illustrative coverage”, with confirmed
  design units/ranges. It must not claim measured coverage or see through all
  traffic/structures by default.

### B. Signal assembly and junction cabinet

Show a mounted signal head, TSH-1, mast arm/pole, pedestrian signal and cabinet
relationship. Starting source:

- `visualizer/scripts/SignalHardware.gd`
- `visualizer/scripts/SensorBuilder.gd`

Explain mounting, intended power/data routing, the role of the local controller
and the difference between sensing and signal authority. Provide isolated-part
views and a reset. A clearly labelled illustrative signal-state selector may
change the model's lamp appearance; it is not an operational traffic command.
Do not animate conflicting movements or represent an invented phase sequence as
an approved safety design. Cabinet internals should remain schematic unless
actual design evidence exists.

### Optional additions after both required models work

A simplified three-junction educational scene can show upstream/downstream queue
relationships. Clearly label illustrative animation or recorded data. A drone
explorer may reuse `visualizer/scripts/DroneAirframe.gd`, but describe it as the
simulator's navigation/inspection visual unless a real hardware product is
separately documented. Do not market the navigation drone as TrafIQ's deployed
traffic sensor or a manufactured aircraft.

## 7. Model preparation and browser implementation

Inspect what already exists before choosing a library. Hardware is currently
procedural Godot geometry; do not assume ready-made TSH-1 GLB files exist.
Vehicle GLBs in `visualizer/assets/vehicles/` are not substitutes for sensor models.

Create an isolated export/build workflow or faithfully rebuild the required
hardware in a browser-friendly source format. Deliver real GLB/glTF assets (or
an equivalently reproducible browser scene), editable source and export commands.
Do not execute or modify the entire live simulation just to generate a product
model. Inspect exports for lost MultiMesh instances, transforms, materials,
normals, scale, camera orientation and hidden/duplicated geometry. Translate or
bake Godot-specific shaders into portable materials. Keep stable part names so
annotations and future updates remain maintainable.

Preserve the site's existing framework when it is suitable. For a conventional
asset viewer, evaluate `<model-viewer>`; for custom isolation, coverage geometry,
exploded assemblies or educational scenes requiring scene-graph control,
evaluate Three.js. Use a React wrapper only if the site already benefits from
React. Do not introduce a large app stack just to host a product page. Check
current official documentation, pin dependencies and explain the chosen tradeoff.
Useful starting references:

- https://modelviewer.dev/
- https://modelviewer.dev/examples/annotations/
- https://threejs.org/docs/

Use a proper asset pipeline, not a third-party iframe as the sole experience.
Keep visualisation read-only: no public visitor action may send commands to a
local simulator, physical signal controller or private traffic service. A public
site must work independently of SUMO, Godot and a developer's localhost.

## 8. Performance, accessibility and failure handling

The website must work well on mobile devices and ordinary connections:

- Show a high-quality poster before loading 3D. Load the viewer/model on user
  intent or near visibility; avoid downloading every model on initial load.
- Run at most one active 3D viewer by default, pause rendering offscreen/when the
  tab is hidden, and dispose of replaced resources.
- Compress geometry/textures appropriately. As initial project budgets, aim for
  a featured model under 3 MB and the non-3D initial page transfer under 1.5 MB.
  These are design targets, not claims already measured; record actual sizes
  and justify exceptions rather than making the model unusable to meet a number.
- Keep model dimensions reserved to prevent layout jumps. Show genuine loading,
  error/retry and unsupported-WebGL states. Essential content and annotations
  must still be available with JavaScript/WebGL unavailable.
- Make controls keyboard-accessible with visible focus, readable contrast,
  descriptive labels and touch-friendly targets. Do not trap scroll or keyboard
  focus inside the viewer. Offer reset and clear interaction instructions.
- Respect `prefers-reduced-motion`. No forced continuous rotation or mandatory
  scroll-driven camera movement. A rotation toggle should be opt-in.
- Test narrow mobile, tablet and desktop layouts, including long labels and
  large text. Use semantic headings and useful alt text.

Measure loading and interaction costs and report the test conditions. Do not
claim a Lighthouse/Core Web Vitals score without running the relevant check;
lab results are not field measurements.

## 9. Keep content maintainable and accurate

Separate content, verified specifications, status labels, media metadata and
hotspot definitions from rendering code. Maintain an asset manifest with source,
licence, capture date, simulator/design version, alt text, poster path and model
size. Keep a claim-to-source register for numerical and maturity claims.

Update page title, description, social image, favicon and structured metadata to
the current branding and evidence. Remove unsupported numbers from metadata too.
Use valid canonical URLs only after identifying the actual domain. Preserve
useful existing routes/redirects and working contact behaviour. Never ship a
fake form-success state or hard-code secrets/API keys into the client.

Future artwork changes must be easy to replace without revising scientific
claims or teaching the signal policy anything. Keep “implemented”, “tested in
simulation” and “proposed hardware” distinct in both content and interactions.

## 10. Work sequence and acceptance

1. Inspect the site/workspace; record the content and asset audit and any missing
   production-repository information. State a concise visual/technical direction.
2. Implement the responsive page structure and corrected copy using real assets.
3. Create the optimised hardware exports and working TSH-1 explorer.
4. Implement the mounted signal/cabinet explorer and remaining media.
5. Test the real build in browsers: model loading, orbit/zoom/reset, every
   hotspot, keyboard/touch controls, failure/fallback states, responsive layouts,
   reduced motion, links and contact flow. Check console/network errors and
   asset paths from a production-style build, not only the development server.
6. Capture desktop and mobile screenshots and a short demonstration of the 3D
   interactions. Inspect them, fix visible issues, and report measured asset sizes
   and performance limitations.
7. Deliver the implementation, editable assets/export tools, update documentation,
   reproducible build/preview commands, validation results and remaining items.

Finish with a working, reviewable preview. Follow any production-deployment
authorisation already given in this session; otherwise prepare the concrete
release before asking to publish. Do not purchase services, change DNS or alter
production infrastructure as an assumed part of a visual redesign.

Acceptance requires a useful current corridor website, consistent monochrome/
orange branding, genuine fresh project imagery, both working interactive hardware
experiences, usable mobile/fallback paths, accurate evidence/status labelling,
and preserved simulator/controller work. Do not call placeholder models,
unverified claims or a broken mobile viewer “complete”.

Begin by inspecting the actual website and current product evidence, then carry
the implementation through asset creation, browser verification and delivery.
