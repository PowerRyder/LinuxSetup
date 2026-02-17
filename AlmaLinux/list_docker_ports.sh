#!/bin/bash
# List occupied ports - Docker only or all system ports

echo "=========================================="
echo "  Occupied Ports Viewer"
echo "=========================================="
echo ""
echo "  1) Docker container ports only"
echo "  2) All system listening ports"
echo ""

while true; do
    read -p "Choice [1-2]: " CHOICE
    if [[ "$CHOICE" == "1" || "$CHOICE" == "2" ]]; then
        break
    fi
    echo "Invalid choice. Try again."
done

echo ""

# ==================================================
# Option 1: Docker container ports
# ==================================================
if [[ "$CHOICE" == "1" ]]; then
    echo "=========================================="
    echo "  Docker Container Host Ports"
    echo "=========================================="
    echo ""

    # Extract host ports from docker ps, sort numerically, deduplicate
    PORTS=$(docker ps --format '{{.Ports}}' \
        | grep -oP '(\d+\.\d+\.\d+\.\d+|\[::\]):(\K\d+)(?=->)' \
        | sort -n -u)

    if [[ -z "$PORTS" ]]; then
        echo "No host port mappings found."
        exit 0
    fi

    printf "%-10s  %-50s  %s\n" "PORT" "CONTAINER" "IMAGE"
    echo "----------  --------------------------------------------------  --------------------------------------------------"

    for port in $PORTS; do
        while IFS= read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            image=$(echo "$line" | awk '{print $2}')
            printf "%-10s  %-50s  %s\n" "$port" "$name" "$image"
        done < <(docker ps --format '{{.Names}} {{.Image}}' --filter "publish=$port")
    done

    echo ""
    echo "Total unique host ports: $(echo "$PORTS" | wc -l)"

# ==================================================
# Option 2: All system listening ports
# ==================================================
else
    echo "=========================================="
    echo "  All System Listening Ports"
    echo "=========================================="
    echo ""

    printf "%-8s  %-6s  %-25s  %s\n" "PORT" "TYPE" "ADDRESS" "PROCESS"
    echo "--------  ------  -------------------------  ----------------------------------------"

    ss -tulnp 2>/dev/null | awk 'NR > 1 {
        proto = ($1 == "tcp") ? "TCP" : "UDP"
        addr = $5

        # Extract port from address (last :port)
        n = split(addr, parts, ":")
        port = parts[n]

        # Extract process name from "users:((...))" field
        pname = "-"
        if (match($0, /users:\(\(\"([^"]+)\"/, m)) {
            pname = m[1]
        }

        printf "%s\t%s\t%s\t%s\n", port, proto, addr, pname
    }' | sort -t$'\t' -k1,1n -k2,2 | uniq | while IFS=$'\t' read -r port proto addr pname; do
        printf "%-8s  %-6s  %-25s  %s\n" "$port" "$proto" "$addr" "$pname"
    done

    echo ""
    echo "Total unique ports: $(ss -tulnp 2>/dev/null | awk 'NR > 1 { n=split($5,p,":"); print p[n] }' | sort -n -u | wc -l)"
fi
