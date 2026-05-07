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
# Patrón preciso: espacio + -G + (espacio | dígito | fin de línea)
# Excluye falsos positivos como -GENERATE_, -GCC_, -GSOMETHING
FLAG_PATTERN=" -G[[:space:]0-9]| -G$"
FOUND_BEFORE=$(grep -rEn "$FLAG_PATTERN" \
  --include="*.xcconfig" \
  --include="*.pbxproj" \
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
# Filtra la salida: muestra instalaciones, errores y warnings relevantes
pod install 2>&1 | grep -E \
  "^(Installing|Using|Downloading|Generating|Analyzing|Building|Warning|Error|Post-install)" \
  || true
echo "✅ pod install finalizado."

# ── [5/7] BUSCAR -G DESPUÉS DE POD INSTALL ─────
echo ""
echo "--- [5/7] BÚSQUEDA DE -G EN PODS GENERADOS ---"
FOUND_XCCONFIG=$(grep -rEn "$FLAG_PATTERN" \
  --include="*.xcconfig" \
  Pods/ 2>/dev/null || true)

FOUND_PBXPROJ=$(grep -rEn "$FLAG_PATTERN" \
  --include="*.pbxproj" \
  . 2>/dev/null || true)

if [ -n "$FOUND_XCCONFIG" ]; then
  echo "⚠️  FLAG -G en xcconfig (POD CULPABLE):"
  echo "$FOUND_XCCONFIG"
  echo ""
  echo "🛠️  Aplicando parche de emergencia en xcconfigs..."
  find Pods/ -name "*.xcconfig" | while read -r xcfile; do
    if grep -qE "$FLAG_PATTERN" "$xcfile" 2>/dev/null; then
      echo "   Parcheando: $xcfile"
      # sed preciso: elimina -G suelto o -G<dígito>, no toca -GENERATE u otros
      sed -i '' -E 's/ -G([[:space:]]|[0-9])/ /g; s/ -G$//g' "$xcfile"
    fi
  done
  echo "   Verificando resultado..."
  STILL_THERE=$(grep -rEn "$FLAG_PATTERN" --include="*.xcconfig" Pods/ 2>/dev/null || true)
  if [ -n "$STILL_THERE" ]; then
    echo "⚠️  Aún quedan ocurrencias después del parche:"
    echo "$STILL_THERE"
  else
    echo "✅ xcconfigs parcheados y limpios."
  fi
else
  echo "✅ Ningún xcconfig en Pods/ contiene el flag -G."
fi

if [ -n "$FOUND_PBXPROJ" ]; then
  echo "⚠️  FLAG -G en .pbxproj:"
  echo "$FOUND_PBXPROJ"
else
  echo "✅ Ningún .pbxproj contiene el flag -G."
fi

# ── [6/7] PODS INSTALADOS ──────────────────────
echo ""
echo "--- [6/7] PODS INSTALADOS ---"
if [ -f Podfile.lock ]; then
  echo "Extracto de Podfile.lock:"
  grep -E "^  - [A-Za-z]" Podfile.lock | head -50 || true
else
  echo "⚠️  Podfile.lock no encontrado."
fi

# ── [7/7] RESUMEN FINAL ────────────────────────
echo ""
echo "--- [7/7] RESUMEN ---"
if [ -z "$FOUND_XCCONFIG" ] && [ -z "$FOUND_PBXPROJ" ]; then
  echo "✅ Sin flag -G detectado. El build debería compilar sin errores de -G."
else
  echo "⚠️  Se encontró -G. Revisa los logs de los pasos [3] y [5] arriba."
fi

cd ..
echo ""
echo "============================================"
echo "   FIN DIAGNÓSTICO — continuando build..."
echo "============================================"
echo ""
