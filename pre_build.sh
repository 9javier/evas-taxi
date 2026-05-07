#!/bin/sh
set -e

echo ""
echo "============================================"
echo "   DIAGNÓSTICO PRE-BUILD — EVA'S TAXI iOS"
echo "============================================"

# ── [1/7] ENTORNO ──────────────────────────────
echo ""
echo "--- [1/7] VERSIONES DEL ENTORNO ---"
flutter --version | head -3
echo "CocoaPods: $(pod --version)"
xcodebuild -version | head -2
echo "Ruby: $(ruby --version)"

# ── [2/7] LIMPIEZA Y DEPS ──────────────────────
echo ""
echo "--- [2/7] LIMPIEZA Y DEPENDENCIAS DART ---"
flutter clean
flutter pub get
echo "✅ flutter pub get completado."

# ── [3/7] BUSCAR -G ANTES DE POD INSTALL ───────
echo ""
echo "--- [3/7] BÚSQUEDA DE -G ANTES DE POD INSTALL ---"
# Solo busca en xcconfigs y plists (excluye pbxproj del proyecto propio para evitar
# falsos positivos del build phase "Clean -G Flag" que agregamos)
FLAG_PATTERN_XCCONFIG=" -G[[:space:]0-9]| -G$"
FOUND_BEFORE=$(grep -rEn "$FLAG_PATTERN_XCCONFIG" \
  --include="*.xcconfig" \
  --include="*.plist" \
  ios/ 2>/dev/null || true)

if [ -n "$FOUND_BEFORE" ]; then
  echo "⚠️  FLAG -G encontrado ANTES de pod install:"
  echo "$FOUND_BEFORE"
else
  echo "✅ Ningún archivo fuente contiene el flag -G."
fi

# ── [4/7] POD INSTALL ──────────────────────────
echo ""
echo "--- [4/7] POD INSTALL ---"
cd ios
rm -rf Pods Podfile.lock

pod repo update --silent
echo "Ejecutando pod install..."
pod install 2>&1 | grep -E \
  "^(Installing|Using|Downloading|Generating|Analyzing|Building|Warning|Error|Post-install)" \
  || true
echo "✅ pod install finalizado."

# ── [5/7] BÚSQUEDA PROFUNDA EN PODS GENERADOS ──
echo ""
echo "--- [5/7] BÚSQUEDA DE -G EN PODS GENERADOS ---"

# 5a. xcconfigs: patrón con espacio (formato más común en xcconfig)
FOUND_XCCONFIG=$(grep -rEn "$FLAG_PATTERN_XCCONFIG" \
  --include="*.xcconfig" \
  Pods/ 2>/dev/null || true)

# 5b. Pods.xcodeproj/project.pbxproj: busca también el formato quoted "-G"
# que aparece cuando CocoaPods escribe el flag directamente en el dict del proyecto
PODS_PBXPROJ="Pods/Pods.xcodeproj/project.pbxproj"
FOUND_PBXPROJ_DICT=""
if [ -f "$PODS_PBXPROJ" ]; then
  # Patrón ampliado: detecta -G con espacio antes, -G entre comillas, o -G<dígito>
  FOUND_PBXPROJ_DICT=$(grep -En '"-G[^"]*"| -G[[:space:]0-9]| -G$|-G[0-9]' \
    "$PODS_PBXPROJ" 2>/dev/null \
    | grep -v "GENERATE\|GCC_SYMBOLS\|GCC_WARN\|GCC_PREPROCESSOR\|GCC_DYNAMIC\|GCC_OPTIMIZATION\|GCC_ENABLE\|GCC_NO\|GCC_TREAT\|GCC_REUSE\|GCC_INLINES\|GCC_THUMB\|GCC_VERSION\|GCC_UNROLL\|GCC_FAST" \
    || true)
fi

# 5c. Buscar en ALL build settings usando grep raw sobre Pods.xcodeproj
echo ">>> Buscando 'OTHER_CFLAGS' y 'OTHER_CPLUSPLUSFLAGS' con -G en Pods.xcodeproj:"
if [ -f "$PODS_PBXPROJ" ]; then
  grep -n "OTHER_C.*FLAGS\|OTHER_CPLUSPLUS" "$PODS_PBXPROJ" 2>/dev/null | grep -v "inherited" | head -20 || echo "   (ninguno encontrado con valor custom)"
  # También mostrar líneas con -G en cualquier contexto de flags
  grep -n "\-G" "$PODS_PBXPROJ" 2>/dev/null \
    | grep -v "GENERATE\|GCC_\|= /\|url\|path\|Path\|dir\|Dir\|Name\|name\|File\|file\|comment\|Comment" \
    | head -30 || echo "   (ningún -G encontrado en Pods.xcodeproj)"
fi

echo ""
if [ -n "$FOUND_XCCONFIG" ]; then
  echo "⚠️  FLAG -G en xcconfigs:"
  echo "$FOUND_XCCONFIG"
else
  echo "✅ xcconfigs en Pods/ limpios."
fi

if [ -n "$FOUND_PBXPROJ_DICT" ]; then
  echo "⚠️  FLAG -G en Pods.xcodeproj/project.pbxproj (build settings dict):"
  echo "$FOUND_PBXPROJ_DICT"
else
  echo "✅ Pods.xcodeproj/project.pbxproj limpio (patrón ampliado)."
fi

# ── [6/7] PODS INSTALADOS ──────────────────────
echo ""
echo "--- [6/7] PODS INSTALADOS ---"
if [ -f Podfile.lock ]; then
  echo "Extracto de Podfile.lock (primeros 60):"
  grep -E "^  - [A-Za-z]" Podfile.lock | head -60 || true
else
  echo "⚠️  Podfile.lock no encontrado."
fi

# ── [7/7] RESUMEN FINAL ────────────────────────
echo ""
echo "--- [7/7] RESUMEN ---"
if [ -z "$FOUND_XCCONFIG" ] && [ -z "$FOUND_PBXPROJ_DICT" ]; then
  echo "✅ Patrón -G no detectado en búsqueda ampliada."
  echo "   Si el build falla de todas formas, el flag puede estar como '\"-G\"'"
  echo "   en algún build setting — revisa el bloque '>>> Buscando OTHER_C' arriba."
else
  echo "⚠️  Se encontró -G. Revisa los pasos [5] arriba para identificar el pod."
fi

cd ..
echo ""
echo "============================================"
echo "   FIN DIAGNÓSTICO — continuando build..."
echo "============================================"
echo ""
