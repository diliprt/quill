| scenario | note | before ms | after ms | after+spec ms | accuracy |
|---|---|---|---|---|---|
| fast_done | done 150ms after stop | 151 | 151 | — | before:ok after:ok |
| slow_done | done 2.5s after stop | 2502 | 600 | — | before:ok after:ok |
| missing_done_sf | no done; speech_final seen | 3000 | 600 | — | before:ok after:ok |
| missing_done_nosf | no done; no speech_final | 3000 | 2000 | — | before:ok after:ok |
| late_tail | segment lands 400ms after stop | 2504 | 1002 | — | before:ok after:ok |
| consolidated_fast | done carries better text @200ms | 201 | 201 | — | before:ok after:ok |
| consolidated_slow | done carries better text @1.2s (beyond grace) | 1203 | 600 | — | before:ok after:DIFF |
| empty_interims | empty partials must not wipe text | 151 | 151 | — | before:ok after:ok |
| long_multiseg | ~700 chars over 4 segments | 301 | 301 | — | before:ok after:ok |
| smart_fast | cleanup 300ms | 458 | 457 | 304 | before:ok after:ok spec:ok |
| smart_slow_clean | long text, cleanup 2s | 2308 | 2308 | 2005 | before:ok after:ok spec:ok |
| smart_timeout | cleanup over budget -> raw | 1683 | 1683 | 1532 | before:ok after:ok spec:ok |
| resemble_reject | rewrite rejected -> raw | 457 | 456 | 304 | before:ok after:ok spec:ok |
| spec_hit | partial == final | 957 | 957 | 804 | before:ok after:ok spec:ok |
| spec_miss | final grew after stop | 3310 | 1807 | 1805 | before:ok after:ok spec:ok |
| spec_empty | nothing said before stop | 908 | 908 | 908 | before:ok after:ok spec:ok |
| spec_race | cleanup faster than finalize | 507 | 507 | 402 | before:ok after:ok spec:ok |
| fastpath_clean | already formatted -> local fast-path | 456 | 151 | 153 | before:ok after:ok spec:ok |
| fastpath_lower | unformatted -> still goes to model | 457 | 456 | 303 | before:ok after:ok spec:ok |
| resemble_filler | filler-heavy; guard must accept the shrink | 456 | 456 | 303 | before:DIFF after:ok spec:ok |
| spec_norm_hit | final gains trailing period; normalized hit | 1306 | 1306 | 803 | before:ok after:ok spec:ok |
