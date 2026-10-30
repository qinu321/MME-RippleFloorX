////////////////////////////////////////////////////////////////////////////////
//
//  RippleFloorX.fx   ver 3.2
//
//  Floor accessory effect (MikuMikuEffect 0.37 or later).
//  Foot contacts are reported by RF_FootRipple.fxsub, which is assigned to
//  every PMD / PMX automatically through the DefaultEffect list below.
//
//  Marker buffer (offscreen render target, float format)
//      one 4 x 4 pixel blob per foot slot, rgba = (local x, local z, 0, 1)
//      the buffer is cleared every frame, so a blob only exists while that
//      foot is really on the floor
//
//  State texture (1 x 32, RGBA32F)
//      rows  0 .. 24 : ripple queue   (x, z, start time, 1 + pattern)
//      rows 25 .. 27 : per model pair last spawn time,  .rgb = 3 pairs per row
//      rows 28 .. 30 : per model pair last spawn point, .rgb = 3 pairs per row
//      row  31       : foot latch, one bit per slot
//
//  WRITE RULE (learned the hard way on this machine)
//      a state row whose written alpha is 0 is lost as a whole - every channel
//      reads back 0, not just alpha.  So every row keeps alpha >= 1, rows 25
//      .. 30 write 1.0 into .a and their payload into .rgb, and no fourth
//      value is ever packed into .a.  The old theory "the .x channel is
//      broken" was wrong: the queue rows always read .x fine, what made them
//      different was that their alpha (1 + pattern) was never 0.
//
//  Trigger = a contact rising edge, or the feet of one model pair sliding away
//  from the point of their own last ripple (choreography that never lifts a
//  foot high enough still leaves ripples).  The slide test compares the
//  midpoint of the feet that are on the floor with the midpoint recorded at
//  that pair's last ripple; comparing a single foot against a single stored
//  point made the two feet take turns "sliding" while the model stood still.
//  It only runs while both feet are down: with one foot in the air the midpoint
//  collapses onto the standing foot, which also reads as a slide on every lift.
//  A state row that fails to come back can only cost a ripple, never make one:
//  a point outside the floor counts as "no record", and the pair then needs a
//  real edge.
//
//  Idea: WorkingFloorX (HariganeP) for the offscreen hand over,
//        Innocencer (Mairi-nyu-P) for the 24 slot ripple queue.
//
//  Usage: load RippleFloorX.x (MMEffect 0.33 or later).
//
////////////////////////////////////////////////////////////////////////////////

// ---------------------------------------------------------------- settings
float4 RippleColor <
    string UIName   = "Ripple Color";
    string UIWidget = "Color";
> = float4(0.10, 0.85, 0.55, 1.0);

float RippleStrength <
    string UIName   = "Ripple Strength";
    string UIWidget = "Scalar";
    float UIMin = 0.0;
    float UIMax = 4.0;
> = 1.0;

// ---------------------------------------------------------------- tuning
#define RIP_MAX      5.0     // ripple life (sec)
#define RIP_RADIUS   16.0    // ring radius at the end of its life (local unit)
#define RIP_BAND     0.04    // shape band thickness (fraction of the radius)
#define RIP_LINE_W   0.15    // line pattern half width  (local unit)
#define RIP_ROT      4.0     // pattern rotation (rad / sec)
#define STAR_INNER   0.45    // five point star: inner radius / outer radius

#define SLOT_MAX     16      // foot marker slots to scan (must match fxsub FOOT_SLOTS)
#define QUEUE_ROW0   0       // first state row used by the ripple queue
#define SLOT_COUNT   25      // ripple queue rows 0 .. 24
#define CD_ROW0      25      // per model pair last spawn time, .rgb = pairs 0, 1, 2
#define CD_ROW1      26      //                                    pairs 3, 4, 5
#define CD_ROW2      27      //                                    pairs 6, 7
#define POS_ROW0     28      // per model pair last spawn point, pairs 0, 1, 2
#define POS_ROW1     29      //                                    pairs 3, 4, 5
#define POS_ROW2     30      //                                    pairs 6, 7
#define MASK_ROW     31      // foot latch: bit per slot, read from .w
#define STEP_R       1.5     // a foot that slid this far (local unit) since its
                             // last ripple counts as a new step, so choreography
                             // that never lifts the foot still leaves ripples
#define STATE_ROWS   32

// trigger spacing (seconds)
#define TRIG_GAP     0.40    // per model: min time between two of its own ripples


// debug overlay: 1 = paint the foot / trigger state along the floor edge
#define DEBUG_HUD    0

// ---------------------------------------------------------------- constants
float4x4 WorldViewProjMatrix : WORLDVIEWPROJECTION;

// accessory transparency (Tr)
float AccessoryTrans : CONTROLOBJECT < string name = "(self)"; string item = "Tr"; >;

float2 ViewportSize : VIEWPORTPIXELSIZE;
float  CurTime : TIME < bool SyncInEditMode = false; >;

// ---------------------------------------------------------------- controller
// Optional controller model (PMX with morphs, same convention as ikBokeh).
// All morphs are 0..1 and 0 = neutral, so the effect looks the same when the
// controller is not loaded, or is loaded but untouched.
#define CTRL_MODEL  "RippleFloorCtrl.pmx"

float CtrlHueP    : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Hue+"; >;
float CtrlHueM    : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Hue-"; >;
float CtrlBrightP : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Bright+"; >;
float CtrlBrightM : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Bright-"; >;
float CtrlFreqP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Freq+"; >;
float CtrlFreqM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Freq-"; >;
float CtrlLifeP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Life+"; >;
float CtrlLifeM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Life-"; >;
float CtrlStepP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Step+"; >;
float CtrlStepM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Step-"; >;

// RIP_MAX and STEP_R can be scaled by the controller morphs (Life+/- and Step+/-);
// a missing morph reads 0, so the defaults below are what you get without it.
float LifeMax()
{
    return RIP_MAX * (1.0 + CtrlLifeP * 2.0) / (1.0 + CtrlLifeM * 2.0);
}

float RipSpeed()
{
    return RIP_RADIUS / LifeMax();
}

float StepLen()
{
    return STEP_R * (1.0 + CtrlStepP * 2.0) / (1.0 + CtrlStepM * 2.0);
}


// ------------------------------------------------------- foot contact buffer
// float format: the marker carries the contact point in floor local units, so
// there is no 8 bit quantisation and no clamped range any more.
texture RippleRT : OFFSCREENRENDERTARGET <
    string Description = "RippleFloorX foot contact buffer";
    float2 ViewPortRatio = {1.0, 1.0};
    string Format = "A32B32G32R32F";
    float4 ClearColor = {0, 0, 0, 0};
    float  ClearDepth = 1.0;
    bool   AntiAlias  = false;
    int    MipLevels  = 1;
    string DefaultEffect =
        "self = hide;"
        "*.pmd = RF_FootRipple.fxsub;"
        "*.pmx = RF_FootRipple.fxsub;"
        "*.x = hide;"
        "* = hide;";
>;

sampler MarkerSamp = sampler_state
{
    texture   = <RippleRT>;
    MinFilter = NONE;
    MagFilter = NONE;
    MipFilter = NONE;
    AddressU  = CLAMP;
    AddressV  = CLAMP;
};

// ------------------------------------------------------- state (1 x 32)
// TEXTUREVALUE (frame-start snapshot), so there is no copy pass any more.
// ver 1.8: the A/B copy lost the foot latch row on this machine.
texture StateA : RENDERCOLORTARGET <
    int Width  = 1;
    int Height = 32;
    string Format = "A32B32G32R32F";
>;


texture StateDepth : RENDERDEPTHSTENCILTARGET <
    int Width  = 1;
    int Height = 32;
>;

sampler StateASamp = sampler_state
{
    texture   = <StateA>;
    MinFilter = NONE;
    MagFilter = NONE;
    MipFilter = NONE;
    AddressU  = CLAMP;
    AddressV  = CLAMP;
};


// ---------------------------------------------------------------- helpers
// previous frame state, read from the frame start snapshot MME keeps in shader
// constant registers (TEXTUREVALUE).  ver 1.8: the A/B copy pass was dropping
// the foot latch row on this machine; this is the mechanism Innocencer uses and
// it needs no second texture at all.
float4 StatePre[STATE_ROWS] : TEXTUREVALUE < string TextureName = "StateA"; >;

// read row i of the previous frame state
float4 StateRow(int i)
{
    return StatePre[i];
}

// marker blob of one foot slot, centred 4 pixels above the bottom edge
float4 MarkerAt(int slot)
{
    return tex2D(MarkerSamp, float2((slot + 0.5) / STATE_ROWS,
                                    1.0 - 4.0 / ViewportSize.y));
}

// a stored time from the future means the timeline was rewound
float PastTime(float t)
{
    return (t > CurTime) ? -1.0e9 : t;
}


// ---------------------------------------------------------------- buffer
struct BUF_OUT
{
    float4 Pos : POSITION;
    float2 Tex : TEXCOORD0;
};

BUF_OUT Buffer_VS(float4 Pos : POSITION, float2 Tex : TEXCOORD0)
{
    BUF_OUT Out = (BUF_OUT)0;
    Out.Pos = Pos;
    Out.Tex = Tex;
    return Out;
}

// Rows 8 .. 30 : ripple queue
// Row  31      : foot latch - one bit per slot, set while that slot touches the
//                floor.  ver 1.7 moved it here: rows 0..7 were never written on
//                this machine (the queue area provably is), which is why the
//                foot state always read back as zero.
// pack a floor local point (x, z) into one float: quarter unit resolution, each
// axis offset by 64 and clamped to 0..511, then z * 1024 + x.  float32 keeps
// integers exact up to 2^24 and 1024 is a power of two, so this round trips.
float EncodePos(float2 p)
{
    float x = floor(clamp((p.x + 64.0) * 4.0, 0.0, 511.0));
    float z = floor(clamp((p.y + 64.0) * 4.0, 0.0, 511.0));
    return x + 1024.0 * z;
}

float2 DecodePos(float v)
{
    float z = floor(v / 1024.0);
    float x = v - 1024.0 * z;
    return float2(x, z) * 0.25 - 64.0;
}

// A row that did not come back (first load, timeline rewind, a dropped write)
// decodes to the packing default (-64, -64), outside the 20 x 20 floor.
// Reject it before the slide test: a missing row may cost a ripple, but it
// must never produce one every frame.
bool HasPoint(float2 p)
{
    return (abs(p.x) <= 40.0) && (abs(p.y) <= 40.0);
}
// rows 0..24  : ripple queue (25 slots)
// rows 25..27 : per model pair last spawn time,  .rgb = pairs 0..2 / 3..5 / 6,7
// rows 28..30 : per model pair last spawn point, same three-per-row split
// row  31     : foot latch, one bit per slot.  Read from .w.
//
// Rows 25..30 write 1.0 into .a and three payload values into .rgb.  That is
// not cosmetic: on this machine a render target row whose alpha ends up 0 is
// dropped completely, so 2.6..2.8 - which packed four pairs per row and let
// the alpha be "the cooldown of pair 3" or "the packed point of pair 3", i.e.
// 0 whenever fewer than four models were loaded - never stored the per pair
// state at all.  Reading it back gave cd = 0 (cooldown never armed) and the
// point decode(0) = (-64, -64) (slide test always true): one ripple every
// 0.4 s while the model stood still.  Three scalars per row plus "alpha = 1"
// is the only layout that has survived readback here.
//
// A pair starts a ripple when one of its feet either touches down (height edge)
// or slides away from the point of its own last ripple.  The second rule exists
// because plenty of choreography never lifts a foot high enough to make an edge.
// Up to 8 pairs (16 feet) can start one in the same frame.
float4 UpdateState_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int idx = (int)floor(Tex.y * STATE_ROWS);

    // controller: Freq+ makes the interval shorter, Freq- longer
    float freq = (1.0 + CtrlFreqM * 2.0) / (1.0 + CtrlFreqP * 2.0);
    float gap  = TRIG_GAP * freq;

    float  prevMask = StateRow(MASK_ROW).w;

    // Rows 25..30: three payload scalars in .rgb, .a is always 1.0.
    float4 cdA  = StateRow(CD_ROW0);
    float4 cdB  = StateRow(CD_ROW1);
    float4 cdC  = StateRow(CD_ROW2);
    float4 posA = StateRow(POS_ROW0);
    float4 posB = StateRow(POS_ROW1);
    float4 posC = StateRow(POS_ROW2);

    float  cd[8];
    float2 pp[8];
    cd[0] = cdA.x; cd[1] = cdA.y; cd[2] = cdA.z;
    cd[3] = cdB.x; cd[4] = cdB.y; cd[5] = cdB.z;
    cd[6] = cdC.x; cd[7] = cdC.y;

    pp[0] = DecodePos(posA.x); pp[1] = DecodePos(posA.y);
    pp[2] = DecodePos(posA.z);
    pp[3] = DecodePos(posB.x); pp[4] = DecodePos(posB.y);
    pp[5] = DecodePos(posB.z);
    pp[6] = DecodePos(posC.x); pp[7] = DecodePos(posC.y);

    // The slide test must not compare one foot of a pair with the other foot's
    // landing point (they are 5..8 units apart, which made the two feet take
    // turns "sliding" while the model stood still).  Per pair we compare the
    // midpoint of the feet that are on the floor with the midpoint recorded at
    // this pair's last ripple.
    float  mask = 0.0;
    bool   pairFire[8];
    float2 pairPos[8];

    [unroll]
    for (int p = 0; p < 8; ++p)
    {
        float4 m0 = MarkerAt(p * 2);
        float4 m1 = MarkerAt(p * 2 + 1);

        bool on0 = m0.w > 0.5;
        bool on1 = m1.w > 0.5;

        float w0 = pow(2.0, (float)(p * 2));
        float w1 = w0 * 2.0;
        bool  prev0 = (fmod(floor(prevMask / w0), 2.0) > 0.5);
        bool  prev1 = (fmod(floor(prevMask / w1), 2.0) > 0.5);

        if (on0) mask += w0;
        if (on1) mask += w1;

        float2 sum      = float2(0.0, 0.0);
        int    cnt      = 0;
        bool   edge     = false;
        float2 edgePos  = float2(0.0, 0.0);

        if (on0) { sum += m0.xy; cnt++; if (!prev0) { edge = true; edgePos = m0.xy; } }
        if (on1 && !edge) { sum += m1.xy; cnt++; if (!prev1) { edge = true; edgePos = m1.xy; } }
        else if (on1)     { sum += m1.xy; cnt++; }

        pairFire[p] = false;
        pairPos[p]  = float2(0.0, 0.0);

        if (cnt > 0)
        {
            float2 avg    = sum / (float)cnt;
            bool   cooled = (CurTime - PastTime(cd[p]) > gap);
            // The midpoint only means something while both feet are down: with
            // one foot in the air the average collapses onto the standing foot,
            // which looks like a slide on every lift.  One-foot phrases get
            // their ripples from the landing edge instead.
            bool   slid   = (cnt > 1) && HasPoint(pp[p]) &&
                            (distance(avg, pp[p]) > StepLen());

            if ((edge || slid) && cooled)
            {
                pairFire[p] = true;
                pairPos[p]  = edge ? edgePos : avg;
                cd[p]       = CurTime;
                if (cnt > 1) pp[p] = avg;   // reference is only valid with both feet down
            }
        }
    }

    // how many pairs start a ripple this frame (0 .. 8)
    int shift = 0;
    [unroll]
    for (int c = 0; c < 8; ++c)
    {
        if (pairFire[c]) shift++;
    }

    // ---- per pair state rows
    if (idx == CD_ROW0)  return float4(cd[0], cd[1], cd[2], 1.0);
    if (idx == CD_ROW1)  return float4(cd[3], cd[4], cd[5], 1.0);
    if (idx == CD_ROW2)  return float4(cd[6], cd[7], 0.0, 1.0);
    if (idx == POS_ROW0) return float4(EncodePos(pp[0]), EncodePos(pp[1]),
                                       EncodePos(pp[2]), 1.0);
    if (idx == POS_ROW1) return float4(EncodePos(pp[3]), EncodePos(pp[4]),
                                       EncodePos(pp[5]), 1.0);
    if (idx == POS_ROW2) return float4(EncodePos(pp[6]), EncodePos(pp[7]),
                                       0.0, 1.0);

    // ---- foot latch row
    if (idx == MASK_ROW)
    {
        return float4(mask, mask, mask, mask);
    }

    // ---- ripple queue
    int    q     = idx - QUEUE_ROW0;
    float4 color = float4(0.0, 0.0, 0.0, 0.0);

    if (q < shift)
    {
        // this row is one of the new entries: find the q-th firing pair
        int    rank = 0;
        int    wp   = 0;
        float2 wpos = float2(0.0, 0.0);

        [unroll]
        for (int k = 0; k < 8; ++k)
        {
            if (pairFire[k])
            {
                if (rank == q) { wp = k; wpos = pairPos[k]; }
                rank++;
            }
        }

        int ptype = (int)fmod(floor(CurTime) + (float)wp, 5.0);
        color = float4(wpos.x, wpos.y, CurTime, 1.0 + (float)ptype);
    }
    else
    {
        float4 pc = StateRow(QUEUE_ROW0 + q - shift);
        if (pc.w > 0.5 && pc.z <= CurTime && CurTime - pc.z <= LifeMax())
        {
            color = pc;
        }
    }

    return color;
}
struct VS_OUT
{
    float4 Pos   : POSITION;
    float2 Local : TEXCOORD1;
};

VS_OUT DrawFloor_VS(float4 Pos : POSITION)
{
    VS_OUT Out = (VS_OUT)0;
    Out.Pos   = mul(Pos, WorldViewProjMatrix);
    Out.Local = Pos.xz;
    return Out;
}

// five patterns, cycled by the ripple start time (same idea as Innocencer):
//   type 0 = rotating lines, 1 = triangle, 2 = square, 3 = circle, 4 = star
// aa = local units per screen pixel, used to soften the hard band edges
float RippleShape(float2 v, float age, float t0, int type, float aa)
{
    float r     = length(v);
    float scale = RipSpeed() * age;
    float aaW   = max(aa * 0.75, 1.0e-4);

    if (type == 0)
    {
        // radial lines, fading out (the original line effect is short lived)
        float radL  = atan2(v.y, v.x) + t0 * 13.0;
        float wL    = r * sin(radL);
        float width = RIP_LINE_W * (1.0 - saturate(age / 1.5));
        return 1.0 - smoothstep(width - aaW, width + aaW, abs(wL));
    }

    float rad = atan2(v.y, v.x) + t0 * 13.0 + age * RIP_ROT;

    // Every pattern is fitted to the same outer radius.  An n-gon whose
    // apothem is s reaches s / cos(pi / n), so before this the triangle
    // reached twice as far as the circle and the ring visibly "breathed"
    // whenever the pattern changed.
    float scl = scale;
    float w;

    if (type == 4)
    {
        // Five point star.  The edge between a valley (radius STAR_INNER,
        // angle 36 deg) and a tip (radius 1.0, angle 72 deg) is a straight
        // chord, so the boundary radius is the polar form of that chord.
        // Interpolating the radius by angle instead would give curved
        // "petals" rather than a star.
        float c36 = cos(radians(36.0));
        float s36 = sin(radians(36.0));
        float phi = abs(fmod(abs(rad), radians(72.0)) - radians(36.0));
        float den = (STAR_INNER - c36) * sin(phi) + s36 * cos(phi);
        w = r * den / (STAR_INNER * s36);
    }
    else
    {
        // triangle / square: the level set of r * cos(offset) is a regular
        // n-gon; scl shrinks the apothem so the outer radius stays "scale"
        float a;
        if      (type == 1) { a = fmod(abs(rad), radians(120.0)) + radians(30.0);
                              scl *= cos(radians(60.0)); }
        else if (type == 2) { a = fmod(abs(rad), radians(90.0))  + radians(45.0);
                              scl *= cos(radians(45.0)); }
        else                { a = radians(90.0); }               // circle
        w = r * sin(a);
    }

    float hi = scl + max(0.10, scl * RIP_BAND);

    return smoothstep(scl - aaW, scl + aaW, w) *
           (1.0 - smoothstep(hi - aaW, hi + aaW, w));
}

// ---------------------------------------------------------------- colour
float3 HsvToRgb(float h, float s, float v)
{
    h = frac(h) * 6.0;
    float i = floor(h);
    float f = h - i;
    float p = v * (1.0 - s);
    float q = v * (1.0 - s * f);
    float t = v * (1.0 - s * (1.0 - f));

    if (i < 1.0) return float3(v, t, p);
    if (i < 2.0) return float3(q, v, p);
    if (i < 3.0) return float3(p, v, t);
    if (i < 4.0) return float3(p, q, v);
    if (i < 5.0) return float3(t, p, v);
    return float3(v, p, q);
}

float3 RgbToHsv(float3 c)
{
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float d  = mx - mn;

    float h = 0.0;
    if (d > 1.0e-5)
    {
        if      (c.r >= c.g && c.r >= c.b) h = fmod((c.g - c.b) / d + 6.0, 6.0);
        else if (c.g >= c.r && c.g >= c.b) h = (c.b - c.r) / d + 2.0;
        else                               h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }

    float s = (mx > 1.0e-5) ? d / mx : 0.0;
    return float3(h, s, mx);
}

// ---------------------------------------------------------------- debug overlay
#if DEBUG_HUD
// DIAGNOSTIC overlay.  Colours never overwrite each other.
//   band A (z -10.0 .. -9.0) : 16 foot slots, from (on now, on last frame)
//       GREEN  = on now AND last frame   -> steady
//       YELLOW = on now, not last frame  -> touchdown edge
//       CYAN   = not now, was last frame -> the lift frame
//       BLACK  = neither
//   band B (z -9.0 .. -8.0) : 29 ripple queue slots, colour = age
//       WHITE < 1s, YELLOW < 3s, RED < 5s, BLACK = empty
//   band C (z -8.4 .. -7.8) : purple bar = this build is compiled
float3 HudDiag(float2 l)
{
    float3 c = float3(0.0, 0.0, 0.0);
    float  pm = StateRow(MASK_ROW).w;

    // ---- band A
    [unroll]
    for (int f = 0; f < SLOT_MAX; ++f)
    {
        float4 m  = MarkerAt(f);
        bool   on = m.w > 0.5;

        float  w      = pow(2.0, (float)f);
        bool   prevOn = (fmod(floor(pm / w), 2.0) > 0.5);

        float2 c0 = float2(-10.0 + (float)f * 1.25, -10.0);
        float2 d  = abs(l - (c0 + float2(0.55, 0.5))) - float2(0.55, 0.5);
        float  mm = 1.0 - smoothstep(-0.05, 0.05, max(d.x, d.y));

        float3 col = float3(0.05, 0.05, 0.05);
        if ( prevOn &&  on) col = float3(0.15, 1.00, 0.30);
        if (!prevOn &&  on) col = float3(1.00, 0.90, 0.10);
        if ( prevOn && !on) col = float3(0.10, 0.60, 1.00);
        c = max(c, col * mm);
    }

    // ---- band B
    [loop]
    for (int i = 0; i < SLOT_COUNT; ++i)
    {
        float4 s = tex2D(StateASamp, float2(0.5, (QUEUE_ROW0 + i + 0.5) / STATE_ROWS));
        float3 col = float3(0.05, 0.05, 0.05);
        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if      (age >= 0.0 && age < 1.0)    col = float3(1.00, 1.00, 1.00);
            else if (age < 3.0)                  col = float3(1.00, 0.85, 0.10);
            else if (age < LifeMax())            col = float3(1.00, 0.20, 0.10);
        }
        float2 c0 = float2(-10.0 + (float)i * 0.69, -9.0);
        float2 d  = abs(l - (c0 + float2(0.32, 0.5))) - float2(0.32, 0.5);
        float  mm = 1.0 - smoothstep(-0.05, 0.05, max(d.x, d.y));
        c = max(c, col * mm);
    }

    // ---- band C: build-live bar
    float2 dbar = float2(abs(l.x) - 10.0, abs(l.y + 8.1) - 0.3);
    c += float3(0.30, 0.06, 0.55) * (1.0 - smoothstep(-0.05, 0.05, max(dbar.x, dbar.y)));

    // ---- band D: the per pair state (rows 25..30), one cell per pair.
    // These rows are the ones that silently read back as zero while their
    // alpha was 0 (2.6..2.8), so they get a readout of their own:
    //   magenta = no usable record  (row lost / first load / rewound)
    //   green   = record present, cooldown expired (may fire)
    //   blue    = record present, still cooling down
    {
        float  gapp = TRIG_GAP * (1.0 + CtrlFreqM * 2.0) / (1.0 + CtrlFreqP * 2.0);
        float4 cdr0 = StateRow(CD_ROW0);
        float4 cdr1 = StateRow(CD_ROW1);
        float4 cdr2 = StateRow(CD_ROW2);
        float4 pnr0 = StateRow(POS_ROW0);
        float4 pnr1 = StateRow(POS_ROW1);
        float4 pnr2 = StateRow(POS_ROW2);

        float  cdv[8];
        float2 pnt[8];
        cdv[0] = cdr0.x; cdv[1] = cdr0.y; cdv[2] = cdr0.z;
        cdv[3] = cdr1.x; cdv[4] = cdr1.y; cdv[5] = cdr1.z;
        cdv[6] = cdr2.x; cdv[7] = cdr2.y;
        pnt[0] = DecodePos(pnr0.x); pnt[1] = DecodePos(pnr0.y);
        pnt[2] = DecodePos(pnr0.z);
        pnt[3] = DecodePos(pnr1.x); pnt[4] = DecodePos(pnr1.y);
        pnt[5] = DecodePos(pnr1.z);
        pnt[6] = DecodePos(pnr2.x); pnt[7] = DecodePos(pnr2.y);

        [unroll]
        for (int p = 0; p < 8; ++p)
        {
            float3 dcol = float3(0.50, 0.00, 0.60);
            if (HasPoint(pnt[p]))
            {
                dcol = (CurTime - PastTime(cdv[p]) > gapp) ? float3(0.15, 1.00, 0.30)
                                                           : float3(0.10, 0.55, 1.00);
            }
            float2 dc0 = float2(-9.0 + (float)p * 2.0, -7.2);
            float2 dd  = abs(l - (dc0 + float2(0.8, 0.4))) - float2(0.8, 0.4);
            float  dm  = 1.0 - smoothstep(-0.05, 0.05, max(dd.x, dd.y));
            c = max(c, dcol * dm);
        }
    }

    return c;
}
#endif

float4 DrawFloor_PS(VS_OUT IN) : COLOR0
{
    float2 l = IN.Local;
    float acc = 0.0;

    // local units covered by one screen pixel (for analytic anti aliasing)
    float pxAA = max(max(length(ddx(l)), length(ddy(l))), 1.0e-4);

    [loop]
    for (int i = 0; i < SLOT_COUNT; ++i)
    {
        // queue rows are QUEUE_ROW0 .. STATE_ROWS-1 of the 1 x 32 state texture
        float4 s = tex2D(StateASamp, float2(0.5, (QUEUE_ROW0 + i + 0.5) / STATE_ROWS));

        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if (age >= 0.0 && age < LifeMax())
            {
                float2 v     = l - s.xy;
                float  rad   = RipSpeed() * age;
                int    type  = (int)(s.w - 0.99);      // pattern stored as 1 + type
                float  shape = RippleShape(v, age, s.z, type, pxAA);

                // fade in at birth, fade out at the end, weaker when far
                float att  = (1.0 / (1.0 + rad * 0.22)) * saturate(age / 0.15);
                float fade = 1.0 - smoothstep(LifeMax() - 1.5, LifeMax(), age);

                acc += shape * att * fade;
            }
        }
    }

    // keep overlapping rings from blowing out
    acc = min(acc, 1.6);

    // controller: hue wheel around the panel colour, plus brightness
    float  hueOff = CtrlHueP - CtrlHueM;
    float  bright = (1.0 + CtrlBrightP * 2.0) / (1.0 + CtrlBrightM * 2.0);
    float3 baseHsv = RgbToHsv(RippleColor.rgb);
    float3 col     = HsvToRgb(baseHsv.x + hueOff, baseHsv.y, baseHsv.z) * bright;

    float3 c = col * (acc * RippleStrength * AccessoryTrans);

#if DEBUG_HUD
    {
        c += HudDiag(l);
    }
#endif

    return float4(c, 1.0);
}


// ---------------------------------------------------------------- technique
// The whole script has to run exactly once per frame, and only in the pass
// where the off-screen foot markers are valid.  1.3 declares MMDPass
// explicitly and gives the other passes an empty technique: while a motion
// plays back, MMD re-runs its z-plot / shadow passes every frame, and the
// update script was being executed there too - with an empty marker buffer.
// That wrote "not touching" into the foot rows, which the next frame read back
// as a touchdown.  The HUD could not show it because the displayed pass was
// the good one.
technique MainTec <
    string MMDPass = "object";
    string Script =
        "RenderColorTarget0=StateA;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=UpdateState;"
        "RenderColorTarget0=;"
        "RenderDepthStencilTarget=;"
        "Pass=DrawFloor;";
>
{
    pass UpdateState < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;   // a row written with alpha 0 is dropped
        COLORWRITEENABLE = 0xF;     // RGBA: never inherit a masked channel write
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 UpdateState_PS();
    }

    pass DrawFloor
    {
        ZENABLE          = TRUE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = TRUE;
        SrcBlend         = ONE;
        DestBlend        = ONE;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 DrawFloor_VS();
        PixelShader      = compile ps_3_0 DrawFloor_PS();
    }
}

technique MainTecSS <
    string MMDPass = "object_ss";
    string Script =
        "RenderColorTarget0=StateA;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=UpdateState;"
        "RenderColorTarget0=;"
        "RenderDepthStencilTarget=;"
        "Pass=DrawFloor;";
>
{
    pass UpdateState < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;   // a row written with alpha 0 is dropped
        COLORWRITEENABLE = 0xF;     // RGBA: never inherit a masked channel write
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 UpdateState_PS();
    }

    pass DrawFloor
    {
        ZENABLE          = TRUE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = TRUE;
        SrcBlend         = ONE;
        DestBlend        = ONE;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 DrawFloor_VS();
        PixelShader      = compile ps_3_0 DrawFloor_PS();
    }
}

// -- other MMD passes -------------------------------------------------------
// Empty on purpose: the state update is only valid in the pass where the
// off-screen foot markers exist (see the comment above MainTec).  Declaring
// these keeps MMD from running the update script in its shadow / z-plot /
// edge passes while a motion plays back.
technique ShadowTec < string MMDPass = "shadow"; > { }
technique EdgeTec   < string MMDPass = "edge";   > { }
technique ZplotTec  < string MMDPass = "zplot";  > { }