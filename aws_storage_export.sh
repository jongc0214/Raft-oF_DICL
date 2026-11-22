    fi
    # Refuse to change any exported namespace while a controller is connected.
    for ss in "$base"/subsystems/node{11..19}; do
        [[ -d "$ss" ]] || continue
        if [[ -d "$ss/allowed_hosts" ]] && find "$ss/allowed_hosts" -mindepth 1 -maxdepth 1 | grep -q .; then
            echo "ERROR: unexpected host ACL under $ss" >&2; exit 1
        fi
        for p in "$base"/ports/*/subsystems/"${ss##*/}"; do
            [[ -L "$p" ]] && rm "$p"
        done
        for ns in "$ss"/namespaces/*; do
            [[ -d "$ns" ]] || continue
            [[ -e "$ns/enable" ]] && echo 0 > "$ns/enable"
            rmdir "$ns"
        done
        rmdir "$ss"
        echo "Removed export ${ss##*/}"
    done
    # Keep port/1 when already configured; 'up' checks IP/port consistency.
    echo 'Raft-oF exports removed (SSD contents unchanged)'
    exit 0
fi

if [[ "$ACTION" == up ]]; then
    if [[ ! -d "$port" ]]; then
        mkdir "$port"
        echo tcp > "$port/addr_trtype"
        echo ipv4 > "$port/addr_adrfam"
        echo "${STORAGE_IP[$my_storage]}" > "$port/addr_traddr"
        echo "$NVME_PORT" > "$port/addr_trsvcid"
    else
        [[ "$(cat "$port/addr_trtype")" == tcp && \
           "$(cat "$port/addr_traddr")" == "${STORAGE_IP[$my_storage]}" && \
           "$(cat "$port/addr_trsvcid")" == "$NVME_PORT" ]] || {
            echo 'ERROR: existing nvmet port conflicts with topology' >&2; exit 1;
        }
    fi
fi

for id in $NODES; do
    [[ "$(aws_owner_for_id "$id")" == "$my_storage" ]] || continue
    dev="$(aws_local_device_for_id "$id")"
    [[ -b "$dev" ]] || { echo "ERROR: missing block device: $dev" >&2; exit 1; }
    real="$(readlink -f "$dev")"
    model="$(lsblk -dn -o MODEL "$real" | xargs)"
    [[ "$model" == *'Instance Storage'* ]] || {
        echo "ERROR: refusing non-Instance-Store device $dev ($model)" >&2; exit 1;
    }
    [[ -z "$(lsblk -nr -o MOUNTPOINTS "$real" | sed '/^$/d')" ]] || {
        echo "ERROR: $dev is mounted" >&2; exit 1;
    }
    nqn="node$id"; ss="$base/subsystems/$nqn"
    if [[ "$ACTION" == status ]]; then
        echo "$nqn -> $dev [$my_storage]"; continue
    fi
    if [[ -d "$ss" ]]; then
        old="$(cat "$ss/namespaces/1/device_path" 2>/dev/null || true)"
        [[ -n "$old" && "$(readlink -f "$old")" == "$real" ]] || {
            echo "ERROR: $nqn existing export maps to a different disk" >&2; exit 1;
        }
    else
        mkdir "$ss"
        echo 1 > "$ss/attr_allow_any_host"
        mkdir "$ss/namespaces/1"
        echo "$dev" > "$ss/namespaces/1/device_path"
        echo 1 > "$ss/namespaces/1/enable"
    fi
    [[ -L "$port/subsystems/$nqn" ]] || ln -s "$ss" "$port/subsystems/$nqn"
    echo "Exported $nqn -> $dev at ${STORAGE_IP[$my_storage]}:$NVME_PORT"
done
