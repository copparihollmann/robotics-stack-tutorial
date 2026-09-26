# What `patches/` is the source of truth for, and what it is not

`patches/*.patch` carry every change this repo needs inside a tree it does not own. Each is
applied by a named script (see the per-patch notes in `deps.lock`) and the whole series is
verified by **`scripts/02_verify_patches.sh`**, which does not grep for markers: it extracts
each touched file at the pinned base, replays the series into a scratch copy, and compares
byte for byte.

That gate currently reports, and is meant to report:

```
ok    spike       11 file(s), 2 patch(es), base 0ee3058d
ok    decoder      6 file(s), 3 patch(es), base 34e5444
--    zcs         pristine at 4007913 (1 optional patch not applied)
DRIFT modelblaster 0009 does not apply to 99b9e84
ok    zephyr       8 file(s), 3 patch(es), base 4329bf61
```

## ModelBlaster: the submodule pin is authoritative, the patch files are historical

**This is a decision, not an unresolved bug.** Nine of the eighteen ModelBlaster patches no
longer reconstruct the tree:

| State | Patches |
|---|---|
| content exactly present — reverse-applies | 0020, 0070, 0105, 0106, 0107, 0109, 0113, 0114, 0115 |
| content present only in an **evolved** form — neither applies nor reverse-applies | **0009, 0060, 0100, 0102, 0103, 0104, 0108, 0111, 0112** |

The cause is benign and is recorded in `docs/PROVENANCE.md` §3: ModelBlaster commit `543437b`
("The int8 Moonshine pipeline") folded that work into git, and `zephyr-chipyard-sw`'s
submodule pointer moved onto it. The patches now describe a base that no longer exists.

**The consequence is not benign, and this file exists so that nobody has to guess which way
it resolves.** For ModelBlaster, and only for ModelBlaster:

* **the checked-out commit is the definition of the pipeline.** `99b9e84` is what every
  `max_abs_err = 0` in this programme was measured against.
* **the nine patches above are a historical record of how that code got there.** Do not
  `git apply` them onto the current tree. They will fail; if one of them is ever forced
  through, the result is a pipeline no measurement in this repo describes.
* **`DRIFT modelblaster` is therefore the expected output of `02_verify_patches.sh`,** not a
  regression to chase. The other four trees (spike, decoder, zephyr, zcs) are unaffected and
  `patches/` remains the source of truth for all of them.

**Where those two commits now live.** When this was written, `543437b` and `99b9e84` were
reachable from **no remote ref**, and that was the worst of it: a fresh clone could fetch
neither the authoritative pin nor a way to rebuild it. Re-verified 2026-09-26 (B185): **both are
public.** They reached `ucb-bar/ModelBlaster` as the base of `refs/heads/ir-passes-into-pipeline`,
which is `99b9e84` plus one commit (`c546ffb`), and `merge-base --is-ancestor` against that
branch's remote sha proves containment — a 200 from the API would not, because GitHub also
serves unreferenced objects. `git submodule update --init` now works from a fresh clone.

**The other half of the problem is unchanged:** `patches/` still cannot reconstruct the
ModelBlaster pipeline, so the clone is the only route to it. And the pin is public without yet
being durable — both commits sit on a feature branch and neither carries a tag, so **tagging
them is the action that still needs doing.**

## Two patches that are checked by reverse-apply only

`0030` and `0090` touch `generators/tacit`, which is **untracked inside the donor Chipyard
tree** and so has no pinned base to reconstruct from. `scripts/03_patch_tacit.sh --check`
tests them the only way available.
