# Issue #5 quick-log workflow

Add a vehicle, open it, and use **Log fill** to enter odometer **miles**, volume **US gallons**, total price in dollars, and Full / Partial / Top-off. Save and Cancel appear in the sheet toolbar and above the decimal keyboard. A second qualifying full fill shows US MPG and the exact miles, gallons, and fill IDs used. Partial or top-off gaps remain unknown. The first full fill establishes an anchor and has no MPG by itself.

Non-increasing odometer miles are blocked with a named error. A jump over **10,000 miles** from an adjacent resolved fill asks for explicit confirmation. This is an entry sanity threshold, not vehicle advice. Corrections check both neighboring resolved fills in chronological order. Prices must have at most two decimal places and fit in integer cents; input parsing rejects trailing junk.

Tap a fill to correct it. The list shows the current resolved values and, when corrected, the original values. Corrections append versioned records; the original keeps its ID, vehicle, and date. Economy uses the latest resolved payload. Service uses a free-text category, and tapping a service row edits that category through a correction event. Retiring a vehicle leaves its fills, services, originals, and corrections viewable and stops new entries. The store repository also rejects new fill/service rows for retired vehicles.

The app opens SQLite under Application Support and displays an error if opening fails. Debug UI tests use a separate on-disk `UITests/PumpLog.sqlite`; `-reset-ui-store` clears only that isolated test store, and only when `-ui-testing` is also present. Normal launches never reset app data.

## Verification

Local Linux verification uses cached `swift:6.2-noble` with `libsqlite3-dev` for PumpStore. The XCUITest added for this workflow exercises the real app, SQLite store, and engines on the pinned Apple CI runner through `Scripts/ci.sh`; it has not run on this Linux host. Toolchain pins, iPhone-only device family, app identifier, and built plist assertions remain in the project and CI script.
