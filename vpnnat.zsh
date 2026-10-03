#!/bin/zsh
# vpnnat - NAT de la subred de VMs (UTM / vmnet-shared) hacia los tuneles
# split-tunnel de Pritunl, via un anchor de pf propio.
#
# Uso: source este archivo desde ~/.zshrc (init.sh ya lo hace) y luego:
#   vpnnat setup            una sola vez: registra el anchor en /etc/pf.conf
#   vpnnat up               reconcilia el anchor con los tuneles activos
#   vpnnat down             deja solo la regla de la interfaz fisica
#   vpnnat status           estado actual vs estado deseado
#   vpnnat doctor           diagnostico de la matriz de fallas conocidas
#   vpnnat watch            reconcilia en loop ante cambios de red
#
# Ver `vpnnat help` para la lista completa.

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------

# Subredes de VMs. Vacio = autodetectar los bridges de vmnet-shared
# (bridgeN con un miembro vmenet*). Formato: ("192.168.64.0/24")
typeset -ga VPNNAT_VM_SUBNETS=()

# Gateways de tunel esperados. Vacio = aceptar cualquier utun con IPv4.
# Sirve para ignorar tuneles que no sean de Pritunl.
# Ej: (10.250.40.1 10.250.30.1 10.251.0.1)
typeset -ga VPNNAT_EXPECTED_GATEWAYS=()

# Alcance del NAT del tunel:
#   any     -> `to any` (la tabla de rutas ya decide que sale por el tunel)
#   routes  -> `to <tabla>` con las subredes que el tunel realmente anuncia
#   config  -> `to <tabla>` con VPNNAT_ALLOWED_NETS
typeset -g VPNNAT_SCOPE=any
typeset -ga VPNNAT_ALLOWED_NETS=()

# Bloquear explicitamente las subredes corporativas cuando no hay tunel,
# para que los intentos de la VM fallen rapido en vez de filtrarse al ISP.
# Usa las subredes vistas la ultima vez que hubo tunel (cache) o
# VPNNAT_CORP_NETS si esta definido.
typeset -g VPNNAT_BLOCK_WHEN_DOWN=0
typeset -ga VPNNAT_CORP_NETS=()

# Host de la VM para los chequeos de conectividad del doctor.
# VPNNAT_VM_SSH habilita el test "desde la VM" (requiere clave sin passphrase).
typeset -g VPNNAT_VM_HOST=192.168.64.2
typeset -g VPNNAT_VM_SSH=""

# Intervalo de polling de `watch` (segundos)
typeset -g VPNNAT_POLL_INTERVAL=30

# Prefijo a partir del cual una ruta anunciada por un tunel se considera
# sospechosamente amplia. Con VPNNAT_SCOPE=any la regla es `to any` y el
# alcance real lo decide la tabla de rutas del host: si un perfil empuja una
# default (o un /1-/7), TODO el trafico de la VM pasaria por esa VPN. 10/8 es
# una ruta corporativa legitima y comun, de ahi que el umbral sea 7 y no 8.
typeset -g VPNNAT_BROAD_PREFIX=7

# Rutas
typeset -g VPNNAT_ANCHOR=utm-vpn
typeset -g VPNNAT_ANCHOR_FILE=/etc/pf.anchors/utm-vpn
typeset -g VPNNAT_BLOCK_ANCHOR=utm-vpn-block
typeset -g VPNNAT_BLOCK_FILE=/etc/pf.anchors/utm-vpn-block
typeset -g VPNNAT_PF_CONF=/etc/pf.conf
typeset -g VPNNAT_STATE_DIR=/var/db/vpnnat
typeset -g VPNNAT_LOG=/var/log/vpnnat.log

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

# El log es root:wheel 0640 a proposito: registra lo que se hizo con
# privilegios, asi que el usuario que invoca no deberia poder reescribirlo.
# `vpnnat log` lo lee con sudo.
_vpnnat_log() {
  local line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$$] $*"
  if (( EUID == 0 )); then
    print -r -- "$line" >> "$VPNNAT_LOG" 2>/dev/null
  else
    print -r -- "$line" | _vpnnat_sudo tee -a "$VPNNAT_LOG" >/dev/null 2>&1
  fi
}

_vpnnat_say()  { print -r -- "$*" }
_vpnnat_warn() { print -ru2 -- "vpnnat: $*" }
_vpnnat_die()  { print -ru2 -- "vpnnat: $*"; return 1 }

# Marcadores de estado para status/doctor
_vpnnat_ok()   { print -r -- "  ok    $*" }
_vpnnat_bad()  { print -r -- "  FALLA $*" }
_vpnnat_info() { print -r -- "        $*" }

# Pide sudo de forma explicita antes de la primera operacion privilegiada
_vpnnat_need_root() {
  (( EUID == 0 )) && return 0
  if sudo -n true 2>/dev/null; then return 0; fi
  _vpnnat_say "vpnnat: se requieren privilegios de root para ${1:-esta operacion}."
  sudo -v || { _vpnnat_warn "sudo denegado, abortando"; return 1 }
}

_vpnnat_sudo() {
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

# chown/chmod/touch/tee siguen symlinks, asi que escribir con root sobre un path
# que resulte ser un link actuaria sobre el destino. Los directorios que usamos
# (/etc/pf.anchors, /var/db/vpnnat, /var/log) son root-only, asi que un usuario
# sin privilegios no puede plantar el link; esto cubre el caso de que alguien
# sobreescriba VPNNAT_LOG o VPNNAT_STATE_DIR hacia un lugar escribible.
_vpnnat_refuse_symlink() {
  [[ -L $1 ]] || return 0
  _vpnnat_warn "$1 es un symlink; me niego a escribir ahi con privilegios"
  return 1
}

# 0xffffff00 -> 24
_vpnnat_mask_to_prefix() {
  local x=$(( $1 )) n=0 i
  for (( i = 31; i >= 0; i-- )); do
    if (( (x >> i) & 1 )); then (( n++ )); else break; fi
  done
  print -r -- $n
}

# ip prefix -> red/prefijo
_vpnnat_net_of() {
  local ip=$1 pre=$2
  local -a o=(${(s:.:)ip})
  local v=$(( (o[1] << 24) | (o[2] << 16) | (o[3] << 8) | o[4] ))
  local mask=$(( pre == 0 ? 0 : (0xFFFFFFFF << (32 - pre)) & 0xFFFFFFFF ))
  local n=$(( v & mask ))
  print -r -- "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))/$pre"
}

# netstat abrevia los destinos: 10.60/20 -> 10.60.0.0/20, 192.168.20 -> 192.168.20.0/24
_vpnnat_norm_cidr() {
  local s=$1 host pre
  host=${s%%/*}
  if [[ $s == */* ]]; then pre=${s##*/}; else pre=""; fi
  local -a o=(${(s:.:)host})
  local present=${#o}
  while (( ${#o} < 4 )); do o+=(0); done
  [[ -n $pre ]] || pre=$(( present * 8 ))
  print -r -- "${(j:.:)o}/$pre"
}

# ---------------------------------------------------------------------------
# Deteccion
# ---------------------------------------------------------------------------

# Lineas "iface<TAB>red/prefijo" de cada bridge de vmnet-shared
_vpnnat_vm_bridges() {
  if (( ${#VPNNAT_VM_SUBNETS} )); then
    local n
    for n in $VPNNAT_VM_SUBNETS; do printf '%s\t%s\n' - "$n"; done
    return 0
  fi
  local b info ip mask pre
  for b in ${(f)"$(ifconfig -l | tr ' ' '\n' | grep -E '^bridge[0-9]+$')"}; do
    info=$(ifconfig $b 2>/dev/null) || continue
    # vmnet-shared mete la interfaz de la VM (vmenet*) como miembro del bridge
    [[ $info == *"member: vmenet"* ]] || continue
    ip=$(print -r -- "$info"   | awk '$1=="inet"{print $2; exit}')
    mask=$(print -r -- "$info" | awk '$1=="inet"{print $4; exit}')
    [[ -n $ip && -n $mask ]] || continue
    pre=$(_vpnnat_mask_to_prefix $mask)
    printf '%s\t%s\n' "$b" "$(_vpnnat_net_of $ip $pre)"
  done
}

_vpnnat_vm_subnets() {
  local -a nets
  nets=(${(f)"$(_vpnnat_vm_bridges | cut -f2)"})
  (( ${#nets} )) && print -rl -- ${(u)nets}
}

# Gateway de un tunel: el mas frecuente entre sus rutas con flag G
_vpnnat_tunnel_gw() {
  netstat -rn -f inet 2>/dev/null | awk -v i=$1 '
    $4 == i && $3 ~ /G/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { c[$2]++ }
    END { m = 0; for (g in c) if (c[g] > m) { m = c[g]; b = g } if (m) print b }'
}

# Subredes que anuncia un tunel
_vpnnat_tunnel_nets() {
  local d
  for d in ${(f)"$(netstat -rn -f inet 2>/dev/null | awk -v i=$1 '$4 == i && $3 ~ /^UG/ && $1 != "default" { print $1 }')"}; do
    [[ $d == *:* ]] && continue
    _vpnnat_norm_cidr $d
  done
}

# Tuneles activos: utun* con IPv4. Los utun de macOS (iCloud Private Relay y
# compania) solo tienen fe80:: link-local, asi que quedan afuera.
_vpnnat_tunnels() {
  local i ip gw
  for i in ${(f)"$(ifconfig -l | tr ' ' '\n' | grep -E '^utun[0-9]+$')"}; do
    ip=$(ifconfig $i 2>/dev/null | awk '$1=="inet"{print $2; exit}')
    [[ -n $ip ]] || continue
    ifconfig $i 2>/dev/null | head -1 | grep -q RUNNING || continue
    if (( ${#VPNNAT_EXPECTED_GATEWAYS} )); then
      gw=$(_vpnnat_tunnel_gw $i)
      [[ -n $gw ]] && (( ${VPNNAT_EXPECTED_GATEWAYS[(Ie)$gw]} )) || continue
    fi
    print -r -- $i
  done
}

# Rutas anunciadas por un tunel que son lo bastante amplias como para cambiar
# el sentido de la regla `to any`: una default explicita, o un prefijo <= umbral.
_vpnnat_broad_routes() {
  local t=$1 d pre
  netstat -rn -f inet 2>/dev/null | awk -v i=$t '$1 == "default" && $4 == i { print "0.0.0.0/0" }'
  for d in ${(f)"$(_vpnnat_tunnel_nets $t)"}; do
    pre=${d##*/}
    (( pre <= VPNNAT_BROAD_PREFIX )) && print -r -- "$d"
  done
}

# Interfaz por la que sale la ruta default
_vpnnat_phys_iface() {
  local i c
  i=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
  if [[ -n $i && $i != utun* && $i != bridge* ]]; then
    print -r -- $i; return 0
  fi
  # La default pasa por un tunel (full-tunnel) o por el bridge: buscar la fisica
  for c in ${(f)"$(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$')"}; do
    ifconfig $c 2>/dev/null | grep -q 'status: active' || continue
    ifconfig $c 2>/dev/null | awk '$1=="inet"{f=1} END{exit !f}' || continue
    print -r -- $c; return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Generacion del estado deseado
# ---------------------------------------------------------------------------

# Subredes a las que se restringe el NAT de un tunel (modo routes/config)
_vpnnat_scope_nets() {
  local tun=$1
  case $VPNNAT_SCOPE in
    routes) _vpnnat_tunnel_nets $tun ;;
    config) (( ${#VPNNAT_ALLOWED_NETS} )) && print -rl -- $VPNNAT_ALLOWED_NETS ;;
  esac
}

# Contenido deseado del anchor de NAT. Sin timestamp: el archivo se compara
# textualmente para decidir si hace falta recargar.
_vpnnat_desired_nat() {
  local -a vms tuns
  vms=(${(f)"$(_vpnnat_vm_subnets)"})
  tuns=(${(f)"$(_vpnnat_tunnels)"})
  local phys; phys=$(_vpnnat_phys_iface)

  (( ${#vms} )) || { _vpnnat_warn "no encuentro ninguna subred de VMs (bridge de vmnet-shared)"; return 1 }
  [[ -n $phys ]] || { _vpnnat_warn "no puedo determinar la interfaz fisica de la ruta default"; return 1 }

  local src="{ ${(j:, :)vms} }"

  print -r -- "# vpnnat: generado automaticamente, no editar a mano"
  print -r -- "# vm=${(j:,:)vms} phys=$phys tunnels=${${(j:,:)tuns}:--} scope=$VPNNAT_SCOPE"

  # En pf gana la PRIMERA regla de traduccion que matchea, pero cada regla
  # esta acotada con `on <iface>` asi que no se solapan. El orden es solo
  # para que el diff sea estable.
  local t
  local -a nets
  for t in $tuns; do
    nets=(${(f)"$(_vpnnat_scope_nets $t)"})
    if [[ $VPNNAT_SCOPE != any ]] && (( ${#nets} )); then
      print -r -- "table <vpnnat_${t}> persist { ${(j:, :)nets} }"
      print -r -- "nat on $t from $src to <vpnnat_${t}> -> ($t)"
    else
      print -r -- "nat on $t from $src to any -> ($t)"
    fi
  done

  # Red de seguridad: sin esta regla la VM pierde internet cuando se recarga
  # pf.conf completo y se van los anchors que vmnet instala en runtime.
  print -r -- "nat on $phys from $src to any -> ($phys)"
}

# Igual pero sin reglas de tunel (para `down`)
_vpnnat_desired_nat_physonly() {
  local -a vms
  vms=(${(f)"$(_vpnnat_vm_subnets)"})
  local phys; phys=$(_vpnnat_phys_iface)
  (( ${#vms} )) || { _vpnnat_warn "no encuentro ninguna subred de VMs"; return 1 }
  [[ -n $phys ]] || { _vpnnat_warn "no puedo determinar la interfaz fisica"; return 1 }
  local src="{ ${(j:, :)vms} }"
  print -r -- "# vpnnat: generado automaticamente, no editar a mano"
  print -r -- "# vm=${(j:,:)vms} phys=$phys tunnels=- scope=$VPNNAT_SCOPE"
  print -r -- "nat on $phys from $src to any -> ($phys)"
}

# Subredes corporativas conocidas (cache de la ultima vez que hubo tunel)
_vpnnat_corp_cache_file() { print -r -- "$VPNNAT_STATE_DIR/corp-nets" }

_vpnnat_save_corp_cache() {
  local -a tuns nets t
  tuns=(${(f)"$(_vpnnat_tunnels)"})
  for t in $tuns; do nets+=(${(f)"$(_vpnnat_tunnel_nets $t)"}); done
  (( ${#nets} )) || return 0
  _vpnnat_sudo mkdir -p "$VPNNAT_STATE_DIR" 2>/dev/null
  local cf; cf=$(_vpnnat_corp_cache_file)
  _vpnnat_refuse_symlink "$cf" || return 1
  print -rl -- ${(u)nets} | _vpnnat_sudo tee "$cf" >/dev/null
}

_vpnnat_corp_nets() {
  if (( ${#VPNNAT_CORP_NETS} )); then print -rl -- $VPNNAT_CORP_NETS; return 0; fi
  local f; f=$(_vpnnat_corp_cache_file)
  [[ -r $f ]] && grep -E '^[0-9]' "$f"
}

# Contenido deseado del anchor de filtrado (bloqueo cuando no hay tunel)
# _vpnnat_desired_block [force-down]
_vpnnat_desired_block() {
  local force=${1:-0}
  print -r -- "# vpnnat: generado automaticamente, no editar a mano"
  (( VPNNAT_BLOCK_WHEN_DOWN )) || { print -r -- "# bloqueo desactivado (VPNNAT_BLOCK_WHEN_DOWN=0)"; return 0 }
  local -a tuns
  (( force )) || tuns=(${(f)"$(_vpnnat_tunnels)"})
  if (( ${#tuns} )); then
    print -r -- "# hay tuneles activos (${(j:,:)tuns}): sin bloqueo"
    return 0
  fi
  local -a nets; nets=(${(f)"$(_vpnnat_corp_nets)"})
  if (( ! ${#nets} )); then
    print -r -- "# sin tuneles y sin cache de subredes corporativas: sin bloqueo"
    return 0
  fi
  print -r -- "table <vpnnat_corp> persist { ${(j:, :)nets} }"
  local line iface net
  _vpnnat_vm_bridges | while IFS=$'\t' read -r iface net; do
    if [[ $iface == - ]]; then
      print -r -- "block return in from $net to <vpnnat_corp>"
    else
      print -r -- "block return in on $iface from $net to <vpnnat_corp>"
    fi
  done
}

# ---------------------------------------------------------------------------
# Lectura del estado cargado en pf
# ---------------------------------------------------------------------------

_vpnnat_pf_enabled() {
  _vpnnat_sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'
}

_vpnnat_forwarding_on() {
  [[ $(sysctl -n net.inet.ip.forwarding 2>/dev/null) == 1 ]]
}

_vpnnat_anchor_registered() {
  grep -qE "^[[:space:]]*nat-anchor[[:space:]]+\"$VPNNAT_ANCHOR\"" "$VPNNAT_PF_CONF" 2>/dev/null
}

_vpnnat_block_anchor_registered() {
  grep -qE "^[[:space:]]*anchor[[:space:]]+\"$VPNNAT_BLOCK_ANCHOR\"" "$VPNNAT_PF_CONF" 2>/dev/null
}

_vpnnat_loaded_nat() {
  _vpnnat_sudo pfctl -a "$VPNNAT_ANCHOR" -s nat 2>/dev/null
}

# Interfaces que aparecen en las reglas NAT cargadas (para detectar flush o utun viejo)
_vpnnat_loaded_nat_ifaces() {
  _vpnnat_loaded_nat | awk '{ for (i = 1; i <= NF; i++) if ($i == "on") { print $(i+1); break } }' | sort -u
}

_vpnnat_desired_nat_ifaces() {
  local -a tuns; tuns=(${(f)"$(_vpnnat_tunnels)"})
  local phys; phys=$(_vpnnat_phys_iface)
  { (( ${#tuns} )) && print -rl -- $tuns; [[ -n $phys ]] && print -r -- $phys } | sort -u
}

# ---------------------------------------------------------------------------
# Aplicacion
# ---------------------------------------------------------------------------

# Escribe un anchor si cambio. Devuelve 0 si escribio, 1 si ya estaba igual.
_vpnnat_write_if_changed() {
  local file=$1 content=$2
  _vpnnat_refuse_symlink "$file" || return 2
  if [[ -r $file ]] && [[ "$(cat "$file")" == "$content" ]]; then return 1; fi
  print -r -- "$content" | _vpnnat_sudo tee "$file" >/dev/null || return 2
  return 0
}

# pfctl escupe a stderr ruido inevitable: el aviso de ALTQ y, con -f, una
# advertencia sobre flushear el ruleset principal que NO aplica cuando se usa
# -a <anchor> (verificado: con -a solo se reemplaza ese anchor).
_vpnnat_pfctl_noise() {
  grep -vE 'ALTQ|Use of -f option|^present in the main ruleset|^See /etc/pf\.conf for further details|^$'
}

# Recarga SOLO el anchor, sin tocar el resto del ruleset.
# `pfctl -f /etc/pf.conf` hace flush completo y borra los anchors que vmnet
# instala en runtime (verificado: com.apple.internet-sharing solo existe en
# runtime, no en pf.conf), por eso el flush completo solo se usa en `setup`.
_vpnnat_load_anchor() {
  local anchor=$1 file=$2
  _vpnnat_sudo pfctl -a "$anchor" -f "$file" 2>&1 | _vpnnat_pfctl_noise >&2
  return ${pipestatus[1]}
}

_vpnnat_pf_enable() {
  if _vpnnat_pf_enabled; then return 0; fi
  # -E usa un contador de referencias: guardamos el token para poder liberarlo
  # y no pisar a otra herramienta que tambien tenga pf habilitado.
  local out token
  out=$(_vpnnat_sudo pfctl -E 2>&1)
  token=$(print -r -- "$out" | awk '/Token/ { print $NF }')
  if [[ -n $token ]]; then
    _vpnnat_sudo mkdir -p "$VPNNAT_STATE_DIR" 2>/dev/null
    if _vpnnat_refuse_symlink "$VPNNAT_STATE_DIR/pf-token"; then
      print -r -- "$token" | _vpnnat_sudo tee "$VPNNAT_STATE_DIR/pf-token" >/dev/null
    fi
    _vpnnat_log "pf habilitado (token $token)"
  fi
  _vpnnat_pf_enabled
}

# El log registra acciones privilegiadas, asi que no deberia ser reescribible
# por el usuario que las invoca. Idempotente y barato: solo actua si hace falta.
_vpnnat_harden_log() {
  _vpnnat_refuse_symlink "$VPNNAT_LOG" || return 1
  if [[ ! -e $VPNNAT_LOG ]]; then
    if ! _vpnnat_sudo touch "$VPNNAT_LOG" 2>/dev/null; then
      _vpnnat_warn "no pude crear $VPNNAT_LOG: las acciones privilegiadas no quedan registradas"
      return 1
    fi
  elif [[ $(stat -f '%u %Lp' "$VPNNAT_LOG" 2>/dev/null) == "0 640" ]]; then
    return 0
  fi
  if ! _vpnnat_sudo chown root:wheel "$VPNNAT_LOG" 2>/dev/null \
  || ! _vpnnat_sudo chmod 640 "$VPNNAT_LOG" 2>/dev/null; then
    _vpnnat_warn "no pude endurecer $VPNNAT_LOG a root:wheel 0640"
    return 1
  fi
}

_vpnnat_forwarding_enable() {
  _vpnnat_forwarding_on && return 0
  _vpnnat_sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null && _vpnnat_log "forwarding habilitado"
}

# Mata los states de la subred de la VM: al cambiar de tunel quedan entradas
# viejas asociadas al utun anterior.
# Verificado: pfctl -k acepta red/prefijo ("killed N states from 1 sources"),
# asi que no hace falta iterar host por host. El fallback a IP suelta queda
# por si una version futura de pfctl deja de aceptar el CIDR.
_vpnnat_kill_states() {
  local -a vms; vms=(${(f)"$(_vpnnat_vm_subnets)"})
  local n
  for n in $vms; do
    _vpnnat_sudo pfctl -k "$n" >/dev/null 2>&1 \
      || _vpnnat_sudo pfctl -k "${n%%/*}" >/dev/null 2>&1
  done
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

_vpnnat_cmd_setup() {
  _vpnnat_need_root "registrar el anchor en $VPNNAT_PF_CONF" || return 1

  [[ -r $VPNNAT_PF_CONF ]] || { _vpnnat_die "no existe $VPNNAT_PF_CONF"; return 1 }

  _vpnnat_sudo mkdir -p "$VPNNAT_STATE_DIR"
  _vpnnat_harden_log

  # Los archivos de anchor tienen que existir antes de que pfctl lea pf.conf.
  # Se escribe ya el contenido definitivo (con los tuneles actuales) para que
  # la recarga completa que viene abajo levante el ruleset bueno de una sola
  # vez, en vez de dejar a la VM sin acceso corporativo hasta el `up` final.
  local initial
  initial=$(_vpnnat_desired_nat 2>/dev/null) || initial=$(_vpnnat_desired_nat_physonly 2>/dev/null)
  if [[ -n $initial ]]; then
    print -r -- "$initial" | _vpnnat_sudo tee "$VPNNAT_ANCHOR_FILE" >/dev/null
  elif [[ ! -r $VPNNAT_ANCHOR_FILE ]]; then
    _vpnnat_sudo touch "$VPNNAT_ANCHOR_FILE"
  fi
  _vpnnat_desired_block | _vpnnat_sudo tee "$VPNNAT_BLOCK_FILE" >/dev/null

  local changed=0
  if ! _vpnnat_anchor_registered || ! _vpnnat_block_anchor_registered; then
    local backup="$VPNNAT_PF_CONF.vpnnat-backup-$(date +%Y%m%d%H%M%S)"
    _vpnnat_sudo cp "$VPNNAT_PF_CONF" "$backup" || { _vpnnat_die "no pude hacer backup"; return 1 }
    _vpnnat_say "backup de pf.conf en $backup"

    local tmp; tmp=$(mktemp -t vpnnat-pfconf) || return 1
    # pf exige el orden: scrub -> traduccion (nat/rdr) -> dummynet -> filtrado.
    # El nat-anchor va despues del ultimo nat/rdr-anchor; el de filtrado,
    # despues del ultimo `anchor` de filtrado.
    awk -v na="$VPNNAT_ANCHOR" -v nf="$VPNNAT_ANCHOR_FILE" \
        -v ba="$VPNNAT_BLOCK_ANCHOR" -v bf="$VPNNAT_BLOCK_FILE" '
      { lines[NR] = $0
        if ($0 ~ /^[[:space:]]*(nat|rdr)-anchor[[:space:]]/) lastnat = NR
        if ($0 ~ /^[[:space:]]*anchor[[:space:]]/)           lastflt = NR
        if ($0 ~ "nat-anchor[[:space:]]+\"" na "\"")         havenat = 1
        if ($0 ~ "^[[:space:]]*anchor[[:space:]]+\"" ba "\"") haveflt = 1
      }
      END {
        for (i = 1; i <= NR; i++) {
          print lines[i]
          if (i == lastnat && !havenat) {
            print ""
            print "# vpnnat: NAT de la subred de VMs hacia los tuneles VPN"
            print "nat-anchor \"" na "\""
            print "load anchor \"" na "\" from \"" nf "\""
          }
          if (i == lastflt && !haveflt) {
            print ""
            print "# vpnnat: bloqueo de subredes corporativas cuando no hay tunel"
            print "anchor \"" ba "\""
            print "load anchor \"" ba "\" from \"" bf "\""
          }
        }
      }' "$VPNNAT_PF_CONF" > "$tmp" || { rm -f "$tmp"; return 1 }

    # El awk ancla la insercion en la ultima linea nat-anchor/rdr-anchor y en
    # la ultima linea `anchor`. Si un pf.conf no tuviera ninguna, el reescrito
    # saldria identico al original y el fallo recien se notaria en el `up`
    # siguiente. Chequear el resultado para fallar aca, ruidosamente.
    if ! grep -qE "^[[:space:]]*nat-anchor[[:space:]]+\"$VPNNAT_ANCHOR\"" "$tmp" \
    || ! grep -qE "^[[:space:]]*anchor[[:space:]]+\"$VPNNAT_BLOCK_ANCHOR\"" "$tmp"; then
      _vpnnat_warn "no encontre donde anclar los anchors en $VPNNAT_PF_CONF:"
      _vpnnat_warn "no tiene ninguna linea nat-anchor/rdr-anchor ni anchor."
      _vpnnat_warn "candidato en $tmp; no toco $VPNNAT_PF_CONF"
      return 1
    fi

    # Validar ANTES de instalar: si el orden quedo mal, pfctl -n lo dice
    _vpnnat_sudo pfctl -n -f "$tmp" 2>&1 | _vpnnat_pfctl_noise >&2
    if (( pipestatus[1] != 0 )); then
      _vpnnat_warn "la validacion de pfctl fallo, no toco $VPNNAT_PF_CONF"
      _vpnnat_warn "candidato guardado en $tmp para inspeccion"
      return 1
    fi
    _vpnnat_sudo cp "$tmp" "$VPNNAT_PF_CONF" && rm -f "$tmp"
    changed=1
    _vpnnat_say "anchors registrados en $VPNNAT_PF_CONF"
  else
    _vpnnat_say "anchors ya registrados en $VPNNAT_PF_CONF"
  fi

  if (( changed )); then
    # El unico lugar donde se recarga pf.conf completo.
    _vpnnat_say "recargando pf.conf completo (unica vez)"
    _vpnnat_warn "esto flushea el ruleset principal: los anchors que vmnet instala"
    _vpnnat_warn "en runtime desaparecen. La regla de la interfaz fisica que sigue"
    _vpnnat_warn "es la que mantiene el internet de la VM."
    _vpnnat_sudo pfctl -f "$VPNNAT_PF_CONF" 2>&1 | _vpnnat_pfctl_noise >&2
    _vpnnat_log "setup: pf.conf recargado completo"
  fi

  _vpnnat_cmd_up
}

_vpnnat_cmd_up() {
  _vpnnat_need_root "aplicar las reglas de NAT" || return 1

  local -a tuns; tuns=(${(f)"$(_vpnnat_tunnels)"})
  local rc=0

  if ! _vpnnat_anchor_registered; then
    _vpnnat_warn "el anchor \"$VPNNAT_ANCHOR\" no esta registrado en $VPNNAT_PF_CONF."
    _vpnnat_warn "corre 'vpnnat setup' primero."
    return 1
  fi

  local nat_content
  if (( ${#tuns} )); then
    nat_content=$(_vpnnat_desired_nat) || return 1
    _vpnnat_save_corp_cache
  else
    _vpnnat_warn "no hay ningun tunel VPN activo (ningun utun con IPv4)."
    _vpnnat_warn "aplico solo la regla de la interfaz fisica para que la VM conserve internet."
    nat_content=$(_vpnnat_desired_nat_physonly) || return 1
    rc=1
  fi

  local block_content; block_content=$(_vpnnat_desired_block)

  # Reconciliacion por diff: no recargar si ya esta correcto
  local nat_changed=0 block_changed=0 w
  _vpnnat_write_if_changed "$VPNNAT_ANCHOR_FILE" "$nat_content"; w=$?
  (( w == 0 )) && nat_changed=1
  (( w == 2 )) && { _vpnnat_warn "no pude escribir $VPNNAT_ANCHOR_FILE"; return 1 }
  _vpnnat_write_if_changed "$VPNNAT_BLOCK_FILE" "$block_content"; w=$?
  (( w == 0 )) && block_changed=1
  (( w == 2 )) && _vpnnat_warn "no pude escribir $VPNNAT_BLOCK_FILE"

  # Tambien recargar si el ruleset cargado no coincide con el archivo
  # (otra herramienta pudo hacer flush de pf)
  local want have
  want=$(_vpnnat_desired_nat_ifaces)
  have=$(_vpnnat_loaded_nat_ifaces)
  if (( ${#tuns} )) && [[ $want != $have ]]; then nat_changed=1; fi
  if (( ! ${#tuns} )) && [[ -n $(_vpnnat_loaded_nat | grep -E 'on utun') ]]; then nat_changed=1; fi

  _vpnnat_harden_log
  _vpnnat_forwarding_enable
  _vpnnat_pf_enable || _vpnnat_warn "no pude habilitar pf"

  if (( nat_changed )); then
    _vpnnat_load_anchor "$VPNNAT_ANCHOR" "$VPNNAT_ANCHOR_FILE" \
      && _vpnnat_log "anchor $VPNNAT_ANCHOR recargado: tuneles=${${(j:,:)tuns}:--} phys=$(_vpnnat_phys_iface)" \
      || { _vpnnat_warn "fallo la carga del anchor $VPNNAT_ANCHOR"; return 1 }
    _vpnnat_kill_states
    _vpnnat_say "anchor actualizado (tuneles: ${${(j:, :)tuns}:-ninguno})"
  else
    _vpnnat_say "sin cambios (tuneles: ${${(j:, :)tuns}:-ninguno})"
  fi

  if (( block_changed )); then
    _vpnnat_load_anchor "$VPNNAT_BLOCK_ANCHOR" "$VPNNAT_BLOCK_FILE" \
      && _vpnnat_log "anchor $VPNNAT_BLOCK_ANCHOR recargado"
  fi

  return $rc
}

_vpnnat_cmd_down() {
  _vpnnat_need_root "quitar las reglas de tunel" || return 1
  local content; content=$(_vpnnat_desired_nat_physonly) || return 1
  _vpnnat_write_if_changed "$VPNNAT_ANCHOR_FILE" "$content"
  _vpnnat_load_anchor "$VPNNAT_ANCHOR" "$VPNNAT_ANCHOR_FILE" || return 1
  _vpnnat_kill_states
  local block; block=$(_vpnnat_desired_block 1)
  _vpnnat_write_if_changed "$VPNNAT_BLOCK_FILE" "$block" \
    && _vpnnat_load_anchor "$VPNNAT_BLOCK_ANCHOR" "$VPNNAT_BLOCK_FILE"
  _vpnnat_log "down: solo regla de interfaz fisica"
  _vpnnat_say "reglas de tunel quitadas; queda la de $(_vpnnat_phys_iface)"
}

_vpnnat_cmd_status() {
  _vpnnat_need_root "leer el estado de pf" || return 1
  local -a tuns vms
  tuns=(${(f)"$(_vpnnat_tunnels)"})
  vms=(${(f)"$(_vpnnat_vm_subnets)"})
  local phys; phys=$(_vpnnat_phys_iface)

  print -r -- "== Entorno =="
  _vpnnat_info "interfaz fisica (ruta default): ${phys:-?}"
  _vpnnat_info "subredes de VMs: ${${(j:, :)vms}:-ninguna detectada}"
  _vpnnat_vm_bridges | while IFS=$'\t' read -r i n; do _vpnnat_info "  bridge $i -> $n"; done
  print

  print -r -- "== Tuneles activos =="
  if (( ! ${#tuns} )); then
    _vpnnat_info "ninguno (ningun utun con IPv4)"
  else
    local t broad
    for t in $tuns; do
      _vpnnat_info "$t  ip=$(ifconfig $t | awk '$1=="inet"{print $2; exit}')  gw=${$(_vpnnat_tunnel_gw $t):--}  rutas=$(_vpnnat_tunnel_nets $t | wc -l | tr -d ' ')"
      broad=$(_vpnnat_broad_routes $t | paste -sd, -)
      [[ -n $broad && $VPNNAT_SCOPE == any ]] && \
        _vpnnat_bad "  $t anuncia $broad con scope=any: todo el trafico de la VM hacia ahi sale por este tunel"
    done
  fi
  print

  print -r -- "== pf =="
  if _vpnnat_pf_enabled; then _vpnnat_ok "pf habilitado"; else _vpnnat_bad "pf deshabilitado"; fi
  if _vpnnat_forwarding_on; then _vpnnat_ok "net.inet.ip.forwarding=1"; else _vpnnat_bad "net.inet.ip.forwarding=0"; fi
  if _vpnnat_anchor_registered; then _vpnnat_ok "nat-anchor \"$VPNNAT_ANCHOR\" en pf.conf"; else _vpnnat_bad "nat-anchor \"$VPNNAT_ANCHOR\" AUSENTE de pf.conf"; fi
  if _vpnnat_block_anchor_registered; then _vpnnat_ok "anchor \"$VPNNAT_BLOCK_ANCHOR\" en pf.conf"; else _vpnnat_info "anchor \"$VPNNAT_BLOCK_ANCHOR\" no registrado (opcional)"; fi
  print

  print -r -- "== Reglas cargadas en el anchor =="
  local loaded; loaded=$(_vpnnat_loaded_nat)
  if [[ -z $loaded ]]; then _vpnnat_info "(vacio)"; else print -r -- "$loaded" | sed 's/^/        /'; fi
  print

  print -r -- "== Reglas que deberian estar =="
  local want; want=$(_vpnnat_desired_nat 2>/dev/null) || want=$(_vpnnat_desired_nat_physonly 2>/dev/null)
  print -r -- "$want" | grep -v '^#' | sed 's/^/        /'
  print

  local w h
  w=$(_vpnnat_desired_nat_ifaces)
  h=$(_vpnnat_loaded_nat_ifaces)
  if [[ $w == $h ]]; then
    _vpnnat_ok "el conjunto de interfaces coincide: ${${(j:, :)${(f)w}}:-ninguna}"
  else
    _vpnnat_bad "desincronizado: cargado=${${(j:,:)${(f)h}}:--} deseado=${${(j:,:)${(f)w}}:--}"
    _vpnnat_info "corre 'vpnnat up'"
  fi
}

_vpnnat_cmd_doctor() {
  _vpnnat_need_root "leer el estado de pf" || return 1
  local -a fixes
  local -a tuns vms
  tuns=(${(f)"$(_vpnnat_tunnels)"})
  vms=(${(f)"$(_vpnnat_vm_subnets)"})
  local phys; phys=$(_vpnnat_phys_iface)

  print -r -- "== 1. Registro del anchor en pf.conf =="
  if _vpnnat_anchor_registered; then
    _vpnnat_ok "nat-anchor \"$VPNNAT_ANCHOR\" presente"
  else
    _vpnnat_bad "nat-anchor \"$VPNNAT_ANCHOR\" ausente: una actualizacion de macOS pudo pisar pf.conf"
    _vpnnat_info "arreglo: vpnnat setup"
    fixes+=("vpnnat up")
  fi
  if [[ -r $VPNNAT_ANCHOR_FILE ]]; then
    _vpnnat_ok "$VPNNAT_ANCHOR_FILE existe"
  else
    _vpnnat_bad "$VPNNAT_ANCHOR_FILE no existe"; fixes+=("vpnnat up")
  fi

  print -r -- "== 2. pf habilitado =="
  if _vpnnat_pf_enabled; then
    _vpnnat_ok "pf habilitado"
  else
    _vpnnat_bad "pf deshabilitado: reinicio del Mac, o otra herramienta corrio pfctl -d/-X"
    _vpnnat_info "arreglo: vpnnat up"
    fixes+=("vpnnat up")
  fi

  print -r -- "== 3. IP forwarding =="
  if _vpnnat_forwarding_on; then
    _vpnnat_ok "net.inet.ip.forwarding=1"
  else
    _vpnnat_bad "forwarding apagado: no sobrevive al reinicio"
    _vpnnat_info "arreglo: vpnnat up"
    fixes+=("vpnnat up")
  fi

  print -r -- "== 4. Subred de la VM =="
  if (( ${#vms} )); then
    _vpnnat_ok "detectada: ${(j:, :)vms}"
    local inrule
    inrule=$(_vpnnat_loaded_nat | sed -n 's/.*from \([0-9][0-9.\/]*\).*/\1/p' | sort -u)
    local v
    for v in $vms; do
      if [[ -n $inrule ]] && ! print -r -- "$inrule" | grep -q "${v%%/*}"; then
        _vpnnat_bad "la regla cargada no cubre $v: bridge recreado con otra subred?"
        fixes+=("vpnnat up")
      fi
    done
  else
    _vpnnat_bad "ninguna: UTM apagado, o el bridge de vmnet no esta levantado"
    fixes+=("vpnnat up")
  fi

  print -r -- "== 5. Tuneles vs reglas cargadas =="
  local -a loaded_ifaces; loaded_ifaces=(${(f)"$(_vpnnat_loaded_nat_ifaces)"})
  local i
  for i in $loaded_ifaces; do
    [[ $i == utun* ]] || continue
    if (( ${tuns[(Ie)$i]} )); then
      _vpnnat_ok "regla sobre $i, que existe y tiene IPv4"
    else
      _vpnnat_bad "regla sobre $i, que ya no es un tunel activo (regla inerte)"
      _vpnnat_info "arreglo: vpnnat up"
      fixes+=("vpnnat up")
    fi
  done
  for i in $tuns; do
    if (( ! ${loaded_ifaces[(Ie)$i]} )); then
      _vpnnat_bad "tunel $i activo (gw $(_vpnnat_tunnel_gw $i)) SIN regla de NAT"
      _vpnnat_info "arreglo: vpnnat up"
      fixes+=("vpnnat up")
    fi
  done
  (( ${#tuns} )) || _vpnnat_info "no hay tuneles activos: el VPN esta desconectado"

  print -r -- "== 6. Interfaz fisica =="
  if [[ -z $phys ]]; then
    _vpnnat_bad "no puedo determinar la interfaz de la ruta default"; fixes+=("vpnnat up")
  elif (( ${loaded_ifaces[(Ie)$phys]} )); then
    _vpnnat_ok "la regla de respaldo apunta a $phys, que es la de la default"
  else
    _vpnnat_bad "la default sale por $phys pero la regla de respaldo apunta a ${${(M)loaded_ifaces:#en*}:-ninguna}"
    _vpnnat_info "cambio de red fisica. arreglo: vpnnat up"
    fixes+=("vpnnat up")
  fi

  print -r -- "== 7. NAT propio de vmnet en el ruleset principal =="
  # com.apple.internet-sharing es el anchor que vmnet instala en runtime y que
  # NO esta en /etc/pf.conf: un `pfctl -f /etc/pf.conf` lo borra. Es la trampa
  # que dejo la VM sin internet.
  local main_nat; main_nat=$(_vpnnat_sudo pfctl -s nat 2>/dev/null)
  if print -r -- "$main_nat" | grep -q 'com.apple.internet-sharing'; then
    _vpnnat_ok "nat-anchor \"com.apple.internet-sharing\" presente (vmnat intacto)"
  elif (( ${#vms} )); then
    _vpnnat_bad "nat-anchor \"com.apple.internet-sharing\" ausente del ruleset principal"
    _vpnnat_info "alguien hizo flush completo de pf. El internet de la VM depende"
    _vpnnat_info "solo de nuestra regla sobre $phys. Para recuperarlo: reinicia la red"
    _vpnnat_info "de la VM en UTM (apagar/encender la VM) y corre vpnnat up."
    fixes+=("vpnnat up")
  else
    _vpnnat_info "sin VM activa, no aplica"
  fi

  print -r -- "== 8. Conectividad =="
  local -a probes
  probes=(${(f)"$(_vpnnat_doctor_probes)"})
  if (( ! ${#probes} )); then
    _vpnnat_info "sin destinos de prueba (no hay tuneles activos)"
  else
    local p
    for p in $probes; do
      if ping -c1 -W 1500 -t 2 "$p" >/dev/null 2>&1; then
        _vpnnat_ok "host -> $p responde"
      else
        _vpnnat_bad "host -> $p NO responde (problema del VPN, no del NAT)"
        fixes+=("revisar el VPN: el host tampoco llega a $p")
      fi
      if [[ -n $VPNNAT_VM_SSH ]]; then
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$VPNNAT_VM_SSH" "ping -c1 -W2 $p" >/dev/null 2>&1; then
          _vpnnat_ok "VM  -> $p responde"
        else
          _vpnnat_bad "VM  -> $p NO responde: el NAT no esta traduciendo"
          fixes+=("vpnnat up")
        fi
      fi
    done
    [[ -n $VPNNAT_VM_SSH ]] || _vpnnat_info "define VPNNAT_VM_SSH=usuario@$VPNNAT_VM_HOST para probar desde la VM"
  fi

  print -r -- "== 9. Alcance de las reglas de tunel =="
  # Con VPNNAT_SCOPE=any la regla es `to any` y es segura solo porque un perfil
  # split-tunnel rutea unicamente lo corporativo por el tunel. Si un perfil
  # empuja una default, TODO el trafico de la VM pasaria por esa VPN, NATeado
  # como si naciera ahi, sin que nada avise.
  if [[ $VPNNAT_SCOPE == any ]] && (( ${#tuns} )); then
    local t broad
    local found=0
    for t in $tuns; do
      broad=$(_vpnnat_broad_routes $t | paste -sd, -)
      [[ -n $broad ]] || continue
      found=1
      _vpnnat_bad "$t anuncia $broad y VPNNAT_SCOPE=any ('to any')"
      _vpnnat_info "todo el trafico de la VM hacia ese rango sale por ese tunel."
      _vpnnat_info "si no es lo que querés, poné VPNNAT_SCOPE=routes para acotar"
      _vpnnat_info "el NAT a las subredes que el tunel realmente anuncia."
      fixes+=("revisar VPNNAT_SCOPE: $t anuncia $broad")
    done
    (( found )) || _vpnnat_ok "ningun tunel anuncia rutas mas amplias que /$VPNNAT_BROAD_PREFIX"
  elif [[ $VPNNAT_SCOPE != any ]]; then
    _vpnnat_ok "VPNNAT_SCOPE=$VPNNAT_SCOPE: el NAT esta acotado por tabla"
  fi

  print -r -- "== 10. Persistencia =="
  # Verificado: /System/Library/LaunchDaemons/com.apple.pfctl.plist corre
  # `pfctl -f /etc/pf.conf` con RunAtLoad pero SIN -e. En el arranque entonces
  # el anchor se carga desde disco (con el utun que quedo escrito, casi siempre
  # obsoleto) y pf queda deshabilitado. El forwarding tampoco persiste.
  local file_tuns
  file_tuns=$(grep -oE 'on utun[0-9]+' "$VPNNAT_ANCHOR_FILE" 2>/dev/null | awk '{print $2}' | sort -u)
  if _vpnnat_watch_running; then
    _vpnnat_ok "hay un watch corriendo (pid $(cat "$(_vpnnat_watch_pidfile)")): reconcilia solo"
  else
    _vpnnat_info "nada reaplica el estado automaticamente. Tras un reinicio pf queda"
    _vpnnat_info "deshabilitado, el forwarding en 0 y el anchor se carga desde disco"
    _vpnnat_info "con ${${(j:,:)${(f)file_tuns}}:-ningun utun}, que puede ya no existir."
    _vpnnat_info "Corré 'vpnnat up' tras un reinicio o una reconexion, o dejá"
    _vpnnat_info "'vpnnat watch' corriendo en una terminal."
  fi

  print -r -- "== 11. Integridad del log =="
  if [[ ! -e $VPNNAT_LOG ]]; then
    _vpnnat_info "$VPNNAT_LOG todavia no existe (se crea en el primer cambio aplicado)"
  elif [[ -L $VPNNAT_LOG ]]; then
    _vpnnat_bad "$VPNNAT_LOG es un symlink: no se escribe ahi con privilegios"
    fixes+=("revisar $VPNNAT_LOG: es un symlink")
  else
    local logperm; logperm=$(stat -f '%u %Lp' "$VPNNAT_LOG" 2>/dev/null)
    if [[ $logperm == "0 640" ]]; then
      _vpnnat_ok "$VPNNAT_LOG es root:wheel 0640"
    else
      _vpnnat_bad "$VPNNAT_LOG es uid/modo '$logperm', no '0 640':"
      _vpnnat_info "el registro de acciones privilegiadas es reescribible por su dueño"
      fixes+=("vpnnat up (endurece el log)")
    fi
  fi

  print
  if (( ${#fixes} )); then
    print -r -- "${#fixes} problema(s). Arreglos sugeridos:"
    local f
    for f in ${(u)fixes}; do print -r -- "  - $f"; done
    return 1
  fi
  print -r -- "todo en orden"
}

# Un destino de prueba por tunel: el gateway del tunel
_vpnnat_doctor_probes() {
  local t gw
  for t in ${(f)"$(_vpnnat_tunnels)"}; do
    gw=$(_vpnnat_tunnel_gw $t)
    [[ -n $gw ]] && print -r -- $gw
  done
}

# Reconciliacion silenciosa: calcula el deseado, compara con el cargado,
# aplica solo si difiere. Es lo que corre `watch` en cada vuelta.
_vpnnat_cmd_reconcile() {
  _vpnnat_need_root "reconciliar las reglas" || return 1
  local -a tuns; tuns=(${(f)"$(_vpnnat_tunnels)"})
  local nat_content
  if (( ${#tuns} )); then
    nat_content=$(_vpnnat_desired_nat 2>/dev/null) || return 1
    _vpnnat_save_corp_cache
  else
    nat_content=$(_vpnnat_desired_nat_physonly 2>/dev/null) || return 1
  fi
  local block_content; block_content=$(_vpnnat_desired_block)

  local need=0
  local cur_nat cur_block
  [[ -r $VPNNAT_ANCHOR_FILE ]] && cur_nat=$(cat "$VPNNAT_ANCHOR_FILE")
  [[ -r $VPNNAT_BLOCK_FILE ]]  && cur_block=$(cat "$VPNNAT_BLOCK_FILE")
  [[ $cur_nat == $nat_content ]] || need=1
  [[ "$(_vpnnat_desired_nat_ifaces)" == "$(_vpnnat_loaded_nat_ifaces)" ]] || need=1
  _vpnnat_pf_enabled || need=1
  _vpnnat_forwarding_on || need=1
  [[ $cur_block == $block_content ]] || need=1

  (( need )) || return 0

  _vpnnat_log "reconcile: cambio detectado (tuneles=${${(j:,:)tuns}:--} phys=$(_vpnnat_phys_iface))"
  _vpnnat_forwarding_enable
  _vpnnat_pf_enable
  if _vpnnat_write_if_changed "$VPNNAT_ANCHOR_FILE" "$nat_content" || [[ "$(_vpnnat_desired_nat_ifaces)" != "$(_vpnnat_loaded_nat_ifaces)" ]]; then
    _vpnnat_load_anchor "$VPNNAT_ANCHOR" "$VPNNAT_ANCHOR_FILE" && _vpnnat_kill_states
    _vpnnat_log "reconcile: anchor NAT aplicado -> $(print -r -- "$nat_content" | grep -c '^nat') reglas"
  fi
  if _vpnnat_write_if_changed "$VPNNAT_BLOCK_FILE" "$block_content"; then
    _vpnnat_load_anchor "$VPNNAT_BLOCK_ANCHOR" "$VPNNAT_BLOCK_FILE"
    _vpnnat_log "reconcile: anchor de bloqueo aplicado"
  fi
}

_vpnnat_watch_pidfile() { print -r -- "$VPNNAT_STATE_DIR/watch.pid" }

# El pidfile vive en /var/db y sobrevive reinicios y kill -9, asi que `kill -0`
# por si solo no alcanza: tras un reboot el PID anotado puede estar reciclado
# por un proceso cualquiera y daria un falso positivo justo cuando el usuario
# mas necesita saber que NO hay nada reconciliando.
_vpnnat_watch_running() {
  local f pid boot mtime
  f=$(_vpnnat_watch_pidfile)
  [[ -r $f ]] || return 1
  pid=$(cat "$f" 2>/dev/null)
  [[ $pid == <-> ]] || return 1
  # Un pidfile anterior al ultimo arranque es basura por definicion.
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')
  mtime=$(stat -f %m "$f" 2>/dev/null)
  if [[ -n $boot && -n $mtime ]] && (( mtime < boot )); then return 1; fi
  kill -0 "$pid" 2>/dev/null || return 1
  # Y que el proceso sea un zsh, no un PID reciclado por otra cosa.
  [[ $(ps -p "$pid" -o comm= 2>/dev/null) == *zsh* ]]
}

_vpnnat_cmd_watch() {
  _vpnnat_need_root "reconciliar en loop" || return 1
  if _vpnnat_watch_running; then
    _vpnnat_warn "ya hay un watch corriendo (pid $(cat "$(_vpnnat_watch_pidfile)"))"
    return 1
  fi
  _vpnnat_sudo mkdir -p "$VPNNAT_STATE_DIR"
  local f; f=$(_vpnnat_watch_pidfile)
  _vpnnat_refuse_symlink "$f" || return 1
  print -r -- $$ | _vpnnat_sudo tee "$f" >/dev/null

  # local_traps: `trap` dentro de una funcion es GLOBAL en zsh por defecto, asi
  # que sin esto el handler quedaria registrado en el shell interactivo del
  # usuario y correria en cada Ctrl-C posterior, incluso al cerrar la terminal.
  setopt local_options local_traps

  # Un trap INT/TERM solo corre el handler: NO termina el loop. Con el handler
  # anterior, Ctrl-C borraba el pidfile y dejaba el reconciliador corriendo
  # huerfano e invisible para doctor. De ahi el flag.
  local stop=0
  trap 'stop=1' INT TERM
  trap "_vpnnat_sudo rm -f ${(q)f}" EXIT

  _vpnnat_say "vigilando cada ${VPNNAT_POLL_INTERVAL}s (Ctrl-C para salir); log en $VPNNAT_LOG"
  _vpnnat_log "watch: iniciado (pid $$)"
  while (( ! stop )); do
    _vpnnat_cmd_reconcile
    (( stop )) && break
    sleep "$VPNNAT_POLL_INTERVAL"
  done
  _vpnnat_say "watch detenido"
  _vpnnat_log "watch: detenido (pid $$)"
}

_vpnnat_cmd_help() {
  cat <<'HELP'
vpnnat - NAT de la subred de VMs de UTM hacia los tuneles split-tunnel de Pritunl

  setup              registra los anchors en /etc/pf.conf (backup + pfctl -n)
                     y recarga pf.conf completo. Una sola vez.
  up                 detecta tuneles e interfaz fisica, genera una regla por
                     tunel mas la de la fisica, recarga SOLO el anchor,
                     habilita forwarding y pf, limpia states de la VM
  down               quita las reglas de tunel, deja la de la fisica
  status             entorno, tuneles, reglas cargadas vs deseadas, pf, forwarding
  doctor             recorre la matriz de fallas conocidas y dice que esta mal
  reconcile          como up pero silencioso e idempotente (lo usa watch)
  watch              reconcile en loop cada VPNNAT_POLL_INTERVAL segundos,
                     en primer plano. Nada reaplica el estado tras un
                     reinicio: hay que correr `up` o dejar `watch` corriendo
  log [n]            ultimas n lineas del log (root)
  help               esto

Config (arriba de vpnnat.zsh, se puede sobreescribir en ~/.zshrc despues
del source): VPNNAT_VM_SUBNETS, VPNNAT_EXPECTED_GATEWAYS, VPNNAT_SCOPE,
VPNNAT_ALLOWED_NETS, VPNNAT_BLOCK_WHEN_DOWN, VPNNAT_CORP_NETS,
VPNNAT_VM_SSH, VPNNAT_POLL_INTERVAL, VPNNAT_BROAD_PREFIX.
HELP
}

_vpnnat_cmd_log() {
  [[ -e $VPNNAT_LOG ]] || { _vpnnat_say "sin log en $VPNNAT_LOG"; return 0 }
  if [[ -r $VPNNAT_LOG ]]; then
    tail -n "${1:-40}" "$VPNNAT_LOG"
  else
    _vpnnat_need_root "leer $VPNNAT_LOG" || return 1
    _vpnnat_sudo tail -n "${1:-40}" "$VPNNAT_LOG"
  fi
}

vpnnat() {
  local cmd=${1:-status}
  shift 2>/dev/null
  case $cmd in
    setup)            _vpnnat_cmd_setup "$@" ;;
    up)               _vpnnat_cmd_up "$@" ;;
    down)             _vpnnat_cmd_down "$@" ;;
    status|st)        _vpnnat_cmd_status "$@" ;;
    doctor|dr)        _vpnnat_cmd_doctor "$@" ;;
    reconcile)        _vpnnat_cmd_reconcile "$@" ;;
    watch)            _vpnnat_cmd_watch "$@" ;;
    log)              _vpnnat_cmd_log "$@" ;;
    help|-h|--help)   _vpnnat_cmd_help ;;
    *) _vpnnat_warn "comando desconocido: $cmd"; _vpnnat_cmd_help; return 1 ;;
  esac
}
