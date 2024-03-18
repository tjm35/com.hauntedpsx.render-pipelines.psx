using System;
using UnityEngine;
using UnityEngine.Rendering;

namespace HauntedPSX.RenderPipelines.PSX.Runtime
{
    [Serializable, VolumeComponentMenu("HauntedPS1/QualityOverrideVolume")]
    public class QualityOverrideVolume : VolumeComponent
    {
        // Default to PSX Quality Enabled so that it's easier to get a project "first working"
        // (you can disable it in the default profile if you do not want to edit prefabs with low / pixelated / CRT settings on)
        public BoolParameter isPSXQualityEnabled = new BoolParameter(true);

        static QualityOverrideVolume s_Default = null;
        public static QualityOverrideVolume @default
        {
            get
            {
                if (s_Default == null)
                {
                    s_Default = ScriptableObject.CreateInstance<QualityOverrideVolume>();
                    s_Default.hideFlags = HideFlags.HideAndDontSave;
                }
                return s_Default;
            }
        }
    }
}