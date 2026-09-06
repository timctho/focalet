public sealed class ZommiDesktopFrameCapture : System.IDisposable {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct OutputDescription {
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public int Left, Top, Right, Bottom, Attached, Rotation;
        public System.IntPtr Monitor;
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct TextureDescription { public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CpuAccessFlags, MiscFlags; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct FrameInformation { public long PresentTime, MouseTime; public uint AccumulatedFrames; public int Coalesced, Protected, PointerLeft, PointerTop, PointerVisible; public uint MetadataSize, PointerSize; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MappedTexture { public System.IntPtr Data; public uint RowPitch, DepthPitch; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct TextureBox { public uint Left, Top, Front, Right, Bottom, Back; }

    [System.Runtime.InteropServices.DllImport("dxgi.dll")] private static extern int CreateDXGIFactory1(ref System.Guid identity, out System.IntPtr factory);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(System.IntPtr adapter, uint driver, System.IntPtr software, uint flags, System.IntPtr levels, uint levelCount, uint version, out System.IntPtr device, out uint level, out System.IntPtr context);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int Enumerate(System.IntPtr self, uint index, out System.IntPtr value);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int DescribeOutput(System.IntPtr self, out OutputDescription description);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int DuplicateOutput(System.IntPtr self, System.IntPtr device, out System.IntPtr duplication);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int CreateTexture(System.IntPtr self, ref TextureDescription description, System.IntPtr initialData, out System.IntPtr texture);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate void DescribeTexture(System.IntPtr self, out TextureDescription description);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int AcquireFrame(System.IntPtr self, uint timeout, out FrameInformation information, out System.IntPtr resource);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int ReleaseFrame(System.IntPtr self);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate void CopyRegion(System.IntPtr self, System.IntPtr destination, uint subresource, uint left, uint top, uint front, System.IntPtr source, uint sourceSubresource, ref TextureBox region);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate int MapTexture(System.IntPtr self, System.IntPtr resource, uint subresource, uint mapType, uint flags, out MappedTexture mapped);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.StdCall)] private delegate void UnmapTexture(System.IntPtr self, System.IntPtr resource, uint subresource);

    private System.IntPtr device, context, duplication, staging;
    private readonly int[] area;
    private TextureBox region;
    private System.Drawing.Bitmap lastFrame;
    public long LastPresentTime { get; private set; }

    private static T Method<T>(System.IntPtr instance, int slot) where T : class {
        var table = System.Runtime.InteropServices.Marshal.ReadIntPtr(instance);
        var address = System.Runtime.InteropServices.Marshal.ReadIntPtr(table, slot * System.IntPtr.Size);
        return (T)(object)System.Runtime.InteropServices.Marshal.GetDelegateForFunctionPointer(address, typeof(T));
    }

    private static void Check(int result) { System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(result); }
    private static void Release(ref System.IntPtr value) {
        if (value != System.IntPtr.Zero) System.Runtime.InteropServices.Marshal.Release(value);
        value = System.IntPtr.Zero;
    }

    public ZommiDesktopFrameCapture(int[] captureArea) {
        area = (int[])captureArea.Clone();
        var previous = SetThreadDpiAwarenessContext(new System.IntPtr(-4));
        try { Initialize(); } catch { Dispose(); throw; }
        finally { SetThreadDpiAwarenessContext(previous); }
    }

    public bool Matches(int[] captureArea) {
        for (var index = 0; index < 4; index++) if (area[index] != captureArea[index]) return false;
        return true;
    }

    private void Initialize() {
        var identity = new System.Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        System.IntPtr factory;
        Check(CreateDXGIFactory1(ref identity, out factory));
        try {
            for (uint adapterIndex = 0; ; adapterIndex++) {
                System.IntPtr adapter;
                var adapterResult = Method<Enumerate>(factory, 12)(factory, adapterIndex, out adapter);
                if (adapterResult == unchecked((int)0x887a0002)) break;
                Check(adapterResult);
                try {
                    for (uint outputIndex = 0; ; outputIndex++) {
                        System.IntPtr output;
                        var outputResult = Method<Enumerate>(adapter, 7)(adapter, outputIndex, out output);
                        if (outputResult == unchecked((int)0x887a0002)) break;
                        Check(outputResult);
                        try {
                            OutputDescription description;
                            Check(Method<DescribeOutput>(output, 7)(output, out description));
                            if (description.Attached == 0 || area[0] < description.Left || area[1] < description.Top || area[0] + area[2] > description.Right || area[1] + area[3] > description.Bottom) continue;
                            if (description.Rotation > 1) throw new System.InvalidOperationException("Rendered acceptance requires an unrotated desktop output.");
                            uint featureLevel;
                            Check(D3D11CreateDevice(adapter, 0, System.IntPtr.Zero, 0x20, System.IntPtr.Zero, 0, 7, out device, out featureLevel, out context));
                            var outputIdentity = new System.Guid("00cddea8-939b-4b83-a340-a685226666cc");
                            System.IntPtr output1;
                            Check(System.Runtime.InteropServices.Marshal.QueryInterface(output, ref outputIdentity, out output1));
                            try { Check(Method<DuplicateOutput>(output1, 22)(output1, device, out duplication)); }
                            finally { Release(ref output1); }
                            var texture = new TextureDescription { Width = (uint)area[2], Height = (uint)area[3], MipLevels = 1, ArraySize = 1, Format = 87, SampleCount = 1, Usage = 3, CpuAccessFlags = 0x20000 };
                            Check(Method<CreateTexture>(device, 5)(device, ref texture, System.IntPtr.Zero, out staging));
                            region = new TextureBox { Left = (uint)(area[0] - description.Left), Top = (uint)(area[1] - description.Top), Right = (uint)(area[0] + area[2] - description.Left), Bottom = (uint)(area[1] + area[3] - description.Top), Back = 1 };
                            return;
                        } finally { Release(ref output); }
                    }
                } finally { Release(ref adapter); }
            }
            throw new System.InvalidOperationException("The rendered capture area is not contained by a desktop output.");
        } finally { Release(ref factory); }
    }

    public System.Drawing.Bitmap Capture() {
        var waiting = System.Diagnostics.Stopwatch.StartNew();
        System.IntPtr resource;
        while (true) {
            FrameInformation information;
            var acquired = Method<AcquireFrame>(duplication, 8)(duplication, 100, out information, out resource);
            if (acquired != unchecked((int)0x887a0027)) {
                Check(acquired);
                if (information.PresentTime != 0) {
                    LastPresentTime = information.PresentTime;
                    break;
                }
                Release(ref resource);
                Check(Method<ReleaseFrame>(duplication, 14)(duplication));
            }
            if (lastFrame != null) return (System.Drawing.Bitmap)lastFrame.Clone();
            if (waiting.ElapsedMilliseconds >= 2000) throw new System.TimeoutException("Desktop Duplication did not produce its first presented image.");
        }
        try {
            var identity = new System.Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
            System.IntPtr texture;
            Check(System.Runtime.InteropServices.Marshal.QueryInterface(resource, ref identity, out texture));
            try {
                TextureDescription description;
                Method<DescribeTexture>(texture, 10)(texture, out description);
                if (region.Right > description.Width || region.Bottom > description.Height || description.Format != 87) throw new System.InvalidOperationException(string.Format("Desktop texture {0}x{1} format {2} does not contain capture region {3},{4}-{5},{6}.", description.Width, description.Height, description.Format, region.Left, region.Top, region.Right, region.Bottom));
                Method<CopyRegion>(context, 46)(context, staging, 0, 0, 0, 0, texture, 0, ref region);
            }
            finally { Release(ref texture); }
            MappedTexture mapped;
            Check(Method<MapTexture>(context, 14)(context, staging, 0, 1, 0, out mapped));
            var bitmap = new System.Drawing.Bitmap(area[2], area[3], System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try {
                var rectangle = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
                var data = bitmap.LockBits(rectangle, System.Drawing.Imaging.ImageLockMode.WriteOnly, bitmap.PixelFormat);
                try {
                    var row = new byte[bitmap.Width * 4];
                    for (var index = 0; index < bitmap.Height; index++) {
                        System.Runtime.InteropServices.Marshal.Copy(System.IntPtr.Add(mapped.Data, checked(index * (int)mapped.RowPitch)), row, 0, row.Length);
                        System.Runtime.InteropServices.Marshal.Copy(row, 0, System.IntPtr.Add(data.Scan0, index * data.Stride), row.Length);
                    }
                } finally { bitmap.UnlockBits(data); }
                if (lastFrame != null) lastFrame.Dispose();
                lastFrame = (System.Drawing.Bitmap)bitmap.Clone();
                return bitmap;
            } catch { bitmap.Dispose(); throw; }
            finally { Method<UnmapTexture>(context, 15)(context, staging, 0); }
        } finally {
            Release(ref resource);
            Check(Method<ReleaseFrame>(duplication, 14)(duplication));
        }
    }

    public void Dispose() {
        if (lastFrame != null) lastFrame.Dispose();
        lastFrame = null;
        Release(ref staging);
        Release(ref duplication);
        Release(ref context);
        Release(ref device);
    }
}
