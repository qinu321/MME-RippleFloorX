////////////////////////////////////////////////////////////////////////////////
//
//  RippleFloorX.fx   ver 1.8
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
//  State texture (1 x 32, RGBA32F); the previous frame is read back through
//      row  0 ..  7 : foot slots   (contact, last spawn time, x, z)
//      row  8 .. 31 : ripple queue (x, z, start time, 1 + pattern)
//
//  Trigger = the rising edge of a contact, and nothing else: the foot was off
//  the floor in the previous frame and is on the floor now.  1.0 also accepted
//  "the contact point moved since this foot last touched the floor"; that rule
//  kept firing while a standing model played back (the stored point and the
//  live one never agreed), so it is gone.  The HUD proved the point: the foot
//  slot stays green during that phase, i.e. no edge at all, yet ripples kept
//  coming.
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
#define RIP_SPEED    (RIP_RADIUS / RIP_MAX)
#define RIP_BAND     0.04    // shape band thickness (fraction of the radius)
#define RIP_LINE_W   0.15    // line pattern half width  (local unit)
#define RIP_ROT      4.0     // triangle / square rotation (rad / sec)

#define FOOT_ROWS    8       // foot state rows, kept at the front (must match fxsub)
#define SLOT_COUNT   23      // ripple queue rows 8 .. 30
#define MASK_ROW     31      // foot latch: bit mask, one bit per slot
#define STATE_ROWS   32

// trigger spacing (seconds)
#define TRIG_HOLD    0.50    // same foot: min time between two of its own ripples
#define TRIG_GAP     0.40    // global: min time since the newest ripple


// debug overlay: 1 = paint the foot / trigger state along the floor edge
#define DEBUG_HUD    1

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

// per-foot trigger test.  Every pixel of the update pass evaluates this the
// same way, so the foot rows and the queue rows always agree on who fires.
//   .x = on the floor now
//   .y = on the floor in the previous frame
//   .z = this foot starts a new ripple in this frame
float4 FootState(int f, bool canSpawn)
{
    float4 m    = MarkerAt(f);
    float4 prev = StateRow(f);

    bool  on    = m.w > 0.5;
    bool  wasOn = prev.x > 0.5;
    bool  known = prev.y > 0.0;                 // has this foot seen a contact before
    float prevT = PastTime(prev.y);

    // rising edge: off the floor last frame, on the floor now
    bool edge = !wasOn;

    // never more than one ripple per TRIG_HOLD from the same foot
    bool hold = !known || (CurTime - prevT > TRIG_HOLD);

    // the only trigger: a real touchdown
    bool fire = on && edge && hold && canSpawn;
    return float4(on ? 1.0 : 0.0, wasOn ? 1.0 : 0.0, fire ? 1.0 : 0.0, 0.0);
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
float4 UpdateState_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int idx = (int)floor(Tex.y * STATE_ROWS);

    // controller: Freq+ makes the interval shorter, Freq- longer
    float freq = (1.0 + CtrlFreqM * 2.0) / (1.0 + CtrlFreqP * 2.0);
    float gap  = TRIG_GAP * freq;

    float4 nrip     = StateRow(FOOT_ROWS);          // newest ripple (row 8)
    bool   canSpawn = (CurTime - PastTime(nrip.z) > gap);
    float  prevMask = StateRow(MASK_ROW).x;

    float  mask     = 0.0;
    bool   winFound = false;
    int    winIdx   = -1;
    float2 winPos   = float2(0.0, 0.0);

    [unroll]
    for (int f = 0; f < FOOT_ROWS; ++f)
    {
        float4 m  = MarkerAt(f);
        bool   on = m.w > 0.5;

        float  w      = pow(2.0, (float)f);
        bool   prevOn = (fmod(floor(prevMask / w), 2.0) > 0.5);

        if (on) mask += w;

        // the only trigger: this slot touches the floor, and it did not last frame
        bool fire = on && !prevOn && canSpawn && !winFound;
        if (fire)
        {
            winFound = true;
            winIdx   = f;
            winPos   = m.xy;
        }
    }

    // ---- foot latch row
    if (idx == MASK_ROW)
    {
        return float4(mask, 0.0, 0.0, 0.0);
    }

    // ---- rows 0..7: unused
    if (idx < FOOT_ROWS)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // ---- ripple queue
    int    q     = idx - FOOT_ROWS;
    int    shift = winFound ? 1 : 0;
    float4 color = float4(0.0, 0.0, 0.0, 0.0);

    if (shift == 1 && q == 0)
    {
        // left / right foot get different patterns
        int ptype = (int)fmod(floor(CurTime) + (float)(winIdx - (winIdx / 2) * 2), 4.0);
        color = float4(winPos.x, winPos.y, CurTime, 1.0 + (float)ptype);
    }
    else if (shift <= q)
    {
        float4 pc = StateRow(FOOT_ROWS + q - shift);
        if (pc.w > 0.5 && pc.z <= CurTime && CurTime - pc.z <= RIP_MAX)
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

// four patterns, cycled by the ripple start time (same idea as Innocencer):
//   type 0 = rotating lines, 1 = triangle, 2 = square, 3 = circle
// aa = local units per screen pixel, used to soften the hard band edges
float RippleShape(float2 v, float age, float t0, int type, float aa)
{
    float r     = length(v);
    float scale = RIP_SPEED * age;
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
    float a;
    if      (type == 1) a = fmod(abs(rad), radians(120.0)) + radians(30.0);
    else if (type == 2) a = fmod(abs(rad), radians(90.0))  + radians(45.0);
    else                a = radians(90.0);                     // circle

    float w  = r * sin(a);
    float hi = scale + max(0.10, scale * RIP_BAND);

    return smoothstep(scale - aaW, scale + aaW, w) *
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
//   band A (z -10.0 .. -9.0) : 8 foot slots, from (on now, on last frame)
//       GREEN  = on now AND last frame   -> steady
//       YELLOW = on now, not last frame  -> touchdown edge
//       CYAN   = not now, was last frame -> the lift frame
//       BLACK  = neither
//   band B (z -9.0 .. -8.0) : ripple queue slots, colour = age
//       WHITE < 1s, YELLOW < 3s, RED < 5s, BLACK = empty
//   band C (z -8.4 .. -7.8) : purple bar = this build is compiled
float3 HudDiag(float2 l)
{
    float3 c = float3(0.0, 0.0, 0.0);
    float  pm = StateRow(MASK_ROW).x;

    // ---- band A
    [unroll]
    for (int f = 0; f < FOOT_ROWS; ++f)
    {
        float4 m  = MarkerAt(f);
        bool   on = m.w > 0.5;

        float  w      = pow(2.0, (float)f);
        bool   prevOn = (fmod(floor(pm / w), 2.0) > 0.5);

        float2 c0 = float2(-10.0 + (float)f * 2.5, -10.0);
        float2 d  = abs(l - (c0 + float2(1.0, 0.5))) - float2(1.0, 0.5);
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
        float4 s = tex2D(StateASamp, float2(0.5, (FOOT_ROWS + i + 0.5) / STATE_ROWS));
        float3 col = float3(0.05, 0.05, 0.05);
        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if      (age >= 0.0 && age < 1.0)    col = float3(1.00, 1.00, 1.00);
            else if (age < 3.0)                  col = float3(1.00, 0.85, 0.10);
            else if (age < RIP_MAX)              col = float3(1.00, 0.20, 0.10);
        }
        float2 c0 = float2(-10.0 + (float)i * 0.87, -9.0);
        float2 d  = abs(l - (c0 + float2(0.40, 0.5))) - float2(0.40, 0.5);
        float  mm = 1.0 - smoothstep(-0.05, 0.05, max(d.x, d.y));
        c = max(c, col * mm);
    }

    // ---- band C: build-live bar
    float2 dbar = float2(abs(l.x) - 10.0, abs(l.y + 8.1) - 0.3);
    c += float3(0.30, 0.06, 0.55) * (1.0 - smoothstep(-0.05, 0.05, max(dbar.x, dbar.y)));

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
        // queue rows are FOOT_ROWS .. STATE_ROWS-1 of the 1 x 32 state texture
        float4 s = tex2D(StateASamp, float2(0.5, (FOOT_ROWS + i + 0.5) / STATE_ROWS));

        if (s.w > 0.5)
        {
            float age = CurTime - s.z;
            if (age >= 0.0 && age < RIP_MAX)
            {
                float2 v     = l - s.xy;
                float  rad   = RIP_SPEED * age;
                int    type  = (int)(s.w - 0.99);      // pattern stored as 1 + type
                float  shape = RippleShape(v, age, s.z, type, pxAA);

                // fade in at birth, fade out at the end, weaker when far
                float att  = (1.0 / (1.0 + rad * 0.22)) * saturate(age / 0.15);
                float fade = 1.0 - smoothstep(RIP_MAX - 1.5, RIP_MAX, age);

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