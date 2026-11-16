-- What vendors charge, shipped with each release (addon/package.py): recipe reagents two or more
-- accounts running the addon saw a vendor sell for gold lately, at the highest price seen, so a
-- recipe's cost uses a reagent's vendor price (Leaded Vial) instead of a far higher auction house
-- price. This placeholder ships empty in the repository; the addon then uses only the prices it
-- notes at the merchants you visit.
AHledgerVendor = AHledgerVendor or {}
