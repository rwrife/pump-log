# Own your Pump Log data

Pump Log has no backend, telemetry, or sync. **Your data** on the vehicle list opens the iOS Files picker to save `pumplog-backup.json`, `fills.csv`, or `service.csv`. You choose the destination; Files may offer third-party or cloud providers, but Pump Log itself makes no network requests. Treat backups as sensitive: they contain vehicle names, mileage, dates, prices, notes, and correction history. Files are not encrypted by Pump Log.

## Backup and restore

The `pumplog-backup/1` JSON format contains `schema`, `vehicles`, `fills`, `services`, and `corrections`. Fills/services contain original entries; corrections contain every version and its original JSON payload. Decimal quantities are ASCII strings, costs are integer cents, and dates use Foundation's lossless Date representation (seconds relative to its reference date). Unknown versions and invalid relationships are refused. A restore first previews counts and earliest/latest dates and requires an explicit **Replace with backup** confirmation. It replaces **all** current local entries in one SQLite transaction; a failed import does not partially erase them. Save a fresh backup before restoring.

## CSV

CSV uses UTF-8, RFC 4180 double-quote escaping and CRLF row endings. Decimal separator is always `.`; timestamps are UTC ISO-8601. CSVs show the *latest resolved correction* and are not lossless backups. Empty optional fields are blank. Retired vehicles are included; deleted vehicles are not.

`fills.csv`: `id,vehicle_id,occurred_at_utc,odometer_miles,volume,volume_unit,cost_cents,classification,note`.

`service.csv`: `id,vehicle_id,occurred_at_utc,odometer_miles,category,cost_cents,interval_miles,interval_days,interval_rule_text,note`.

## Delete

Each vehicle's **Permanent deletion** section asks you to type `DELETE <vehicle name>`; this removes its fills, services, and corrections as well. **Erase all local data** on the vehicle list requires `DELETE ALL` and removes every vehicle and all related evidence. Both operations are irreversible locally; exports made *before* deletion remain in Files and must be removed there separately. Exports made afterward cannot include deleted rows.
