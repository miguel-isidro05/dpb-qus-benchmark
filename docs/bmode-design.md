# Contrato del B-mode

Este flujo procesa RF de canal ya generada por k-Wave. No ejecuta simulaciones ni modifica el MAT de entrada. Su objetivo es formar una imagen B-mode para revisar la adquisición. El cálculo cuantitativo de ACS debe usar los datos RF y el método de estimación correspondiente, sin TGC ni operaciones de presentación.

## Fuentes usadas

- `Echographic Imaging.pdf`, diapositivas "Arrays: Focusing in Tx vs. Rx", "Delay-and-Sum Algorithm" y "Dynamic Focusing in Rx".
- `QUS.pdf`, capítulo de compensación de atenuación y estimación. El texto trata el foco y la difracción como parte de la adquisición que debe conservarse cuando se comparan muestra y referencia.
- ADMIRE, `ADMIRE_Models_Generation_Code/generate_models_for_stft_window.m` y `ADMIRE_models_generation_main.m`. Usa crecimiento de apertura con F#=2 y un mínimo de 16 elementos.

## Datos requeridos

Para `rf_prebf`, el MAT debe contener RF con forma `[tiempo, elemento, línea]`, `fs`, `c0`, `x`, `source_focus`, `element_pitch`, `source_cycles` y `time_delays`. Si existen, se usan `active_tx_elements`, `focal_number_Tx`, `focal_number_Rx` y `element_width` para comprobar el contrato de adquisición.

## Banda de imagen y malla computacional

La adquisición lateral se determina por las líneas de exploración, no por el ancho total de la malla. Con 128 líneas y `pitch = 0.3 mm`, su ancho es `(128 - 1) * 0.3 = 38.1 mm`, es decir, aproximadamente **4 cm**. La figura del paper adjunta puede recortar la ventana central a 3 cm para su presentación, pero los previews Geometry y ACS de la GUI muestran el dominio completo y su PML, que es lo que calcula k-Wave.

La malla de k-Wave debe ser más ancha para que el subarreglo Rx de las líneas extremas no quede fuera del dominio. Para la configuración de 2 cm de foco, F# Rx = 2 y 33 elementos Rx, se requieren 47.95 mm de malla física; 5 cm deja margen y conserva la adquisición de aproximadamente 4 cm y la vista central de 3 cm. No se debe aumentar la banda de exploración a 5 cm para compensar la malla.

## Formación de cada línea

La transmisión ya está focalizada en la simulación mediante `time_delays`. El origen temporal se calcula con esos retardos y con la duración del pulso. Para una profundidad axial `z` y un elemento de recepción en `x_n`, el DAS usa

```text
Delta_t_rx(n, z) = (sqrt(z^2 + x_n^2) - z) / c0
```

El canal se interpola en `t + Delta_t_rx` y se combinan los canales activos. Los pesos son uniformes. El resultado se divide por el número de canales activos para que un cambio de apertura no se interprete como ganancia o atenuación del medio.

La apertura dinámica sigue ADMIRE:

```text
N(z) = min(max(2 * ceil(ceil(z / (pitch * F#)) / 2), N_min), N_channels)
```

El valor por defecto es `F#` guardado en el MAT y `N_min = 16`. La apertura se centra sobre la línea. El número de elementos no puede superar los canales realmente guardados en la RF.

## Visualización

Después del DAS se aplica un filtro simétrico alrededor de `source_f0`, la envolvente analítica de Hilbert y compresión logarítmica. La barra indica `dB`. El rango dinámico por defecto es de 50 dB. TGC está desactivado por defecto porque sólo es una corrección visual y no debe mezclarse con una comparación cuantitativa.

El revisor conserva la escala ACS de la GUI, con límites 0.35 a 1.05 dB/cm/MHz y etiquetas visibles en 0.4, 0.6, 0.8 y 1. Cada B-mode se muestra junto al `alpha_coeff` del mismo MAT.

## Límites de validez

Si la figura indica "RF recortada lateralmente", las líneas externas se adquirieron con parte del arreglo fuera de la malla. El DAS no puede recuperar esos canales. Hay que regenerar la RF con una malla lateral que contenga el desplazamiento de todas las líneas y la apertura Rx completa.

La simulación guarda sólo los canales del subarreglo Rx que se usó. Una RF con 33 canales no contiene los 128 canales que tendría un sistema de recepción completa. El B-mode usa la apertura disponible y deja ese límite documentado en los metadatos.
