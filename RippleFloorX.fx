////////////////////////////////////////////////////////////////////////////////
//
//  RippleFloorX.fx   ver 3.8
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
//  State texture (1 x 256, RGBA32F)
//      rows   0 .. 120 : ripple queue   (x, z, start time, 1 + pattern)
//      rows 121 .. 128 : one row per model pair
//                        .x  = its last spawn time (<= 0: no record yet)
//                        .yz = its last spawn point
//                        .a  = 1
//      row  129        : foot latch, one bit per slot
//
//  WRITE RULE (learned the hard way on this machine)
//      a state row whose written alpha is 0 is lost as a whole - every channel
//      reads back 0, not just alpha.  So every row keeps alpha >= 1, the pair
//      rows write 1.0 into .a and their payload into .rgb, and no fourth
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
//        Innocencer (Mairi-nyu-P) for the ripple queue idea.
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
#define SIZE_GAIN    1.5     // Sz+ at 1.0 -> x2.5, Sz- at 1.0 -> /2.5 (0 = default)
#define JITTER_AMP   0.25    // Jitter at 1.0 -> every ripple gets +-25 % size
#define STAR_BAND_MUL 1.25   // the star reads lighter than a square at equal width
#define ROT_GAIN     1.5     // Rot+ at 1.0 -> 10 rad/s, Rot- -> 1.6 rad/s (0 = RIP_ROT)
                             // the range stops at x2.5 on purpose: MMD runs at 30 fps and
                             // past ~10 rad/s a 5 point star starts to strobe

#define SLOT_MAX     16      // foot marker slots to scan (must match fxsub FOOT_SLOTS)
#define QUEUE_ROW0   0       // first state row used by the ripple queue
#define SLOT_COUNT   121     // ripple queue rows 0 .. 120 (8 models x 2.5 ripples
                             // per second x 5 s = 100 rings alive, plus margin)
#define PAIR_ROW0    121     // one row per model pair, rows 121 .. 128:
                             //   .x  = time of its last ripple (<= 0: none yet)
                             //   .yz = the point of that ripple
                             //   .a  = 1 (a row written with alpha 0 is dropped)
#define MASK_ROW     129     // foot latch: bit per slot, read from .w
#define STEP_R       1.5     // a foot that slid this far (local unit) since its
                             // last ripple counts as a new step, so choreography
                             // that never lifts the foot still leaves ripples
#define STATE_ROWS   256     // power of two, because some drivers only create
                             // POT targets; rows 130 .. 255 are unused

// The foot marker buffer is cut into MARKER_STRIPS columns, one per slot; the
// fxsub draws its blobs with its own STRIP_SLOTS (32), so keep this equal to
// it.  It has nothing to do with STATE_ROWS.
#define MARKER_STRIPS 32

#define TRIG_GAP     0.40    // per model: min time between two of its own ripples
#define FREQ_GAIN_P  2.0     // Freq+ at 1.0 -> gap / 3   = 0.13 s (dense)
#define FREQ_GAIN_M  12.0    // Freq- at 1.0 -> gap x 13  = 5.20 s (sparse)
                             // the two sides are deliberately asymmetric: a crowded
                             // scene (8 models) needs a much longer gap, and 0.13 s is
                             // already past what the 121 slot queue can hold


// debug overlay: 1 = paint the foot / trigger state along the floor edge
#define DEBUG_HUD    0

// ---------------------------------------------------------------- constants
float4x4 WorldViewProjMatrix : WORLDVIEWPROJECTION;

// accessory transparency (Tr)
float AccessoryTrans : CONTROLOBJECT < string name = "(self)"; string item = "Tr"; >;

// MMD's accessory add-mode flag (MME reference: opadd).  When it is on, MMD
// draws with ONE/ONE, so the shader premultiplies the ring colour by its
// coverage; with the flag off MMD uses normal alpha and the colour stays
// straight.  That makes the add checkbox in the accessory panel a live
// switch between the glow look and the transparent look.
bool opadd;

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

// per pattern size (0 = default, + grows, - shrinks) and a per ripple jitter
float CtrlTriSzP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "TriSz+"; >;
float CtrlTriSzM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "TriSz-"; >;
float CtrlSqrSzP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "SqrSz+"; >;
float CtrlSqrSzM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "SqrSz-"; >;
float CtrlCirSzP   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "CirSz+"; >;
float CtrlCirSzM   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "CirSz-"; >;
float CtrlStarSzP  : CONTROLOBJECT < string name = CTRL_MODEL; string item = "StarSz+"; >;
float CtrlStarSzM  : CONTROLOBJECT < string name = CTRL_MODEL; string item = "StarSz-"; >;
float CtrlLineSzP  : CONTROLOBJECT < string name = CTRL_MODEL; string item = "LineSz+"; >;
float CtrlLineSzM  : CONTROLOBJECT < string name = CTRL_MODEL; string item = "LineSz-"; >;
float CtrlJitter   : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Jitter"; >;
float CtrlRotP     : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Rot+"; >;
float CtrlRotM     : CONTROLOBJECT < string name = CTRL_MODEL; string item = "Rot-"; >;

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

// Per model ripple interval.  Both morphs at 0 (or no controller at all) give
// exactly TRIG_GAP.  Freq+ divides it, Freq- multiplies it.
float TriggerGap()
{
    return TRIG_GAP * (1.0 + CtrlFreqM * FREQ_GAIN_M) / (1.0 + CtrlFreqP * FREQ_GAIN_P);
}

// Pattern rotation speed.  Both morphs at 0 (or no controller at all) give
// exactly RIP_ROT, i.e. the look the effect has without any of this.
float RotSpeed()
{
    return RIP_ROT * (1.0 + CtrlRotP * ROT_GAIN) / (1.0 + CtrlRotM * ROT_GAIN);
}

// Per pattern size factor.  Both morphs at 0 (or no controller at all) give
// exactly 1.0 - i.e. the look the effect has without any of this.
float ShapeSize(int type)
{
    float p = 0.0;
    float m = 0.0;

    if      (type == 0) { p = CtrlLineSzP; m = CtrlLineSzM; }
    else if (type == 1) { p = CtrlTriSzP;  m = CtrlTriSzM;  }
    else if (type == 2) { p = CtrlSqrSzP;  m = CtrlSqrSzM;  }
    else if (type == 3) { p = CtrlCirSzP;  m = CtrlCirSzM;  }
    else                { p = CtrlStarSzP; m = CtrlStarSzM; }

    return (1.0 + p * SIZE_GAIN) / (1.0 + m * SIZE_GAIN);
}

// One deterministic factor per ripple: stable for the whole life of that
// ring and different from ripple to ripple, so consecutive rings never look
// stamped from the same mould.  0 = off.
float ShapeJitter(float seed)
{
    return 1.0 + CtrlJitter * JITTER_AMP * (frac(seed) * 2.0 - 1.0);
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

// ------------------------------------------------------- state (1 x 256)
// Two targets and two passes instead of the TEXTUREVALUE snapshot.  (v3.8)
//
// TEXTUREVALUE hands the previous frame's texels over in constant registers,
// and a *dynamic* index into that array (the queue shift reads row i - shift,
// where i is the row being rendered) runs out of ps_3_0 constant registers
// between 48 and 56 rows (fxc X4507).  Some drivers only create power-of-two
// targets, so the old 1 x 32 layout was the largest one that mechanism could
// do - that wall, not an MME limit, is why the queue was 25 slots.
//
// UpdatePairs reads StateA and writes StateB; ShiftQueue reads StateB and
// writes StateA, so the next frame finds the state in the same texture again
// and the technique script never has to switch buffers between frames.
texture StateA : RENDERCOLORTARGET <
    int Width  = 1;
    int Height = STATE_ROWS;
    string Format = "A32B32G32R32F";
>;

texture StateB : RENDERCOLORTARGET <
    int Width  = 1;
    int Height = STATE_ROWS;
    string Format = "A32B32G32R32F";
>;

texture StateDepth : RENDERDEPTHSTENCILTARGET <
    int Width  = 1;
    int Height = STATE_ROWS;
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

sampler StateBSamp = sampler_state
{
    texture   = <StateB>;
    MinFilter = NONE;
    MagFilter = NONE;
    MipFilter = NONE;
    AddressU  = CLAMP;
    AddressV  = CLAMP;
};


// ---------------------------------------------------------------- helpers
// row i of the previous state (StateA) and of the state pass 1 produced (B)
float4 StateRow(int i)
{
    return tex2Dlod(StateASamp, float4(0.5, (i + 0.5) / STATE_ROWS, 0.0, 0.0));
}

float4 NewRow(int i)
{
    return tex2Dlod(StateBSamp, float4(0.5, (i + 0.5) / STATE_ROWS, 0.0, 0.0));
}

// marker blob of one foot slot, centred 4 pixels above the bottom edge
float4 MarkerAt(int slot)
{
    return tex2D(MarkerSamp, float2((slot + 0.5) / MARKER_STRIPS,
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

// rows 0 .. 120 : ripple queue, rows 121 .. 128 : one row per model pair,
// row 129 : foot latch.  A pair starts a ripple when one of its feet either
// touches down (height edge) or slides away from the point of its own last
// ripple; the second rule exists because plenty of choreography never lifts a
// foot high enough to make an edge.  Up to 8 pairs (16 feet) can start one in
// the same frame.
//
// Pass 1: recompute the eight pair rows.  The pair state lives in texture rows
// on purpose - a local cd[8]/pp[8] would stay live in ps_3_0 temporary
// registers across the whole unrolled loop and blow the 32 register budget
// (fxc X4505).  Rows that are not pair rows are copied straight through.
float4 UpdatePairs_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int idx = (int)floor(Tex.y * STATE_ROWS);

    float gap      = TriggerGap();
    float prevMask = StateRow(MASK_ROW).w;
    float mask     = 0.0;

    [unroll]
    for (int p = 0; p < 8; ++p)
    {
        float4 pair = StateRow(PAIR_ROW0 + p);
        float  cd   = pair.x;
        float2 pp   = pair.yz;

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

        float2 sum     = float2(0.0, 0.0);
        int    cnt     = 0;
        bool   edge    = false;
        float2 edgePos = float2(0.0, 0.0);

        if (on0) { sum += m0.xy; cnt++; if (!prev0) { edge = true; edgePos = m0.xy; } }
        if (on1 && !edge) { sum += m1.xy; cnt++; if (!prev1) { edge = true; edgePos = m1.xy; } }
        else if (on1)     { sum += m1.xy; cnt++; }

        if (cnt > 0)
        {
            float2 avg    = sum / (float)cnt;
            bool   cooled = (CurTime - PastTime(cd) > gap);
            // The midpoint only means something while both feet are down: with
            // one foot in the air the average collapses onto the standing foot,
            // which looks like a slide on every lift.
            bool   slid   = (cnt > 1) && (cd > 0.0) &&
                            (distance(avg, pp) > StepLen());

            if ((edge || slid) && cooled)
            {
                cd = CurTime;
                pp = edge ? edgePos : avg;
            }
        }

        if (idx == PAIR_ROW0 + p)
            return float4(cd, pp.x, pp.y, 1.0);
    }

    if (idx == MASK_ROW)
        return float4(mask, mask, mask, mask);

    return StateRow(idx);
}


// Pass 2: shift the queue by the number of pairs that spawned this frame.
// A pair that spawned has cd == CurTime, so the same frame run twice is a
// no-op: pass 1 finds no new edge and no cooled pair, shift stays 0.
float4 ShiftQueue_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int idx = (int)floor(Tex.y * STATE_ROWS);

    // everything outside the queue is copied through unchanged
    if (idx >= PAIR_ROW0)
        return NewRow(idx);

    // A second update in the same frame must not shift twice.  Pass 1 leaves a
    // pair that just spawned at cd == CurTime, so a second run of pass 2 would
    // otherwise re-insert the same entries; the newest queue row is the tell
    // (a frame that already produced entries has one stamped with CurTime).
    float4 newest = NewRow(QUEUE_ROW0);
    if (newest.w > 0.5 && newest.z == CurTime)
        return NewRow(QUEUE_ROW0 + idx);

    float  shift    = 0.0;
    float4 newEntry = float4(0.0, 0.0, 0.0, 0.0);

    [unroll]
    for (int p = 0; p < 8; ++p)
    {
        float4 pair = NewRow(PAIR_ROW0 + p);
        // pair.x > 0.0: on the very first frame every pair row is still 0 and
        // CurTime is 0 as well, so `pair.x == CurTime` used to be true for all
        // eight pairs at once - eight rings (five different patterns) dropped
        // onto the floor origin.  A real spawn can never happen at CurTime 0:
        // the `cooled` test needs CurTime to be larger than the trigger gap.
        if (pair.x == CurTime && pair.x > 0.0)
        {
            if ((int)shift == idx)
            {
                int type = (int)fmod(floor(CurTime) + (float)p, 5.0);
                newEntry = float4(pair.y, pair.z, CurTime, 1.0 + (float)type);
            }
            shift += 1.0;
        }
    }

    if ((float)idx < shift)
        return newEntry;

    float4 pc = NewRow(QUEUE_ROW0 + idx - (int)shift);
    if (pc.w > 0.5 && pc.z <= CurTime && CurTime - pc.z <= LifeMax())
        return pc;

    return float4(0.0, 0.0, 0.0, 0.0);
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
float RippleShape(float2 v, float age, float t0, int type, float aa, float sizeK)
{
    float r     = length(v);
    float scale = RipSpeed() * age;
    float aaW   = max(aa * 0.75, 1.0e-4);

    if (type == 0)
    {
        // radial lines, fading out (the original line effect is short lived)
        float radL  = atan2(v.y, v.x) + t0 * 13.0;
        float wL    = r * sin(radL);
        float width = RIP_LINE_W * sizeK * (1.0 - saturate(age / 1.5));
        return 1.0 - smoothstep(width - aaW, width + aaW, abs(wL));
    }

    float rad = atan2(v.y, v.x) + t0 * 13.0 + age * RotSpeed();

    // Every pattern is fitted to the same outer radius.  An n-gon whose
    // apothem is s reaches s / cos(pi / n), so before this the triangle
    // reached twice as far as the circle and the ring visibly "breathed"
    // whenever the pattern changed.
    float scl = scale * sizeK;

    // band thickness measured ACROSS the edge (world units) and the AA half
    // width; both are expressed in w units below, so a pattern whose w changes
    // faster per unit of r has to scale them down to keep the same look
    float bw  = max(0.10, scl * RIP_BAND);
    float aaw = aaW;
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

        // k = |dw/dr|.  Near a valley the level sets sit about 1/STAR_INNER
        // as far apart radially as at a tip, so without this the outline was
        // a third as thick there and the star read as a much thinner line
        // than the triangle / square.  Scaling w, the band and the AA all by k
        // keeps the thickness perpendicular to the edge constant - the same
        // "line weight" the other patterns have.
        float k = den / (STAR_INNER * s36);
        w   = r * k;
        bw  *= k * STAR_BAND_MUL;
        aaw *= k;
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

    float hi = scl + bw;

    return smoothstep(scl - aaw, scl + aaw, w) *
           (1.0 - smoothstep(hi - aaw, hi + aaw, w));
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
#define HUD_SLOTS    32   // the overlay strip has room for this many queue cells
// DIAGNOSTIC overlay.  Colours never overwrite each other.
//   band A (z -10.0 .. -9.0) : 16 foot slots, from (on now, on last frame)
//       GREEN  = on now AND last frame   -> steady
//       YELLOW = on now, not last frame  -> touchdown edge
//       CYAN   = not now, was last frame -> the lift frame
//       BLACK  = neither
//   band B (z -9.0 .. -8.0) : the newest HUD_SLOTS queue rows, colour = age
//       WHITE < 1s, YELLOW < 3s, RED < 5s, BLACK = empty
//   band C (z -8.4 .. -7.8) : purple bar = this build is compiled
//   band D (z -7.2 .. -6.8) : one cell per pair, colour = its stored record
//       MAGENTA = no record, GREEN = ready to fire, BLUE = still cooling down
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
    for (int i = 0; i < HUD_SLOTS; ++i)
    {
        float4 s = StateRow(QUEUE_ROW0 + i);
        float3 col = float3(0.05, 0.05, 0.05);
        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if      (age >= 0.0 && age < 1.0)    col = float3(1.00, 1.00, 1.00);
            else if (age < 3.0)                  col = float3(1.00, 0.85, 0.10);
            else if (age < LifeMax())            col = float3(1.00, 0.20, 0.10);
        }
        float2 c0 = float2(-10.0 + (float)i * 0.62, -9.0);
        float2 d  = abs(l - (c0 + float2(0.32, 0.5))) - float2(0.32, 0.5);
        float  mm = 1.0 - smoothstep(-0.05, 0.05, max(d.x, d.y));
        c = max(c, col * mm);
    }

    // ---- band C: build-live bar
    float2 dbar = float2(abs(l.x) - 10.0, abs(l.y + 8.1) - 0.3);
    c += float3(0.30, 0.06, 0.55) * (1.0 - smoothstep(-0.05, 0.05, max(dbar.x, dbar.y)));

    // ---- band D: the per pair records
    {
        float gapp = TriggerGap();
        [unroll]
        for (int p = 0; p < 8; ++p)
        {
            float4 pair  = StateRow(PAIR_ROW0 + p);
            bool   valid = pair.x > 0.0;
            bool   ready = valid && (CurTime - PastTime(pair.x) > gapp);

            float3 dcol = float3(0.50, 0.00, 0.60);
            if (valid) dcol = ready ? float3(0.15, 1.00, 0.30)
                                    : float3(0.10, 0.55, 1.00);

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

    // The queue is a shift register: row 0 is the newest entry and every step
    // along the row index is one step older, so once a row has no record left
    // every row behind it is empty too.  Stopping there makes the per-pixel
    // cost follow the number of live rings instead of SLOT_COUNT (it used to
    // sample every row even when nothing was on the floor).
    // Dead rows are written as 0; a row that lost its entry to a timeline
    // rewind keeps z > 0, so only a start time of 0 counts as the empty tail.
    // tex2Dlod, not tex2D: an implicit derivative is not allowed inside a loop
    // with a break (fxc X3526), and the state texture has a single mip.
    [loop]
    for (int i = 0; i < SLOT_COUNT; ++i)
    {
        float4 s = tex2Dlod(StateASamp, float4(0.5, (QUEUE_ROW0 + i + 0.5) / STATE_ROWS, 0.0, 0.0));

        if (s.w <= 0.5 && s.z <= 0.0)
            break;

        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if (age >= 0.0 && age < LifeMax())
            {
                float2 v     = l - s.xy;
                float  rad   = RipSpeed() * age;
                int    type  = (int)(s.w - 0.99);      // pattern stored as 1 + type
                // the jitter seed mixes the birth time with the landing point,
                // otherwise ripples that fire in the same frame (multi model
                // choreography does this a lot) would all get the same size
                float  sizeK = ShapeSize(type) * ShapeJitter(s.z * 7.31 + s.x * 1.7 + s.y * 2.9);
                float  shape = RippleShape(v, age, s.z, type, pxAA, sizeK);

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

    // straight alpha compositing (v3.7): the floor plane itself is fully
    // transparent, only the rings are drawn.  The ring coverage becomes the
    // alpha, so the pattern stays readable on a white stage - the old add-one
    // blend could not do that, because white plus colour is still white.
    // RippleStrength and the accessory Tr fade the rings through the alpha.
    float  a = saturate(acc * RippleStrength * AccessoryTrans);
    float3 c = col;

#if DEBUG_HUD
    {
        float3 h = HudDiag(l);
        c += h;
        a = max(a, max(h.r, max(h.g, h.b)));
    }
#endif

    // additive path: MMD blends with ONE / ONE, so premultiply; the alpha
    // path blends with SRCALPHA / INVSRCALPHA and keeps the straight colour
    if (opadd) c *= a;

    return float4(c, a);
}


// ---------------------------------------------------------------- technique
// Per frame: UpdatePairs (A -> B), ShiftQueue (B -> A), DrawFloor (reads A).
// The chain runs in the object pass and again in object_ss; the second run is
// a no-op by construction (a pair that just spawned has cd == CurTime, so it
// is neither an edge nor cooled and shift stays 0), which is why the update can
// stay in both techniques.  1.3 declares MMDPass explicitly and gives the other
// passes an empty technique: while a motion plays back MMD re-runs its z-plot /
// shadow passes every frame, and the update script was being executed there
// too - with an empty marker buffer.
technique MainTec <
    string MMDPass = "object";
    string Script =
        "RenderColorTarget0=StateB;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=UpdatePairs;"
        "RenderColorTarget0=StateA;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=ShiftQueue;"
        "RenderColorTarget0=;"
        "RenderDepthStencilTarget=;"
        "Pass=DrawFloor;";
>
{
    pass UpdatePairs < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;   // a row written with alpha 0 is dropped
        COLORWRITEENABLE = 0xF;     // RGBA: never inherit a masked channel write
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 UpdatePairs_PS();
    }

    pass ShiftQueue < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;
        COLORWRITEENABLE = 0xF;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 ShiftQueue_PS();
    }

    pass DrawFloor
    {
        ZENABLE          = TRUE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = TRUE;
        // SrcBlend / DestBlend are deliberately left to MMD: the accessory
        // panel's add-mode switch then works at run time (opadd below).
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 DrawFloor_VS();
        PixelShader      = compile ps_3_0 DrawFloor_PS();
    }
}

technique MainTecSS <
    string MMDPass = "object_ss";
    string Script =
        "RenderColorTarget0=StateB;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=UpdatePairs;"
        "RenderColorTarget0=StateA;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=ShiftQueue;"
        "RenderColorTarget0=;"
        "RenderDepthStencilTarget=;"
        "Pass=DrawFloor;";
>
{
    pass UpdatePairs < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;
        COLORWRITEENABLE = 0xF;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 UpdatePairs_PS();
    }

    pass ShiftQueue < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        ALPHATESTENABLE  = FALSE;
        COLORWRITEENABLE = 0xF;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 ShiftQueue_PS();
    }

    pass DrawFloor
    {
        ZENABLE          = TRUE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = TRUE;
        // SrcBlend / DestBlend are deliberately left to MMD: the accessory
        // panel's add-mode switch then works at run time (opadd below).
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