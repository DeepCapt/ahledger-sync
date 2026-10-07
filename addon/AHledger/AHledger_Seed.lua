-- Starting price tables that ship with each release, so the addon prices items from the first
-- login. Built from the latest player scans when the release is packaged (addon/package.py).
-- The addon uses a market's seed only while nothing newer exists: a table AHledger sync writes,
-- or one pasted with /ahl import, always wins. This placeholder ships empty in the repository.
AHledgerSeed = AHledgerSeed or {}
