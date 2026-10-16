# Scanner para Mac

Port del [Scanner de Steffen Gerlach](http://www.steffengerlach.de/freeware/) (Windows) a macOS, escrito desde cero en Swift/SwiftUI. Muestra en un gráfico de anillos concéntricos qué ocupa espacio en el disco. Cada anillo hacia afuera es un nivel más profundo de carpetas, y el área es proporcional al espacio ocupado. Es liviana, nativa y sin dependencias.

## Uso

- Al abrirse escanea el disco de arranque. A la izquierda se elige otro disco o una carpeta, y si se hace clic de nuevo en el elegido, se vuelve a escanear.
- Al pasar el mouse por un segmento se ven su tamaño, el porcentaje y la ruta.
- **Clic** en una carpeta hace zoom en ella, con una animación en la que el segmento se abre hasta ocupar el círculo. **Clic en el centro** sube a la carpeta superior.
- **Clic derecho**: Abrir, Mostrar en Finder, Copiar ruta, Re-escanear y Mover a la Papelera (pide confirmación).
- **Panel de detalles** (⌥⌘I): el contenido de la carpeta con tamaños exactos, o sus 50 archivos más grandes aunque estén muy adentro. Pasar el mouse por una fila resalta su segmento en el gráfico.
- **Colorear por tipo** (⌘T): video, imágenes, audio, documentos, apps, desarrollo, cachés… Una carpeta toma el color de lo que más ocupa y la leyenda muestra el total de cada tipo.
- **Papelera** (abajo a la izquierda): muestra cuánto ocupa, con un clic se ve en el gráfico y se puede vaciar.
- Atajos: ⌘[ atrás, ⌘↑ carpeta superior, ⌘R re-escanear, ⌘. detener, ⌘O abrir carpeta.
- También se puede arrastrar una carpeta a la ventana, usar **clic derecho › Servicios › Analizar con Scanner** en Finder, "Abrir con › Scanner" o `open -a Scanner ~/carpeta`.

En el disco de arranque, además de las carpetas, aparecen **Libre**, que incluye el espacio purgeable, y **Sistema y otros**. Este último se desglosa en el anillo siguiente con los otros volúmenes del disco (macOS, Arranque, Swap) y lo que quedó sin escanear (carpetas sin acceso, snapshots, metadatos).

### Permisos

- **Acceso total al disco**: sin este permiso macOS no deja leer algunas carpetas (Mail, Safari, la Papelera, etc.), que la barra inferior cuenta como "sin acceso". Para incluirlas, agregá Scanner en **Ajustes del Sistema › Privacidad y seguridad › Acceso total al disco**.
- **Automatización › Finder**: se pide la primera vez que vaciás la Papelera, porque Scanner le pide a Finder que lo haga.

## Compilar

Alcanza con las Command Line Tools; no hace falta Xcode.

```sh
scripts/setup-signing.sh        # una sola vez: certificado local para firmar
scripts/build-app.sh            # arma build/Scanner.app
scripts/build-app.sh --install  # y además la copia a ~/Applications y registra el servicio de Finder
scripts/test.sh                 # tests
```

Sin el certificado local, la app se firma ad-hoc y macOS olvida el permiso de Acceso total al disco cada vez que se recompila. El certificado se guarda en un llavero aparte, en `~/Library/Application Support/com.vhpenas.scanner.signing/`, y no toca el llavero de inicio de sesión.

## Estructura

- `Sources/ScannerCore`: escaneo, modelo del árbol, categorías, uso de volúmenes APFS y cálculo del gráfico. No tiene UI y tiene tests.
  - El escaneo usa POSIX `readdir`/`fstatat` en paralelo, cuenta bloques asignados, no cruza volúmenes y cuenta los hardlinks una sola vez.
  - Cada nodo ocupa 80 bytes.
- `Sources/Scanner`: la app SwiftUI.
- `scripts/`: compilación, firma, ícono y tests.

## Licencia

MIT. Ver [LICENSE](LICENSE).
