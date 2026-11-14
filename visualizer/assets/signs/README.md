# Roadside sign artwork

`valiborn.svg`, `akwaaba.svg` and `connect.svg` are project-authored vector
designs for the simulation. They contain geometric artwork; `BillboardBuilder.gd`
adds fitted text in Godot. The advertising copy is illustrative, not an actual
advertiser placement or endorsement.

Edit `StreetSignLayout.gd` to relocate billboards. The same plot definitions
reserve space in `EnvironmentBuilder.gd`, so buildings and trees do not occupy
the advertising sites. SVG textures import with mipmaps for distant viewing.
