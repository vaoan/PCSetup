# LIMITE DE FPS GLOBAL en el driver NVIDIA (igual que "Max Frame Rate" en NVIDIA App).
#   -Fps 90    pone el tope en 90 FPS para todos los juegos
#   -Quitar    quita el tope (fabrica)
#   (sin parametros) muestra el valor actual
# Se guarda en el driver: se mantiene al reiniciar.
param([int]$Fps = 0, [switch]$Quitar, [switch]$SinPausa)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; if ($Fps) { $a += " -Fps $Fps" }; if ($Quitar) { $a += " -Quitar" }
  Start-Process powershell -Verb RunAs -ArgumentList $a; exit
}

if (-not ('NvFrl' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NvFrl {
  [DllImport("nvapi64.dll", EntryPoint="nvapi_QueryInterface", CallingConvention=CallingConvention.Cdecl)]
  static extern IntPtr QI(uint id);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D0();
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DOut(out IntPtr h);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D1(IntPtr h);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D2Out(IntPtr s, out IntPtr p);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DGet(IntPtr s, IntPtr p, uint id, IntPtr buf);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSet(IntPtr s, IntPtr p, IntPtr buf);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DDel(IntPtr s, IntPtr p, uint id);
  static T F<T>(uint id) { IntPtr p = QI(id); if (p == IntPtr.Zero) throw new Exception("NVAPI funcion no encontrada 0x" + id.ToString("X")); return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T)); }
  const uint FRL_ID = 0x10835002; const int SZ = 12320; const int OFF_ID = 4100, OFF_TYPE = 4104, OFF_CUR = 8220;
  static void Ok(int r, string w) { if (r != 0) throw new Exception(w + " fallo, codigo " + r); }
  static IntPtr Open(out IntPtr prof) {
    Ok(F<D0>(0x0150E828)(), "Initialize");
    IntPtr s; Ok(F<DOut>(0x0694D52E)(out s), "CreateSession");
    Ok(F<D1>(0x375DBD6B)(s), "LoadSettings");
    Ok(F<D2Out>(0xDA8466A0)(s, out prof), "GetBaseProfile");
    return s;
  }
  // devuelve -1 si no hay tope definido
  public static int Get() {
    IntPtr prof; IntPtr s = Open(out prof); IntPtr b = Marshal.AllocHGlobal(SZ);
    try {
      for (int i = 0; i < SZ; i++) Marshal.WriteByte(b, i, 0);
      Marshal.WriteInt32(b, 0, SZ | (1 << 16));
      int r = F<DGet>(0x73BF8338)(s, prof, FRL_ID, b);
      if (r != 0) return -1;
      return Marshal.ReadInt32(b, OFF_CUR);
    } finally { Marshal.FreeHGlobal(b); F<D1>(0xDAD9CFF8)(s); }
  }
  public static void Set(int fps) {
    IntPtr prof; IntPtr s = Open(out prof); IntPtr b = Marshal.AllocHGlobal(SZ);
    try {
      if (fps <= 0) {
        int r = F<DDel>(0xE4A26362)(s, prof, FRL_ID);
        if (r != 0 && r != -160) Ok(r, "DeleteSetting");
      } else {
        for (int i = 0; i < SZ; i++) Marshal.WriteByte(b, i, 0);
        Marshal.WriteInt32(b, 0, SZ | (1 << 16));
        Marshal.WriteInt32(b, OFF_ID, unchecked((int)FRL_ID));
        Marshal.WriteInt32(b, OFF_TYPE, 0);
        Marshal.WriteInt32(b, OFF_CUR, fps);
        Ok(F<DSet>(0x577DD202)(s, prof, b), "SetSetting");
      }
      Ok(F<D1>(0xFCBC7E14)(s), "SaveSettings");
    } finally { Marshal.FreeHGlobal(b); F<D1>(0xDAD9CFF8)(s); }
  }
}
'@
}

try {
  if ($Quitar) { [NvFrl]::Set(0) } elseif ($Fps -gt 0) { [NvFrl]::Set($Fps) }
  $v = [NvFrl]::Get()
  if ($v -le 0) { Write-Host "Limite de FPS NVIDIA: SIN LIMITE" -ForegroundColor Yellow } else { Write-Host "Limite de FPS NVIDIA: $v FPS (global)" -ForegroundColor Green }
} catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
if (-not $SinPausa) { try { Read-Host "`nPresiona Enter para cerrar" | Out-Null } catch {} }
