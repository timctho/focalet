using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;
public static class DemoAccess {
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X; public int Y; }
 [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
 [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
 public static bool OwnsPoint(IntPtr window, int x, int y) {
   return GetAncestor(WindowFromPoint(new Point { X=x, Y=y }),2)==window;
 }

 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rectangle rectangle);
 [StructLayout(LayoutKind.Sequential)] public struct Rectangle { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
 [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
 [DllImport("oleacc.dll")] private static extern int AccessibleChildren(IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] object[] children, out int obtained);
 [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
 [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint first, uint second, bool attach);
 [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
 public static bool Focus(IntPtr window) {
  uint pid; uint foreground=GetWindowThreadProcessId(GetForegroundWindow(),out pid); uint current=GetCurrentThreadId();
  bool attached=foreground!=current && foreground!=0 && AttachThreadInput(current,foreground,true);
  try { BringWindowToTop(window); SetForegroundWindow(window); return GetForegroundWindow()==window; }
  finally { if(attached) AttachThreadInput(current,foreground,false); }
 }
 [StructLayout(LayoutKind.Sequential)] public struct KeyInput {public ushort key,scan;public uint flags,time;public IntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] public struct MouseInput {public int x,y;public uint data,flags,time;public IntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] public struct InputData {[FieldOffset(0)]public KeyInput keyboard;[FieldOffset(0)]public MouseInput mouse;}
 [StructLayout(LayoutKind.Sequential)] public struct Input {public uint type;public InputData data;}
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
 public static void TypeText(string text) {
  foreach(char c in text){
   var down=new Input{type=1,data=new InputData{keyboard=new KeyInput{scan=c,flags=4}}};
   var up=new Input{type=1,data=new InputData{keyboard=new KeyInput{scan=c,flags=6}}};
   if(SendInput(2,new[]{down,up},Marshal.SizeOf(typeof(Input)))!=2)throw new InvalidOperationException("Unicode input failed");
   System.Threading.Thread.Sleep(22);
  }
 }
 public sealed class Entry { public string Name; public string Value; public string Role; public int State; public int[] Bounds; internal IAccessible Accessible; internal object Child; }
    public static void SetValue(Entry entry, string value) { entry.Accessible.set_accValue(entry.Child, value); }
    public static Entry[] Read(IntPtr window) {
        var identity = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        IAccessible root;
        Marshal.ThrowExceptionForHR(AccessibleObjectFromWindow(window, unchecked((uint)-4), ref identity, out root));
        var entries = new List<Entry>();
        Visit(root, 0, entries, 0);
        return entries.ToArray();
    }

    private static void Visit(IAccessible parent, object child, List<Entry> entries, int depth) {
        if (depth > 65 || entries.Count > 15000) return;
        try {
            int left, top, width, height;
            parent.accLocation(out left, out top, out width, out height, child);
            entries.Add(new Entry { Accessible = parent, Child = child, Name = parent.get_accName(child), Value = ReadValue(parent,child), Role = Convert.ToString(parent.get_accRole(child)), State = Convert.ToInt32(parent.get_accState(child)), Bounds = new [] { left, top, width, height } });
        } catch (COMException) { }
        try {
            if (!(child is int) || (int)child != 0) return;
            var count = parent.accChildCount;
            if (count == 0) return;
            var children = new object[count];
            int obtained;
            if (AccessibleChildren(parent, 0, count, children, out obtained) < 0) return;
            for (var index = 0; index < obtained; index++) {
                var accessible = children[index] as IAccessible;
                if (accessible != null) Visit(accessible, 0, entries, depth + 1);
                else if (children[index] is int) Visit(parent, children[index], entries, depth + 1);
            }
        } catch (COMException) { }
    }

 private static string ReadValue(IAccessible parent, object child) { try { return parent.get_accValue(child); } catch(COMException) { return null; } }
}