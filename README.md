# Scanner para Mac

Port del [Scanner de Steffen Gerlach](http://www.steffengerlach.de/freeware/) (Windows) a macOS, escrito desde cero en Swift/SwiftUI. Muestra en un gráfico de anillos concéntricos qué ocupa espacio en el disco. Cada anillo hacia afuera es un nivel más profundo de carpetas, y el área es proporcional al espacio ocupado.

## Uso

- Al abrirse escanea el disco de arranque. A la izquierda se elige otro disco o una carpeta, y si se hace clic de nuevo en el elegido, se vuelve a escanear.
- Al pasar el mouse por un segmento se ven su tamaño, el porcentaje y la ruta.
- **Clic** en una carpeta hace zoom en ella. **Clic en el centro** sube a la carpeta superior.
- **Clic derecho**: Abrir, Mostrar en Finder, Copiar ruta, Re-escanear y Mover a la Papelera (pide confirmación).
- Atajos: ⌘[ atrás, ⌘↑ carpeta superior, ⌘R re-escanear, ⌘. detener, ⌘O abrir carpeta.
- También se puede arrastrar una carpeta a la ventana, usar "Abrir con › Scanner" en Finder o `open -a Scanner ~/carpeta`.

En el disco de arranque, además de las carpetas, aparecen **Libre** y **Sistema y otros**. Este último es lo que macOS reporta como usado pero el escaneo no alcanza: el volumen del sistema, snapshots, espacio purgeable y carpetas sin acceso.

### Acceso total al disco

Sin ese permiso, macOS no deja leer algunas carpetas (Mail, Safari, etc.) y la barra inferior las cuenta como "sin acceso". Para incluirlas, agregá Scanner en **Ajustes del Sistema › Privacidad y seguridad › Acceso total al disco**. La app está firmada ad-hoc, así que al recompilarla puede que haya que volver a darle el permiso.

## Compilar

Alcanza con las Command Line Tools; no hace falta Xcode.

```sh
scripts/build-app.sh            # arma build/Scanner.app
scripts/build-app.sh --install  # y además la copia a ~/Applications
scripts/test.sh                 # tests
```

## Estructura

- `Sources/ScannerCore`: escaneo (POSIX `readdir`/`fstatat`, en paralelo, cuenta bloques asignados, no cruza volúmenes, hardlinks una vez), modelo del árbol y cálculo del gráfico. Sin UI, con tests.
- `Sources/Scanner`: la app SwiftUI.
- `scripts/make-icon.swift`: dibuja el ícono.

## Licencia

MIT. Ver [LICENSE](LICENSE).
