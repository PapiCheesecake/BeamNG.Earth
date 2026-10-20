-- EarthSync (BeamNG.Earth on BeamMP): keep the sync extension loaded across level changes; the mod
-- manager loads every 'manual' extension right after the modScripts (see scripts/beamng_earth).
setExtensionUnloadMode('beamngEarthMP', 'manual')
