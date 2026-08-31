# Uso del cluster LIM

Estas son las restricciones operativas comunicadas por Rodolfo Huacasi para el
usuario de pregrado Miguel Isidro. Se aplican a cualquier experimento de este
repositorio que se ejecute en el cluster.

## Alcance autorizado

- Usar únicamente la partición `thinkstation`.
- Los únicos nodos permitidos son `worker7`, `worker8`, `worker9` y `worker10`.
- No usar otras particiones ni nodos, salvo autorización explícita del equipo
  administrador del cluster.

## Límites de uso

- Mantener como máximo dos nodos en uso al mismo tiempo.
- Mantener como máximo un job en cola.
- Antes de enviar un job, comprobar los jobs propios activos y en cola para no
  sobrepasar esos límites.

## Archivos y almacenamiento

- Trabajar y guardar códigos, datos de trabajo y resultados únicamente en la
  carpeta personal del NAS2: `/mnt/nfs2/misidro/`.
- No escribir en directorios ajenos ni en ubicaciones compartidas sin
  autorización explícita.
- Mantener los experimentos reproducibles desde esa carpeta personal.

## Nombre de scripts

- Todo script de ejecución debe comenzar con las iniciales `mi`.
- Para Python, usar el patrón `mi_p_<descripcion>.sh`.
- Para MATLAB, usar el patrón `mi_m_<descripcion>.sh`.

Ejemplos válidos: `mi_p_qus_baseline.sh` y `mi_m_medium_sweep.sh`.

## Protocolo para cada experimento

1. Preparar el código y el script de envío dentro de `/mnt/nfs2/misidro/`.
2. Elegir `thinkstation` y, si el script fija un nodo, limitarlo a `worker7`,
   `worker8`, `worker9` o `worker10`.
3. Verificar que el nombre del script cumple el patrón de iniciales y lenguaje.
4. Verificar que el envío no excede dos nodos en uso ni un job en cola.
5. Enviar el job y revisar su estado sin enviar duplicados mientras permanezca
   en cola.
6. Guardar resultados y registros en la carpeta personal. Reportar problemas
   operativos, mantenimientos o dudas por el canal de WhatsApp del cluster.

## Límites de esta guía

La comunicación recibida no incluye el hostname, el método de conexión, el
planificador o los comandos de envío. No se deben asumir esos datos ni copiar
comandos de fuentes externas. Cuando se disponga de la guía institucional o de
un ejemplo aprobado, se añadirá aquí el procedimiento exacto.

## Seguridad de acceso

El usuario de acceso comunicado es `misidro`. La contraseña entregada por
correo no se registra en este repositorio ni se incorpora a scripts.
