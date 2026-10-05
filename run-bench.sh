#!/usr/bin/env bash
# Прогон матрицы сетевых тестов в кластере. Совместим с bash 3.2 (macOS).
#
#   CLUSTER=selectel-bm ./run-bench.sh
#   CLUSTER=yandex-vm   ./run-bench.sh
#   LABEL=netpol SCENARIOS="pod-cross svc" CLUSTER=selectel-bm ./run-bench.sh
#
# Тесты запускаются ВНУТРИ подов в фоне, kubectl только опрашивает завершение,
# поэтому длинные тесты не рвутся по idle-таймаутам API и kubectl не влияет на замер.
set -euo pipefail

NS=${NS:-netbench}
CLUSTER=${CLUSTER:?"задайте CLUSTER, например CLUSTER=selectel-bm"}
LABEL=${LABEL:-baseline}
DUR=${DUR:-60}
OMIT=${OMIT:-5}
REPEATS=${REPEATS:-5}
PARALLEL=${PARALLEL:-8}
PAUSE=${PAUSE:-5}
SCENARIOS=${SCENARIOS:-"host pod-cross pod-local svc"}
TESTS=${TESTS:-"tcp-1 tcp-n tcp-n-rev tcp-n-bidir udp-mtu udp-64 rr crr"}
OUT=${OUT:-results/${CLUSTER}/${LABEL}-$(date +%Y%m%d-%H%M%S)}

mkdir -p "$OUT"/env "$OUT"/raw "$OUT"/cpu "$OUT"/counters

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ОШИБКА: $*"; exit 1; }
trap 'log "Сбой на строке $LINENO: $BASH_COMMAND"' ERR
kx()  { local pod=$1; shift; kubectl -n "$NS" exec "$pod" -- "$@"; }
jp()  { kubectl -n "$NS" get "$1" "$2" -o jsonpath="$3"; }

#фоновый запуск внутри пода
SEQ=0
bg_start() { # pod "command" -> печатает id
  local pod=$1 cmd=$2 id
  SEQ=$((SEQ + 1)); id="/tmp/nb.$$.$SEQ"
  kx "$pod" sh -c "rm -f $id.*; ( $cmd > $id.out 2> $id.err; echo \$? > $id.done ) </dev/null >/dev/null 2>&1 &"
  echo "$id"
}
bg_wait() { # pod id timeout_s
  local pod=$1 id=$2 t=${3:-600} s=0
  until kx "$pod" test -f "$id.done" 2>/dev/null; do
    sleep 2; s=$((s + 2))
    [ "$s" -lt "$t" ] || { log "  таймаут: $pod $id"; return 1; }
  done
}
bg_fetch() { kx "$1" cat "$2.out"; }
bg_rc()    { kx "$1" cat "$2.done" 2>/dev/null || echo "?"; }

#параметры сценариев
sc_cli()   { case $1 in host) echo cli-host;; pod-local) echo cli-local;; *) echo cli-pod;; esac; }
sc_tgt()   { case $1 in host) echo "$NODE_A_IP";; svc) echo "$SVC_IP";; *) echo "$SRV_POD_IP";; esac; }
sc_iport() { case $1 in host) echo 15201;; *) echo 5201;; esac; }
sc_nctl()  { case $1 in host) echo 22865;; *) echo 12865;; esac; }
sc_ndata() { case $1 in host) echo 22866;; *) echo 12866;; esac; }

iperf_args() {
  case $1 in
    tcp-1)       echo "-P 1";;
    tcp-n)       echo "-P $PARALLEL";;
    tcp-n-rev)   echo "-P $PARALLEL -R";;
    tcp-n-bidir) echo "-P $PARALLEL --bidir";;
    udp-mtu)     echo "-u -b 0 -l $UDP_LEN -P 4";;
    udp-64)      echo "-u -b 0 -l 64 -P 4";;
    *) die "неизвестный тест $1";;
  esac
}

#предпроверки
log "Жду готовности подов в $NS"
kubectl -n "$NS" wait --for=condition=Ready \
  pod/srv-pod pod/srv-host pod/cli-pod pod/cli-local pod/cli-host --timeout=300s >/dev/null

NODE_A=$(jp pod srv-pod '{.spec.nodeName}')
NODE_B=$(jp pod cli-pod '{.spec.nodeName}')
[ "$NODE_A" != "$NODE_B" ]                              || die "srv-pod и cli-pod на одной ноде"
[ "$(jp pod cli-local '{.spec.nodeName}')" = "$NODE_A" ] || die "cli-local не на ноде A"
[ "$(jp pod srv-host  '{.spec.nodeName}')" = "$NODE_A" ] || die "srv-host не на ноде A"
[ "$(jp pod cli-host  '{.spec.nodeName}')" = "$NODE_B" ] || die "cli-host не на ноде B"

SRV_POD_IP=$(jp pod srv-pod '{.status.podIP}')
CLI_POD_IP=$(jp pod cli-pod '{.status.podIP}')
NODE_A_IP=$(jp pod srv-host '{.status.podIP}')
NODE_B_IP=$(jp pod cli-host '{.status.podIP}')
SVC_IP=$(jp svc srv-svc '{.spec.clusterIP}')
POD_MTU=$(kx cli-pod cat /sys/class/net/eth0/mtu)
UDP_LEN=$((POD_MTU - 28))
ZONE_A=$(jp node "$NODE_A" '{.metadata.labels.topology\.kubernetes\.io/zone}' || true)
ZONE_B=$(jp node "$NODE_B" '{.metadata.labels.topology\.kubernetes\.io/zone}' || true)
[ "$ZONE_A" = "$ZONE_B" ] || log "ВНИМАНИЕ: ноды в разных зонах ($ZONE_A / $ZONE_B)"

cat > "$OUT/env/summary.env" <<EOF
CLUSTER=$CLUSTER
LABEL=$LABEL
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NODE_A=$NODE_A
NODE_B=$NODE_B
ZONE_A=$ZONE_A
ZONE_B=$ZONE_B
NODE_A_IP=$NODE_A_IP
NODE_B_IP=$NODE_B_IP
SRV_POD_IP=$SRV_POD_IP
CLI_POD_IP=$CLI_POD_IP
SVC_IP=$SVC_IP
POD_MTU=$POD_MTU
UDP_LEN=$UDP_LEN
DUR=$DUR
OMIT=$OMIT
REPEATS=$REPEATS
PARALLEL=$PARALLEL
EOF

#сбор окружения
log "Собираю описание стенда в $OUT/env"
E="$OUT/env"
kubectl version -o yaml                       > "$E/k8s-version.yaml" 2>&1 || true
kubectl get nodes -o wide                      > "$E/nodes.txt" 2>&1 || true
kubectl get node "$NODE_A" "$NODE_B" -o yaml   > "$E/nodes-ab.yaml" 2>&1 || true
for r in ippools.crd.projectcalico.org felixconfigurations.crd.projectcalico.org \
         bgpconfigurations.crd.projectcalico.org installations.operator.tigera.io; do
  kubectl get "$r" -o yaml > "$E/${r%%.*}.yaml" 2>&1 || true
done
kubectl -n kube-system get cm calico-config -o yaml > "$E/calico-config.yaml" 2>&1 || true
kubectl -n kube-system get cm kube-proxy    -o yaml > "$E/kube-proxy.yaml"    2>&1 || true
kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE_A" > "$E/pods-on-node-a.txt" 2>&1 || true
kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE_B" > "$E/pods-on-node-b.txt" 2>&1 || true
kx srv-host nb-hostinfo > "$E/host-a.txt" 2>&1 || true
kx cli-host nb-hostinfo > "$E/host-b.txt" 2>&1 || true
for p in srv-pod cli-pod; do
  kx "$p" sh -c 'ip -d link show eth0; ip addr show eth0; ip route' > "$E/pod-$p.txt" 2>&1 || true
done
{ kx srv-host iperf3 --version; kx srv-host netperf -V; kx srv-host mpstat -V; } > "$E/tools.txt" 2>&1 || true

#Какие интерфейсы считать физическими (для мониторинга)
PHYS_A=$(kx srv-host sh -c 'for d in /sys/class/net/*; do [ -e $d/device ] || continue; basename $d; done' | xargs)
PHYS_B=$(kx cli-host sh -c 'for d in /sys/class/net/*; do [ -e $d/device ] || continue; basename $d; done' | xargs)
UPLINK_A=$(kx srv-host sh -c "ip route get $NODE_B_IP | grep -o 'dev [^ ]*' | cut -d' ' -f2")
echo "PHYS_A=$PHYS_A"     >> "$E/summary.env"
echo "PHYS_B=$PHYS_B"     >> "$E/summary.env"
echo "UPLINK_A=$UPLINK_A" >> "$E/summary.env"

# Проверка пути: что реально летит по аплинку (IPIP = proto 4, VXLAN = udp 4789,
# голые IP подов = native routing)
log "Проверка пути трафика (tcpdump на $UPLINK_A ноды A)"
TD=$(bg_start srv-host "timeout 20 tcpdump -i $UPLINK_A -nn -v -c 30 host $NODE_B_IP or host $CLI_POD_IP")
sleep 2
kx cli-pod iperf3 -c "$SRV_POD_IP" -p 5201 -t 3 >/dev/null 2>&1 || true
bg_wait srv-host "$TD" 40 || true
bg_fetch srv-host "$TD" > "$E/path-check-tcpdump.txt" 2>/dev/null || true
kx srv-host cat "$TD.err" >> "$E/path-check-tcpdump.txt" 2>/dev/null || true

# Фоновая загрузка CPU нод без теста (вычитается в сводке)
log "Замер фоновой загрузки CPU (15 c)"
IA=$(bg_start srv-host "mpstat -P ALL -o JSON 1 15")
IB=$(bg_start cli-host "mpstat -P ALL -o JSON 1 15")
bg_wait srv-host "$IA" 60 || true; bg_wait cli-host "$IB" 60 || true
bg_fetch srv-host "$IA" > "$E/idle__a.json" 2>/dev/null || true
bg_fetch cli-host "$IB" > "$E/idle__b.json" 2>/dev/null || true

# --- один тест --------------------------------------------------------------------
snap() { # tag
  kx srv-host nb-counters > "$OUT/counters/$1-srv-host.txt" 2>/dev/null || true
  kx cli-host nb-counters > "$OUT/counters/$1-cli-host.txt" 2>/dev/null || true
}

run_one() { # scenario test rep
  local sc=$1 t=$2 r=$3
  local cli tgt name ext cmd tt ma mb c rc
  cli=$(sc_cli "$sc"); tgt=$(sc_tgt "$sc"); name="${sc}__${t}__r${r}"
  case $t in
    rr|crr)
      tt=TCP_RR; [ "$t" = crr ] && tt=TCP_CRR
      ext=txt
      cmd="netperf -H $tgt -p $(sc_nctl "$sc") -l $DUR -t $tt -P 0 -- -P ,$(sc_ndata "$sc") -r 1,1 \
-k MIN_LATENCY,MEAN_LATENCY,P50_LATENCY,P90_LATENCY,P99_LATENCY,MAX_LATENCY,THROUGHPUT,THROUGHPUT_UNITS";;
    *)
      ext=json
      cmd="iperf3 -c $tgt -p $(sc_iport "$sc") -t $DUR -O $OMIT -J $(iperf_args "$t")";;
  esac

  snap "${name}__before"
  ma=$(bg_start srv-host "mpstat -P ALL -o JSON 1 $((DUR + OMIT))")
  mb=$(bg_start cli-host "mpstat -P ALL -o JSON 1 $((DUR + OMIT))")
  c=$(bg_start "$cli" "$cmd")
  bg_wait "$cli" "$c" $((DUR + OMIT + 120)) || true
  bg_fetch "$cli" "$c" > "$OUT/raw/$name.$ext" 2>/dev/null || true
  rc=$(bg_rc "$cli" "$c")
  bg_wait srv-host "$ma" 60 || true
  bg_wait cli-host "$mb" 60 || true
  bg_fetch srv-host "$ma" > "$OUT/cpu/${name}__a.json" 2>/dev/null || true
  bg_fetch cli-host "$mb" > "$OUT/cpu/${name}__b.json" 2>/dev/null || true
  snap "${name}__after"
  if [ "$rc" != 0 ]; then
    kx "$cli" cat "$c.err" > "$OUT/raw/$name.err" 2>/dev/null || true
    log "  ! код $rc, см. raw/$name.*"
  fi
}

# матрица
# Повторы — внешний цикл: сценарии чередуются, и дрейф нагрузки во времени
# распределяется по всем сценариям
n_sc=$(echo $SCENARIOS | wc -w | tr -d ' ')
n_t=$(echo $TESTS | wc -w | tr -d ' ')
total=$((n_sc * n_t * REPEATS))
log "Тестов: $total, примерно $(( total * (DUR + OMIT + PAUSE + 15) / 60 )) мин. Результаты: $OUT"

i=0
for r in $(seq 1 "$REPEATS"); do
  for sc in $SCENARIOS; do
    for t in $TESTS; do
      i=$((i + 1))
      log "[$i/$total] $sc / $t / прогон $r"
      run_one "$sc" "$t" "$r"
      sleep "$PAUSE"
    done
  done
done

log "Готово. Сводка: ./summarize.py $OUT"
