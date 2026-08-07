# Fixture MANIFEST — docs/evidence/fixtures/ (APPEND-ONLY)
#
# > Append-only ledger: NEVER edit or delete existing entries. Add new rows only.
# > Entries below are byte-immutable copies of the certified originals; the
# > originals remain authoritative in state/spool/{pcaps,archived}/.
# > Regenerate a row ONLY if the source artifact itself changes (new hash).

## pcap/ (1 file)
| sha256 | provenance | role | date |
| :--- | :--- | :--- | :--- |
| 2ea364fbec2514091ad1e28d471fbf088bb61e1132d2a37bf3a6f66ea3ce1c2c | state/spool/pcaps/385288b878ffcf5e-d60dcbeab13dbc0c.pcap | Real live-mic call pcap (rtpengine recording-format=eth), call 07:43-07:44 | 2026-08-07 |

## archived/ (44 files)
| sha256 | provenance | role | date |
| 91cd6ebfba9d57dff748f93b5d0db098ff0f67533f9d607553ff45bbf5d7ed45 | state/spool/archived/385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.60.txt | Tier-3 --once extraction, callee leg (2s) | 2026-08-07 |
| ea89d45e370e25e77953e7dd140c5ec51b9ebd174a048e87c40a6ae1a082d56f | state/spool/archived/385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.60.wav | Tier-3 --once extraction, callee leg (2s) | 2026-08-07 |
| 956faaa2caead2bc941afd4bf515aba269b771c4c693e3a444ad001f51baa934 | state/spool/archived/385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61.txt | Tier-3 --once extraction, caller leg (71s) | 2026-08-07 |
| 3812cb3ad76c96cb4d076860c059c59e115cba4e86058c58a44d51506eeaab52 | state/spool/archived/385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61.wav | Tier-3 --once extraction, caller leg (71s) | 2026-08-07 |
| 3a7b8a139c4d9b88a9dcf718bf0fe531193d037ff73230f835fb0ab3f1014409 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.60-0.txt | Tier-1 live chunk, CALLEE leg 10.89.0.60 | 2026-08-07 |
| ea89d45e370e25e77953e7dd140c5ec51b9ebd174a048e87c40a6ae1a082d56f | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.60-0.wav | Tier-1 live chunk, CALLEE leg 10.89.0.60 | 2026-08-07 |
| 3f2b9cca1e31c7cde19cd580627fca11db20760eb1a85d34ab2765460d1962a5 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-0.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| b429aca5b818958485abdf4e638364ce9174a9bebaf0051b95abe58524be1da9 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-0.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-10.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| cf35421066fefc2a2c246812b974600c0da155158bf50fb592b82569739abfd1 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-10.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-11.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| c2a41fbd0b6b0126464c6ac21db1463008e3cf2d608b5f10d248b6ec7ab097d5 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-11.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-12.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 9d101f4c846bc7c173d994fc412b22c5575a99d2e943caaaf5e24d996ac0007e | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-12.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-13.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 79b3eea846a1f0f592a1e16980df78bfadd920bbe5655b3a2f58abae98ec81f7 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-13.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 0ec99791bede6c797706e8552dd896584e79315f02db39616061a7f08611511a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-14.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| b39e15211bf4968fbe41f253c764cd1864099ee71fbdc30cf06b14c668a2038f | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-14.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-1.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a6b66db25497f330ce2904268394a6c5905b7a7474e9e34af43957d799a82d98 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-1.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-2.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 8af08e2ed0b0e3be6fe1118090a586fcaba6a662934a7eb06bd71f72960ebc14 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-2.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-3.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| f3c4addb668c5349f57d0d5b98815b8f20427d349cc35656d8a4fb9f1900f325 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-3.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-4.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| e6ee8a6f51a7ba158690fb856e346a8c1e3acb2915f24fc59176d82e680ef50b | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-4.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-5.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| f097dc375bf4e81b425978b17119271c6cc4508690620186f3b94aae79837da7 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-5.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-6.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a3ab15124b3bcc75aa5c5a9a8cbf1c86fb3143032e46a1deebd32a7b2fd11246 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-6.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-7.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 489ee33b4f9c8b6a6205687ef7638b3a1db55611c33afaaf976408bef1c94e11 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-7.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-8.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| ffcd7feccf5729086873943adaebfc908792f81d3ab89d7511b964e28915f6e6 | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-8.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| a389abcd9cfab46074736db0a214856fadf2046238228f5e3e6804cbc6980b6a | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-9.txt | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 756172c71a8081844964b9f31d386c009502430102af5bc06bbcb6496faccbec | state/spool/archived/live-385288b878ffcf5e-d60dcbeab13dbc0c-10.89.0.61-9.wav | Tier-1 live chunk, CALLER leg 10.89.0.61 (real voice; 71.64s/27-chunk parity proof) | 2026-08-07 |
| 4c0e119e250fdfd1b7bc1cc52c3a0d2ec2bb5bcc85befa8f695db3ac668aa0e1 | state/spool/archived/live-callee.txt | Scam-script callee leg + transcript ('you have won a prime target now') | 2026-08-07 |
| 0c68bb85aadb423cef098661ef56415c065e3eb980f72bf59a1402bfd788dc97 | state/spool/archived/live-callee.wav | Scam-script callee leg + transcript ('you have won a prime target now') | 2026-08-07 |
| 7fc791729c992b238ba2c6bb5408689a0ca2fa521040ac1e7af98bbbaa74aa37 | state/spool/archived/live-caller.txt | Real caller-voice recording + transcript (18s mic capture) | 2026-08-07 |
| 721cf799ccfcd0f9ee2213069dec6f7cd1bdfe988f044f7604258d8600255838 | state/spool/archived/live-caller.wav | Real caller-voice recording + transcript (18s mic capture) | 2026-08-07 |
| 4fecfc57ba6495a4b8cbd0d3132d7fa2fd15bae5c7ae0e6e9a5375bffe88733f | state/spool/archived/mic-probe-19348.txt | Microphone probe capture + transcript (initial empty-tape fix proof) | 2026-08-07 |
| 5d1b580a2623ad9447aebc29d8d6ac8aebd6dda2a23c7b5caad2500fdf98e0d4 | state/spool/archived/mic-probe-19348.wav | Microphone probe capture + transcript (initial empty-tape fix proof) | 2026-08-07 |
| 1f6a8c09c8cfef0dc5bf37c77a1e4e6e9162c549dd87813cb1034e887e073135 | state/spool/archived/speaker-proof.txt | Speaker identity proof capture + transcript | 2026-08-07 |
| 243b66eb89150f5199f29d279bff4292e38d410feedc6e75da1b26d8845edaf0 | state/spool/archived/speaker-proof.wav | Speaker identity proof capture + transcript | 2026-08-07 |
