| scenario | note | before ms | after ms | after+spec ms | accuracy |
|---|---|---|---|---|---|
| fast_done | done 150ms after stop | 151 | 151 | — | before:ok after:ok |
| slow_done | done 2.5s after stop | 2503 | 2000 | — | before:ok after:ok |
| missing_done_sf | no done; speech_final seen | 3000 | 2000 | — | before:ok after:ok |
| missing_done_nosf | no done; no speech_final | 3000 | 2000 | — | before:ok after:ok |
| late_tail | segment lands 400ms after stop | 2503 | 2401 | — | before:ok after:ok |
| consolidated_fast | done carries better text @200ms | 201 | 201 | — | before:ok after:ok |
| consolidated_slow | done carries better text @1.2s (beyond grace) | 1202 | 1202 | — | before:ok after:ok |
| empty_interims | empty partials must not wipe text | 151 | 151 | — | before:ok after:ok |
| long_multiseg | ~700 chars over 4 segments | 301 | 301 | — | before:ok after:ok |
| late_head | server revises segment with missing head 1s later | 1401 | 1402 | — | before:ok after:ok |
| smart_fast | cleanup 300ms | 457 | 456 | 303 | before:ok after:ok spec:ok |
| smart_slow_clean | long text, cleanup 2s | 2306 | 2306 | 2004 | before:ok after:ok spec:ok |
| smart_timeout | cleanup over budget -> raw | 1683 | 1683 | 1532 | before:ok after:ok spec:ok |
| resemble_reject | rewrite rejected -> raw | 456 | 457 | 304 | before:ok after:ok spec:ok |
| spec_hit | partial == final | 956 | 956 | 803 | before:ok after:ok spec:ok |
| spec_miss | final grew after stop | 3313 | 3207 | 3204 | before:ok after:ok spec:ok |
| spec_empty | nothing said before stop | 906 | 906 | 906 | before:ok after:ok spec:ok |
| spec_race | cleanup faster than finalize | 506 | 506 | 402 | before:ok after:ok spec:ok |
| fastpath_clean | already formatted -> local fast-path | 457 | 151 | 153 | before:ok after:ok spec:ok |
| fastpath_lower | unformatted -> still goes to model | 455 | 455 | 303 | before:ok after:ok spec:ok |
| resemble_filler | filler-heavy; guard must accept the shrink | 455 | 455 | 303 | before:DIFF after:ok spec:ok |
| spec_norm_hit | final gains trailing period; normalized hit | 1306 | 1306 | 803 | before:ok after:ok spec:ok |
