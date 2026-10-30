RippleFloorX ver 3.7
======================================================================

[ Overview ]

  - A foot touches the floor: a ring appears at the contact point and fades
    out in about 5 seconds.
  - Walking or jumping leaves one ring per footstep, building up a trail of
    rings of different sizes.
  - Standing still (including idle sway while a motion plays) produces nothing.
  - Five patterns take turns: radial lines, triangle, square, circle and a
    five pointed star.

  No model names are hardcoded, so swapping the characters needs no file edits.
  Note: This MME is a rework of 舞力介入P's "Innocencer". The original required editing the .fx file to add model names by hand; that pain point is gone here. Drawing on 針金P's "WorkingFloorX" and ikeno's "WF_XxShadow", it has been reworked to be binding-free — no file editing, just drag in a model and it works — and a five pointed star pattern and a controller for the ripples have been added.

[ Files ]

  RippleFloorX.x        the floor accessory (20 x 20 plane, y = 0)  <- load this
  RippleFloorX.fx       the effect itself
  RF_FootRipple.fxsub   per model foot reporter (assigned automatically)
  RippleFloorCtrl.pmx   optional parameter controller

  readme_en.txt / readme_jp.txt   this text in English / Japanese

  Keep the four files in one folder (MMEffect 0.33 or later).
  * .fx and .fxsub must be the same version; they share the marker format.

  How it works, every tunable #define, debugging and build notes are in
  docs\TECH.txt (Chinese only). You do not need it for normal use.

[ Usage ]

  1. Load a dark floor model first (recommended), then drag the characters in.
  2. Load RippleFloorX.x and edit its accessory values: Y = the floor height
     plus about 0.1; Si scales the floor; Tr sets the overall transparency.
  3. In 「背景」 > 「アクセサリ編集」 (Background > Edit accessories), make sure
     RippleFloorX.x is drawn after the floor model (if unsure, set the number
     to 0). Then, in MMEffect's 「エフェクト割当」 (Effect Mapping) list, put
     RippleFloorX.x below the floor model.
  4. To change the colour, size or interval, load RippleFloorCtrl.pmx as well
     (you can hide it).
  5. Move the character's foot IK up and down. If rings appear, it works.
  6. After editing .fx you must restart MMD or reload the floor accessory;
     MME does not recompile effects while it runs.

  Up to eight character models are supported. With several models, raise Freq-
  to about 0.4-0.5 (see the table below); otherwise the rings compete for the
  queue and appear irregularly.

[ Controller morphs (RippleFloorCtrl.pmx, optional) ]

  0 on every morph means "no change": the effect looks identical when the
  controller is not loaded, or is loaded but untouched.
  Morph names are matched exactly (ASCII, case sensitive).

    Hue+ / Hue-        hue clockwise / counter clockwise; 1.0 is a full turn
    Bright+ / Bright-  brightness ×3 / ÷3
    Freq+ / Freq-      per model spawn interval: 0.40 s → 0.13 s (denser) /
                       5.2 s (sparser)
    Life+ / Life-      ripple life: 5 s → 15 s (longer and larger) / 1.7 s
    Step+ / Step-      slide threshold: ×3 counts only large steps, ÷3 counts
                       even a slight slide as one step
    TriSz+ / TriSz-    triangle size: up to 2.5× / 0.4×
    SqrSz+ / SqrSz-    square size: same
    CirSz+ / CirSz-    circle size: same
    StarSz+ / StarSz-  five pointed star size: same
    LineSz+ / LineSz-  radial line width: same
    Jitter             per ring size jitter: 0 = off, full = ±25% per ring
    Rot+ / Rot-        pattern rotation: 4.0 rad/s → 10.0 (faster) / 1.6 (slower)

  Notes

  * The + and - morphs of one pattern can be pulled together: the factor is
    (1 + 1.5*P) / (1 + 1.5*M), and both at 1.0 cancel back to 1.0×.
  * Want the five patterns at different sizes? Give a few Sz morphs different
    values. Want every single ring to differ? Turn Jitter up; it only changes
    the visible size, never how often rings spawn.
  * With five to eight models keep Freq- at 0.25 or more (a 1.6 s interval);
    0.4-0.5 is comfortable.
  * Life+ fills the queue faster, so the oldest rings are dropped early.
    Combine it with a higher Freq- if you want them long and plentiful.
  * Rot+ / Rot- only affect the triangle, square and star; a circle and the
    radial lines look the same however they are rotated.
  * Morphs can be keyframed: register Hue+ every 1000 frames, for example, and
    the pattern colour changes over time.
  * Add mode: the accessory panel's 加算 (add) checkbox switches the look at
    run time. On: the rings glow, which is the better look on a dark floor.
    Off: the floor is fully transparent and the rings are solid colour, so they
    also read on a white stage.

[ Troubleshooting ]

  1. Nothing appears
     - Check that you are on MME 0.33 or later.
     - Check that RippleFloorX is in the effect mapping and that RF_FootRipple
       is assigned to the character.
     - Check that the floor Y matches the plane the character stands on; even
       a small offset stops the trigger.

  2. Rings appear but the centre is off
     - The centre is the ankle projected onto the floor, so models with long
       feet are naturally a little off. This is expected.

  3. Rings are too large, too small or too fast
     - Adjust with Life+/- and the Sz+/- morphs first. For the base values see
       RIP_RADIUS and RIP_MAX in docs\TECH.txt.

  4. Rings appear irregularly with several models
     - The queue is saturated; raise Freq- (0.25 or more).

  5. Changes have no effect
     - MME does not recompile .fx while it runs: restart MMD or reload the
       floor accessory.
     - If it still fails, set DEBUG_HUD to 1 at the top of .fx to draw the
       debug bands (their meaning is in docs\TECH.txt).

[ Credits ]

  Offscreen hand over: 針金P "WorkingFloorX"
  Ripple queue: 舞力介入P "Innocencer" (modified)
  Height projection (the 0.1 version): ikeno "WF_XxShadow"

  Modification and redistribution are free under the original authors' terms.
  Credits may be left out when using this MME. If you are happy to add them,
  please write: 針金P, 舞力介入P, ikeno, 大D, 千野

2026-10-31
DeepSeek-V4.1-Flash-1017 & 千野
