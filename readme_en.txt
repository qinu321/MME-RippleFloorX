RippleFloorX ver 3.6
======================================================================

[ What it does ]

  A foot touches the floor -> a ring appears at that spot, grows and fades
  out in about 5 seconds.
  Walking / jumping -> one ring per footstep, stacking into a trail of rings
  with different radii.
  Standing still (including idle sway while a motion plays) -> nothing.
  Five patterns take turns: radial lines / triangle / square / circle /
  five pointed star.

  No model name is hardcoded: swapping the character needs no file edit.

[ Files ]

  RippleFloorX.x        the floor accessory (20x20 plane, y=0)   <- load this
  RippleFloorX.fx       the effect itself
  RF_FootRipple.fxsub   per model foot reporter (assigned automatically)
  RippleFloorCtrl.pmx   optional parameter controller

  readme_en.txt / readme_jp.txt   this text in English / Japanese

  Keep the four files in one folder (MMEffect 0.33 or later).
  * .fx and .fxsub must be the same version - the marker format is shared.

  How it works, every tunable #define, debugging and build notes are in
  docs\TECH.txt (Chinese only). Not needed for normal use.

[ Usage ]

  1. Load a dark floor model first (recommended), then drag the character in.
  2. Load RippleFloorX.x and edit its accessory values: Y = floor height
     + 0.1 or so; Si scales the floor; Tr sets the overall transparency.
  3. Check the accessory draw order (Background - Edit accessories) so that
     RippleFloorX.x is drawn after the floor model (if unsure, set the number
     to 0). Then, in MMEffect's effect assignment, make sure RippleFloorX.x is
     listed below the floor model.
  4. To change colour / size / interval, load RippleFloorCtrl.pmx as well
     (you can hide it).
  5. Move the character's foot IK up and down; if ripples appear, it works.
  6. After editing .fx you must restart MMD or reload the floor accessory -
     MME does not recompile hot.

  Up to 8 character models are supported. With several models, raise Freq- to
  about 0.4-0.5 (see below), otherwise the rings push each other out and
  appear irregularly.

[ Controller morphs (RippleFloorCtrl.pmx, optional) ]

  0 on every morph = no change: the effect looks identical when the controller
  is not loaded, or is loaded but untouched.
  Morph names are matched exactly (ASCII, case sensitive).

    Hue+ / Hue-        hue clockwise / counter clockwise, 1.0 = a full turn
    Bright+ / Bright-  brightness x3 / /3
    Freq+ / Freq-      per model spawn interval: 0.40 s -> 0.13 s (denser) / 5.2 s (sparser)
    Life+ / Life-      ripple life: 5 s -> 15 s (longer and bigger) / 1.7 s
    Step+ / Step-      slide threshold: x3 = only large steps / /3 = slight slides count
    TriSz+ / TriSz-    triangle size: up to 2.5x / 0.4x
    SqrSz+ / SqrSz-    square size: same
    CirSz+ / CirSz-    circle size: same
    StarSz+ / StarSz-  five pointed star size: same
    LineSz+ / LineSz-  radial line width: same
    Jitter             per ripple size jitter: 0 = off, full = +-25% per ring
    Rot+ / Rot-        pattern rotation: 4.0 rad/s -> 10.0 (faster) / 1.6 (slower)

  Notes:

  * The + and - morphs of the same pattern can be pulled together; the factor
    is (1 + 1.5*P) / (1 + 1.5*M), and both at 1.0 cancel back to 1.0x.
  * To make the five patterns differ in size, give a few Sz +/- morphs
    different values. To make every single ring differ, turn Jitter up (it
    only changes the visible size, never how often ripples spawn).
  * With 5-8 models keep Freq- at 0.25 or more (1.6 s interval); 0.4-0.5 is
    comfortable.
  * Life+ fills the queue faster, so the oldest rings get dropped early;
    combine it with a higher Freq- if you want long AND many.
  * Rot+ / Rot- only show on triangle / square / star (a circle and the radial
    lines look the same when rotated).

[ Troubleshooting ]

  1. Nothing at all
     - MME version 0.33 or later?
     - Is RippleFloorX in the effect assignment, and is RF_FootRipple assigned
       to the character?
     - Does the floor Y match the plane the character stands on? (even a small
       offset stops the trigger)

  2. Rings appear but the centre is off
     - the centre is the ankle projected onto the floor, so models with long
       feet are naturally a little off

  3. Rings too big / small / fast
     - use Life+/- and *Sz+/- first; for the base numbers see RIP_RADIUS and
       RIP_MAX in docs\TECH.txt

  4. Rings appear irregularly with several models
     - the queue is saturated; raise Freq- (>= 0.25)

  5. Nothing changed
     - MME does not recompile .fx hot: restart MMD or reload the floor accessory
     - if it still fails, set DEBUG_HUD to 1 at the top of .fx to show the debug
       bands (meaning in docs\TECH.txt)

[ Credits ]

  Offscreen hand over: 針金P "WorkingFloorX"
  Ripple queue: 舞力介入P "Innocencer" (modified)
  Height projection (the 0.1 version): ikeno "WF_XxShadow"

  Modification and redistribution are free under the original authors' terms.

2026-10-30
