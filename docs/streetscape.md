# Accra streetscape

The single-junction and corridor visualizers share a detailed procedural
environment. This is an Accra-inspired visual reconstruction, not a surveyed
digital twin. Both scenes now render their existing SUMO networks in metres. Neither change alters the
trained models or SUMO network inputs.

## Metric roads — 15 November 2026

Both scenes use **one Godot unit per metre**. Road ribbons, junction outlines,
corner walking areas, zebra crossings, stop bars and footways are generated
from `simulation/corridor.net.xml` or `simulation/intersection.net.xml` through
read-only JSON exports. J0/J1/J2
are now 300 m apart. Motor lanes are 3.2 m wide: the main carriageway is 12.8 m,
and cross streets are 6.4 m or 12.8 m according to the existing lane counts.
All four single-junction arms have 12.8 m carriageways. Footways are 1.5 m
and crossings are 4 m wide. These are the current synthetic
SUMO network's dimensions, not surveyed Accra measurements or a design-standard
compliance claim.

Vehicles use the same coordinate transform and simulated length/width (cars
4.5 m long, trotros 7 m). Minibus display height is 2.4 m because the route
file omits height and SUMO falls back to a passenger-car default. Front-bumper
positions are converted to mesh centres. Neither scene squeezes
queues or hides tails to fit compressed links; the separate render cap is
2,000 vehicles. Sidewalk and crossing pedestrians follow SUMO positions;
independent decorative sidewalk walkers are disabled in both scenes.

Commercial frontages, taller buildings, signals, sensor coverage illustrations,
streetlights and billboards now follow the larger layout. The corridor trotro stops
keep their original SUMO longitudinal locations, with off-road bays, entry/exit
aprons and lowered footway sections. The single-junction stops are at ±330.4 m
and remain curbside stops in their actual SUMO lane; they are not falsely drawn
as off-road parking. Pull-in offsets remain visual: SUMO still
controls parking, stopping, boarding and departure. This does not add a new
simulated access lane or model its pedestrian conflicts. Airport and residential
background precincts remain illustrative, with their earlier decorative local
roads; they are not surveyed or part of the AI-controlled network.

The corridor opens at J1. Outside drone mode, **1 / 2 / 3** focus J0 / J1 / J2,
**0** frames the corridor, **R** resets and **H** flies the drone. Drone cruise
and fast modes cover the larger area, and both scenes report metres and metres per second. **V** in the single
junction enters ground-level navigation at a 1.62 m eye height, with collision
on the generated road and footway surfaces. In flight, 1 / 2 / 3 still select speed presets.

Regenerate only the display export after an intentional network change:

```sh
.venv/bin/python3 scripts/export_corridor_geometry.py
.venv/bin/python3 scripts/export_corridor_geometry.py --check
.venv/bin/python3 scripts/export_corridor_geometry.py --single
.venv/bin/python3 scripts/export_corridor_geometry.py --single --check
godot --headless --path visualizer --script res://tools/validate_metric_single.gd
godot --headless --path visualizer --script res://tools/validate_metric_corridor.gd
```

`build_network.py` refreshes the corresponding display export after each
successful network build. This renderer migration did not run netconvert, modify route
files, change observation slots or replace model checkpoints. Retraining is
not needed for the display change; measured geometry or lane-count changes
would require new simulation evaluation and model compatibility checks.

Validation: generated geometry matches the source; a 40-car queue retains all
40 positions at 7 m intervals; zoning and station alignment checks pass in
both scenes. The real SUMO crossing replay completes 119 corridor crossings
with no reported vehicle collisions; the renderer checks 7,774 stopped-front
samples and 1,152 pedestrian samples with no queue overlaps. The single-junction replay checks 3,928 stopped fronts
and 296 crossing samples, also without queue overlaps. The live
SUMO → WebSocket → Godot test verifies moving cars, changing signals and
controller metadata. These are scenario regression results, not a field-safety
certification.

## Shared visual features

- Main-road frontages are commercial: glazed supermarkets, two-storey malls,
  open mechanic workshops with service cars and tyre stacks, police stations,
  independent shops and corrugated kiosks. Fascia signs and entrances face the
  road; paved approaches cross the drains at the actual shop entrances.
- Homes are confined to interior compounds, at least 12 scene units from the
  arterial road surfaces. The single scene has two tall apartment blocks and four tall offices;
  the metric corridor has seven apartment blocks and three offices of eight
  storeys or more. Taller buildings have entrance paving,
  planted troughs, balconies or sunshades, and rooftop service details.
- Districts and access streets are placed before roadside infill. Full plot
  checks protect building spacing, neighbourhood entrances, parking, billboard
  plots and trotro stations. The corridor uses one roadside building row,
  removing the second row that crowded the districts behind it.
- Houses and shops use hipped metal roofs or parapets, window reveals and
  frames, security bars, doors, projecting sills, balconies, drainpipes,
  rooftop tanks, AC units, and shaded shopfronts. Shop names are illustrative.
- Compounds have paved yards, piers, gates, and palms. Offices have individual
  glazing bays and sunshades. Schools, clinics, warehouses and factories use
  the same material palette and architectural kit.
- Asphalt, plaster, and dry ground use bundled photographed color, roughness
  and height maps, with world-space projection and procedural weathering.
  Concrete, paving, sheet metal and bark add procedural seams and grain. Rain
  changes surface roughness and darkens materials through the existing weather
  controller. Height detail changes shading without displacing the road mesh.
- Surrounding neighbourhoods use irregular plots, compound walls, varied roof
  shapes and a street grid, replacing the isolated ring of distant buildings.
- Trees have branching trunks and instanced leaf clusters; palms have curved
  fronds. Soft noise-shaped cloud layers replace the faceted sphere clouds.
- Cars use curved coachwork, fitted glazing, mirrors, door seams, wheel arches,
  alloy wheels, taxi trim and several paint colours. Wheel rotation follows
  distance travelled; front wheels steer into turns. Headlights and brake
  lights respond to driving conditions. Traffic, parked and residential cars
  share the same mesh kit; the ambulance retains its bundled model.
- Trotros use a dedicated cab-over minibus body, side stripes, roof racks,
  destination boards, yellow registration plates and sliding passenger doors.
  SUMO vehicle types now select the correct pool, replacing the random choice
  of vans for unrelated car IDs.
- Each scene has two trotro stations with shelters, benches, dispatch desks,
  route signs, lighting, a spare minibus and marked curbside loading bays.
  The visualizer servers schedule real SUMO stops on eligible existing trotros,
  add up to three riders per pickup within the vehicle's available capacity,
  and let SUMO handle boarding and departure after a 22-second dwell.
  Waiting passengers approach the open door and duck as they enter.
- Pedestrians use smooth anatomical meshes, cloth shading, varied skin tones,
  clothing, hair, hats and bags. Distance-driven foot placement, bending knees,
  counter-swinging arms, breathing and head turns replace rigid box characters.
  Ambient walkers accelerate, pause, ease into turns and keep passing lanes and
  following distances. Crossing pedestrians still follow SUMO snapshots.
- Traffic signals have tapered galvanized masts, curved arms, braces, bolted
  bases, rounded housings, sun hoods and individual LED lenses. Three-aspect
  roadside repeaters include amber and follow the overhead phase. CCTV cameras,
  radar radomes and controller cabinets have brackets, seals, optics and cables.
  These are visual representations; SUMO supplies the traffic data. **K** shows
  the camera sightlines, hidden by default.
- Billboards occupy reserved plots outside the road and walking strips: two
  in the single-junction scene and three in the corridor. Printed graphic
  panels, structural supports and dusk lighting replace the oversized text
  boards. Direction signs replace floating junction labels; fitted fascia
  signs attach to shopfronts. Advertising and shop names are illustrative.
- The default camera is perspective. **P** toggles the orthographic plan view.
  **R** resets, **H** flies the drone, and **V** enters street-level walking
  in the single-junction scene. Existing mouse and keyboard zoom still work.
- Drone flight uses smooth target velocity, normalised diagonal input, automatic
  hover and a swept collision body. **1/2/3** select Inspect/Cruise/Fast;
  **Shift** boosts and **X** brakes. **F** switches chase/gimbal cameras;
  wheel or pinch adjusts lens zoom. A spring arm keeps the chase camera clear
  of obstacles. Compass, minimap, speed and height instruments replace the old
  hint line. **Tab** releases the mouse and restores the dashboard while the
  drone hovers; losing window focus also stops movement. **R** resets to a safe
  home point. Position and view persist across toggles within the same scene.
  Rain tracks the active camera and its altitude in all navigation modes.
- The drone itself uses a sculpted survey airframe: curved shell and battery
  cover, articulated arm hinges, cooling slots, brushless motor housings,
  swept two-blade airfoils, slim navigation LEDs and rubber landing pads.
  Its suspended camera has dampers, yokes, a layered lens and a gimbal that
  counters body bank and follows camera pitch. Static geometry is baked by
  material; rotors and gimbal remain animated. The design is project-authored.

The existing launcher starts the environment as usual: open
`visualizer/project.godot` in Godot 4.6+ Standard, press F5, and pick a scene.
Forward+ is the intended renderer for ambient occlusion, indirect lighting,
soft shadows, and tone mapping. Shader materials also render in Compatibility;
screen-space lighting effects depend on renderer support.

## Source

| File | Responsibility |
| --- | --- |
| `visualizer/scripts/EnvironmentBuilder.gd` | District layouts, setbacks, gutters, landmark placement, day/night lighting |
| `visualizer/scripts/AccraStreetscape.gd` | Architecture, foliage, parking, simplified building colliders and spatial mesh batches |
| `visualizer/scripts/AccraStreetLife.gd` | Roadside traders, hawkers, okadas, hand carts, direction boards and open drains |
| `visualizer/scripts/StreetscapeMaterials.gd` | Cached surface materials, seeded noise and weather wetness |
| `visualizer/shaders/streetscape_*.gdshader` | Surface detail, leaves and clouds |
| `visualizer/scripts/CloudManager.gd` | Drifting cloud layers, time/weather tinting |
| `visualizer/scripts/PedestrianActor.gd` | Character geometry, distance-driven gait and two-bone leg placement |
| `visualizer/scripts/PedestrianManager.gd` | Ambient movement, passing lanes and SUMO crossing interpolation |
| `visualizer/scripts/SignalHardware.gd` | Shared mast assemblies, LED lenses and three-aspect repeaters |
| `visualizer/scripts/SensorBuilder.gd` | Mounted CCTV, radar, cabinets and optional camera sightlines |
| `visualizer/scripts/StreetSignLayout.gd` | Billboard positions and reserved plots shared with the environment builder |
| `visualizer/scripts/BillboardBuilder.gd` | Printed advertising panels, lighting and direction signs |
| `visualizer/scripts/PropGeometry.gd` | Cached primitives, rounded housings, anatomical lofts and fitted lettering |
| `visualizer/scripts/VehicleActor.gd` | Cached car/minibus bodywork, rotating wheels, lights and sliding doors |
| `visualizer/scripts/VehicleManager.gd` | Type-specific pools, snapshots and curbside stop presentation |
| `visualizer/scripts/DroneController.gd` | Assisted flight, collision, camera views, input and audio |
| `visualizer/scripts/DroneAirframe.gd` | Sculpted drone body, motors, propellers, sensors, gimbal and livery |
| `visualizer/scripts/DroneHUD.gd` | Compass, minimap, instruments and cursor-release notice |
| `visualizer/scripts/TrotroStationManager.gd` | Station geometry, waiting queues and boarding presentation |
| `visualizer/assets/transit/stations.json` | Shared station positions, SUMO edges, stop positions and destination labels |
| `scripts/trotro_service.py` | Visualizer-only TraCI stop scheduling and actual SUMO passengers |

Repeated architectural parts and foliage use MultiMesh batches grouped into
24-unit cells (64-unit cells without shadows for the distant backdrop).
Detailed trim and leaves do not create physics bodies. Building
envelopes and compound boundaries retain collisions for walking mode; distant
background blocks are decorative. Roofs also share an instanced mesh. Fonts
reuse existing bundled resources. Vehicle bodies are cached by variant and
batched by material; only wheels, lights and doors animate. Nine 1K CC0 texture maps
add about 4.7 MB of source assets, with credits and verified download checksums
in `visualizer/assets/streetscape/`. There is no runtime network dependency.
Sign artwork in `visualizer/assets/signs/` is project-authored SVG. Character
meshes are procedural game characters, not scanned humans or motion capture.
Temporal antialiasing smooths fine geometry and soft-shadow noise in Forward+.

## Trotro service and simulation scope

Station names and vehicle designs are illustrative Accra-inspired assets, not
surveyed terminal layouts or manufacturer-licensed models. The shared station
JSON reserves clear plots in the environment builder and aligns each loading
bay with its actual SUMO stop. Both scenes use metres. A smooth lateral offset draws corridor parking
services in their loading bays. Single-junction curbside stops keep the
actual SUMO lane position. SUMO still
owns longitudinal movement, stopping, rider counts and departure.

Transit is enabled by default in both visualizer servers. Stops introduce
additional dwell time into the live traffic simulation. Training/evaluation
scripts, trained checkpoints and benchmark route files are unchanged. Pass
`--no-transit` to either visualizer server for the previous demand behaviour.
The corridor's historical fixed-timer comparison badge is suppressed while
transit is enabled because that benchmark did not include these stops.

The service uses [TraCI vehicle stops](https://sumo.dlr.de/docs/TraCI/Change_Vehicle_State.html)
and [person driving stages](https://eclipse.dev/sumo/docs/TraCI/Change_Person_State.html).
Visual reference photographs, not bundled assets:
[Toyota minibus](https://commons.wikimedia.org/wiki/File:Toyota-van-ghana.jpg),
[trotro station](https://commons.wikimedia.org/wiki/File:TROTRO_STATION.jpg).

## Validation

From the repository root, substitute the path to your Godot executable:

```sh
godot --headless --path visualizer --script res://tools/validate_streetscape.gd
godot --headless --path visualizer --script res://tools/validate_zoning.gd
godot --headless --path visualizer --script res://tools/validate_street_details.gd
godot --headless --path visualizer --script res://tools/validate_transit.gd
godot --headless --path visualizer --script res://tools/validate_drone.gd
python scripts/validate_trotro_service.py --replay /tmp/transit-replay.json
```

The check loads both complete scenes with networking disabled. It verifies
that the detailed architecture and background blocks are built, collision
footprints keep the SUMO roads clear, angled beams meet their anchors, windows
respond to day/night changes, and perspective and plan view zoom work.
A failure exits with a nonzero status.
The zoning check verifies commercial variety, taller apartments and offices,
residential setbacks, pairwise building/plot overlaps, clear internal access
streets and reserved sign/station plots in both assembled scenes.
The street-detail check also verifies frame-rate-independent strides, planted
feet, stopping, passing and turning, crossing heading interpolation and mesh
reuse, all eight signal phases, signal facing directions, camera sightlines,
reserved sign plots and day/night billboard lighting in both scenes.
The transit scene check verifies type-specific pool reuse, wheel rotation,
door/light states, reserved station plots and alignment with SUMO stop positions.
The drone check exercises speed and steering, consistent deceleration, boosted
wall/ceiling collisions, camera obstruction and recovery, input/view controls,
hover on cursor release or focus loss, resumable position, dashboard/camera
handover and rain tracking in both scenes. It also checks that the redesigned
airframe stays inside the collision envelope during banking and rotor motion.
The Python integration check runs both actual networks, verifies boarding and
departure, and exercises a bus leaving a junction so it cannot be offered a
stop behind its current position.

To render an offline image of an application scene, use a graphical display
(not `--headless`) and an absolute output filename:

```sh
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/accra-day.png overview 12
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/accra-street.png street 15.5
godot --path visualizer --script res://tools/preview_streetscape.gd -- corridor /tmp/accra-night.png overview 20
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/accra-rain.png street 14 2
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/accra-buildings.png district 14 0
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/accra-workshop.png mechanic 14 0
```

The final optional weather argument is 0 clear, 1 overcast or 2 rain. Previews hide the HUD and do not start SUMO. For a live capture, run
the appropriate existing Python visualizer server with `--port 8877`, then
append `live` after the weather argument. The preview prints render counters;
those snapshots are diagnostic, not a performance benchmark.
The `district`, `supermarket`, `mall`, `mechanic`, `police` and `apartment`
views inspect the actual assembled buildings. Capture windows ignore keyboard
input so normal application shortcuts cannot disturb a preview.

Close-up previews use the same assembled scenes:

```sh
godot --path visualizer --script res://tools/preview_street_details.gd -- signals /tmp/signals.png single
godot --path visualizer --script res://tools/preview_street_details.gd -- sensor /tmp/camera.png corridor
godot --path visualizer --script res://tools/preview_street_details.gd -- billboard /tmp/billboard.png corridor
godot --path visualizer --fixed-fps 20 --script res://tools/preview_street_details.gd -- people /tmp/walk.png single /tmp/walk-frames
```

The optional final directory exports 100 frames of actual scene motion.

For vehicle and station close-ups, including a replay of the recorded SUMO pickup:

```sh
godot --path visualizer --fixed-fps 20 --script res://tools/preview_transit.gd -- fleet /tmp/cars.png
godot --path visualizer --fixed-fps 20 --script res://tools/preview_transit.gd -- station /tmp/station.png /tmp/transit-replay.json
godot --path visualizer --fixed-fps 20 --script res://tools/preview_transit.gd -- pickup /tmp/pickup.png /tmp/transit-replay.json /tmp/pickup-frames
```

The pickup preview exports 340 frames, replaying recorded simulation seconds
at approximately twice normal speed. It does not change the running simulation.

For a flight HUD screenshot and an optional scripted chase/gimbal sequence:

```sh
godot --path visualizer --script res://tools/preview_drone.gd -- single /tmp/drone.png
godot --path visualizer --script res://tools/preview_drone.gd -- corridor /tmp/drone.png /tmp/drone-frames
godot --path visualizer --script res://tools/preview_drone_model.gd -- /tmp/drone-model.png
godot --path visualizer --script res://tools/preview_drone_model.gd -- /tmp/drone-rear.png rear
```


## Airport and weather pass

The corridor airport is rebuilt in `AirportBuilder.gd`, with a shared site
reservation in `AirportLayout.gd`. The airfield, city frontage, background
blocks and trees respect the same reservation. A road extension connects the
terminal parking/drop-off area to the eastern cross street. The terminal has
curved roof panels, a glazed facade, shade fins, canopies and two elbowed
boarding bridges. The apron contains two original `AircraftModel.gd`
airliners with smooth fuselages, swept wings, winglets, engines and fan blades,
windows, doors and landing gear. Their fictional ACCRA AIR livery does not
represent an operating airline. Tugs, baggage carts, a fuel vehicle, hangar,
control tower, runway markings, taxiway signs and night lighting complete the
precinct. Static geometry is batched by material; simplified collision bodies
support drone navigation.

The architectural reference is the modern terminal and landside organization
shown by [Ghana Airports Company](https://www.gacl.com.gh/projects/). This is
an illustrative, compressed layout. Runway dimensions, headings, stands and
building positions are not surveyed or aviation navigation data. Aircraft and
airport service vehicles are parked scenery; they do not add flight schedules
or airport demand to SUMO.

`CloudManager.gd` now installs `accra_sky.gdshader` in both scenes. It uses
continuous drifting noise layers instead of individual cloud planes, with
coverage, dust and storm shading smoothly driven by `WeatherManager.gd`.
`TimeOfDayManager.gd` and weather write into the same sky material. Sky
radiance uses a cheap gradient during cubemap rendering, while visible clouds
are rendered in the background pass.

Weather transitions use an exponential response independent of frame rate.
Clear, overcast and rain have distinct cloud cover, wind, visibility
and lighting. Rain particles track the current overview/ground/drone camera;
their lifetime adapts to altitude so they reach street level. A snapped 512px
GPU heightfield stops rain at roofs and ground, with no capture updates while
dry. The visible streak angle, foliage movement and airport windsock share
the gusting wind vector. A procedural rainfall loop fades with rain intensity,
alongside the existing delayed thunder.

Surface water accumulates over seconds and evaporates over minutes. Irregular
puddles on upward-facing asphalt, concrete and paving have low roughness,
clearcoat and rain ripples; screen-space reflections enable while surfaces
are wet. These reflections use visible geometry, so off-screen objects are
not guaranteed to appear. Weather affects visual atmosphere/materials and
audio; it does not modify the traffic model's friction or safety behavior.

Validation and actual-scene previews:

```sh
godot --headless --path visualizer --script res://tools/validate_airport_weather.gd
godot --path visualizer --script res://tools/preview_streetscape.gd -- corridor /tmp/airport.png airport 13 0
godot --path visualizer --script res://tools/preview_streetscape.gd -- corridor /tmp/terminal.png terminal 14 0
godot --path visualizer --script res://tools/preview_streetscape.gd -- corridor /tmp/airport-night.png airport 20 0
godot --path visualizer --script res://tools/preview_streetscape.gd -- single /tmp/rain.png weather 15 2
```

The validator checks airport obstructions, apron clearance, batched wing/tail
visibility, street access, clock/weather sky sharing, night/storm lighting,
frame-independent transitions, rain reaching the ground, and drying after a
shower. Preview scripts settle weather and wetness before capture; normal
application weather changes retain their gradual transitions.


### Crossing clearance and street lighting

`TrafficLayout.gd` is the shared coordinate contract for all four zebra
crossings, the approach stop bars, vehicles and crossing pedestrians. SUMO
reports a vehicle's front-bumper position; centred meshes are placed behind
that point using the vehicle's actual length. Stop bars end at incoming SUMO
lane endpoints, before the zebra markings. The network's walking areas join
crossings to footways. Both scenes preserve vehicle spacing and complete queue
geometry, subject to the separate 2,000-vehicle renderer cap. Existing station
locations remain anchored to their physical SUMO stops.

The visualizer servers apply `CrossingSafety` before each SUMO step. Turns yield
to enabled pedestrian crossings, and occupied crossings hold conflicting
movements until people finish. The policy still requests the phase; this live
visualizer clearance layer does not rewrite the training environments or
checkpoints. Packets carry the actual per-arm aspects, signal effective time,
and progress along each crossing's real SUMO geometry. `SignalPlayback` and
pedestrians use the vehicle playback clock. Empty pedestrian updates retire
actors after their final rendered sample, preventing frozen or early-vanishing
walkers. People may briefly yield to one another; the clearance hold lets them
finish even after the pedestrian entry signal changes.

`StreetLamp.gd` replaces the box lamps with tapered galvanised masts, curved
arms, bolted bases, service hatches, finned LED housings and photocells. Neutral
warm LED optics and downward spotlights brighten smoothly around dusk/dawn;
heavy rain and cloud cover also increase demand. Distance fading limits the
cost of distant light pools. Lamp bodies are shared batched meshes.

Regression commands (SUMO replay generation needs a local TraCI socket):

```sh
.venv/bin/python3 scripts/validate_crossing_safety.py --output /private/tmp/crossing-replay
godot --headless --path visualizer --script res://tools/validate_crossings.gd
godot --headless --path visualizer --script res://tools/validate_live_traffic.gd
godot --headless --path visualizer --script res://tools/validate_street_details.gd
godot --headless --path visualizer --script res://tools/validate_transit.gd
godot --path visualizer --script res://tools/preview_crossings.gd -- corridor /tmp/crossings.png 326 14.5
```

The seeded 420-second runs exercised 148 crossing pedestrians across both
networks; all finished, with zero SUMO vehicle-collision reports. Godot checks
12,492 stopped-front samples, 1,448 crossing samples, queue spacing, delayed
actor retirement, actual signal aspects/effective times and day/night/rain lamp
response. These are regression results for those scenarios, not a guarantee
about every traffic-demand configuration.

## Compact corridor town — 16 November 2026

The broad metropolitan grid has been replaced with a compact developed strip:
`CityDistrictBuilder.TOWN` is 368 × 1000 m, centred on the three junctions.
The main roads retain their SUMO dimensions and 300 m junction spacing. Only
the scenery footprint is smaller; approach lanes still extend to their actual
network endpoints. Local streets and parked vehicles do not add SUMO demand.

Larger arterial shops and mixed-height corner blocks define the streets.
Infill combines apartments, offices, walled homes, a mall, supermarket and bank
with the existing school, clinic, market and industrial premises. Shared paved
frontages, service yards and planted courts replace isolated pads on grass.
Street reservations precede frontage placement; local asphalt and footways are
clipped at arterial junctions and local street mouths to keep them open.

`AirportBuilder.gd` again supplies the active airport: a curved terminal,
two detailed parked airliners, boarding bridges, baggage vehicles, tower and
hangar. `AirportLayout.gd` reserves a 144 × 213 m site at (135,50), with the
original detailed precinct scaled uniformly by 1.5. Its runway is deliberately
compressed scenery, not an operational-length runway or a surveyed Kotoka model.
The access road reaches the J0 cross street.

Press **4** outside drone mode for the airport; **1/2/3** return to the junctions.
Fog density uses metre-scale view distances. Run `validate_city_expansion.gd`,
`validate_zoning.gd`, `validate_airport_weather.gd` and
`validate_metric_corridor.gd` after changing placement. The first validator keeps
its earlier filename but now checks the compact town and two-stand airport.

### Four-section redesign and aerial review

The subsequent aerial review exposed two problems: the repeated ground scan
looked like cultivated rows, and identical square compounds made the whole
town read as a plot grid. The town-wide laterite slab and uniform infill rows
have now been removed. Surface kinds 9 and 10 use non-periodic world-space
noise for weathered hardstand and quiet natural ground; fine surface relief
fades with screen footprint. The airport turf also avoids the repeated soil
scan. Existing asphalt, markings, crossings and metre-scale lanes are retained.

The three cross roads define four separately authored sections. Camera keys
below apply outside drone mode:

| Key | Section | Layout |
| --- | --- | --- |
| 5 | J0–J1 commercial | Deep commercial courts, attached building wings, varied roof lengths, smaller infill tenancies and service canopies |
| 6 | J1–J2 civic and shopping | Mall and bank courts, school playing field, clinic, a planted public green and a few office/apartment landmarks |
| 7 | North of J2 | Walled family courts and apartments behind the commercial frontage; workshops and warehouses on the western side |
| 8 | South of J0 | Three covered market aisles with stalls and cross passages, smaller shops and low residential courts around the existing street loop |

`UrbanBlockKit.gd` composes each court from separate building envelopes, with
asymmetric wings, different heights, lean-to service roofs, solar canopies and
marked parking. The frontage and original destinations remain reserved before
new infill is placed. Irregularly sampled planting softens the edges; larger
trees use clear trunk reservations. The ambient residential traffic loop stays
at its existing coordinates. Parked courtyard vehicles are scenery, never
reported as AI-controlled traffic or added to dashboard metrics.

Visual references were reviewed as references only, not bundled as textures:
[Guido Sohne's Oxford Street photograph](https://commons.wikimedia.org/wiki/File:Oxford_Street,_Osu,_Ghana.jpg)
and the [Oxford Street aerial property photographs](https://african.land/real-estate/commercial-properties-for-sale/land-available-on-oxford-street-osu-for-sale-or-joint-venture_i54).
The useful features were the varied low-rise roofscape, closely grouped
premises, small internal courts, service areas and continuous shopfronts. This
remains a procedural, Accra-inspired environment rather than a surveyed model.

Each section was rendered individually during the redesign. The metric
corridor validator also accepts `section1` through `section4`, `plan`, or
`review` as its second user argument after the output image path. `review`
saves both an overhead image and a `-street.png` view from the assembled scene.
The city validator checks all four sections remain populated; zoning checks
building pairs, local streets, live carriageways, residential setbacks and
reserved station/sign plots. Metric validation covers queue spacing and the
new section camera shortcuts.

## Accra street character — 16 November 2026

An aerial and street-level review found that the scenes read as a tidy
temperate suburb: brown brick-like blocks on grey paved courts, lawns, a square
street grid with kerbed footways on every back street, and nobody on the
roadside. This pass replaces that look in both scenes. The SUMO roads, lanes,
crossings, footways, signals, stations and vehicles are unchanged, and so are
the networks, routes, observations and checkpoints.

What now carries the place:

- **Green ground, red earth where it's worn.** On 17 Nov 2026 the user chose a
  green ground over the red-brown one. Open ground is rainy-season grass that
  dries to olive in swathes, with laterite only in small worn patches (surface
  kind 3 in the single scene). The corridor's ground plane (kind 10, tint
  `4f6a33`) is green coastal savanna. Under the town it stays mostly grass,
  worn to swept laterite in broad patches. The worn area frays into the bush
  along a noisy edge taken from `CityDistrictBuilder.TOWN`, not along the plan
  rectangle. Roadside aprons, shoulders, yards and tracks keep their red earth.
  The soil photograph fades out with distance, so it no longer tiles from the
  drone.
- **Painted sandcrete.** Walls use emulsion colours over a darker oil-paint
  dado, with sun fade, rain streaks and laterite splash-back at the foot of
  every wall. Public school and clinic blocks are yellow over brown; police
  stations are white over blue. Uncompleted buildings and fitting shops show
  bare 460 × 230 mm blockwork (kind 11).
- **Storey buildings.** `building()` makes the shop-below, rooms-above block
  with a verandah on posts, a line of lock-up stores under a flat canopy, or a
  plain house. Roofs are long-span sheets in oxide red, blue, green and
  weathered zinc, hipped or gabled, or a flat slab with a parapet, a black
  polytank, a dish and often column starter bars for a floor not yet built.
  Lock-up bays have steel double doors, mostly open on stocked shelves, with
  stock on the apron and a signboard each. `uncompleted()` adds the grey
  shells with sand, blocks and a red "STOP WORK / PRODUCE PERMIT" notice.
- **Container kiosks, fitting shops, flats and offices** are restyled to
  match: painted steel boxes with a propped awning, a zinc-roofed workshop with
  tyres and an engine block, flats with a balcony, condenser and washing per
  unit and a row of polytanks, and blue-glass offices with white fins.
- **The trading apron.** Shop fronts stand 7 m behind the footway in the
  corridor and 6 m in the single scene. Lamp columns and utility poles keep
  the first strip; the corridor then has an open concrete drain with slab
  crossings; the rest is swept earth. `AccraStreetLife.gd` fills it with
  umbrella traders, table sellers, produce heaps, hawkers with head pans,
  okada riders, hand carts and direction boards. Side-street mouths get a
  cluster of boards and an okada rank, and each trotro station a row of
  traders behind its bays. All of it is batched scenery placed off the
  carriageway and footway. None of it is a SUMO pedestrian or vehicle, and it
  adds nothing to the dashboard counts.
- **Town layout.** The corridor keeps its street reservations, but back
  streets lose their kerbed footways for earth shoulders, three side lanes are
  unsurfaced laterite with wheel ruts, courts become earth yards with a zinc
  lean-to, a tank stand, washing and unmarked parking, and residential infill
  is mostly walled compounds. Only the mall and bank keep marked asphalt car
  parks. Bush, scattered trees and clustered outlying compounds thin out
  beyond the town edge in place of an empty plain.
- **Corridor landmarks.** Two Sankofa filling stations front the main road
  (z 236 east, z 672 west). A steel footbridge crosses it at z 462 between the
  school and the clinic, with dog-leg stairs down to each apron; its piers are
  solid but the deck has no collider, because it spans the carriageway. Three
  red-and-white lattice telecom masts stand in walled compounds. The lorry
  park beside the market holds eight parked trotros, a taxi rank, the
  bookman's shed and traders. The business quarter's three towers and the six
  apartment blocks now have metre-scale floor plates and storey heights. Shade
  trees stand on the aprons every thirty-odd metres. Shop doors carry a strip
  light that comes on at dusk. These reserve their ground before the shop
  rows are placed, so the frontage, drain and traders leave them clear. Parked
  vehicles are scenery and add no demand.
- **Planting.** Trees are drawn as dark domed mango, open neem, tropical
  almond or flamboyant in red flower; coconut palms have arching fronds and
  are batched; compounds get plantain clumps and bougainvillea on the wall.
- **Light.** Daytime fill is warmer and a little stronger, as light bounced
  off red ground is, and the horizon is hazier.

Shop, church, school and hotel names are invented in the style of Accra
signboards. No real business, telecom or fuel brand is shown.

Rendering changes that matter when editing the kit:

- Every `StreetscapeMaterials.solid()` and coloured `surface()` material now
  carries its colour and a shared white material as metadata. `_batch()` draws
  through the shared material and passes the colour per instance, so a cell
  needs one draw call per finish, not one per paint colour. A material from
  these two functions must therefore not be modified after creation to change
  batched geometry; night-lit materials are created separately and are not
  affected. The surface shader multiplies `tint` by the instance colour.
- Fine trim (window bars, sills, railings, starter bars, stock, washing,
  trader figures) is emitted between `_detail = true` and `_detail = false`.
  Those batches cast no shadows and are hidden beyond 140 m.
- Surface kind 0 has two branches. Vertical faces are painted walls. Upward
  faces keep the earlier treatment because the carriageway mesh uses kind 0;
  leave that branch alone when changing wall weathering.
- In the foliage shader an instance colour with zero blue is blossom: red when
  green is high (flamboyant), magenta when low (bougainvillea).

Measured on the same corridor camera views before and after (1440 × 900, one
machine, render counters only, not a frame-rate benchmark), with all the added
street life and landmarks included:

| View | Draw calls before → after | Primitives before → after |
| --- | --- | --- |
| Aerial over J0–J1 | 14,453 → 9,232 | 10.3 M → 7.0 M |
| Street level, looking north | 18,527 → 12,086 | 12.2 M → 8.7 M |
| Shop frontage | 8,322 → 5,843 | 6.3 M → 4.8 M |

`tools/preview_views.gd` renders any number of named camera views of either
scene in one launch:

```sh
godot --path visualizer --script res://tools/preview_views.gd -- corridor /tmp/out 13 0 \
  "aerial=-150,120,130>0,0,300@60" "apron=-10.5,1.7,95>-12.5,1.6,140@66"
```

Arguments are the scene, an output directory, the hour, the weather index and
then `name=from>look_at[@fov]` for each view. A recorded crossing replay in
`/private/tmp`, when present, supplies traffic.

## Night, paved districts, vehicle lamps and sound — 16 November 2026

**Night.** The corridor used to fall to black between lamps, and from the drone
the roads vanished. Three changes, none of which touch the simulation:

- `TimeOfDayManager` adds a shadowless `MoonLight` (energy 0.42 at full night)
  and raises the night ambient and horizon to a city skyglow, so roofs, ground
  and carriageway stay readable.
- `StreetLamp` throws a wider, longer cone (76°, 24 m, energy 9) that reaches
  across all four lanes and meets the next lamp's pool. Its distance fade now
  starts at 250 m.
- `LampPools.gd` (corridor) lays one additive quad under every lamp in a single
  MultiMesh. It strengthens as the real spot lights fade with distance, so the
  lit corridor still reads from high up.
- Traders, kiosks and market stalls carry a bulb, and open shop doors a strip
  light, all on the kit's early-evening window material.

**Vehicle lamps.** `VehicleActor` lenses are always present (clear and dark red
by day) and switch between shared off, lit and brake materials. Each vehicle
adds two additive meshes through `vehicle_glow.gdshader`: lamp halos plus the
pool its headlights or tail lights throw on the road, which read from any
distance. The real headlight beam is longer (22 m) and fades between 60 and
100 m from the camera. Brake lights flare at night through a per-instance
`boost`; by day they only brighten the lens.

**Paved districts.** Not all of Accra is red earth. `CityDistrictBuilder.PAVED`
names two kept districts: the business quarter between J0 and J1, and the
mall, bank and office frontage north of J1. Inside them the ground plane is
interlocking concrete block (the `paved_a` / `paved_b` uniforms of surface kind
10), aprons are block paving with a red band behind the footway, the drain
runs under cover slabs, side streets get kerbed block footways, courts are
forecourts with marked bays, planters and palms, and frontages have planters
and fewer traders. Buildings batched there carry a low instance alpha, which
the wall and roof shaders read as less splash-back and rust. Infill there
places no uncompleted shells or vacant plots. South of J0 and north of J2 stay
earth, so the corridor shows both.

**Sound.** The old audio was a constant 110 Hz hum, a 660 Hz beep at every
phase change and engines made of stacked sine tones. A first replacement added
synthesised engine loops per vehicle, a traffic-roar bed and street murmur.
The owner heard that as the same fake engine noise starting with the sim and
never stopping, so every continuous layer is gone. What remains:

- `TrafficAudio.gd` plays an occasional horn tap from a vehicle near the
  listener (gaps of 2.5 to 7 s at the least, none in the first 6 s), crickets
  at night and a few birds by day, both low. A silent layer is stopped, not
  left running. **M** mutes and unmutes all sim sound.
- There are no engine loops, no traffic roar and no murmur. Do not add a
  continuous synthesised layer back; if richer sound is wanted it needs real
  recordings and the owner's go-ahead.
- `scripts/build_soundscape.py` synthesises the six remaining WAV files into
  `visualizer/assets/audio/` (1.7 MB, 32 kHz, no recordings or third-party
  samples); the folder has a `.gdignore` and the files are read directly.
- An `AudioListener3D` sits near what the camera looks at, at most 60 m from
  it, and a hard limiter on the master bus holds the sum under full scale.
- `AudioManager`'s hum is retired and its phase beep is a faint low tick.
- Rain, thunder and the drone's own buzz (drone mode only) are unchanged.

A headless probe of the running corridor lists every player: by day only the
birds layer sounds, at about −45 dB, with the three old generator players
pushing silence.

The company motto shown in the sim is "Valiborn Tech. Build Beyond." The
earlier one is retired.

## Shorter roads and three weathers — 16 November 2026

**Drawn window.** The SUMO approaches run 1.5 km beyond the outer junctions to
where traffic is inserted. Drawn in full they were long empty roads into
nothing. `CorridorGeometry.VIEW` (x ±380, z −430 … 1030, past both trotro
stations) is now the window the corridor scene draws: carriageway, footways,
markings, street lamps, light pools, utility poles and shoulders all stop at
it. Each road end sits inside a belt of forest whose crowns close over the
carriageway, and vehicles fade in over the last 35 m as they enter the window
and out as they leave. The network, routes, SUMO positions, the controller and
the HUD and dashboard counts are untouched and still cover every vehicle. One
consequence: a queue longer than a visible approach (about 420 m on the main
road, 370 m on the cross streets) continues out of sight. The single junction
still draws its full roads.

**Weather.** Harmattan is removed. The modes are 0 Clear, 1 Overcast, 2 Rain
in `WeatherManager`, the HUD, the tools and the validators.

