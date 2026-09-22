# DPB QUS Benchmark

Repositorio de avance del DPB sobre la evaluación comparativa de ultrasonido cuantitativo (QUS) mediante simulaciones en MATLAB.

El proyecto reúne el desarrollo de una interfaz gráfica en MATLAB App Designer, pruebas de simulación, configuraciones y resultados seleccionados en formato `.mat`, además de notas y evidencias del progreso.

La primera etapa consiste en construir una simulación reproducible de un medio simplificado y organizar sus resultados para compararlos entre experimentos.

## Posprocesamiento B-mode

El pipeline MATLAB está en `pipelines/bmode/mi_m_bmode_pipeline.m`. Acepta RF multicanal del clúster o scan lines ya beamformadas; exporta B-mode, RF, envolvente, espectros y comparación con referencia común. TGC está apagado por defecto.

Consultar [uso y contrato de entrada](docs/bmode-pipeline.md), [diseño y fuentes por etapa US](docs/bmode-design.md) y [verificación local](docs/bmode-verification.md).
