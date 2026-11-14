**Instituto Politécnico Nacional** 

**Escuela Superior de Cómputo** 

| Programa académico / Plan de estudios |
| :---: |
| Ingeniería en Sistemas Computacionales / 2020 |

| Unidad de aprendizaje |
| :---: |
| Desarrollo de aplicaciones móviles nativas |

**Práctica 5: Consulta de bases de datos vía APIs y funcionalidades específicas en aplicaciones  multiplataforma (Android e iOS)** 

**Objetivo:** Desarrollar una aplicación móvil multiplataforma que consulte datos mediante APIs REST, integre  una API pública, implemente búsquedas, historial, favoritos y recomendaciones, y sincronice datos entre el  servidor y una base local. La experiencia deberá funcionar tanto en Android como en iOS y conservar las  funciones disponibles sin conexión. 

**Instrucciones generales** 

• Elegir una sola tecnología para la aplicación: Kotlin Multiplatform (KMP, con interfaz Compose Multiplatform  o nativa) o Flutter (Dart). 

• Demostrar el funcionamiento de todos los ejercicios en Android 7.0 (API 24\) o superior e iOS 15 o superior;  no basta con declarar ambos destinos en el proyecto. 

• La Práctica 5 puede continuar el trabajo de la Práctica 2 o desarrollarse sobre una solución equivalente.  En ambos casos se exige el funcionamiento completo en Android e iOS y una API REST operativa. • El acceso a información local y funciones ya sincronizadas debe mantenerse sin Internet. Las operaciones  que requieran al servidor deben mostrar su estado de espera o error y sincronizarse al recuperar la  conexión. 

• Toda la comunicación remota deberá usar HTTPS. No se deben subir secretos, tokens, claves de servicios  ni información personal a repositorios o evidencias públicas. 

**Tecnología sugerida (no obligatoria): KMP — Ktor Client \+ base SQLite multiplataforma; Flutter — cliente  HTTP (http/Dio) \+ SQLite (sqflite/Drift). Las bibliotecas elegidas deben funcionar en Android e iOS.** 

**Relación con la Práctica 2: continuidad permitida** 

**Continuación de la Práctica 2:** Se permite continuar directamente el proyecto de la Práctica 2, “Aplicación  móvil básica para operaciones CRUD con un servicio REST”. No se exige empezar desde cero ni reconstruir el  backend si ya funciona. 

• Pueden reutilizar el mismo repositorio, el backend REST dockerizado (Docker Compose), la base de datos,  las operaciones CRUD, el registro y login, y el manejo de sesiones seguras desarrollados en la Práctica  2\. 

• La ampliación consiste en convertir o reconstruir el cliente como una sola aplicación KMP o Flutter que  funcione en Android e iOS e incorporar las nuevas funciones de esta práctica: API pública, caché y  sincronización local, historial, favoritos, recomendaciones, autenticación con Google y rol administrador. 

• El ejemplo Flask \+ Kotlin/Jetpack Compose de la Práctica 2 puede servir como base, pero su cliente Android  original no demuestra compatibilidad con iOS. También se admite un proyecto distinto que cumpla y  documente los mismos requisitos.  
**Ejercicio 1: Integración de consultas a la base de datos vía API REST** 

**Descripción:** Extender la aplicación para consultar la API REST del proyecto, autenticar usuarios y mantener  una copia local de la información relevante con sincronización controlada. 

**1.1 Conexión, consulta y sesión** 

• Conservar y demostrar las cuatro operaciones CRUD (GET, POST, PUT y DELETE) de la Práctica 2  cuando se utilice como base; además, implementar las consultas y funcionalidades adicionales de esta  práctica. Si se usa otro backend, debe ofrecer un CRUD equivalente. 

• Mostrar resultados reales, tiempos de carga y estados de lista vacía, error HTTP, error de red y datos  malformados sin provocar cierres inesperados. 

• Mantener una sesión identificable y segura, con registro/login y cierre de sesión; si se continúa la Práctica  2, conservar su autenticación existente e integrar la opción adicional de Google sin exponer tokens ni  credenciales. 

• Usar un cliente HTTP compatible con ambas plataformas: por ejemplo, Ktor Client en KMP o http/Dio en  Flutter. Retrofit puede usarse en Android, pero no sustituye una implementación para iOS. 

**1.2 Almacenamiento local y sincronización** 

• Guardar en una base de datos local las consultas relevantes y su fecha de actualización; permitir mostrar  los resultados guardados cuando la red no esté disponible. 

• Implementar una sincronización explícita al iniciar o recuperar conexión, con indicador de última  actualización, manejo de errores y reintentos razonables. 

• Si se modifican favoritos o preferencias sin conexión, conservar una cola de operaciones pendientes y  resolverlas al recuperar Internet, evitando duplicados. 

• Documentar la estrategia de conflictos y la prioridad de los datos (servidor/local); justificar qué información  permanece accesible al cerrar y volver a abrir la aplicación. 

**Ejercicio 2: Consumo de una API pública** 

**Descripción:** Integrar al menos una API pública gratuita con respuestas JSON para permitir búsquedas y  enriquecer la experiencia de la aplicación. 

**Opciones de referencia:** Open Library (libros y autores: https\://openlibrary.org/developers/api) o TVMaze  (series y programas de televisión: https\://www\.tvmaze.com/api). Se admite una alternativa gratuita justificada. 

**2.1 Búsqueda y presentación** 

• Implementar búsqueda por texto con resultados relevantes, vista de detalle y tratamiento de respuestas  vacías, errores, límites de consulta y fallas de conectividad. 

• Procesar datos JSON reales, conservar el historial de búsquedas y almacenar localmente resultados  consultados para poder volver a visualizarlos sin conexión. 

• Habilitar marcadores o favoritos sobre los resultados, con persistencia después de reiniciar la aplicación. 

**2.2 Registro e inicio de sesión con Google** 

• Incorporar registro o inicio de sesión con Google en Android e iOS; demostrar ingreso, restauración de  sesión y cierre de sesión en ambas plataformas. 

• Realizar la configuración OAuth propia de cada plataforma. La identidad del usuario debe validarse en el  servicio de autenticación o backend, y la sesión debe almacenarse de forma segura. • En modo offline se puede mantener una sesión ya validada y consultar datos locales, pero no se exige  iniciar por primera vez con Google sin conexión. 

**Ejercicio 3: Búsqueda, favoritos y recomendaciones** 

**3.1 Historial y favoritos por usuario** 

• El usuario podrá consultar su historial de búsquedas, marcar y desmarcar favoritos, y recuperar estos datos  después de reiniciar o cambiar entre estados online y offline. 

• Implementar un rol administrador que consulte historiales y favoritos de usuarios autorizados. Los permisos  se validarán en el backend, no sólo ocultando elementos en la interfaz. 

• Diferenciar datos personales por cuenta y evitar que una sesión acceda a información perteneciente a otro  usuario.  
**3.2 Recomendaciones verificables** 

• Generar sugerencias utilizando el historial y los favoritos del usuario. Puede aplicarse una regla  reproducible (tema, género, autor, categoría o coincidencia de etiquetas); no se exige un modelo de  inteligencia artificial. 

• Explicar el criterio de recomendación, mostrar al menos tres recomendaciones cuando existan datos  suficientes y resolver el caso sin historial o favoritos. 

• Persistir las recomendaciones o los datos necesarios para reproducirlas y permitir visualizar resultados  previos sin conexión. 

**Pruebas y verificación obligatoria** 

• Ejecutar las mismas pruebas funcionales en Android e iOS; indicar dispositivo o simulador, versión de  sistema operativo, pasos, resultado esperado, resultado obtenido y captura. 

• Documentar al menos ocho escenarios: consulta REST, búsqueda pública, estado vacío/error, acceso con  Google y cierre de sesión, favoritos, recomendaciones, reinicio de aplicación, consulta offline, reconexión  y sincronización (al menos ocho; pueden agruparse cuando corresponda). 

• Demostrar cambios de conectividad en tiempo real y explicar cómo se evitan pérdidas o duplicaciones de  datos durante los reintentos. 

• Probar la autorización del administrador y un acceso denegado desde una cuenta sin permisos. Registrar  los defectos reproducibles como issues. 

• Para compilar y ejecutar en iOS se requiere acceso a macOS con Xcode, mediante equipo físico o entorno  adecuado. Se permite simulador para las pruebas; debe identificarse claramente. 

**Entrega de la práctica** 

• Repositorio GitHub con el código fuente de Android e iOS y del backend REST; se permite entregar el  repositorio de la Práctica 2 extendido, con historial verificable de los cambios. No se aceptan dos clientes  inconexos como solución multiplataforma. 

• README en español e inglés con requisitos, ejecución en Android e iOS, arranque del backend (Docker  Compose si aplica), configuración de API/OAuth sin secretos y sincronización. Si se retomó la Práctica 2,  enlazar el commit o etiqueta anterior y distinguir endpoints reutilizados y mejoras añadidas. 

• Informe técnico: introducción, arquitectura (componentes comunes y nativos), endpoints usados, modelo  de datos, persistencia, autenticación, recomendaciones, resultados, conclusiones y bibliografía APA. • Evidencias de ambas plataformas: capturas o videos de búsqueda, inicio de sesión, favoritos,  recomendaciones, modo offline, sincronización y rol administrador. 

• Matriz de pruebas con los resultados reales y enlace a las issues de defectos; identificar contribuciones de  los integrantes y declarar las herramientas de IA utilizadas, cuando aplique. 

• Exposición de máximo diez minutos con demostración en Android e iOS y explicación del código compartido  y los componentes específicos de cada plataforma. 

**Fecha de entrega:** La fecha límite para la entrega de esta práctica es el **viernes 06 de noviembre de 2026**.  No se aceptarán entregas fuera de tiempo y forma bajo ninguna circunstancia.