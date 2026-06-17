# GeoLite2 Country Database

circle uses MaxMind GeoLite2-Country for `GEOIP` rules.

## Option 1: Download with license key

1. Create a free MaxMind account and generate a license key.
2. Run:

```sh
MAXMIND_LICENSE_KEY=your_key ./Scripts/download-geolite2.sh
```

This installs `GeoLite2-Country.mmdb` into `Resources/`. The app copies it to
`~/Library/Application Support/circle/` on first launch.

## Option 2: Auto-update in app

Set `geolite2-license-key` in the profile `[General]` section, or export
`MAXMIND_LICENSE_KEY`. circle refreshes the database on launch when it is older
than 30 days.

## License

GeoLite2 is distributed under the Creative Commons Attribution-ShareAlike 4.0
International License. See https://dev.maxmind.com/geoip/geolite2-free-geolocation-data
