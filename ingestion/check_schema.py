#!/usr/bin/env python3
"""
Compara el esquema real de un Odoo contra el contrato de ingesta.

    make check-version VERSION=17

Para qué sirve
--------------
El pipeline lee el esquema crudo de Odoo, así que la deriva entre versiones es
responsabilidad nuestra. `load_bronze.py` está diseñado para tolerarla —
introspecciona `information_schema` y emite NULL para las columnas que esa
versión no tenga— pero eso es una afirmación, no un hecho, hasta que alguien la
prueba contra la versión en cuestión.

Este script convierte la afirmación en una verificación: apunta a una base de
Odoo cualquiera y reporta, tabla por tabla, qué del contrato existe ahí y qué
no. Lo que reporta como faltante saldrá NULL en Bronze, no romperá la carga.

Conexión por las variables estándar de libpq (PGHOST, PGPORT, PGUSER,
PGPASSWORD, PGDATABASE), igual que el cargador.

Salida
------
Código 0 si todas las TABLAS del contrato existen, aunque falten columnas: eso
es deriva tolerable. Código 1 si falta una tabla entera, que sí rompe Silver.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import contract  # noqa: E402


def psql(sql):
    r = subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-A", "-t", "-c", sql],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"psql falló: {r.stderr.strip()[:300]}")
    return r.stdout


def main():
    base = os.environ.get("PGDATABASE", "?")
    version = psql("SELECT COALESCE((SELECT latest_version FROM ir_module_module "
                   "WHERE name = 'base'), 'desconocida')").strip()
    print(f"\nBase: {base} | Odoo {version}\n")

    nombres = ", ".join(f"'{t}'" for t in contract.TABLES)
    filas = psql(
        "SELECT table_name || '|' || column_name FROM information_schema.columns "
        f"WHERE table_schema = 'public' AND table_name IN ({nombres})"
    )
    real = {t: set() for t in contract.TABLES}
    for linea in filas.strip().splitlines():
        if "|" in linea:
            t, c = linea.split("|", 1)
            if t in real:
                real[t].add(c.lower())

    tablas_ausentes, columnas_ausentes, ok = [], {}, 0
    for tabla in contract.REPLICATED_TABLES:
        if not real[tabla]:
            tablas_ausentes.append(tabla)
            continue
        falta = contract.missing_columns(tabla, real[tabla])
        if falta:
            columnas_ausentes[tabla] = falta
        else:
            ok += 1

    total = len(contract.REPLICATED_TABLES)
    print(f"  {ok}/{total} tablas calzan completo con el contrato")

    if columnas_ausentes:
        print("\n  Columnas del contrato que esta versión NO tiene.")
        print("  Saldrán como NULL en Bronze; la carga no se rompe:")
        for tabla, cols in sorted(columnas_ausentes.items()):
            print(f"    {tabla:<22} {', '.join(cols)}")

    if tablas_ausentes:
        print("\n  TABLAS AUSENTES — esto SÍ rompe Silver:")
        for t in tablas_ausentes:
            print(f"    {t}")
        print("\n  ¿Están instalados sale_management y stock en esta base?")
        return 1

    print("\n  Veredicto: el contrato es compatible con esta versión.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
