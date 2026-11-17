# Soundscape

These WAV files are synthesised by `scripts/build_soundscape.py`. They contain
no recordings and no third-party samples. Regenerate them with:

```sh
.venv/bin/python3 scripts/build_soundscape.py --report
```

`TrafficAudio.gd` reads them straight from disk, so the folder carries a
`.gdignore` and Godot does not import them.
