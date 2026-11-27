# Indoor map runtime bundle

Only deployment assets live here: three compiled floor scenes and a sanitized manifest with verified store bindings. The app does not require source screenshots, OCR output, CSV imports, research scripts, manual review files, or a map provider key to display these scenes.

Each scene retains its source model revision. The manifest records its SHA-256 over `JSON.stringify(parsedScene)`; `indoor-assets.js` checks both the revision and checksum before serving it. A changed scene must be exported together with its matching manifest. Bindings reference stable floor/region IDs and must be reviewed before publication.

Source extraction, annotations and review history remain on the `junyue/indoor-map-research` / `junyue/store-bindings` branches. This is a display model in screenshot pixels, not a surveyed navigation map. AR integration is separate.
