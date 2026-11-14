# Transit layout

`stations.json` is shared by the Python visualizer service and Godot station
builder. Each scene has two illustrative station sites. `edge` and `pos` locate
the actual SUMO stop on lane 1, the curbside vehicle lane. `z` is the same point
under the visualizer's existing piecewise map; the validation script checks it.

`side`, `road_half` and `sidewalk` locate the waiting area and reserve an 8×14
plot behind the sidewalk. Names, destination labels and registration numbers
are illustrative. New vehicle and station meshes are project-authored code;
no external vehicle artwork is required.

The service is active only in the visualizer servers. `--no-transit` disables
stops and passengers without changing the scenery or evaluation configurations.
