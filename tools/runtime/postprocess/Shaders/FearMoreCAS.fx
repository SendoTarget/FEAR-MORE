/*
 * FearMore native-resolution Contrast Adaptive Sharpening effect.
 *
 * This is a ReShade FX translation of AMD FidelityFX CAS v1.0's
 * sharpen-only CasFilter path with the official CAS_BETTER_DIAGONALS and
 * CAS_SLOW quality branches enabled. It intentionally performs no image
 * scaling and consumes neither depth nor motion data.
 *
 * Reference pin:
 * https://github.com/GPUOpen-Effects/FidelityFX-CAS/blob/9fabcc9a2c45f958aff55ddfda337e74ef894b7f/ffx-cas/ffx_cas.h
 * - gamma-2 UNORM input/output guidance: source lines 23-25
 * - sharpness-to-negative-lobe mapping: source lines 49-51
 * - sharpen-only soft extrema, shaping, and filter: source lines 54-60
 * - CAS_BETTER_DIAGONALS rationale: source lines 37-42
 *
 * Adaptation is limited to ReShade sampling/entry-point plumbing, an epsilon
 * guard for a black neighborhood, and preservation of the source alpha.
 *
 * AMD source copyright (c) 2017-2019 Advanced Micro Devices, Inc.
 * FearMore adaptation copyright (c) 2026 FearMore contributors.
 * SPDX-License-Identifier: MIT
 * See ../licenses/AMD-CAS-MIT.txt in the source package.
 */

uniform float FearMoreSharpness <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "FearMore CAS strength";
    ui_tooltip = "Native-resolution contrast-adaptive sharpening. Low values protect HUD text and film grain.";
> = 0.25;

texture2D FearMoreBackBuffer : COLOR;

sampler2D FearMoreBackBufferSampler
{
    Texture = FearMoreBackBuffer;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
    SRGBTexture = false;
};

void FearMoreFullscreenVS(
    uint vertexId : SV_VertexID,
    out float4 position : SV_Position,
    out float2 texcoord : TEXCOORD0)
{
    texcoord.x = (vertexId == 2) ? 2.0 : 0.0;
    texcoord.y = (vertexId == 1) ? 2.0 : 0.0;
    position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

float3 FearMoreToLinearApprox(float3 color)
{
    return color * color;
}

float3 FearMoreToGammaApprox(float3 color)
{
    return sqrt(saturate(color));
}

float4 FearMoreCASPS(float4 position : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target
{
    const float2 pixelSize = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    const float4 centerSample = tex2D(FearMoreBackBufferSampler, texcoord);

    float3 northwest = tex2D(FearMoreBackBufferSampler, texcoord - pixelSize).rgb;
    float3 north = tex2D(FearMoreBackBufferSampler, texcoord - float2(0.0, pixelSize.y)).rgb;
    float3 northeast = tex2D(FearMoreBackBufferSampler, texcoord + float2(pixelSize.x, -pixelSize.y)).rgb;
    float3 west = tex2D(FearMoreBackBufferSampler, texcoord - float2(pixelSize.x, 0.0)).rgb;
    float3 center = centerSample.rgb;
    float3 east = tex2D(FearMoreBackBufferSampler, texcoord + float2(pixelSize.x, 0.0)).rgb;
    float3 southwest = tex2D(FearMoreBackBufferSampler, texcoord + float2(-pixelSize.x, pixelSize.y)).rgb;
    float3 south = tex2D(FearMoreBackBufferSampler, texcoord + float2(0.0, pixelSize.y)).rgb;
    float3 southeast = tex2D(FearMoreBackBufferSampler, texcoord + pixelSize).rgb;

    // AMD's suggested gamma-2 approximation keeps the adaptive filter in a
    // roughly linear space when consuming an 8-bit final backbuffer.
    northwest = FearMoreToLinearApprox(northwest);
    north = FearMoreToLinearApprox(north);
    northeast = FearMoreToLinearApprox(northeast);
    west = FearMoreToLinearApprox(west);
    center = FearMoreToLinearApprox(center);
    east = FearMoreToLinearApprox(east);
    southwest = FearMoreToLinearApprox(southwest);
    south = FearMoreToLinearApprox(south);
    southeast = FearMoreToLinearApprox(southeast);

    // AMD's better-diagonals branch forms a soft extremum by adding the
    // five-tap circle extremum to the full 3x3 box extremum. Both values are
    // intentionally left 2x-scaled, matching ffx_cas.h's factored math.
    const float3 crossMinimum = min(min(north, west), min(center, min(east, south)));
    const float3 crossMaximum = max(max(north, west), max(center, max(east, south)));
    const float3 boxMinimum = min(crossMinimum, min(min(northwest, northeast), min(southwest, southeast)));
    const float3 boxMaximum = max(crossMaximum, max(max(northwest, northeast), max(southwest, southeast)));
    const float3 softMinimum = crossMinimum + boxMinimum;
    const float3 softMaximum = crossMaximum + boxMaximum;
    float3 amplitude = saturate(min(softMinimum, 2.0 - softMaximum) / max(softMaximum, 0.00001));
    amplitude = sqrt(amplitude);

    const float peak = -1.0 / lerp(8.0, 5.0, saturate(FearMoreSharpness));
    const float3 weight = amplitude * peak;
    const float3 reciprocalWeight = 1.0 / (1.0 + 4.0 * weight);
    const float3 filtered = saturate(
        (north * weight + west * weight + center + east * weight + south * weight) * reciprocalWeight);

    return float4(FearMoreToGammaApprox(filtered), centerSample.a);
}

technique FearMoreCAS <
    ui_label = "FearMore CAS";
    ui_tooltip = "Conservative, native-resolution sharpening for the dgVoodoo D3D11 output.";
>
{
    pass
    {
        VertexShader = FearMoreFullscreenVS;
        PixelShader = FearMoreCASPS;
    }
}
