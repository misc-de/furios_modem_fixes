# Germany and the Netherlands are missing EU-Alert channel 4372, while listing its local-language counterpart

**Repo:** GNOME/mobile-broadband-provider-info
**File:** `serviceproviders.xml`, `<country code="de">` and `<country code="nl">`
**Observed on:** upstream `main` (fetched 13.9.2026) and Debian/FuriOS package
`20251101-1`. Both identical, so this is not a packaging change.

## Summary

Both country blocks subscribe a phone to EU-Alert **Level 2** with three of its
four channels. Channel **4372** is missing, while **4385** - the local-language
counterpart of exactly that channel - is present.

Level 2 is "extreme threat". A phone configured from this database will not
receive a warning sent on 4372.

## The four channels of EU-Alert Level 2

ETSI TS 102 900 assigns message identifiers per level. In hex, as the
specification writes them, Level 2 is `1113`, `1114`, `1120`, `1121` - in
decimal, as this file writes them:

| Level 2 | primary | local language |
|---|---|---|
| Extreme, immediate, observed | 4371 | 4384 |
| Extreme, immediate, likely   | **4372** | 4385 |

`de` and `nl` both list 4371, 4384 and 4385, and not 4372.

## Why this reads as an omission rather than a national choice

1. **The local-language channel is there without its primary.** 4385 carries the
   translated text of the warning sent on 4372. Subscribing to the translation
   of a warning but not to the warning is not a configuration anyone chooses.
2. **Every other level in both blocks is complete**, and each pairs exactly with
   the +13 offset the specification uses for local-language variants:
   presidential 4370/4383, severe 4373-4378/4386-4391, amber 4379/4392.
3. **The two countries that get it right write it as a range.** `us` and `il`
   both carry `<channels start="4371" end="4372"/>`. `de` and `nl` carry
   `<channels start="4371" end="4371"/>` - one character apart from correct.
4. **`de` and `nl` are otherwise identical** in this block, so a single slip
   explains both.

## Suggested fix

```diff
 		<level type="extreme">
-			<channels start="4371" end="4371"/>
+			<channels start="4371" end="4372"/>
 			<channels start="4384" end="4384"/>
 			<channels start="4385" end="4385"/>
 		</level>
```

in both `<country code="de">` and `<country code="nl">`.

## How it was noticed

On a FuriPhone FLX1 running phosh's `cellbroadcastd`, which reads its channel
list from this database. The modem's own list happened to contain 4372; after
the database list was applied, it did not. Measured on the device, in oFono's
`CellBroadcast.Topics`:

```
before:  4370,4372,4378,4383,4385,4391,4396-4397
after:   919,4370-4371,4373-4392,4396-4397
```

The database list is far better overall - 25 channels against 8 - which is why
the one channel it drops is easy to miss.
