## Azure VM price data consolidation script
### Overview
- This data consolidation script retrieves pricesheet data from:
	- the Consumption API https://docs.microsoft.com/en-us/rest/api/consumption/pricesheet/get
	- the Compute API https://docs.microsoft.com/en-us/rest/api/compute/resourceskus/list

- There is no single key on which to match these datasets so we have to use a combination of fields to establish a link.

### Matching logic
- Consumption `meterLocation` (e.g. 'EU West') = Compute `locations[0]` (e.g. 'westeurope') - need hardcoded mapping in script
- Consumption `meterSubCategory` (notcontains Standard) = Compute `tier` (Standard)
- Consumption `meterName` (D32a v4/D32as v4) = Compute `size` (D32a_v4) - when space replaced with underscore
- if no match found check meter name for "/"
- if "/" found, split into two separate meter names and search for them
- if not match found, sku not available