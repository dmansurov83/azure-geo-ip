# azure-geo-ip

A ready-to-use `azure.dat` GeoIP dataset built from [Microsoft Azure Service Tags](https://www.microsoft.com/download/details.aspx?id=56519), formatted as a protobuf `GeoIP` file for **v2rayA / Xray** routing rules.

Each Azure Service Tag becomes a "country code": the tag name is uppercased, non-alphanumeric characters become dashes, and the result is prefixed with `AZURE-`. You can then route traffic with ordinary `geoip:` rules:

| Service Tag        | Code in `azure.dat`    |
| ------------------ | ---------------------- |
| `AzureCloud`       | `AZURE-AZURECLOUD`     |
| `Storage`          | `AZURE-STORAGE`        |
| `Sql`              | `AZURE-SQL`            |
| `Sql.WestEurope`   | `AZURE-SQL-WESTEUROPE` |

Example routing rule:

```json
{ "type": "field", "outboundTag": "direct", "ip": ["geoip:azure-storage"] }
```

## Files

| File                    | Purpose                                                          |
| ----------------------- | ---------------------------------------------------------------- |
| `azure.dat`             | Generated GeoIP dataset (protobuf), refreshed automatically      |
| `update-azure-dat.sh`   | POSIX shell script that downloads Service Tags and builds `.dat` |

## Automatic updates

`.github/workflows/update-azure-dat.yml` runs on the **1st and 15th of every month** (i.e. roughly every two weeks) and on demand via *Actions → Update azure.dat → Run workflow*. It re-downloads the latest Service Tags, rebuilds `azure.dat`, and commits it back to `main` only when the content actually changed.

To use the dataset without building it yourself, just pull the file:

```sh
curl -fsSLO https://raw.githubusercontent.com/dmansurov83/azure-geo-ip/main/azure.dat
```

## Building locally

Requires a POSIX shell with `awk`, `sort` and either `curl` or `wget`:

```sh
# all Service Tags -> ./azure.dat
./update-azure-dat.sh

# only SQL and Storage tags
./update-azure-dat.sh --tags 'Sql.*,Storage.*'

# from an already downloaded ServiceTags JSON
./update-azure-dat.sh --file ServiceTags_Public_latest.json --output azure.dat
```

`--tags` accepts a comma-separated list of glob patterns matched against Service Tag names: `*` (all tags, default), `Sql.*`, `Sql.*,Storage.WestEurope`.

Run `./update-azure-dat.sh --help` for the full option list and environment variables (`SOURCE_URL`, `TAGS`, `OUTPUT`).

## Notes

- The dataset is generated, not hand-edited: changes to `azure.dat` should come from the pipeline or from running the script.
- The file is about 1.5 MB; Azure publishes updated Service Tags roughly monthly and the schedule above keeps it current.
- Azure Service Tags data is published by Microsoft and remains subject to Microsoft's terms. This repository only redistributes the converted form.

## License

The script in this repository is released under the MIT License. The underlying Service Tags data belongs to Microsoft.
