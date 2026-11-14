# Práctica 5 — Biblioteca ESCOM

Aplicación Flutter compartida para Android e iOS. Consulta el catálogo público de Open Library, conserva búsquedas, libros vistos y favoritos en SQLite y permite abrirlos sin conexión. Las recomendaciones usan los temas que aparecen en las búsquedas y favoritos guardados. La primera apertura funciona como invitado y no requiere claves ni servicios propios.

## Requisitos

- Flutter estable 3.32 o posterior y Dart compatible con `pubspec.yaml`.
- Android Studio con Android SDK y un emulador Android API 24 o superior. El AVD esperado para esta práctica es **Pixel_4a**.
- Para iOS: macOS con Xcode completo (15 o posterior), CocoaPods y simulador iOS 15 o posterior.
- Conexión a Internet para la primera búsqueda. Las búsquedas ya guardadas y los favoritos quedan en SQLite.

## Android — ejecución desde un clon

```sh
git clone <URL-del-repositorio>
cd p5
flutter pub get
flutter emulators --launch Pixel_4a
flutter run
```

También se puede abrir el directorio en Android Studio, seleccionar el dispositivo Pixel 4a y ejecutar `lib/main.dart`. La aplicación declara permiso de Internet y no necesita un archivo `.env`, una API key ni un backend para iniciar.

## iOS

```sh
flutter pub get
open -a Xcode ios/Runner.xcworkspace
flutter run -d <id-del-simulador-iOS>
```

Selecciona el equipo de desarrollo en Signing & Capabilities si Xcode lo solicita. iOS no está verificado en este entorno: aunque Xcode.app está instalado, `xcode-select` apunta a Command Line Tools. En ese estado `xcodebuild` no puede compilar. Seleccionar Xcode completo en macOS (`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`) y aceptar su licencia es un requisito del equipo, no del repositorio.

## Uso

1. Escribe título, autor o tema y toca buscar. Se consultan resultados JSON reales de `https://openlibrary.org/search.json`.
2. Toca una ficha para abrir el detalle; toca el marcador para agregar o quitar el favorito.
3. «Para ti» ordena libros consultados por coincidencia con temas de los favoritos/resultados. Sin datos muestra un estado vacío.
4. «Historial» permite repetir búsquedas. El icono de nube indica el estado de conectividad; al reconectar se intenta actualizar la vista local.
5. La cuenta local distingue los favoritos en este dispositivo; no es una cuenta autenticada en un servidor.

## Persistencia y sincronización

SQLite almacena los metadatos de los resultados (incluida fecha de actualización), favoritos identificados por usuario local y el historial de consultas. Una búsqueda online reemplaza en caché el resultado más reciente para cada clave de Open Library. Si falla la red, se buscan coincidencias en caché. Los cambios de favoritos se aplican en una transacción local, por lo que reiniciar la app no los elimina. No se implementa cola de sincronización con servidor: todavía no hay backend remoto asociado al proyecto.

## Configuración y alcance de entrega

No se guardan secretos en el repositorio. El cliente usa HTTPS para Open Library; las imágenes de portada provienen de `covers.openlibrary.org`. Google OAuth requiere un proyecto OAuth real, IDs de cliente para Android/iOS y validación en un backend. Esas credenciales y el backend no se proporcionaron, así que la pantalla de cuenta se limita a un perfil local y **no simula** un inicio de sesión Google.

Esta carpeta no contenía el cliente ni el backend de la Práctica 2. La implementación actual entrega la app Flutter común, búsqueda pública, SQLite, historial, favoritos, sugerencias y estados básicos de conectividad. Aún hace falta integrar un backend CRUD/autenticación/administración y OAuth de Google para cubrir todos los puntos del enunciado; también hay que obtener evidencias reales en iOS y llenar la matriz de pruebas. No se declara que esas partes estén implementadas.

## English

Flutter client shared by Android and iOS. It searches the public Open Library API and keeps search history, cached book metadata and per-local-profile favorites in SQLite. Topic overlap drives reproducible recommendations. The app starts as a guest without API keys or a custom server.

### Run on Android

Install Flutter, Android Studio and the Android SDK, then run:

```sh
git clone <repository-url>
cd p5
flutter pub get
flutter emulators --launch Pixel_4a
flutter run
```

### Run on iOS

Requires macOS, full Xcode, CocoaPods and an iOS 15+ simulator. Open `ios/Runner.xcworkspace` in Xcode, select a signing team if prompted, then run `flutter run -d <simulator-id>`. This machine currently selects Command Line Tools instead of Xcode, so iOS compilation has not been verified here.

Google sign-in, a server-side CRUD API, administrator authorization and remote synchronization are not implemented. OAuth needs platform client IDs and a backend verifier; the original folder contained no Practice 2 backend. See the Spanish sections above for the local storage and conflict behavior.
