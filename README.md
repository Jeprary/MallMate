# MallMate

MallMate recommends places to eat, get drinks, shop, and find entertainment inside Taicang Wanda Plaza. Ask in your own words, for example, “I want something hot to eat, but no hot pot.” MallMate uses your preferences and available store information, including listed opening hours, to suggest places and show where they are in the mall.

RouteWalk is the companion iOS app for on-site AR guidance.

The live MallMate application uses Softr as its database. DeepSeek powers AI store recommendations, and Qwen provides streaming speech recognition.

<p align="center">
  <img src="docs/images/mallmate-orb.png" alt="MallMate home screen with the green voice orb at Taicang Wanda" width="320">
</p>

## Start here

- [Open the live MallMate website](https://mallmate.pages.dev/). The shopper experience is available as a guest.
- [Download the course materials ZIP](#download-the-course-materials).
- [Deploy your own server and configure DeepSeek, Qwen and Softr credentials](deploy/README.md).
- [Import the 65 published stores into Softr](data/README.md). Use your own Softr workspace to inspect or edit a copy of the catalogue.

## Download the course materials

1. Download [mallmate-course-materials-20261124.zip](https://github.com/Jeprary/MallMate/releases/download/course-materials-20261124/mallmate-course-materials-20261124.zip) from GitHub Releases.
2. Extract the ZIP beside the MallMate source folder. Keep the extracted top-level folder. If you downloaded the source from `main` as a ZIP, the source folder is named `MallMate-main`.

```text
MallMate/                              source code
mallmate-course-materials-20261124/
  README.md                            contents and source notes
  images/                              204 store, dish and welcome images
  image-attribution.csv                image sources and checksums
  data/                                65-store snapshot and Softr CSV
  maps/                                compiled 1–3F maps and manifest
```

Open the extracted `README.md` to review the materials. The source already includes the catalogue and 2.5D maps needed to run the website. The extracted images can be viewed locally, and the running website loads its store photos from production URLs.

## Setup checklist

| Goal | Prepare | Follow |
| --- | --- | --- |
| Local store browsing and the 1–3F maps | This source package, Node.js 22 and npm. Store photos use the internet. | [Run the website locally](#run-the-website-locally). The included catalogue needs no credentials. |
| Your own Softr data, AI recommendations or speech recognition | Personal accounts and credentials for the services you want to test. For microphone testing on a phone, use HTTPS. | [Create and install provider credentials](deploy/README.md#optional-provider-credentials). |
| Scan and navigate a route on an iPhone | A Mac with Xcode, your development signing team and an ARKit-capable iPhone on iOS 26 or later. Use a short route you can visit in person. | [Build RouteWalk](#build-routewalk), then [scan and try a route](#scan-and-try-a-route-on-site). |
| Open a specific route from the phone browser | RouteWalk built from this package, a route saved on the same iPhone and access to configure an HTTPS deployment of this web source. | [Deploy the web source](deploy/README.md), then [bind the store to the route](#open-routewalk-from-the-map). |

## Run the website locally

With Node.js 22 and npm installed, run these commands from the repository root.

```sh
npm ci --prefix web --omit=dev --ignore-scripts
node --env-file-if-exists=.env start-local.cjs
```

Open [the local site with the Stores tab available](http://127.0.0.1:8766/?nav=on) or [UNIQLO on the local 2.5D map](http://127.0.0.1:8766/?screen=map&store=amap-B02001HUD4&nav=on). The default snapshot requires no keys. Store photos use the live public asset URLs and require internet access.

Start the local server before opening `web/index.html`. Opening the file directly uses the default local address, `http://127.0.0.1:8766/`. If you choose a different port, open that local address in the browser.

To enable optional local providers, copy `.env.example` to `.env`. Set `CREDENTIALS_DIRECTORY` in `.env` to an absolute private directory. Put each credential in its own file using the [credential filenames and provider settings](deploy/README.md#optional-provider-credentials). Enter any additional provider settings in `.env`, then restart the local Node process.

## Build RouteWalk

1. Open `ios/RouteWalk.xcodeproj` in Xcode. Select the **RouteWalk** scheme and a physical iPhone running iOS 26 or later with ARKit support. In **Signing & Capabilities**, select your development team and use a bundle identifier that your team owns. Build and run.
2. The source was built with Xcode 27.2 and launched in an iOS simulator. Use a physical iPhone for the camera, scanning and AR navigation.

The iOS project contains source and tests. Production route captures and signing materials are handled separately.

### Scan and try a route on site

1. Pick a short walking route with a clear destination and a starting point on the same floor. Begin the scan **at the destination**. Open **Routes → New route**, name the route, choose **Start scanning** and allow camera access.
2. Move the iPhone slowly so the camera can see the area. When tracking is ready, aim the reticle at the floor and tap **+** to place the destination. Walk toward the point where visitors will start, tapping **+** at turns and at the intended starting point. Scan visible surroundings along the way. The app uses this scan in reverse when it guides visitors to the destination.
3. Place at least two points, including the destination. If the app says **Keep scanning**, continue scanning the area until **Save** is enabled. Tap **Save**.
4. Stand at the visitor starting point within the scanned area. Open the saved route and tap **Start navigation**. Point the camera toward the surroundings that were scanned and wait for tracking to match the area. Follow the AR arrows toward the destination.

To use a previously captured route, choose **Routes → More → Import route** and select the `.routewalk` file. Start from the corresponding physical location on the same floor.

### Open RouteWalk from the map

To configure a store map to open a specific saved route:

1. On the iPhone that will navigate, long-press the saved route in **Routes** and choose **Copy route ID**.
2. Open the store's 2.5D map and copy the `store` value from its address. The UNIQLO store ID is `amap-B02001HUD4`. Use that store ID and the copied route ID in the [server settings](deploy/README.md#routewalk-store-bindings).
3. Open the regular store map on the iPhone and tap **Go here**. RouteWalk opens the configured route. At the visitor starting point, tap **Start navigation**.

The binding points to a route saved on that iPhone. Importing the same route on another iPhone creates a new route ID, so copy the ID from the device that will navigate. Use a MallMate HTTPS address reachable from the iPhone. The Mac's loopback address `127.0.0.1` is for desktop testing.

Use `MALLMATE_ROUTE_DESTINATION` to give stores without a binding a site-wide fallback. The server returns the fallback from `GET /api/public/stores`. Leave it unset to show **Go here** only on configured store maps.

- `mallmate-route://practice` displays **Open RouteWalk** and opens the route library on the iPhone. Pick a route you scanned or imported on that phone. Each import gets a new local UUID.
- `mallmate-route://route/<route-uuid>` displays **Go here** and selects a route with that UUID on the iPhone. MallMate adds a return link to the selected store's map.
- An HTTPS destination displays **Go here** and opens the supplied address. Use an existing Universal Link associated with the installed app and include its required callback to hand off to RouteWalk.

## Source layout

| Path | Contents |
| --- | --- |
| `web/` | Guest website, Node.js API, store catalogue and 2.5D map runtime |
| `ios/` | RouteWalk Xcode project and native tests |
| `data/` | Public production snapshot and CSV for importing into Softr |
| `deploy/` | Linux service, HTTPS proxy and credentials templates |

The [third-party notices](web/THIRD_PARTY_NOTICES.md) document included libraries and referenced artwork. Store images remain on the existing production website.
