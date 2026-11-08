# AMD AMF headers

The `core/` headers and the encoder `components/` headers (`Component.h`,
`ComponentCaps.h`, `ColorSpace.h`, `PreAnalysis.h`, `VideoConverter.h`,
`VideoEncoderVCE.h`, `VideoEncoderHEVC.h`) from AMD's
[AMF SDK](https://github.com/GPUOpen-LibrariesAndSDKs/AMF) at tag `v1.5.3`
(`amf/public/include`), unmodified. MIT-licensed; see the notice at the top of each file.

moonsec loads `amfrt64.dll` (installed by AMD's driver) at run time
(platform/host/windows/enc_amf.c) and needs runtime 1.4.0 or newer. Nothing links
against AMD libraries and the build needs no SDK.
