# BeamNG.Earth on BeamMP (EarthSync)

This branch is **BeamNG.Earth 1.5.3-beta** plus **EarthSync**: players close to each other (within 5 km) share one
world origin, so their tiles and cars line up; players further apart are ghosts to each other (their cars are hidden
until they're close again).

## Players

### Requirements

1. **The same BeamNG.Earth version as the server.** Download the `.exe` from the **same release** of this fork as
   the server's mod zip ([releases](https://github.com/PapiCheesecake/BeamNG.Earth/releases)), not TecnaGamer's
   `.exe` and not an older or newer one. The `.exe` runs the companion that builds your world (it also has the RHD
   sign fix); a different version doesn't match the server's mod.
2. **A `BeamNG Earth` folder** (anywhere, e.g. your Desktop) with exactly these two files in it:
   - the BeamNG.Earth `.exe` (its name must start with `BeamNG` and contain `Earth`)
   - [`server.bat`](beammp/player/server.bat) from this repo

   ```
   BeamNG Earth/
   ├── BeamNG.Earth-1.5.3-beta-mp.1.exe
   └── server.bat
   ```

   Always start the companion with `server.bat`, never the `.exe` on its own. `server.bat` starts it with:
   - `--no-game`: only the companion; you start the game with the BeamMP launcher
   - `--keep-mod`: never puts the normal BeamNG.Earth mod back into your mods folder (it would clash with the
     server's MP mod)
   - `--update-check off`: no "new version" prompt, so you stay on the server's version
3. **No normal BeamNG.Earth mod installed.** Before joining, delete this folder if it exists:
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_earth`
   (paste `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked` into File Explorer's address bar). BeamMP downloads the server's MP version of the
   mod for you; with the normal one also installed, the two copies clash and the sync can quietly stop working.
   Opening the `.exe` directly puts that folder back, so check again if you ever did.

### Every time you play

1. Run `server.bat`. Keep its window open while you play.
2. Start the BeamMP launcher and join the server.

## Server owners

1. Put the client mod zip in `Resources/Client/`. Build it from this branch with
   `python beammp/build_client_zip.py` (it writes `beammp/dist/BeamNG_Earth_153_MP.zip`), or download it from the
   release.
2. Copy [`beammp/Server/EarthSync/`](beammp/Server/EarthSync) to `Resources/Server/EarthSync/` (the release has it as
   `EarthSync_server_plugin.zip`).
3. In `ServerConfig.toml`, set the map to BeamNG.Earth's level:
   ```toml
   Map = "/levels/beamng_earth/info.json"
   ```
4. Start the server.

Tell your players which release the server runs, so they download the matching `.exe`.

## What EarthSync changes

- `mod/beamng_earth/lua/ge/extensions/beamngEarthMP.lua` (new): the sync (positions and origins, groups, ghosts).
- `mod/beamng_earth/scripts/beamng_earth_mp/modScript.lua` (new): keeps the sync loaded.
- `mod/beamng_earth/lua/ge/extensions/beamngEarth/core.lua`: `adoptOrigin` (switch to another player's origin), and
  the mod only ever moves your own car, not another player's (spectating with Tab).
- `beammp/Server/EarthSync/main.lua` (new): the server plugin that relays each player's position and origin.
