#!/usr/bin/env python3
"""
Carril BATCH: Odoo (PostgreSQL) -> bronze_pg (Delta en Unity Catalog).

Para qué existe
---------------
El carril CDC (Lakeflow Connect) necesita un gateway sobre compute clásico, y
un workspace Free Edition solo tiene serverless. Lakehouse Sync de Lakebase
tampoco sirve ahí: exige un catálogo con external storage y Free Edition solo
ofrece default storage. Este carril llena el mismo contrato de Bronze sin
depender de ninguna de las dos cosas, así que Silver, Gold, el dashboard y
Genie funcionan igual.

Lo que se pierde frente al CDC: no captura borrados entre corridas y no es
continuo. Para la demo alcanza — recargar las 17 tablas son segundos, así que
el momento "creo un pedido en Odoo y aparece en el dashboard" se conserva.

Cómo funciona
-------------
1. Introspecciona `information_schema` del Odoo origen para saber qué columnas
   del contrato existen en ESA versión (17, 18 o 19).
2. Exporta cada tabla a JSON Lines con `row_to_json`, casteando todo a
   text y emitiendo NULL para las columnas que esa versión no tenga.
3. Sube los .jsonl a un Volume de Unity Catalog.
4. Reconstruye cada tabla de `bronze_pg` con `read_files`.

Por qué JSON Lines y no CSV: los campos traducibles de Odoo son JSONB, o sea
que su contenido lleva comas y comillas. En CSV eso obliga a comillas dobladas
(`""`) y el lector de Databricks parte el campo en la coma interna, dejando el
nombre truncado y corriendo el resto de las columnas. Con JSON Lines el
escapado es del formato y no hay ambigüedad.

Bronze queda todo en STRING a propósito: es la capa cruda, y Silver ya castea
explícitamente. Eso hace la carga inmune a cambios de tipo entre versiones.

Uso
---
Desde la raíz del repo:

    make load-bronze

Contra el Postgres de un cliente, con las variables estándar de libpq:

    PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=... \\
      python3 ingestion/batch/load_bronze.py --profile FREE \\
        --catalog workspace --schema bronze_pg

Requiere `psql` y el CLI `databricks` en el PATH. Sin dependencias de Python.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import contract  # noqa: E402


def psql(sql, capture=True):
    """Corre SQL con psql usando las variables de entorno de libpq."""
    cmd = ["psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-A", "-t", "-c", sql]
    r = subprocess.run(cmd, capture_output=capture, text=True)
    if r.returncode != 0:
        raise SystemExit(
            f"psql falló ({r.returncode}).\nSQL: {sql[:200]}\n{r.stderr or ''}"
        )
    return r.stdout


def databricks(args, profile, capture=True):
    cmd = ["databricks", *args, "--profile", profile]
    r = subprocess.run(cmd, capture_output=capture, text=True)
    if r.returncode != 0:
        raise SystemExit(
            f"databricks {' '.join(args[:3])} falló ({r.returncode}).\n"
            f"{r.stderr or r.stdout or ''}"
        )
    return r.stdout


def sql_databricks(query, profile):
    """Ejecuta SQL en el SQL warehouse por defecto del workspace."""
    return databricks(
        ["experimental", "aitools", "tools", "query", query], profile
    )


def introspect_schema():
    """{tabla: [columnas reales]} del Odoo origen. La clave es el nombre de la tabla."""
    names = ", ".join(f"'{t}'" for t in contract.TABLES)
    rows = psql(
        "SELECT table_name || '|' || column_name "
        "FROM information_schema.columns "
        f"WHERE table_schema = 'public' AND table_name IN ({names}) "
        "ORDER BY table_name, ordinal_position"
    )
    real = {t: [] for t in contract.TABLES}
    for line in rows.strip().splitlines():
        if "|" not in line:
            continue
        table_name, col = line.split("|", 1)
        if table_name in real:
            real[table_name].append(col)
    return real


def export_table(table_name, actual_columns, dest):
    """Exporta una tabla a JSON Lines. Devuelve el número de filas."""
    exprs = ",\n       ".join(contract.column_expressions(table_name, actual_columns))
    consulta = f"SELECT {exprs}\nFROM public.{table_name}"
    # row_to_json escapa el contenido según las reglas de JSON, así que los
    # campos traducibles (jsonb, con comas y comillas adentro) viajan intactos.
    #
    # OJO con COPY: `FORMAT text` aplica SU PROPIO escapado de backslashes y
    # convierte el \" del JSON en \\", rompiendo cada línea. Y `FORMAT csv`
    # dobla las comillas, que es el problema que nos hizo abandonar CSV.
    # La salida sin alinear de psql (-A -t) emite el valor tal cual, una fila
    # por línea, sin escapado propio. row_to_json nunca mete saltos de línea
    # literales (los escapa como \n), así que una línea = una fila.
    sql = f"SELECT row_to_json(f) FROM ({consulta}) f"

    with open(dest, "w", encoding="utf-8") as fh:
        r = subprocess.run(
            ["psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-A", "-t", "-c", sql],
            stdout=fh, stderr=subprocess.PIPE, text=True,
        )
    if r.returncode != 0:
        raise SystemExit(f"Falló la exportación de {table_name}:\n{r.stderr}")

    with open(dest, encoding="utf-8") as fh:
        return sum(1 for _ in fh)   # una fila por línea


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--profile", default=os.environ.get("DATABRICKS_CONFIG_PROFILE", "FREE"))
    p.add_argument("--catalog", default="workspace")
    p.add_argument("--schema", default="bronze_pg")
    p.add_argument("--volume", default="landing")
    p.add_argument("--export-only", action="store_true",
                   help="Exporta los .jsonl y no toca Databricks (para depurar).")
    p.add_argument("--output", help="Dónde dejar los .jsonl (default: temporal).")
    args = p.parse_args()

    cat, esq, vol = args.catalog, args.schema, args.volume

    print(f"Origen: {os.environ.get('PGDATABASE', '?')} en "
          f"{os.environ.get('PGHOST', 'localhost')}:{os.environ.get('PGPORT', '5432')}")
    version = psql("SHOW server_version").strip()
    print(f"PostgreSQL {version}")

    print("\n== 1. Introspección del esquema de Odoo ==")
    real = introspect_schema()
    empty = [t for t, c in real.items() if not c]
    if empty:
        raise SystemExit(
            "Estas tablas del contrato no existen en el Odoo origen: "
            + ", ".join(empty)
            + "\n¿Instalaste sale_management y stock?"
        )
    for table_name in contract.REPLICATED_TABLES:
        missing = contract.missing_columns(table_name, real[table_name])
        if missing:
            print(f"  {table_name}: esta versión de Odoo no tiene {', '.join(missing)}"
                  f" — se emiten como NULL")
    if not any(contract.missing_columns(t, real[t]) for t in contract.TABLES):
        print("  el contrato calza completo con esta versión de Odoo")

    print("\n== 2. Exportando a JSON Lines ==")
    tmp = args.output or tempfile.mkdtemp(prefix="bronze_")
    Path(tmp).mkdir(parents=True, exist_ok=True)
    counts = {}
    for table_name in contract.REPLICATED_TABLES:
        dest = Path(tmp) / f"{table_name}.jsonl"
        counts[table_name] = export_table(table_name, real[table_name], dest)
        print(f"  {table_name:<22} {counts[table_name]:>8} filas")
    print(f"  -> {tmp}")

    if args.export_only:
        print("\n--export-only: no se tocó Databricks.")
        return

    print("\n== 3. Subiendo al Volume de Unity Catalog ==")
    sql_databricks(f"CREATE SCHEMA IF NOT EXISTS {cat}.{esq}", args.profile)
    sql_databricks(f"CREATE VOLUME IF NOT EXISTS {cat}.{esq}.{vol}", args.profile)
    volume_path = f"dbfs:/Volumes/{cat}/{esq}/{vol}"
    for table_name in contract.REPLICATED_TABLES:
        databricks(["fs", "cp", str(Path(tmp) / f"{table_name}.jsonl"),
                    f"{volume_path}/{table_name}.jsonl", "--overwrite"], args.profile)
        print(f"  {table_name}")

    print("\n== 4. Reconstruyendo bronze_pg ==")
    for table_name in contract.REPLICATED_TABLES:
        # Esquema EXPLÍCITO, todo STRING: Bronze es la capa cruda y el casteo
        # es de Silver. Así un cambio de tipo entre versiones de Odoo no rompe
        # la carga, y no dependemos de la inferencia de read_files.
        cols = contract.TABLES[table_name]
        schema = ", ".join(f"{c} STRING" for c in cols)
        sql_databricks(
            f"CREATE OR REPLACE TABLE {cat}.{esq}.{table_name} AS "
            f"SELECT {', '.join(cols)} FROM read_files("
            f"'/Volumes/{cat}/{esq}/{vol}/{table_name}.jsonl', "
            f"format => 'json', schema => '{schema}')",
            args.profile,
        )
        print(f"  {cat}.{esq}.{table_name}")

    total = sum(counts.values())
    print(f"\nListo: {len(counts)} tablas, {total} filas en {cat}.{esq}")
    print("Siguiente: desplegá el bundle y corré el pipeline de Silver/Gold.")


if __name__ == "__main__":
    main()
