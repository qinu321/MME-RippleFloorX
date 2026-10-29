////////////////////////////////////////////////////////////////////////////////
//
//  RippleFloorX.fx   ver 1.0
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
//  State texture (1 x 32, RGBA32F, double buffered, B = previous frame)
//      row  0 ..  7 : foot slots   (contact, last spawn time, x, z)
//      row  8 .. 31 : ripple queue (x, z, start time, 1 + pattern)
//
//  Trigger = the rising edge of a contact: the foot was off the floor in the
//  previous frame and is on the floor now.  A second rule - "the contact point
//  moved since this foot last touched the floor" - is merged in with OR, so the
//  floor also works on a machine where the previous-frame copy cannot be read
//  back.  The two rules can only add ripples; neither can block the other, so
//  the floor can never become completely silent while a foot is planted.
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
#define SLOT_COUNT   24      // ripple queue rows after the feet
#define STATE_ROWS   32      // FOOT_ROWS + SLOT_COUNT

// trigger spacing (seconds)
#define TRIG_HOLD    0.50    // same foot: min time between two of its own ripples
#define TRIG_GAP     0.40    // global: min time since the newest ripple
#define STEP_R       2.0     // foot moved at least this far (local unit) since its
                             // last contact -> count it as a new step

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
// StateB always holds a copy of the previous frame, so every read is a plain
// texture fetch (TEXTUREVALUE turned out to be unreliable in this pass).
texture StateA : RENDERCOLORTARGET <
    int Width  = 1;
    int Height = 32;
    string Format = "A32B32G32R32F";
>;

texture StateB : RENDERCOLORTARGET <
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
// read row i of the previous frame state
float4 StateRow(int i)
{
    return tex2D(StateBSamp, float2(0.5, (i + 0.5) / STATE_ROWS));
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

    // the contact point moved since the last contact of this foot
    bool moved = !known || (distance(m.xy, prev.zw) > STEP_R);

    // never more than one ripple per TRIG_HOLD from the same foot
    bool hold = !known || (CurTime - prevT > TRIG_HOLD);

    bool fire = on && hold && (edge || moved) && canSpawn;
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

// queue rows: push new ripples, shift old ones
// foot rows : remember the contact state and the last spawn time
float4 UpdateState_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int idx = (int)floor(Tex.y * STATE_ROWS);

    // controller: Freq+ makes the interval shorter, Freq- longer
    float freq = (1.0 + CtrlFreqM * 2.0) / (1.0 + CtrlFreqP * 2.0);
    float gap  = TRIG_GAP * freq;

    // newest ripple of the last frame; a time from the future means the
    // timeline was rewound, so treat it as "long ago"
    float4 nrip    = StateRow(FOOT_ROWS);
    bool   canSpawn = (CurTime - PastTime(nrip.z) > gap);

    // ---- who starts a ripple this frame (identical in every pixel)
    int    winIdx = -1;
    float2 winPos = float2(0.0, 0.0);

    [loop]
    for (int f = 0; f < FOOT_ROWS; ++f)
    {
        float4 st = FootState(f, canSpawn && winIdx < 0);
        if (st.z > 0.5)
        {
            winIdx = f;
            winPos = MarkerAt(f).xy;
        }
    }

    // ---- foot slot rows
    if (idx < FOOT_ROWS)
    {
        float4 prev = StateRow(idx);
        float4 m    = MarkerAt(idx);
        bool   on   = m.w > 0.5;

        float2 pos   = on ? m.xy : prev.zw;     // keep the last contact point
        float  lastT = (idx == winIdx) ? CurTime : prev.y;

        return float4(on ? 1.0 : 0.0, lastT, pos.x, pos.y);
    }

    // ---- ripple queue rows
    int    q     = idx - FOOT_ROWS;
    int    shift = (winIdx >= 0) ? 1 : 0;
    float4 color = float4(0.0, 0.0, 0.0, 0.0);

    if (shift == 1 && q == 0)
    {
        // left / right foot get different patterns
        int ptype = (int)fmod(floor(CurTime) + (float)(winIdx - (winIdx / 2) * 2), 4.0);
        color = float4(winPos.x, winPos.y, CurTime, 1.0 + (float)ptype);
    }
    else if (shift <= q)
    {
        float4 p = StateRow(FOOT_ROWS + q - shift);

        // expired or from the future: written as a zero row, so a dead entry
        // can never block the "moved" rule with a stale position
        if (p.w > 0.5 && p.z <= CurTime && CurTime - p.z <= RIP_MAX)
        {
            color = p;
        }
    }

    return color;
}

// ---------------------------------------------------------------- floor
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
// 8 boxes along the -z edge of the floor:
//   green = foot on the floor, blue = was on the floor last frame,
//   magenta = this foot starts a ripple now, dark = free
float3 HudColor(float2 l, bool canSpawn)
{
    float3 c = float3(0.0, 0.0, 0.0);

    [loop]
    for (int f = 0; f < FOOT_ROWS; ++f)
    {
        float4 st = FootState(f, canSpawn);

        float2 c0 = float2(-10.0 + (float)f * 2.5, -10.0);
        float2 d  = abs(l - (c0 + float2(1.0, 1.0))) - float2(1.0, 1.0);
        float  m  = 1.0 - smoothstep(-0.05, 0.05, max(d.x, d.y));

        float3 col = float3(0.04, 0.04, 0.04);
        if (st.y > 0.5) col = float3(0.10, 0.30, 1.00);
        if (st.x > 0.5) col = float3(0.15, 1.00, 0.30);
        if (st.z > 0.5) col = float3(1.00, 0.20, 0.90);

        c = max(c, col * m);
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
        float4 nrip = StateRow(FOOT_ROWS);
        bool canSpawn = (CurTime - PastTime(nrip.z) > TRIG_GAP);
        c += HudColor(l, canSpawn);
    }
#endif

    return float4(c, 1.0);
}

// copy the fresh state into StateB, so the next frame can read it
float4 CopyState_PS(float2 Tex : TEXCOORD0) : COLOR0
{
    int i = (int)floor(Tex.y * STATE_ROWS);
    return tex2D(StateASamp, float2(0.5, (i + 0.5) / STATE_ROWS));
}

// ---------------------------------------------------------------- technique
technique MainTec <
    string Script =
        "RenderColorTarget0=StateA;"
        "RenderDepthStencilTarget=StateDepth;"
        "Pass=UpdateState;"
        "RenderColorTarget0=StateB;"
        "Pass=CopyState;"
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
    pass CopyState < string Script = "Draw=Buffer;";>
    {
        ZENABLE          = FALSE;
        ZWRITEENABLE     = FALSE;
        ALPHABLENDENABLE = FALSE;
        CULLMODE         = NONE;
        VertexShader     = compile vs_3_0 Buffer_VS();
        PixelShader      = compile ps_3_0 CopyState_PS();
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
