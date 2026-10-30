# FR-<NN> eval: <feature name>

<!-- Lives at specs/features/fr-NN/eval.md, beside the rd.md it was derived from.
     Written by the write-evals skill. That skill never implements — it only writes this file
     (and the mockup). The front table is what the gate and the loop parse, so keep its row
     names exactly as below. -->

| | |
|---|---|
| **RD** | [rd.md](rd.md) |
| **Mockup** | [mockup.html](mockup.html) |
| **Risk** | medium |
| **Eval status** | Draft | <!-- Draft → In review → Approved -->
| **Approved** | — | <!-- `<name>, <date> · sha:<commit>` once a human says yes -->
| **Perf baseline** | `e2e/evidence/fr-<NN>/perf-baseline.json` |
| **New e2e paths** | P15 <path name>, P16 <path name> |

## How to verify

The commands the verifier runs. Everything below must be executable from the repo root exactly as written.

```bash
npm run build && npm run e2e
```

## Checks

Numbered by category. A check is a claim plus the observation that settles it — the gate quotes the
check ID when it refuses "done", so the IDs must be stable.

- `U-` usage — every way to use the feature, happy paths
- `F-` failure — every way it can fail, and what must happen instead
- `R-` regression — what adding this must not break
- `Q-` quality · `S-` security · `D-` data — add these on high-risk features

Every check carries a `Result:` line. `PASS` or `FAIL: <what you actually saw>`. No other value.

### U-1 Shopper reschedules a visit from the account page

- **Expect:** the visit moves to the new slot and the old slot frees up
- **Result:** FAIL: route returns 404, the reschedule page does not exist yet

### U-2 Reschedule keeps the visit when the target slot is taken

- **Expect:** an error is shown and the original visit is unchanged
- **Result:** FAIL: no such behaviour

### F-1 Reschedule rejects a slot in the past

- **Expect:** 400 and the visit is untouched
- **Result:** FAIL: no validation

### R-1 Booking a new visit still picks the earliest free slot

- **Expect:** unchanged behaviour from before this feature
- **Result:** PASS

## Red evidence

_Fill on the first run, before any implementation. Every check above must be red here; one that is
already green is not testing the feature. Paste the run or link it._

```
$ npm run build && npm run e2e
<actual failing output>
```

## Coverage note

These checks cannot see: <UX confusion, copy tone, other breakpoints, load under real traffic, …>.
The first-time-user test covers what is listed here.

## Rules learned

_Appended only by the loop, only with human approval — one line per rule. Promote a repeated rule to
a lint check or into REVIEW.md._
