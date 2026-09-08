"""
Genera volumen de ventas realista sobre la demo data de Odoo.

La demo de Odoo trae un puñado de pedidos: alcanza para probar el conector,
NO alcanza para un dashboard que convenza a nadie. Esto crea departamentos
hondureños, zonas de venta con gerente, vendedores, y ~900 pedidos repartidos
en 18 meses con estacionalidad.

Se corre DENTRO de odoo shell (acceso directo al ORM, sin RPC). Desde la raíz
del repo:

    make seed

que equivale a:

    docker compose -f odoo/docker-compose.yml run --rm -T odoo \
      odoo shell -d demo --no-http < odoo/scripts/seed_sales.py

El -T es obligatorio: sin él, compose no conecta el stdin y el script no entra.

Requiere que `make localize` ya haya corrido: si la compañía no está en
Honduras, los departamentos se crean colgando del país equivocado.

Idempotente: si lo corrés dos veces, no duplica zonas ni vendedores, pero SÍ
agrega otra tanda de pedidos. Para empezar limpio, recreá la base.
"""

import random
from datetime import datetime, timedelta

random.seed(42)          # reproducible: la misma demo en cada máquina
N_PEDIDOS = 900
MESES_HISTORIA = 18

# --- Geografía --------------------------------------------------------------
# Odoo no trae departamentos de Honduras precargados, se crean acá.
DEPARTAMENTOS = [
    ("Cortés", "CR"), ("Francisco Morazán", "FM"), ("Atlántida", "AT"),
    ("Yoro", "YO"), ("Choluteca", "CH"), ("Comayagua", "CM"),
    ("Copán", "CP"), ("Olancho", "OL"), ("Santa Bárbara", "SB"),
    ("El Paraíso", "EP"), ("Valle", "VA"), ("La Paz", "LP"),
]

# Zona de venta -> departamentos que cubre. Esta es la jerarquía que después
# el gerente va a querer filtrar en el dashboard.
ZONAS = {
    "Zona Norte":      ["Cortés", "Yoro", "Atlántida", "Santa Bárbara"],
    "Zona Centro":     ["Francisco Morazán", "Comayagua", "La Paz"],
    "Zona Sur":        ["Choluteca", "Valle", "El Paraíso"],
    "Zona Occidente":  ["Copán", "Olancho"],
}

GERENTES = {
    "Zona Norte": "Marta Zelaya",
    "Zona Centro": "Rigoberto Andino",
    "Zona Sur": "Karla Núñez",
    "Zona Occidente": "Elder Mejía",
}

VENDEDORES = {
    "Zona Norte":     ["José Fúnez", "Dilcia Ramos", "Wilmer Cáceres"],
    "Zona Centro":    ["Ana Portillo", "Óscar Banegas"],
    "Zona Sur":       ["Suyapa Discua", "Nelson Rivera"],
    "Zona Occidente": ["Iris Perdomo", "Marvin Alvarado"],
}

# Estacionalidad: multiplicador de volumen por mes (dic y jun altos).
ESTACIONALIDAD = [0.8, 0.7, 0.9, 0.9, 1.0, 1.3, 1.0, 0.9, 0.9, 1.0, 1.2, 1.6]

# Con demo data, Odoo 19 crea varias compañías (San Francisco, Chicago, y una
# por localización instalada). `env.company` es la primera, que puede no ser la
# del país de la demo. Se elige por MONEDA: si hay una compañía en DEMO_CURRENCY
# con almacén, se usa esa; si no, se cae en env.company y se avisa.
DEMO_CURRENCY = "HNL"

def pick_company():
    candidates = env["res.company"].search([("currency_id.name", "=", DEMO_CURRENCY)])
    with_wh = candidates.filtered(
        lambda c: env["stock.warehouse"].search_count([("company_id", "=", c.id)])
    )
    if env.company in with_wh:
        return env.company
    if with_wh:
        return with_wh[0]
    if env.company.currency_id.name == DEMO_CURRENCY:
        return env.company
    print(f"AVISO: ninguna compañía en {DEMO_CURRENCY} con almacén. "
          f"Se usa {env.company.name} en {env.company.currency_id.name}. "
          f"El dashboard va a mostrar la moneda equivocada: revisá `make currency`.")
    return env.company

company = pick_company()
env = env(context=dict(env.context, allowed_company_ids=[company.id]))
hn = env.ref("base.hn")
print(f"Compañía: {company.name} | moneda {company.currency_id.name}")
if company.currency_id.name != DEMO_CURRENCY:
    print(f"  OJO: se esperaba {DEMO_CURRENCY}. Corré `make currency` antes de dar la demo.")

# --- 1. Departamentos -------------------------------------------------------
estados = {}
for nombre, codigo in DEPARTAMENTOS:
    est = env["res.country.state"].search(
        [("country_id", "=", hn.id), ("code", "=", codigo)], limit=1
    )
    if not est:
        est = env["res.country.state"].create(
            {"name": name, "code": codigo, "country_id": hn.id}
        )
    estados[nombre] = est
print(f"Departamentos listos: {len(estados)}")

# --- 2. Usuarios: gerentes y vendedores -------------------------------------
def get_user(name):
    login = name.lower().replace(" ", ".").replace("ó", "o").replace("é", "e") \
                          .replace("í", "i").replace("á", "a").replace("ú", "u") + "@demo.hn"
    u = env["res.users"].with_context(active_test=False).search(
        [("login", "=", login)], limit=1)
    if u:
        # Puede venir de una siembra anterior sobre OTRA compañía. Odoo prohíbe
        # el cruce, así que hay que darle acceso a esta y ponerla por defecto.
        if company not in u.company_ids:
            u.company_ids = [(4, company.id)]
        u.company_id = company
    else:
        u = env["res.users"].create({
            "name": name, "login": login, "password": "demo1234",
            "company_id": company.id, "company_ids": [(4, company.id)],
        })
        group = env.ref("sales_team.group_sale_salesman", raise_if_not_found=False)
        if group:
            # Odoo 19 renombró res.users.groups_id -> group_ids. Se resuelve
            # por introspección del ORM en vez de fijar una versión.
            campo = "group_ids" if "group_ids" in u._fields else "groups_id"
            u.write({campo: [(4, group.id)]})
    return u

# --- 3. Equipos de venta (zonas) --------------------------------------------
# Se setea team.user_id (el gerente) y se asigna team_id/user_id en el pedido.
# A propósito NO se tocan member_ids: ese campo cambió de forma entre versiones
# y no vale la pena acoplarse.
equipos, plantilla = {}, {}
for zona, deptos in ZONAS.items():
    gerente = get_user(GERENTES[zona])
    # Acotado por compañía: un equipo con el mismo nombre en otra compañía no
    # sirve, y usarlo dispara el error de cruce de compañías de Odoo.
    eq = env["crm.team"].search(
        [("name", "=", zona), ("company_id", "in", [company.id, False])], limit=1)
    if not eq:
        eq = env["crm.team"].create({
            "name": zona, "user_id": gerente.id, "company_id": company.id,
        })
    elif not eq.company_id:
        eq.company_id = company
    else:
        eq.user_id = gerente
    equipos[zona] = eq
    plantilla[zona] = [get_user(v) for v in VENDEDORES[zona]]
print(f"Zonas listas: {', '.join(equipos)}")

depto_a_zona = {d: z for z, ds in ZONAS.items() for d in ds}

# --- 4. Clientes repartidos por departamento --------------------------------
clientes = env["res.partner"].search([
    ("is_company", "=", True), ("customer_rank", ">", 0),
    ("company_id", "in", [company.id, False]),
], limit=120)
if len(clientes) < 20:   # la demo trae pocos: se completan
    faltan = 40 - len(clientes)
    nuevos = []
    for i in range(max(faltan, 0)):
        nuevos.append({
            "name": f"Distribuidora {random.choice(['La Ceiba','El Progreso','San Juan','Santa Rosa','Danlí','Tela'])} {i+1}",
            "is_company": True, "customer_rank": 1, "country_id": hn.id,
        })
    clientes |= env["res.partner"].create(nuevos)

for c in clientes:
    depto = random.choices(
        list(estados), weights=[4 if d in ("Cortés", "Francisco Morazán") else 1
                                for d in estados]
    )[0]
    c.write({"state_id": estados[depto].id, "country_id": hn.id})
print(f"Clientes con departamento asignado: {len(clientes)}")

# --- 5. Productos -----------------------------------------------------------
# company_id False = producto compartido entre compañías, que es lo normal en
# la demo data. Filtrar acá evita el cruce de compañías al crear las líneas.
productos = env["product.product"].search([
    ("sale_ok", "=", True),
    ("company_id", "in", [company.id, False]),
], limit=60)
if not productos:
    raise SystemExit(
        f"No hay productos vendibles para {company.name}. "
        f"¿Cargaste la demo data con --with-demo?")

# --- 5b. Inventario ---------------------------------------------------------
# La demo data de Odoo deja las existencias en OTRA compañía, así que la de la
# demo nace con el almacén vacío. Sin esto, Silver filtra por compañía y el
# inventario sale en cero: se cae la pregunta "¿qué se me va a acabar?", que es
# de las que mejor funcionan en vivo.
#
# Se siembran cantidades deliberadamente desparejas para que haya productos en
# riesgo real de quiebre y otros sobrados. Un inventario plano no cuenta nada.
almacen = env["stock.warehouse"].search([("company_id", "=", company.id)], limit=1)
if not almacen:
    raise SystemExit(
        f"{company.name} no tiene almacén. Corré `make company` antes del seed.")

ubicacion = almacen.lot_stock_id
existentes = env["stock.quant"].search_count([
    ("company_id", "=", company.id), ("location_id", "=", ubicacion.id),
])
if existentes:
    print(f"Inventario ya sembrado en {almacen.name}: {existentes} quants")
else:
    # Solo productos ALMACENABLES: Odoo rechaza quants para consumibles y
    # servicios ("Quants cannot be created for consumables or services").
    # Odoo 18 reemplazó type = 'product' por is_storable, así que se resuelve
    # por introspección en vez de fijar una versión.
    Producto = env["product.product"]
    if "is_storable" in Producto._fields:
        almacenables = productos.filtered(lambda p: p.is_storable)
    else:
        almacenables = productos.filtered(lambda p: p.type == "product")
    if not almacenables:
        print("  ningún producto almacenable: se omite la siembra de inventario")

    Quant = env["stock.quant"].with_context(inventory_mode=True)
    sembrados = 0
    for i, prod in enumerate(almacenables):
        # Perfil de existencias: ~1 de cada 6 productos queda escaso a
        # propósito, el resto en rangos normales.
        if i % 6 == 0:
            cantidad = random.randint(0, 8)        # riesgo de quiebre
        elif i % 6 == 1:
            cantidad = random.randint(9, 30)       # cobertura corta
        else:
            cantidad = random.randint(40, 400)     # sobrado
        quant = Quant.create({
            "product_id": prod.id,
            "location_id": ubicacion.id,
            "inventory_quantity": cantidad,
        })
        # En Odoo 17+ el ajuste se aplica con action_apply_inventory. Se
        # resuelve por introspección: el nombre cambió entre versiones.
        if hasattr(quant, "action_apply_inventory"):
            quant.action_apply_inventory()
        sembrados += 1
    env.cr.commit()
    print(f"Inventario sembrado en {almacen.name}: {sembrados} de "
          f"{len(productos)} productos (solo los almacenables)")

# --- 6. Pedidos -------------------------------------------------------------
# Se borra la tanda anterior (todas llevan client_order_ref = SEED-*) para que
# volver a sembrar dé el mismo resultado en vez de apilar otra tanda encima.
previos = env["sale.order"].search([("client_order_ref", "like", "SEED-%")])
if previos:
    print(f"Borrando {len(previos)} pedidos de una siembra anterior...")
    previos.filtered(lambda o: o.state == "sale")._action_cancel()
    previos.write({"state": "draft"})
    previos.unlink()
    env.cr.commit()

hoy = datetime.now()
inicio = hoy - timedelta(days=30 * MESES_HISTORIA)
creados, confirmados = 0, 0

for i in range(N_PEDIDOS):
    dias = random.randint(0, 30 * MESES_HISTORIA)
    fecha = inicio + timedelta(days=dias, hours=random.randint(8, 17))
    # estacionalidad: se descarta parte de los pedidos de meses flojos
    if random.random() > ESTACIONALIDAD[fecha.month - 1] / 1.6:
        continue

    cliente = random.choice(clientes)
    depto = cliente.state_id.name
    zona = depto_a_zona.get(depto, "Zona Centro")
    vendedor = random.choice(plantilla[zona])

    lineas = []
    for prod in random.sample(list(productos), random.randint(1, 4)):
        lineas.append((0, 0, {
            "product_id": prod.id,
            "product_uom_qty": random.choice([1, 2, 3, 5, 10, 12, 24]),
        }))

    pedido = env["sale.order"].create({
        "company_id": company.id,
        "partner_id": cliente.id,
        "user_id": vendedor.id,
        "team_id": equipos[zona].id,
        "client_order_ref": f"SEED-{i:05d}",
        "order_line": lineas,
    })
    creados += 1

    suerte = random.random()
    if suerte < 0.72:
        pedido.action_confirm()
        confirmados += 1
    elif suerte < 0.85:
        pass                      # queda en cotización
    else:
        pedido._action_cancel() if hasattr(pedido, "_action_cancel") else pedido.action_cancel()

    # OJO: action_confirm reescribe date_order con la fecha de hoy.
    # Hay que retrofechar DESPUÉS de confirmar o toda la historia se apila hoy.
    pedido.write({"date_order": fecha})

    if creados % 100 == 0:
        env.cr.commit()
        print(f"  {creados} pedidos...")

env.cr.commit()

print(f"\nListo: {creados} pedidos creados, {confirmados} confirmados")
print(f"Rango: {inicio.date()} a {hoy.date()}")
for zona, eq in equipos.items():
    n = env["sale.order"].search_count([("team_id", "=", eq.id)])
    print(f"  {zona:<16} {n:>4} pedidos   gerente: {eq.user_id.name}")
