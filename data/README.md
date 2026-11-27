# Published production data

This export contains all 65 store records returned by MallMate's public production catalogue. See [snapshot-info.json](snapshot-info.json) for the source, version and export date. The snapshot contains publicly presented opening hours, location, cost references, photos and published detail content where available.

[public-catalogue.json](public-catalogue.json) is the full public snapshot. [stores-for-softr.csv](stores-for-softr.csv) contains matching records for a separate assessor-owned Softr workspace. Each row includes both editable store columns and `PublicDataJson`, which preserves the complete published record as a single JSON value.

## Import the Stores table into Softr

1. In your Softr workspace, create a new database and choose **Import CSV**. Select `stores-for-softr.csv` and name the table `Stores`. [Softr database setup](https://docs.softr.io/softr-databases/softr-databases-overview)
2. Keep `Name` as the primary text column. Treat `MallPoiId` and `AmapPoiId` as text and preserve every value. Confirm `NameEn`, `Floor`, `Category`, `Hours`, `AmapHours` and `Address` are text fields, `Pricemin` and `Pricemax` are numbers and `PublicDataJson` is long text. Confirm all 65 rows were imported and that each mall and POI ID pair is unique.
3. Create a Personal Access Token scoped to your review workspace. The [Softr Database API](https://docs.softr.io/softr-api/softr-database-api) lists databases at `GET /api/v1/databases`; [the tables endpoint](https://docs.softr.io/softr-api/softr-database-api/tables/get-tables) provides the IDs in your database. Store the token as the server-side `softr-api-token` credential.
4. In the server environment set `MALLMATE_CATALOGUE_SOURCE=review-softr`, `MALLMATE_SOFTR_DATABASE_ID` and `MALLMATE_SOFTR_STORES_TABLE_ID`. Follow the [server instructions](../deploy/README.md), restart the service and verify `/api/public/stores` reports `softr-review+production-public-snapshot` and returns 65 records.

The app reads the named text and price columns from your Stores table using the mall and POI IDs as stable keys. Photos, published review highlights and dishes come from the exported public snapshot. `PublicDataJson` also keeps that full record available in Softr for inspection. For a quick test, edit the English name of one store in your copy and wait for the catalogue cache to refresh before checking the website.
