| scenario | note | before ms | after ms | after+spec ms | accuracy |
|---|---|---|---|---|---|
| fast_done | done 150ms after stop | 151 | 151 | — | before:ok after:ok |
| slow_done | done 2.5s after stop | 2503 | 350 | — | before:ok after:ok |
| missing_done_sf | no done; speech_final seen | 3000 | 350 | — | before:ok after:ok |
| missing_done_nosf | no done; no speech_final | 3000 | 2000 | — | before:ok after:ok |
| late_tail | segment lands 400ms after stop | 2504 | 752 | — | before:ok after:ok |
| consolidated_fast | done carries better text @200ms | 201 | 201 | — | before:ok after:ok |
| consolidated_slow | done carries better text @600ms | 602 | 350 | — | before:ok after:DIFF |
| empty_interims | empty partials must not wipe text | 151 | 151 | — | before:ok after:ok |
| long_multiseg | ~700 chars over 4 segments | 301 | 301 | — | before:ok after:ok |
| smart_fast | cleanup 300ms | 458 | 456 | 304 | before:ok after:ok spec:ok |
| smart_slow_clean | long text, cleanup 2s | 2310 | 2308 | 2005 | before:ok after:ok spec:ok |
| smart_timeout | cleanup over budget -> raw | 1683 | 1683 | 1532 | before:ok after:ok spec:ok |
| resemble_reject | rewrite rejected -> raw | 457 | 457 | 305 | before:ok after:ok spec:ok |
| spec_hit | partial == final | 958 | 959 | 804 | before:ok after:ok spec:ok |
| spec_miss | final grew after stop | 3311 | 1558 | 1559 | before:ok after:ok spec:ok |
| spec_empty | nothing said before stop | 907 | 907 | 908 | before:ok after:ok spec:ok |
| spec_race | cleanup faster than finalize | 507 | 456 | 351 | before:ok after:ok spec:ok |
| fastpath_clean | already formatted -> local fast-path | 457 | 151 | 153 | before:ok after:ok spec:ok |
| fastpath_lower | unformatted -> still goes to model | 456 | 457 | 304 | before:ok after:ok spec:ok |
| resemble_filler | filler-heavy; guard must accept the shrink | 457 | 457 | 304 | before:DIFF after:ok spec:ok |
| spec_norm_hit | final gains trailing period; normalized hit | 1307 | 1257 | 805 | before:ok after:ok spec:ok |
