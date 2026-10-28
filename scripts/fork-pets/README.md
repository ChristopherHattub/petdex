# Fork pets

Pets this fork bundles. `scripts/install-fork-macos.sh` copies each folder into
`~/.petdex/pets/<slug>/`. Sheets are 1536x1872 (8 columns of 192x208, 9 state rows).

Evolution lines are listed in `packages/petdex-desktop-native/src/evolution.zig`.
A later species (e.g. `wartortle`) stays hidden from the collection until the earlier
one (`squirtle`) reaches the step's level; the earlier pet is always kept.
