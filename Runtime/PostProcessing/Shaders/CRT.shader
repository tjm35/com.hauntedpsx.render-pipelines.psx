Shader "Hidden/HauntedPS1/CRT"
{
    HLSLINCLUDE

    // #pragma target 4.5
    // #pragma only_renderers d3d11 ps4 xboxone vulkan metal switch
    #pragma prefer_hlslcc gles
    #pragma exclude_renderers d3d11_9x
    #pragma target 2.0

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"

    #include "Packages/com.hauntedpsx.render-pipelines.psx/Runtime/ShaderLibrary/ShaderVariables.hlsl"
    #include "Packages/com.hauntedpsx.render-pipelines.psx/Runtime/ShaderLibrary/ShaderFunctions.hlsl"

    float4 _FrameBufferScreenSize;
    float4 _BlueNoiseSize;
    float4 _WhiteNoiseSize;
    int _CRTIsEnabled;
    float _CRTBloom;
    float2 _CRTGrateMaskScale;
    float _CRTScanlineSharpness;
    float _CRTImageSharpness;
    float2 _CRTBloomSharpness;
    float _CRTNoiseIntensity;
    float _CRTNoiseSaturation;
    float2 _CRTGrateMaskIntensityMinMax;
    float2 _CRTBarrelDistortion;
    float _CRTVignetteSquared;
    TEXTURE2D(_FrameBufferTexture);
    TEXTURE2D(_WhiteNoiseTexture);
    TEXTURE2D(_BlueNoiseTexture);
    float4 _UVTransform;

    // Emulated input resolution.
#if 1
    // Fix resolution to set amount.
    #define res (_FrameBufferScreenSize.xy)
#else
    // Optimize for resize.
    #define res ((_ScreenSize.xy / 6.0f * _CRTGrateMaskScale.y))
#endif

    float EvaluatePBRVignette(float distanceFromCenterSquaredNDC, float vignetteAtOffsetOneSquared)
    {
        // Use cosine based falloff
        // This simulates the energy loss when firing the electron beam to the corner of the screen, where the distance to the screen is greatest
        // compared to firing the electron beam to the center of the screen, where the distance to the center of the screen is least.
        // To make this cosine falloff artist friendly, we parameterize it by the desired amount of vignette aka energy loss at a NDC distance of 1 (side of screen)
        // In order to parameterize it this way, we solve:
        //
        // vignette = cos(angle)
        // vignetteMax = cos(angleMax)
        // acos(vignetteMax) = angleMax
        //          +
        //         /| <--- angleMax
        //        / |
        //       /  |
        //      /   |
        //     /    |
        //    /     |   TOA = tan(angleMax) == opposite / adjacent where opposite is 1.0 = (1.0 / tan(angleMax) == adjacent)
        //   /      |
        //  /       |
        // +--------+ [0, 1] NDC space

        // adjacent = 1.0 / tan(angleMax) = 1.0 / tan(acos(vignetteMax))
        // opposite = offsetNDC [0, 1]
        // vignette = cos(angleCurrent)
        // angleCurrent = atan(offsetNDC / adjacent)
        // angleCurrent = atan(offsetNDC / (1.0 / tan(acos(vignetteMax))))
        // angleCurrent = atan(offsetNDC * tan(acos(vignetteMax)))
        // vignette = cos(atan(offsetNDC * tan(acos(vignetteMax))))
        // vignette = rsqrt((offsetNDC * offsetNDC * (1.0 - vignetteMax * vignetteMax)) / (vignetteMax * vignetteMax) + 1.0)
        
        return rsqrt((-vignetteAtOffsetOneSquared * distanceFromCenterSquaredNDC + distanceFromCenterSquaredNDC) / vignetteAtOffsetOneSquared + 1.0);
    }

    float3 FetchNoise(float2 p, TEXTURE2D(noiseTextureSampler))
    {
        float2 uv = float2(1.0f, cos(_Time.y)) * _Time.y * 8.0f + p;

        // Noise texture is treated as data texture - noise is expected to be distributed in linear space, not perceptual / gamma space.
        float3 s = SAMPLE_TEXTURE2D_LOD(noiseTextureSampler, s_linear_repeat_sampler, uv, 0).rgb;
        s = s * 2.0 - 1.0;
        s.yz *= _CRTNoiseSaturation;
        s *= _CRTNoiseIntensity;
        return s;
    }

    float3 CompositeSignalAndNoise(TEXTURE2D(noiseTextureSampler), float2 posNoiseSignal, float2 posNoiseCRT, float2 off, float3 c)
    {
        float3 steps = float3(64.0, 32.0, 32.0);
        float3 cyuv = floor(FCCYIQFromSRGB(c) * steps + 0.5) / steps;
        float3 noiseSignalYUV = FetchNoise(posNoiseSignal, noiseTextureSampler);
        float3 noiseCRTYUV = FetchNoise(posNoiseCRT, noiseTextureSampler);

        return saturate(SRGBFromFCCYIQ(cyuv + noiseSignalYUV + noiseCRTYUV));
    }

    float4 FetchFrameBuffer(float2 pos)
    {
        return SAMPLE_TEXTURE2D_LOD(_FrameBufferTexture, s_point_clamp_sampler, pos.xy, 0);
    }

    // Nearest emulated sample given floating point position and texel offset.
    // Also zero's off screen.
    float3 Fetch(float2 pos, float2 off, TEXTURE2D(noiseTextureSampler), float4 noiseTextureSize)
    {
        float2 posNoiseSignal = floor(pos * res + off) * noiseTextureSize.zw;
        float2 posNoiseCRT = floor(pos * _ScreenSize.xy + off * res * _ScreenSize.zw) * noiseTextureSize.zw;
        pos = floor(pos * res + off) / res;
        if(max(abs(pos.x - 0.5), abs(pos.y - 0.5)) > 0.5) { return float3(0.0,0.0,0.0); }
        float3 value = CompositeSignalAndNoise(noiseTextureSampler, posNoiseSignal, posNoiseCRT, off, FetchFrameBuffer(pos).rgb);
        value = SRGBToLinear(value);
        return value;
    }

    // Distance in emulated pixels to nearest texel.
    float2 Dist(float2 pos)
    {
        pos = pos * res;
        return -((pos - floor(pos)) - 0.5);
    }

    // 1D Gaussian.
    float Gaus(float pos, float sharpness)
    {
        return exp2(sharpness * pos * pos);
    }

    // Lanczos filter will be used for simulating overshoot ringing.
    // Waiting until the big cleanup pass on this post process.
    float FilterWeightLanczos(const in float x, const in float widthInverse)
    {
        float c1 = PI * x;
        float c2 = widthInverse * c1;
        return (c2 > PI)
            ? 0.0f
            : (x < 1e-5f)
                ? 1.0
                : (sin(c2) * sin(c1) / (c2 * c1));
    }

    // 3-tap Gaussian filter along horz line.
    float3 Horz3(float2 pos,float off)
    {
        float3 b=Fetch(pos,float2(-1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 c=Fetch(pos,float2( 0.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 d=Fetch(pos,float2( 1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float dst=Dist(pos).x;

        // Use gaussian as windowing function for lanczos filter.
        // TODO: Use more efficient / less agressive windowing function.
        float scale=_CRTImageSharpness;
        float wb = Gaus(dst-1.0,scale);
        float wc = Gaus(dst+0.0,scale);
        float wd = Gaus(dst+1.0,scale);

        // Return filtered sample.
        return (b*wb+c*wc+d*wd)/(wb+wc+wd);
    }

    // 5-tap Gaussian filter along horz line.
    float3 Horz5(float2 pos,float off)
    {
        float3 a=Fetch(pos,float2(-2.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 b=Fetch(pos,float2(-1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 c=Fetch(pos,float2( 0.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 d=Fetch(pos,float2( 1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 e=Fetch(pos,float2( 2.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float dst=Dist(pos).x;

        // Use gaussian as windowing function for lanczos filter.
        // TODO: Use more efficient / less agressive windowing function.
        float scale=_CRTImageSharpness;
        float wa = Gaus(dst-2.0,scale);
        float wb = Gaus(dst-1.0,scale);
        float wc = Gaus(dst+0.0,scale);
        float wd = Gaus(dst+1.0,scale);
        float we = Gaus(dst+2.0,scale);

        // Return filtered sample.
        return (a*wa+b*wb+c*wc+d*wd+e*we)/(wa+wb+wc+wd+we);
    }

    // 7-tap Gaussian filter along horz line.
    float3 Horz7(float2 pos,float off)
    {
        float3 a=Fetch(pos,float2(-3.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 b=Fetch(pos,float2(-2.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 c=Fetch(pos,float2(-1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 d=Fetch(pos,float2( 0.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 e=Fetch(pos,float2( 1.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 f=Fetch(pos,float2( 2.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float3 g=Fetch(pos,float2( 3.0,off), _WhiteNoiseTexture, _WhiteNoiseSize);
        float dst=Dist(pos).x;

        // Convert distance to weight.
        float scale=_CRTBloomSharpness.x;

        // Use gaussian as windowing function for lanczos filter.
        // TODO: Use more efficient / less agressive windowing function.
        float wa = Gaus(dst-3.0,scale);
        float wb = Gaus(dst-2.0,scale);
        float wc = Gaus(dst-1.0,scale);
        float wd = Gaus(dst+0.0,scale);
        float we = Gaus(dst+1.0,scale);
        float wf = Gaus(dst+2.0,scale);
        float wg = Gaus(dst+3.0,scale);

        // Return filtered sample.
        return (a*wa+b*wb+c*wc+d*wd+e*we+f*wf+g*wg)/(wa+wb+wc+wd+we+wf+wg);
    }

    // Return scanline weight.
    float Scan(float2 pos,float off)
    {
        float dst=Dist(pos).y;
        return Gaus(dst+off,_CRTScanlineSharpness);
    }

    // Return scanline weight for bloom.
    float BloomScan(float2 pos,float off)
    {
        float dst=Dist(pos).y;
        return Gaus(dst+off,_CRTBloomSharpness.y);
    }

    // Allow nearest three lines to effect pixel.
    float3 Tri(float2 pos)
    {
        float3 a=Horz3(pos,-1.0);
        float3 b=Horz5(pos, 0.0);
        float3 c=Horz3(pos, 1.0);
        float wa=Scan(pos,-1.0);
        float wb=Scan(pos, 0.0);
        float wc=Scan(pos, 1.0);
        return a*wa+b*wb+c*wc;
    }

    // Small bloom.
    float3 Bloom(float2 pos)
    {
        float3 a=Horz5(pos,-2.0);
        float3 b=Horz7(pos,-1.0);
        float3 c=Horz7(pos, 0.0);
        float3 d=Horz7(pos, 1.0);
        float3 e=Horz5(pos, 2.0);
        float wa=BloomScan(pos,-2.0);
        float wb=BloomScan(pos,-1.0);
        float wc=BloomScan(pos, 0.0);
        float wd=BloomScan(pos, 1.0);
        float we=BloomScan(pos, 2.0);
        return a*wa+b*wb+c*wc+d*wd+e*we;
    }

    // Distortion of scanlines, and end of screen alpha.
    float2 Warp(float2 pos)
    {
        pos = pos * 2.0 - 1.0;    
        pos *= float2(1.0 + (pos.y * pos.y) * _CRTBarrelDistortion.x, 1.0 + (pos.x * pos.x) * _CRTBarrelDistortion.y);
        return pos * 0.5 + 0.5;
    }

#if 1
    // Very compressed TV style mask.
    float3 CRTMask(float2 pos)
    {
        float line0 = _CRTGrateMaskIntensityMinMax.y;
        float odd=0.0;
        if(frac(pos.x/6.0)<0.5)odd=1.0;
        if(frac((pos.y+odd)/2.0)<0.5)line0=_CRTGrateMaskIntensityMinMax.x;  
        pos.x=frac(pos.x/3.0);
        float3 mask=float3(_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x);
        if(pos.x<0.333)mask.r=_CRTGrateMaskIntensityMinMax.y;
        else if(pos.x<0.666)mask.g=_CRTGrateMaskIntensityMinMax.y;
        else mask.b=_CRTGrateMaskIntensityMinMax.y;
        mask*=line0;
        return mask;
    }        
#endif

#if 0
    // Aperture-grille.
    float3 CRTMask(float2 pos)
    {
        pos.x=frac(pos.x/3.0);
        float3 mask=float3(_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x);
        if(pos.x<0.333)mask.r=lerp(_CRTGrateMaskIntensityMinMax.y, _CRTGrateMaskIntensityMinMax.x, abs(pos.x - 0.5 * 0.333) / 0.333);
        else if(pos.x<0.666)mask.g=lerp(_CRTGrateMaskIntensityMinMax.y, _CRTGrateMaskIntensityMinMax.x, abs(pos.x - 1.5 * 0.333) / 0.333);
        else mask.b=lerp(_CRTGrateMaskIntensityMinMax.y, _CRTGrateMaskIntensityMinMax.x, abs(pos.x - 2.5 * 0.333) / 0.333);
        return mask;
    }        
#endif

#if 0
    // Stretched VGA style mask.
    float3 CRTMask(float2 pos)
    {
        pos.x+=pos.y*3.0;
        float3 mask=float3(_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x);
        pos.x=frac(pos.x/6.0);
        if(pos.x<0.333)mask.r=_CRTGrateMaskIntensityMinMax.y;
        else if(pos.x<0.666)mask.g=_CRTGrateMaskIntensityMinMax.y;
        else mask.b=_CRTGrateMaskIntensityMinMax.y;
        return mask;
    }    
#endif

#if 0
    // VGA style mask.
    float3 CRTMask(float2 pos)
    {
        pos.xy=floor(pos.xy*float2(1.0,0.5));
        pos.x+=pos.y*3.0;
        float3 mask=float3(_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x,_CRTGrateMaskIntensityMinMax.x);
        pos.x=frac(pos.x/6.0);
        if(pos.x<0.333)mask.r=_CRTGrateMaskIntensityMinMax.y;
        else if(pos.x<0.666)mask.g=_CRTGrateMaskIntensityMinMax.y;
        else mask.b=_CRTGrateMaskIntensityMinMax.y;
        return mask;
    }    
#endif

    // Entry.
    float4 EvaluateCRT(float2 positionSS)
    {
        float4 crt = 0.0;

        float2 crtUV = Warp(positionSS.xy * _ScreenSize.zw);

        // Note: if we use the pure NDC coordinates, our vignette will be an ellipse, since we do not take into account physical distance differences from the aspect ratio.
        // Apply aspect ratio to get circular, physically based vignette:
        float2 crtNDC = crtUV * 2.0 - 1.0;
        if (_ScreenSize.x > _ScreenSize.y)
        {
            // X axis is max:
            crtNDC.y *= _ScreenSize.y / _ScreenSize.x;
        }
        else
        {
            // Y axis is max:
            crtNDC.x *= _ScreenSize.x / _ScreenSize.y;
        }
        float distanceFromCenterSquaredNDC = dot(crtNDC, crtNDC);
        float vignette = EvaluatePBRVignette(distanceFromCenterSquaredNDC, _CRTVignetteSquared);

        crt.rgb = Tri(crtUV) * CRTMask(positionSS.xy * _CRTGrateMaskScale.y);

        #if 1
        // Energy conserving normalized bloom.
        crt.rgb = lerp(crt.rgb, Bloom(crtUV), _CRTBloom);    
        #else
        // Additive bloom.
        crt.rgb += Bloom(crtUV) * _CRTBloom;   
        #endif

        crt.rgb *= vignette;

        return float4(crt.rgb, 1.0);
    }

    struct Attributes
    {
        float4 vertex : POSITION;
        float2 uv : TEXCOORD0;
    };

    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        float2 texcoord   : TEXCOORD0;
        UNITY_VERTEX_OUTPUT_STEREO
    };

    Varyings Vertex(Attributes input)
    {
        Varyings output;
        output.positionCS = input.vertex;
        output.texcoord = input.uv;
        return output;
    }

    float4 Fragment(Varyings input) : SV_Target0
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

        float2 positionNDC = input.texcoord;
        uint2 positionSS = input.texcoord * _ScreenSize.xy;

        #if UNITY_SINGLE_PASS_STEREO
        positionNDC.x = (positionNDC.x + unity_StereoEyeIndex) * 0.5;
        #endif

        // Flip logic
        positionSS = positionSS * _UVTransform.xy + _UVTransform.zw * (_ScreenSize.xy - 1.0);
        positionNDC = positionNDC * _UVTransform.xy + _UVTransform.zw;

        if (!_IsPSXQualityEnabled || !_CRTIsEnabled)
        {
            return SAMPLE_TEXTURE2D_LOD(_FrameBufferTexture, s_point_clamp_sampler, positionNDC.xy, 0);
        }

        float4 outColor = EvaluateCRT(positionSS);
        outColor.rgb = saturate(outColor.rgb);
        outColor.rgb = LinearToSRGB(outColor.rgb);

        return float4(outColor.rgb, 1.0);
    }

    ENDHLSL

    SubShader
    {
        Tags{ "RenderPipeline" = "PSXRenderPipeline" }

        Pass
        {
            Cull Off ZWrite Off ZTest Always

            HLSLPROGRAM
            // Required to compile gles 2.0 with standard srp library
            #pragma prefer_hlslcc gles
            #pragma exclude_renderers d3d11_9x gles
            #pragma target 4.5

            #pragma vertex Vertex
            #pragma fragment Fragment

            ENDHLSL
        }
    }
}