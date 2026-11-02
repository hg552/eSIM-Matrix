# Scrolling performance

The changes following 2.4.0+600 target shared page work and profile-list work:

- Tabs, including embedded browser pages, initialize on their first visit. Visited tabs retain state; inactive tabs stop their Flutter animation tickers.
- Settings rows have individual repaint boundaries so scrolling does not require repainting the whole settings group.
- Profile-size predictions use an SM-DP+ index and a bounded result cache, including unmatched predictions. The 735 KB reference JSON is parsed outside the mobile UI isolate.
- Missing profile sizes and operator icons are cached. Cards use synchronous cached misses without repeatedly creating database-backed waiting states. Newly saved sizes and downloaded icons still replace those misses.

## Validation

The repeated-prediction comparison used the shipped 1,638-row reference file, 20 repeating profile metadata combinations and 2,000 predictions. It ran in a local Flutter debug test, after warming both implementations:

| Implementation | Total prediction CPU time |
| --- | --- |
| Previous implementation | 200.316 ms |
| Indexed, cached implementation | 1.719 ms |

Both produced identical results. These numbers measure the repeated computation, not whole-app frame rate. Reference loading was outside the timed region. Physical-device build/raster frame timings are still needed to quantify the reported scrolling improvement.

Regression tests cover negative database caching, replacing a missing size with a saved size, case-insensitive reference matching, first-visit tab construction, retained tab state and disabled inactive animation tickers.
